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
    var sizeDescription: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
    var lastUsedDescription: String {
        guard let lastUsed else { return "Не запускался" }
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

    let devicesURL: URL

    init(devicesURL: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library/Developer/CoreSimulator/Devices")) {
        self.devicesURL = devicesURL
    }

    func refresh() {
        isLoading = true
        errorMessage = nil

        Task.detached(priority: .userInitiated) { [devicesURL] in
            do {
                let result = try DeviceScanner.loadDevices(at: devicesURL)
                let disk = DeviceScanner.fetchDiskInfo(for: devicesURL)
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
        errorMessage = nil
        isLoading = true

        do {
            let result = try await Task.detached(priority: .userInitiated) { [devicesURL] in
                try DeviceScanner.performDelete(udid: device.udid)
                return try DeviceScanner.loadDevices(at: devicesURL)
            }.value

            self.devices = result.devices
            self.totalSizeBytes = result.totalSizeBytes
            let disk = DeviceScanner.fetchDiskInfo(for: devicesURL)
            self.diskTotalBytes = disk.total
            self.diskAvailableBytes = disk.available
            self.isLoading = false
        } catch {
            self.errorMessage = error.localizedDescription
            self.isLoading = false
        }
    }

    nonisolated static func loadDevices(at url: URL) throws -> (devices: [SimulatorDevice], totalSizeBytes: Int64) {
        let fm = FileManager.default

        guard fm.fileExists(atPath: url.path) else {
            throw NSError(domain: "DeviceScanner", code: 1, userInfo: [NSLocalizedDescriptionKey: "Каталог устройств не найден по пути \(url.path)."])
        }

        let entries: [URL]
        do {
            entries = try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        } catch {
            throw NSError(domain: "DeviceScanner", code: 1, userInfo: [NSLocalizedDescriptionKey: "Не удалось прочитать каталог устройств по пути \(url.path): \(error.localizedDescription)"])
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
            throw NSError(domain: "DeviceScanner", code: 2, userInfo: [NSLocalizedDescriptionKey: "Отсутствует device.plist в \(url.lastPathComponent)."])
        }

        var format = PropertyListSerialization.PropertyListFormat.binary
        guard let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: &format) as? [String: Any] else {
            throw NSError(domain: "DeviceScanner", code: 3, userInfo: [NSLocalizedDescriptionKey: "Не удалось распарсить device.plist в \(url.lastPathComponent)."])
        }

        guard let udid = plist["UDID"] as? String else {
            throw NSError(domain: "DeviceScanner", code: 4, userInfo: [NSLocalizedDescriptionKey: "В device.plist отсутствует UDID в \(url.lastPathComponent)."])
        }

        let name = plist["name"] as? String ?? "Без имени"
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

    private nonisolated static func performDelete(udid: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "delete", udid]

        let errorPipe = Pipe()
        process.standardError = errorPipe
        process.standardOutput = Pipe()

        try process.run()
        process.waitUntilExit()

        if process.terminationStatus != 0 {
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let message = String(data: data, encoding: .utf8) ?? "Неизвестная ошибка"
            throw NSError(
                domain: "DeviceScanner",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "Не удалось удалить симулятор \(udid): \(message.trimmingCharacters(in: .whitespacesAndNewlines))"]
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
