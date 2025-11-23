//
//  SimulatorDevice.swift
//  XCode Devices
//
//  Created by Ivan Stepanok on 22.11.2025.
//

import AppKit
import Combine
import Foundation

struct SimulatorApp: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let path: URL
    let icon: URL?
    let sizeBytes: Int64

    var sizeDescription: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}

struct SimulatorDevice: Identifiable, Hashable {
    let id: String
    let name: String
    let deviceType: String
    let runtime: String
    let runtimeGroup: String
    let category: DeviceCategory
    let udid: String
    let state: Int
    let lastBootedAt: Date?
    let lastModifiedAt: Date?
    let sizeBytes: Int64
    let apps: [SimulatorApp]
    let rootPath: URL
    let isDefault: Bool

    var appCount: Int { apps.count }
    var lastUsed: Date? { lastBootedAt }
    var lastUsedSortKey: Date { lastUsed ?? .distantPast }
    var sizeDescription: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
    var lastUsedDescription: String {
        guard let lastUsed else { return "Never launched" }
        return RelativeDateTimeFormatter.shared.localizedString(for: lastUsed, relativeTo: .now)
    }
}

enum DeviceCategory: String, CaseIterable, Identifiable {
    case iPhone
    case iPad
    case Watch
    case TV
    case Vision
    case Other

    var id: String { rawValue }

    static let ordered: [DeviceCategory] = [.iPhone, .iPad, .Watch, .TV, .Vision, .Other]

    static func from(deviceType: String) -> DeviceCategory {
        let lower = deviceType.lowercased()
        if lower.contains("iphone") { return .iPhone }
        if lower.contains("ipad") { return .iPad }
        if lower.contains("watch") { return .Watch }
        if lower.contains("appletv") || lower.contains("tv") { return .TV }
        if lower.contains("vision") { return .Vision }
        return .Other
    }

    var title: String {
        switch self {
        case .iPhone: return "iPhone"
        case .iPad: return "iPad"
        case .Watch: return "Apple Watch"
        case .TV: return "Apple TV"
        case .Vision: return "Vision Pro"
        case .Other: return "Other"
        }
    }
}

@MainActor
final class DeviceScanner: ObservableObject {
    @Published var devices: [SimulatorDevice] = []
    @Published var totalSizeBytes: Int64 = 0
    @Published var diskTotalBytes: Int64 = 0
    @Published var diskAvailableBytes: Int64 = 0
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    @Published var devicesURL: URL
    @Published var hasFolderAccess: Bool = false

    private var activeSecurityScopedURL: URL?

    private static let devicesBookmarkKey = "SimulatorDevicesDirectoryBookmark"
    private static var defaultDevicesURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Developer/CoreSimulator/Devices")
    }

    init(devicesURL: URL? = nil) {
        if let bookmarked = DeviceScanner.restoreBookmarkedURL() {
            self.devicesURL = bookmarked
            if beginAccessing(url: bookmarked, securityScoped: true) {
                print("DeviceScanner init: restored bookmarked URL \(bookmarked.path)")
            } else {
                print("DeviceScanner init: failed to access bookmarked URL \(bookmarked.path)")
            }
        } else {
            let resolved = devicesURL ?? DeviceScanner.defaultDevicesURL
            self.devicesURL = resolved
            print("DeviceScanner init: using default URL \(resolved.path)")
        }
    }

    func refresh() {
        let scanURL = devicesURL
        isLoading = true
        errorMessage = nil

        Task.detached(priority: .userInitiated) { [scanURL] in
            do {
                let result = try DeviceScanner.loadDevices(at: scanURL)
                let disk = DeviceScanner.fetchDiskInfo(for: scanURL)
                await MainActor.run {
                    self.devices = result.devices
                    self.totalSizeBytes = result.totalSizeBytes
                    self.diskTotalBytes = disk.total
                    self.diskAvailableBytes = disk.available
                    self.isLoading = false
                }
            } catch {
                await MainActor.run {
                    self.devices = []
                    self.totalSizeBytes = 0
                    self.diskTotalBytes = 0
                    self.diskAvailableBytes = 0
                    self.errorMessage = error.localizedDescription
                    self.isLoading = false
                }
            }
        }
    }

    func delete(device: SimulatorDevice) async {
        await delete(devices: [device])
    }

    func delete(devices: [SimulatorDevice]) async {
        guard !devices.isEmpty else { return }
        errorMessage = nil
        isLoading = true
        let udids = devices.map(\.udid)
        let scanURL = devicesURL
        print("Delete requested for \(udids.joined(separator: ",")) at path \(scanURL.path)")

        do {
            let result = try await Task.detached(priority: .userInitiated) { [scanURL, udids] in
                try DeviceScanner.performDelete(udids: udids, devicesRoot: scanURL)
                return try DeviceScanner.loadDevices(at: scanURL)
            }.value

            self.devices = result.devices
            self.totalSizeBytes = result.totalSizeBytes
            let disk = DeviceScanner.fetchDiskInfo(for: scanURL)
            self.diskTotalBytes = disk.total
            self.diskAvailableBytes = disk.available
            self.isLoading = false
        } catch {
            self.errorMessage = error.localizedDescription
            self.isLoading = false
        }
    }

    func chooseDevicesDirectory() {
        let panel = NSOpenPanel()
        panel.title = "Allow access to the simulator devices folder"
        panel.message = "The app needs permission to read the Xcode simulator data."
        panel.directoryURL = devicesURL
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use This Folder"

        let response = panel.runModal()
        guard response == .OK, let url = panel.url else {
            hasFolderAccess = false
            print("User cancelled folder selection")
            return
        }

        let granted = beginAccessing(url: url, securityScoped: true)
        hasFolderAccess = granted
        if granted {
            DeviceScanner.saveBookmark(for: url)
            print("User selected devices folder: \(url.path)")
            devicesURL = url
            refresh()
        } else {
            print("Failed to start security scoped access for \(url.path)")
        }
    }

    nonisolated static func loadDevices(at url: URL) throws -> (devices: [SimulatorDevice], totalSizeBytes: Int64) {
        let fm = FileManager.default

        guard fm.fileExists(atPath: url.path) else {
            throw NSError(domain: "DeviceScanner", code: 1, userInfo: [NSLocalizedDescriptionKey: "Devices directory not found at \(url.path)."])
        }

        let entries: [URL]
        do {
            entries = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        } catch {
            throw NSError(domain: "DeviceScanner", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to read devices directory at \(url.path): \(error.localizedDescription)"])
        }

        let defaultSet = loadDefaultDeviceUDIDs(at: url)

        var devices: [SimulatorDevice] = []
        var totalSize: Int64 = 0

        for entry in entries {
            guard entry.isDirectory else { continue }
            do {
                let device = try buildDevice(at: entry, defaultDeviceUDIDs: defaultSet)
                devices.append(device)
                totalSize += device.sizeBytes
            } catch {
                // Skip unreadable devices but keep scanning the rest.
                continue
            }
        }

        return (devices, totalSize)
    }

    private nonisolated static func buildDevice(at url: URL, defaultDeviceUDIDs: Set<String>) throws -> SimulatorDevice {
        let plistURL = url.appending(path: "device.plist")
        let fm = FileManager.default
        guard let data = fm.contents(atPath: plistURL.path) else {
            throw NSError(domain: "DeviceScanner", code: 2, userInfo: [NSLocalizedDescriptionKey: "device.plist missing in \(url.lastPathComponent)."])
        }

        var format = PropertyListSerialization.PropertyListFormat.binary
        guard let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: &format) as? [String: Any] else {
            throw NSError(domain: "DeviceScanner", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to parse device.plist in \(url.lastPathComponent)."])
        }

        guard let udid = plist["UDID"] as? String else {
            throw NSError(domain: "DeviceScanner", code: 4, userInfo: [NSLocalizedDescriptionKey: "UDID missing in device.plist for \(url.lastPathComponent)."])
        }

        let name = plist["name"] as? String ?? "Unnamed"
        let deviceTypeRaw = plist["deviceType"] as? String ?? ""
        let runtimeRaw = plist["runtime"] as? String ?? ""
        let lastBootedAtPlist = plist["lastBootedAt"] as? Date
        let state = (plist["state"] as? NSNumber)?.intValue ?? 0

        let runtime = friendlyRuntime(runtimeRaw)
        let deviceType = friendlyDeviceType(deviceTypeRaw, fallback: name)
        let runtimeGroup = buildRuntimeGroup(runtimeRaw)
        let category = DeviceCategory.from(deviceType: deviceTypeRaw)

        let (apps, lastAppChange) = fetchInstalledApps(at: url)
        let sizeBytes = directorySize(at: url)

        let dataURL = url.appending(path: "data")
        let lastModified = dataURL.contentModificationDate ?? url.contentModificationDate ?? lastAppChange
        let isDefault = defaultDeviceUDIDs.contains(udid)

        let stateLastBooted = fetchStateLastBooted(at: url)
        let lastBootedAt = lastBootedAtPlist ?? stateLastBooted

        return SimulatorDevice(
            id: udid,
            name: name,
            deviceType: deviceType,
            runtime: runtime,
            runtimeGroup: runtimeGroup,
            category: category,
            udid: udid,
            state: state,
            lastBootedAt: lastBootedAt,
            lastModifiedAt: lastModified,
            sizeBytes: sizeBytes,
            apps: apps,
            rootPath: url,
            isDefault: isDefault
        )
    }

    private nonisolated static func loadDefaultDeviceUDIDs(at devicesRoot: URL) -> Set<String> {
        let plistURL = devicesRoot.appending(path: "device_set.plist")
        guard let data = try? Data(contentsOf: plistURL) else { return [] }
        var format = PropertyListSerialization.PropertyListFormat.binary
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: &format) as? [String: Any],
              let defaults = plist["DefaultDevices"] as? [String: Any] else { return [] }

        var udids = Set<String>()
        for (_, runtimeValue) in defaults {
            guard let runtimeDict = runtimeValue as? [String: Any] else { continue }
            for (key, value) in runtimeDict where key != "version" {
                if let udid = value as? String {
                    udids.insert(udid)
                }
            }
        }
        return udids
    }

    private nonisolated static func performDelete(udid: String, devicesRoot: URL) throws {
        try performDelete(udids: [udid], devicesRoot: devicesRoot)
    }

    private nonisolated static func performDelete(udids: [String], devicesRoot: URL) throws {
        guard !udids.isEmpty else { return }
        print("performDelete launching xcrun simctl delete for: \(udids)")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "delete"] + udids

        let errorPipe = Pipe()
        let outputPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = outputPipe

        try process.run()
        process.waitUntilExit()

        let stdoutData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""
        print("simctl delete stdout: \(stdout.trimmingCharacters(in: .whitespacesAndNewlines))")
        print("simctl delete stderr: \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))")
        print("simctl delete exit code: \(process.terminationStatus)")

        if process.terminationStatus != 0 {
            let sandboxBlocked = stderr.lowercased().contains("sandbox")
            if sandboxBlocked {
                print("simctl blocked by sandbox, attempting manual removal of device folders")
                try deleteDeviceFolders(udids: udids, devicesRoot: devicesRoot)
                return
            }
            let message = stderr.isEmpty ? "Unknown error" : stderr
            let ids = udids.joined(separator: ", ")
            throw NSError(
                domain: "DeviceScanner",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "Failed to delete simulator(s) \(ids): \(message.trimmingCharacters(in: .whitespacesAndNewlines))"]
            )
        }
    }

    private nonisolated static func deleteDeviceFolders(udids: [String], devicesRoot: URL) throws {
        let fm = FileManager.default
        var errors: [String] = []
        for udid in udids {
            let url = devicesRoot.appending(path: udid)
            guard fm.fileExists(atPath: url.path) else {
                print("Device folder not found for \(udid) at \(url.path)")
                continue
            }
            do {
                try fm.removeItem(at: url)
                print("Removed device folder at \(url.path)")
            } catch {
                let message = error.localizedDescription
                errors.append("\(udid): \(message)")
                print("Failed to remove device folder for \(udid): \(message)")
            }
        }
        if !errors.isEmpty {
            throw NSError(
                domain: "DeviceScanner",
                code: 6,
                userInfo: [NSLocalizedDescriptionKey: "Manual delete errors: \(errors.joined(separator: "; "))"]
            )
        }
    }

    private nonisolated static func fetchInstalledApps(at url: URL) -> ([SimulatorApp], Date?) {
        let appRoot = url.appending(path: "data/Containers/Bundle/Application")
        let fm = FileManager.default
        guard let containers = try? fm.contentsOfDirectory(at: appRoot, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) else {
            return ([], nil)
        }

        var apps: [SimulatorApp] = []
        var newestDate: Date?

        for container in containers where container.isDirectory {
            guard let bundles = try? fm.contentsOfDirectory(at: container, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) else { continue }

            for bundle in bundles where bundle.pathExtension == "app" {
                let name = bundle.deletingPathExtension().lastPathComponent
                let icon = findAppIcon(in: bundle)
                let size = directorySize(at: bundle)
                apps.append(SimulatorApp(name: name, path: bundle, icon: icon, sizeBytes: size))

                if let mod = bundle.contentModificationDate, let currentNewest = newestDate {
                    if mod > currentNewest { newestDate = mod }
                } else if newestDate == nil {
                    newestDate = bundle.contentModificationDate
                }
            }
        }

        return (apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }, newestDate)
    }

    private nonisolated static func friendlyRuntime(_ runtime: String) -> String {
        guard let suffix = runtime.split(separator: ".").last else { return runtime }
        let parts = suffix.split(separator: "-")
        guard parts.count >= 2 else { return String(suffix) }

        let platformRaw = parts[0].lowercased()
        let platform: String
        switch platformRaw {
        case "ios": platform = "iOS"
        case "tvos": platform = "tvOS"
        case "watchos": platform = "watchOS"
        case "visionos": platform = "visionOS"
        default: platform = platformRaw.capitalized
        }

        let version = parts.dropFirst().joined(separator: ".")
        return "\(platform) \(version)"
    }

    private nonisolated static func buildRuntimeGroup(_ runtimeRaw: String) -> String {
        // Input raw like "com.apple.CoreSimulator.SimRuntime.iOS-26-1"
        let friendly = friendlyRuntime(runtimeRaw) // e.g., "iOS 26.1"
        let components = friendly.split(separator: " ")
        guard components.count >= 2 else { return friendly }
        let platform = components[0]
        let version = components[1]

        let parts = version.split(separator: ".")
        if parts.count >= 2 {
            return "\(platform) \(parts[0]).\(parts[1])"
        } else if let first = parts.first {
            return "\(platform) \(first)"
        } else {
            return friendly
        }
    }

    private nonisolated static func friendlyDeviceType(_ deviceType: String, fallback: String) -> String {
        guard let suffix = deviceType.split(separator: ".").last else { return fallback }
        return suffix.replacingOccurrences(of: "-", with: " ")
    }

    private nonisolated static func directorySize(at url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey], options: [.skipsHiddenFiles]) else {
            return 0
        }

        var size: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
            guard values?.isRegularFile == true else { continue }
            size += Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
        }
        return size
    }

    private nonisolated static func findAppIcon(in bundle: URL) -> URL? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: bundle, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles]) else {
            return nil
        }

        var bestIcon: (url: URL, size: Int64) = (bundle, -1)

        for case let fileURL as URL in enumerator {
            let name = fileURL.lastPathComponent.lowercased()
            guard name.hasPrefix("appicon"), fileURL.pathExtension.lowercased() == "png" else { continue }
            let values = try? fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }
            let fileSize = Int64(values?.fileSize ?? 0)
            if fileSize > bestIcon.size {
                bestIcon = (fileURL, fileSize)
            }
        }

        return bestIcon.size > 0 ? bestIcon.url : nil
    }

    private nonisolated static func fetchStateLastBooted(at deviceURL: URL) -> Date? {
        let plistURL = deviceURL.appending(path: "state.plist")
        guard let data = try? Data(contentsOf: plistURL) else { return nil }
        var format = PropertyListSerialization.PropertyListFormat.binary
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: &format) as? [String: Any] else { return nil }
        return plist["lastBootedAt"] as? Date
    }

    nonisolated static func fetchDiskInfo(for path: URL) -> (total: Int64, available: Int64) {
        let fm = FileManager.default
        guard let values = try? fm.attributesOfFileSystem(forPath: path.path) else {
            return (0, 0)
        }

        let total = (values[.systemSize] as? NSNumber)?.int64Value ?? 0
        let free = (values[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        return (total, free)
    }

    @discardableResult
    private func beginAccessing(url: URL, securityScoped: Bool) -> Bool {
        activeSecurityScopedURL?.stopAccessingSecurityScopedResource()
        activeSecurityScopedURL = nil
        guard securityScoped else {
            hasFolderAccess = true
            return true
        }
        if url.startAccessingSecurityScopedResource() {
            activeSecurityScopedURL = url
            hasFolderAccess = true
            print("Started security scoped access for \(url.path)")
            return true
        } else {
            print("Failed to start security scoped access for \(url.path)")
            hasFolderAccess = false
            return false
        }
    }

    private nonisolated static func restoreBookmarkedURL() -> URL? {
        guard let data = UserDefaults.standard.data(forKey: devicesBookmarkKey) else { return nil }
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            if isStale {
                UserDefaults.standard.removeObject(forKey: devicesBookmarkKey)
                return nil
            }
            return url
        } catch {
            return nil
        }
    }

    private nonisolated static func saveBookmark(for url: URL) {
        guard let data = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) else {
            return
        }
        UserDefaults.standard.set(data, forKey: devicesBookmarkKey)
    }

    private nonisolated static func clearBookmark() {
        UserDefaults.standard.removeObject(forKey: devicesBookmarkKey)
    }
}

private extension URL {
    var isDirectory: Bool {
        (try? resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }

    var contentModificationDate: Date? {
        try? resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}

private extension DateFormatter {
    static let shortDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}

private extension RelativeDateTimeFormatter {
    static let shared: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()
}
