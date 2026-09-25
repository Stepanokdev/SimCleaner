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
    let bundleId: String
    let bundlePath: URL
    let dataContainerPath: URL?
    let icon: URL?
    let bundleSizeBytes: Int64
    let dataSizeBytes: Int64

    var path: URL { bundlePath }
    var sizeBytes: Int64 { bundleSizeBytes + dataSizeBytes }

    var sizeDescription: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}

/// Where a device folder lives. Xcode keeps several independent device sets under ~/Library/Developer.
enum DeviceSetKind: String, Hashable {
    case simulators
    case previews
    case testClones
    case playgrounds

    nonisolated static func from(setURL url: URL) -> DeviceSetKind {
        let path = url.path
        if path.contains("/XCTestDevices") { return .testClones }
        if path.contains("/XCPGDevices") { return .playgrounds }
        if path.contains("/Previews/") || url.lastPathComponent == "Simulator Devices" { return .previews }
        return .simulators
    }

    /// Short label shown next to devices that are not regular simulators.
    var badge: String? {
        switch self {
        case .simulators: return nil
        case .previews: return "Previews"
        case .testClones: return "Test clone"
        case .playgrounds: return "Playground"
        }
    }
}

struct DeviceSet: Hashable {
    let url: URL
    let kind: DeviceSetKind
}

/// What the simulator list area shows. Kept separate from the view so each state can be tested.
enum SimulatorListState: Equatable {
    case needsAccess
    /// The granted folder is where macOS keeps runtimes (e.g. /System/Library/AssetsV2), not simulators.
    case runtimeFolder
    case error(String)
    case loading
    /// Nothing listed, but some simulator folders couldn't be read: not a definitive "empty".
    case unreadableFolders
    /// The granted folder contains no device sets at all (wrong folder).
    case noDeviceFolders
    /// Device sets exist but hold no simulators.
    case noSimulators
    /// Simulators exist, but the current filter or search hides all of them.
    case noMatches
    case list

    nonisolated static func isRuntimeLocation(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return path.hasPrefix("/System/") || path.hasPrefix("/Library/Developer/CoreSimulator")
    }

    nonisolated static func resolve(
        hasFolderAccess: Bool,
        scannedURL: URL,
        errorMessage: String?,
        isLoading: Bool,
        hasCompletedScan: Bool,
        deviceCount: Int,
        filteredCount: Int,
        deviceSetCount: Int,
        isScanPartial: Bool
    ) -> SimulatorListState {
        guard hasFolderAccess else { return .needsAccess }
        // Checked before errors: the sandbox may refuse to list a system folder, and the useful answer
        // is still "these are runtimes", not a raw permission error.
        if isRuntimeLocation(scannedURL) && deviceCount == 0 && !isLoading { return .runtimeFolder }
        if let errorMessage { return .error(errorMessage) }
        if isLoading && deviceCount == 0 { return .loading }
        if deviceCount == 0 && hasCompletedScan {
            if isScanPartial { return .unreadableFolders }
            return deviceSetCount == 0 ? .noDeviceFolders : .noSimulators
        }
        if filteredCount == 0 { return .noMatches }
        return .list
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
    /// `lastUsedAt` (Xcode 27+) or `lastBootedAt` (older Xcode) from device.plist.
    let lastUsedAt: Date?
    /// The device has booted at least once, even if CoreSimulator recorded no date for it.
    let hasBootedBefore: Bool
    let lastModifiedAt: Date?
    let sizeBytes: Int64
    let apps: [SimulatorApp]
    let rootPath: URL
    let isDefault: Bool
    let setKind: DeviceSetKind

    var appCount: Int { apps.count }
    var isBooted: Bool { state == 3 }
    var lastUsed: Date? { lastUsedAt }
    var lastUsedSortKey: Date {
        if let lastUsedAt { return lastUsedAt }
        // Used-but-undated devices sort just above ones that never booted.
        return hasBootedBefore ? .distantPast.addingTimeInterval(1) : .distantPast
    }
    var sizeDescription: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
    var lastUsedDescription: String {
        if let lastUsedAt {
            return RelativeDateTimeFormatter.shared.localizedString(for: lastUsedAt, relativeTo: .now)
        }
        return hasBootedBefore ? "Date unknown" : "Never launched"
    }
}

struct ScanResult {
    let devices: [SimulatorDevice]
    let totalSizeBytes: Int64
    let deviceSets: [DeviceSet]
    /// UUID folders inside a device set without a device.plist (leftovers, not simulators).
    let unrecognizedFolderCount: Int
    let unrecognizedSizeBytes: Int64
    /// Device set folders that exist but couldn't be listed. Simulators inside them are missing from `devices`.
    let unreadableLocations: [URL]
    /// Device folders whose device.plist exists but couldn't be read or parsed.
    let unreadableDeviceCount: Int

    var isPartial: Bool { !unreadableLocations.isEmpty || unreadableDeviceCount > 0 }

    static let empty = ScanResult(
        devices: [],
        totalSizeBytes: 0,
        deviceSets: [],
        unrecognizedFolderCount: 0,
        unrecognizedSizeBytes: 0,
        unreadableLocations: [],
        unreadableDeviceCount: 0
    )
}

struct ScanProgress: Equatable {
    let completed: Int
    let total: Int

    var fraction: Double {
        guard total > 0 else { return 0 }
        return Double(completed) / Double(total)
    }

    var label: String {
        guard total > 0 else { return "Scanning..." }
        let percent = (fraction * 100).rounded()
        return "\(completed)/\(total) • \(Int(percent))%"
    }
}

struct DeletionProgress: Equatable {
    let completed: Int
    let total: Int
    let currentDeviceName: String
    let totalSizeBytes: Int64

    var fraction: Double {
        guard total > 0 else { return 0 }
        return Double(completed) / Double(total)
    }

    var label: String {
        guard total > 0 else { return "Deleting..." }
        return "\(completed) of \(total)"
    }

    var sizeDescription: String {
        ByteCountFormatter.string(fromByteCount: totalSizeBytes, countStyle: .file)
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
    @Published var scanProgress: ScanProgress?
    @Published var deletionProgress: DeletionProgress?
    @Published var deviceSets: [DeviceSet] = []
    @Published var unrecognizedFolderCount: Int = 0
    @Published var unrecognizedSizeBytes: Int64 = 0
    @Published var unreadableLocations: [URL] = []
    @Published var unreadableDeviceCount: Int = 0
    @Published var hasCompletedScan: Bool = false
    /// Downloaded simulator runtimes. Shown for context only; SimCleaner never deletes them.
    @Published var runtimeStorageBytes: Int64?
    /// Devices that couldn't be deleted in the last deletion. The list itself is rescanned and stays visible.
    @Published var deletionError: String?

    private var activeSecurityScopedURL: URL?
    private var scanGeneration = 0

    /// The user's real home folder. Inside the sandbox `homeDirectoryForCurrentUser` points at the app container.
    nonisolated static var realHomeDirectory: URL {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// ~/Library/Developer holds every device set Xcode creates, so one grant here covers all of them.
    nonisolated static var developerFolderURL: URL {
        realHomeDirectory.appending(path: "Library/Developer", directoryHint: .isDirectory)
    }

    /// Some simulator folders couldn't be read, so the list may be missing devices.
    var isScanPartial: Bool { !unreadableLocations.isEmpty || unreadableDeviceCount > 0 }

    /// True when the granted folder is ~/Library/Developer or one of its parents.
    var coversDeveloperFolder: Bool {
        let granted = devicesURL.standardizedFileURL.path
        let developer = DeviceScanner.developerFolderURL.standardizedFileURL.path
        return developer == granted || developer.hasPrefix(granted.hasSuffix("/") ? granted : granted + "/")
    }
    nonisolated private static var bookmarkFileURL: URL? {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return appSupport.appending(path: "devices.bookmark")
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
            let resolved = devicesURL ?? DeviceScanner.developerFolderURL
            self.devicesURL = resolved
            print("DeviceScanner init: using default URL \(resolved.path)")
        }
    }

    func refresh() {
        let scanURL = devicesURL
        scanGeneration += 1
        let generation = scanGeneration
        isLoading = true
        errorMessage = nil
        scanProgress = nil

        Task.detached(priority: .userInitiated) { [scanURL, weak self] in
            let outcome = Result {
                try DeviceScanner.loadDevices(at: scanURL) { progress in
                    Task { @MainActor [weak self] in
                        self?.updateScanProgress(progress, generation: generation)
                    }
                }
            }
            let disk = DeviceScanner.fetchDiskInfo(for: scanURL)
            let runtimeBytes = DeviceScanner.simulatorRuntimeStorageBytes()
            await self?.finishScan(outcome, disk: disk, runtimeBytes: runtimeBytes, generation: generation)
        }
    }

    private func updateScanProgress(_ progress: ScanProgress, generation: Int) {
        guard scanGeneration == generation else { return }
        scanProgress = progress
    }

    private func finishScan(_ outcome: Result<ScanResult, Error>, disk: (total: Int64, available: Int64), runtimeBytes: Int64?, generation: Int) {
        // A newer refresh or a deletion started meanwhile; its result wins.
        guard scanGeneration == generation else { return }
        switch outcome {
        case .success(let result):
            apply(result)
            diskTotalBytes = disk.total
            diskAvailableBytes = disk.available
        case .failure(let error):
            apply(.empty)
            diskTotalBytes = 0
            diskAvailableBytes = 0
            errorMessage = error.localizedDescription
        }
        runtimeStorageBytes = runtimeBytes
        isLoading = false
        scanProgress = nil
    }

    private func apply(_ result: ScanResult) {
        devices = result.devices
        totalSizeBytes = result.totalSizeBytes
        deviceSets = result.deviceSets
        unrecognizedFolderCount = result.unrecognizedFolderCount
        unrecognizedSizeBytes = result.unrecognizedSizeBytes
        unreadableLocations = result.unreadableLocations
        unreadableDeviceCount = result.unreadableDeviceCount
        hasCompletedScan = true
    }

    func delete(device: SimulatorDevice) async {
        await delete(devices: [device])
    }

    func delete(devices: [SimulatorDevice]) async {
        guard !devices.isEmpty else { return }
        errorMessage = nil
        deletionError = nil
        isLoading = true
        scanProgress = nil

        let totalSize = devices.reduce(0) { $0 + $1.sizeBytes }
        deletionProgress = DeletionProgress(
            completed: 0,
            total: devices.count,
            currentDeviceName: devices.first?.name ?? "",
            totalSizeBytes: totalSize
        )

        let devicesToDelete = devices
        let scanURL = devicesURL
        scanGeneration += 1
        print("Delete requested for \(devicesToDelete.map(\.udid).joined(separator: ",")) within \(scanURL.path)")

        let (deleteError, rescan) = await Task.detached(priority: .userInitiated) { [scanURL, devicesToDelete, weak self] () -> ((any Error)?, Result<ScanResult, any Error>) in
            var deleteError: (any Error)?
            do {
                try DeviceScanner.performDelete(devices: devicesToDelete, allowedRoot: scanURL) { completed, currentName in
                    Task { @MainActor in
                        self?.deletionProgress = DeletionProgress(
                            completed: completed,
                            total: devicesToDelete.count,
                            currentDeviceName: currentName,
                            totalSizeBytes: totalSize
                        )
                    }
                }
            } catch {
                deleteError = error
            }
            // Rescan even after a partial failure: some folders may already be gone.
            return (deleteError, Result { try DeviceScanner.loadDevices(at: scanURL) })
        }.value

        switch rescan {
        case .success(let result):
            apply(result)
            let disk = DeviceScanner.fetchDiskInfo(for: scanURL)
            diskTotalBytes = disk.total
            diskAvailableBytes = disk.available
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
        deletionError = deleteError?.localizedDescription
        isLoading = false
        deletionProgress = nil
    }

    func chooseDevicesDirectory() {
        let panel = NSOpenPanel()
        panel.title = "Allow access to the Developer folder"
        panel.message = "Choose the Developer folder in your Library. SimCleaner finds simulators, Preview devices and test clones inside it."
        panel.directoryURL = DeviceScanner.developerFolderURL
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use This Folder"

        let response = panel.runModal()
        guard response == .OK, let url = panel.url else {
            // Cancelling "Change…" keeps the folder that is already granted.
            print("User cancelled folder selection")
            return
        }

        let granted = beginAccessing(url: url, securityScoped: true)
        if granted {
            DeviceScanner.saveBookmark(for: url)
            print("User selected devices folder: \(url.path)")
            devicesURL = url
            refresh()
        } else {
            print("Failed to start security scoped access for \(url.path)")
        }
    }

    /// Device set locations relative to ~/Library/Developer.
    private nonisolated static let knownDeviceSetPaths = [
        "CoreSimulator/Devices",
        "Xcode/UserData/Previews/Simulator Devices",
        "XCTestDevices",
        "XCPGDevices",
    ]

    /// Finds device sets inside the granted folder. Works whether the user picked ~/Library/Developer,
    /// a parent of it, a folder in between (CoreSimulator, Xcode) or a device set itself.
    /// Known set locations that exist but can't be listed come back as `unreadable`.
    nonisolated static func discoverDeviceSets(in root: URL) -> (sets: [DeviceSet], unreadable: [URL]) {
        var candidates: [URL] = [root]
        for path in knownDeviceSetPaths {
            let components = path.split(separator: "/").map(String.init)
            // Every tail of the path covers a pick somewhere inside ~/Library/Developer.
            for start in components.indices {
                candidates.append(root.appending(path: components[start...].joined(separator: "/"), directoryHint: .isDirectory))
            }
            for prefix in ["Developer", "Library/Developer"] {
                candidates.append(root.appending(path: "\(prefix)/\(path)", directoryHint: .isDirectory))
            }
        }

        let fm = FileManager.default
        var seen = Set<String>()
        var sets: [DeviceSet] = []
        var unreadable: [URL] = []
        for candidate in candidates {
            let key = candidate.resolvingSymlinksInPath().standardizedFileURL.path
            guard !seen.contains(key) else { continue }
            if isDeviceSet(candidate) {
                seen.insert(key)
                sets.append(DeviceSet(url: candidate, kind: DeviceSetKind.from(setURL: candidate)))
                continue
            }
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            if (try? fm.contentsOfDirectory(atPath: candidate.path)) == nil {
                seen.insert(key)
                unreadable.append(candidate)
            }
        }
        return (sets, unreadable)
    }

    /// A device set has a device_set.plist or contains folders named by a device UDID.
    private nonisolated static func isDeviceSet(_ url: URL) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.appending(path: "device_set.plist").path) { return true }
        guard let entries = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return false
        }
        return entries.contains { $0.isDirectory && UUID(uuidString: $0.lastPathComponent) != nil }
    }

    nonisolated static func loadDevices(at url: URL, progress: ((ScanProgress) -> Void)? = nil) throws -> ScanResult {
        let fm = FileManager.default

        guard fm.fileExists(atPath: url.path) else {
            throw NSError(domain: "DeviceScanner", code: 1, userInfo: [NSLocalizedDescriptionKey: "Folder not found at \(url.path)."])
        }
        do {
            _ = try fm.contentsOfDirectory(atPath: url.path)
        } catch {
            throw NSError(domain: "DeviceScanner", code: 1, userInfo: [NSLocalizedDescriptionKey: "Can't read \(url.path): \(error.localizedDescription)"])
        }

        let discovery = discoverDeviceSets(in: url)
        var readableSets: [DeviceSet] = []
        var unreadableLocations = discovery.unreadable

        // Collect every folder up front so progress doesn't jump backwards between sets.
        var work: [(folder: URL, set: DeviceSet, defaults: Set<String>)] = []
        var seenFolders = Set<String>()
        for set in discovery.sets {
            guard let entries = try? fm.contentsOfDirectory(at: set.url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
                // Has a device_set.plist but can't be listed: its simulators are missing, not absent.
                unreadableLocations.append(set.url)
                continue
            }
            readableSets.append(set)
            let defaults = loadDefaultDeviceUDIDs(at: set.url)
            for entry in entries where entry.isDirectory {
                let key = entry.resolvingSymlinksInPath().standardizedFileURL.path
                guard seenFolders.insert(key).inserted else { continue }
                work.append((entry, set, defaults))
            }
        }
        progress?(ScanProgress(completed: 0, total: work.count))

        var devices: [SimulatorDevice] = []
        var totalSize: Int64 = 0
        var unrecognizedCount = 0
        var unrecognizedSize: Int64 = 0
        var unreadableDeviceCount = 0

        for (index, item) in work.enumerated() {
            do {
                let device = try buildDevice(at: item.folder, set: item.set, defaultDeviceUDIDs: item.defaults)
                devices.append(device)
                totalSize += device.sizeBytes
            } catch {
                let folderIsListable = (try? fm.contentsOfDirectory(atPath: item.folder.path)) != nil
                if !folderIsListable || fm.fileExists(atPath: item.folder.appending(path: "device.plist").path) {
                    // A simulator we couldn't read, not a leftover. Report it so the list isn't mistaken for complete.
                    unreadableDeviceCount += 1
                } else if UUID(uuidString: item.folder.lastPathComponent) != nil {
                    // No device.plist at all: leftover data, not a simulator.
                    unrecognizedCount += 1
                    unrecognizedSize += directorySize(at: item.folder)
                }
            }
            progress?(ScanProgress(completed: index + 1, total: work.count))
        }

        return ScanResult(
            devices: devices,
            totalSizeBytes: totalSize,
            deviceSets: readableSets,
            unrecognizedFolderCount: unrecognizedCount,
            unrecognizedSizeBytes: unrecognizedSize,
            unreadableLocations: unreadableLocations,
            unreadableDeviceCount: unreadableDeviceCount
        )
    }

    /// Reads a plist date that may be stored as a date or, defensively, as an ISO 8601 string.
    private nonisolated static func plistDate(_ value: Any?) -> Date? {
        if let date = value as? Date { return date }
        if let string = value as? String { return ISO8601DateFormatter().date(from: string) }
        return nil
    }

    private nonisolated static func buildDevice(at url: URL, set: DeviceSet, defaultDeviceUDIDs: Set<String>) throws -> SimulatorDevice {
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
        // CoreSimulator in Xcode 27 renamed `lastBootedAt` to `lastUsedAt`. Devices untouched since the
        // upgrade still carry the old key, so read both.
        let lastUsedAtPlist = plistDate(plist["lastUsedAt"]) ?? plistDate(plist["lastBootedAt"])
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

        let lastUsedAt = lastUsedAtPlist ?? fetchStateLastUsed(at: url)
        // CoreSimulator creates data/Containers on first boot; freshly created devices don't have it.
        let hasBootedBefore = fm.fileExists(atPath: dataURL.appending(path: "Containers").path) || !apps.isEmpty

        return SimulatorDevice(
            id: url.standardizedFileURL.path,
            name: name,
            deviceType: deviceType,
            runtime: runtime,
            runtimeGroup: runtimeGroup,
            category: category,
            udid: udid,
            state: state,
            lastUsedAt: lastUsedAt,
            hasBootedBefore: hasBootedBefore,
            lastModifiedAt: lastModified,
            sizeBytes: sizeBytes,
            apps: apps,
            rootPath: url,
            isDefault: isDefault,
            setKind: set.kind
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
        print("performDelete: deleting via FileManager for \(udids)")
        try deleteDeviceFolders(udids: udids, devicesRoot: devicesRoot)
    }

    /// Deletes each device's own folder. A folder is removed only if it sits inside `allowedRoot`
    /// (the folder the user granted), is named by the device UDID and still holds that device.
    nonisolated static func performDelete(
        devices: [SimulatorDevice],
        allowedRoot: URL,
        progress: ((Int, String) -> Void)? = nil
    ) throws {
        guard !devices.isEmpty else { return }
        print("performDelete: deleting \(devices.count) devices via FileManager")

        let fm = FileManager.default
        var errors: [String] = []
        let rootPath = allowedRoot.resolvingSymlinksInPath().standardizedFileURL.path
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"

        for (index, device) in devices.enumerated() {
            progress?(index, device.name)

            let url = device.rootPath.resolvingSymlinksInPath().standardizedFileURL
            guard url.path.hasPrefix(rootPrefix), url.lastPathComponent == device.udid else {
                errors.append("\(device.name): folder is outside the allowed location")
                print("Refusing to delete \(url.path): not a device folder inside \(rootPath)")
                continue
            }
            guard fm.fileExists(atPath: url.path) else {
                print("Device folder not found for \(device.udid) at \(url.path)")
                continue
            }
            guard readUDID(inDeviceFolder: url) == device.udid else {
                errors.append("\(device.name): folder changed since the last scan")
                print("Refusing to delete \(url.path): device.plist no longer matches \(device.udid)")
                continue
            }
            do {
                try fm.removeItem(at: url)
                print("Removed device folder at \(url.path)")
            } catch {
                let message = error.localizedDescription
                errors.append("\(device.name): \(message)")
                print("Failed to remove device folder for \(device.udid): \(message)")
            }
        }

        progress?(devices.count, "")

        if !errors.isEmpty {
            throw NSError(
                domain: "DeviceScanner",
                code: 6,
                userInfo: [NSLocalizedDescriptionKey: errors.joined(separator: "\n")]
            )
        }
    }

    private nonisolated static func readUDID(inDeviceFolder url: URL) -> String? {
        guard let data = FileManager.default.contents(atPath: url.appending(path: "device.plist").path) else { return nil }
        var format = PropertyListSerialization.PropertyListFormat.binary
        let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: &format) as? [String: Any]
        return plist?["UDID"] as? String
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
        let bundleRoot = url.appending(path: "data/Containers/Bundle/Application")
        let dataRoot = url.appending(path: "data/Containers/Data/Application")
        let fm = FileManager.default

        guard let bundleContainers = try? fm.contentsOfDirectory(at: bundleRoot, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) else {
            return ([], nil)
        }

        // Build a mapping: bundleId -> Data container URL
        let dataContainerMap = buildDataContainerMap(at: dataRoot)

        var apps: [SimulatorApp] = []
        var newestDate: Date?

        for container in bundleContainers where container.isDirectory {
            // Read bundleId from metadata plist
            let bundleId = readBundleId(from: container)

            guard let bundles = try? fm.contentsOfDirectory(at: container, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) else { continue }

            for bundle in bundles where bundle.pathExtension == "app" {
                let name = bundle.deletingPathExtension().lastPathComponent
                let icon = findAppIcon(in: bundle)

                // Calculate Bundle size (the .app folder)
                let bundleSize = directorySize(at: bundle)

                // Find and calculate Data container size
                let dataContainerURL = bundleId.flatMap { dataContainerMap[$0] }
                let dataSize = dataContainerURL.map { directorySize(at: $0) } ?? 0

                apps.append(SimulatorApp(
                    name: name,
                    bundleId: bundleId ?? "unknown",
                    bundlePath: bundle,
                    dataContainerPath: dataContainerURL,
                    icon: icon,
                    bundleSizeBytes: bundleSize,
                    dataSizeBytes: dataSize
                ))

                if let mod = bundle.contentModificationDate, let currentNewest = newestDate {
                    if mod > currentNewest { newestDate = mod }
                } else if newestDate == nil {
                    newestDate = bundle.contentModificationDate
                }
            }
        }

        return (apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }, newestDate)
    }

    /// Builds a mapping from bundleId to Data container URL
    private nonisolated static func buildDataContainerMap(at dataRoot: URL) -> [String: URL] {
        let fm = FileManager.default
        guard let containers = try? fm.contentsOfDirectory(at: dataRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return [:]
        }

        var map: [String: URL] = [:]
        for container in containers where container.isDirectory {
            if let bundleId = readBundleId(from: container) {
                map[bundleId] = container
            }
        }
        return map
    }

    /// Reads MCMMetadataIdentifier (bundleId) from container's metadata plist
    private nonisolated static func readBundleId(from containerURL: URL) -> String? {
        let metadataURL = containerURL.appending(path: ".com.apple.mobile_container_manager.metadata.plist")
        guard let data = try? Data(contentsOf: metadataURL) else { return nil }

        var format = PropertyListSerialization.PropertyListFormat.binary
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: &format) as? [String: Any] else {
            return nil
        }

        return plist["MCMMetadataIdentifier"] as? String
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

    private nonisolated static func fetchStateLastUsed(at deviceURL: URL) -> Date? {
        let plistURL = deviceURL.appending(path: "state.plist")
        guard let data = try? Data(contentsOf: plistURL) else { return nil }
        var format = PropertyListSerialization.PropertyListFormat.binary
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: &format) as? [String: Any] else { return nil }
        return plistDate(plist["lastUsedAt"]) ?? plistDate(plist["lastBootedAt"])
    }

    /// Space taken by downloaded simulator runtimes. Read-only: macOS protects these folders and only
    /// Xcode (Settings → Components) or `xcrun simctl runtime delete` can remove them.
    /// Returns nil when the folders can't be read.
    nonisolated static func simulatorRuntimeStorageBytes() -> Int64? {
        let fm = FileManager.default
        let assetsRoot = URL(fileURLWithPath: "/System/Library/AssetsV2", isDirectory: true)
        guard let entries = try? fm.contentsOfDirectory(at: assetsRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return nil
        }
        let runtimeFolders = entries.filter { $0.lastPathComponent.contains("SimulatorRuntime") && $0.isDirectory }
        guard !runtimeFolders.isEmpty else { return nil }
        let total = runtimeFolders.reduce(Int64(0)) { $0 + directorySize(at: $1) }
        return total > 0 ? total : nil
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
        guard securityScoped else {
            activeSecurityScopedURL?.stopAccessingSecurityScopedResource()
            activeSecurityScopedURL = nil
            hasFolderAccess = true
            return true
        }
        if url.startAccessingSecurityScopedResource() {
            // Release the previous folder only once the new one is open, so a failed switch keeps working access.
            activeSecurityScopedURL?.stopAccessingSecurityScopedResource()
            activeSecurityScopedURL = url
            hasFolderAccess = true
            print("Started security scoped access for \(url.path)")
            return true
        } else {
            print("Failed to start security scoped access for \(url.path)")
            hasFolderAccess = activeSecurityScopedURL != nil
            return false
        }
    }

    private nonisolated static func restoreBookmarkedURL() -> URL? {
        guard let bookmarkLocation = bookmarkFileURL,
              let data = try? Data(contentsOf: bookmarkLocation) else { return nil }
        var isStale = false
        do {
            let url = try URL(
                resolvingBookmarkData: data,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            )
            if isStale {
                try? FileManager.default.removeItem(at: bookmarkLocation)
                return nil
            }
            return url
        } catch {
            return nil
        }
    }

    private nonisolated static func saveBookmark(for url: URL) {
        guard let destination = bookmarkFileURL else { return }
        let fm = FileManager.default
        if let dir = destination.deletingLastPathComponent() as URL? {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        guard let data = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) else {
            return
        }
        do {
            try data.write(to: destination, options: [.atomic])
            print("Saved bookmark to \(destination.path)")
        } catch {
            print("Failed to save bookmark: \(error.localizedDescription)")
        }
    }

    private nonisolated static func clearBookmark() {
        guard let destination = bookmarkFileURL else { return }
        try? FileManager.default.removeItem(at: destination)
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
