//
//  SimulatorScanner.swift
//  SimCleanerKit
//

import Foundation

/// Well-known locations, resolved for the real user even inside the App Sandbox.
public enum DeveloperPaths {
    /// The user's real home folder. Inside the sandbox `homeDirectoryForCurrentUser` points at the app container.
    public static var realHomeDirectory: URL {
        if let entry = getpwuid(getuid()), let dir = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    /// ~/Library/Developer holds every device set Xcode creates, so one grant here covers all of them.
    public static var developerFolder: URL {
        realHomeDirectory.appending(path: "Library/Developer", directoryHint: .isDirectory)
    }

    /// Device Hub mounts the file systems of running simulators and connected devices here.
    /// Anything that walks or deletes inside ~/Library/Developer must stay out of it.
    public static var deviceFSMount: URL {
        developerFolder.appending(path: "CoreDevice/DeviceFS", directoryHint: .isDirectory)
    }

    /// CoreSimulator, which Xcode installs on its first launch. While it's on the Mac it may be running or
    /// changing any simulator, so only CoreSimulator itself may delete one.
    public static let coreSimulatorFramework = URL(fileURLWithPath: "/Library/Developer/PrivateFrameworks/CoreSimulator.framework", isDirectory: true)

    public static var coreSimulatorInstalled: Bool {
        FileManager.default.fileExists(atPath: coreSimulatorFramework.path)
    }

    /// Device set locations relative to ~/Library/Developer.
    public static let knownDeviceSetPaths = [
        "CoreSimulator/Devices",
        "Xcode/UserData/Previews/Simulator Devices",
        "XCTestDevices",
        "XCPGDevices",
    ]
}

/// Capacity and free space of the volume that holds a path.
public struct VolumeSpace: Sendable, Equatable {
    public let totalBytes: Int64
    public let availableBytes: Int64

    public static let unknown = VolumeSpace(totalBytes: 0, availableBytes: 0)

    public init(totalBytes: Int64, availableBytes: Int64) {
        self.totalBytes = totalBytes
        self.availableBytes = availableBytes
    }

    public static func of(_ url: URL) -> VolumeSpace {
        guard let values = try? FileManager.default.attributesOfFileSystem(forPath: url.path) else { return .unknown }
        let total = (values[.systemSize] as? NSNumber)?.int64Value ?? 0
        let free = (values[.systemFreeSize] as? NSNumber)?.int64Value ?? 0
        return VolumeSpace(totalBytes: total, availableBytes: free)
    }
}

public enum SimulatorScanError: LocalizedError, Equatable {
    case folderNotFound(String)
    case folderUnreadable(String, String)

    public var errorDescription: String? {
        switch self {
        case .folderNotFound(let path): return "Folder not found at \(path)."
        case .folderUnreadable(let path, let reason): return "Can't read \(path): \(reason)"
        }
    }
}

/// Reads simulators straight from disk: device sets, device.plist files, installed apps and sizes.
public enum SimulatorScanner {
    /// Finds device sets inside `root`. Works whether `root` is ~/Library/Developer, a parent of it,
    /// a folder in between (CoreSimulator, Xcode) or a device set itself.
    /// Known set locations that exist but can't be listed come back as `unreadable`.
    public static func discoverDeviceSets(in root: URL) -> (sets: [DeviceSet], unreadable: [URL]) {
        var candidates: [URL] = [root]
        for path in DeveloperPaths.knownDeviceSetPaths {
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
    static func isDeviceSet(_ url: URL) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.appending(path: "device_set.plist").path) { return true }
        guard let entries = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return false
        }
        return entries.contains { $0.isDirectory && UUID(uuidString: $0.lastPathComponent) != nil }
    }

    public static func loadDevices(at url: URL, progress: ((ScanProgress) -> Void)? = nil) throws -> ScanResult {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else {
            throw SimulatorScanError.folderNotFound(url.path)
        }
        do {
            _ = try fm.contentsOfDirectory(atPath: url.path)
        } catch {
            throw SimulatorScanError.folderUnreadable(url.path, error.localizedDescription)
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
        var leftovers: [LeftoverFolder] = []
        var unreadableDeviceCount = 0

        for (index, item) in work.enumerated() {
            do {
                devices.append(try buildDevice(at: item.folder, set: item.set, defaultDeviceUDIDs: item.defaults))
            } catch {
                let folderIsListable = (try? fm.contentsOfDirectory(atPath: item.folder.path)) != nil
                if !folderIsListable || fm.fileExists(atPath: item.folder.appending(path: "device.plist").path) {
                    // A simulator we couldn't read, not a leftover. Report it so the list isn't mistaken for complete.
                    unreadableDeviceCount += 1
                } else if UUID(uuidString: item.folder.lastPathComponent) != nil {
                    // No device.plist at all: leftover data, not a simulator.
                    leftovers.append(LeftoverFolder(
                        url: item.folder,
                        deviceSet: item.set,
                        footprint: DiskUsage.measure(item.folder),
                        lastModifiedAt: item.folder.contentModificationDate
                    ))
                }
            }
            progress?(ScanProgress(completed: index + 1, total: work.count))
        }

        return ScanResult(
            devices: devices,
            deviceSets: readableSets,
            leftovers: leftovers,
            unreadableLocations: unreadableLocations,
            unreadableDeviceCount: unreadableDeviceCount
        )
    }

    /// Reads a plist date that may be stored as a date or, defensively, as an ISO 8601 string.
    static func plistDate(_ value: Any?) -> Date? {
        if let date = value as? Date { return date }
        if let string = value as? String { return ISO8601DateFormatter().date(from: string) }
        return nil
    }

    /// The UDID recorded in a device folder's device.plist, read fresh from disk.
    public static func readUDID(inDeviceFolder url: URL) -> String? {
        readDevicePlist(in: url)?["UDID"] as? String
    }

    /// The state recorded in a device folder's device.plist, read fresh from disk.
    public static func readPlistState(inDeviceFolder url: URL) -> DeviceState? {
        (readDevicePlist(in: url)?["state"] as? NSNumber).map { DeviceState(plistValue: $0.intValue) }
    }

    static func readDevicePlist(in folder: URL) -> [String: Any]? {
        guard let data = FileManager.default.contents(atPath: folder.appending(path: "device.plist").path) else { return nil }
        var format = PropertyListSerialization.PropertyListFormat.binary
        return try? PropertyListSerialization.propertyList(from: data, options: [], format: &format) as? [String: Any]
    }

    static func buildDevice(at url: URL, set: DeviceSet, defaultDeviceUDIDs: Set<String>) throws -> SimulatorDevice {
        let plistURL = url.appending(path: "device.plist")
        let fm = FileManager.default
        guard let data = fm.contents(atPath: plistURL.path) else {
            throw CocoaError(.fileReadNoSuchFile, userInfo: [NSFilePathErrorKey: plistURL.path])
        }
        var format = PropertyListSerialization.PropertyListFormat.binary
        guard let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: &format) as? [String: Any],
              let udid = plist["UDID"] as? String else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: plistURL.path])
        }

        let name = plist["name"] as? String ?? "Unnamed"
        let deviceTypeRaw = plist["deviceType"] as? String ?? ""
        let runtimeRaw = plist["runtime"] as? String ?? ""
        // CoreSimulator in Xcode 27 renamed `lastBootedAt` to `lastUsedAt`. Devices untouched since the
        // upgrade still carry the old key, so read both.
        let lastUsedAtPlist = plistDate(plist["lastUsedAt"]) ?? plistDate(plist["lastBootedAt"])
        let state = (plist["state"] as? NSNumber).map { DeviceState(plistValue: $0.intValue) } ?? .unknown("")

        let (apps, lastAppChange) = fetchInstalledApps(at: url)
        let dataURL = url.appending(path: "data")
        let lastModified = dataURL.contentModificationDate ?? url.contentModificationDate ?? lastAppChange
        // CoreSimulator creates data/Containers on first boot; freshly created devices don't have it.
        let hasBootedBefore = fm.fileExists(atPath: dataURL.appending(path: "Containers").path) || !apps.isEmpty

        return SimulatorDevice(
            id: url.standardizedFileURL.path,
            name: name,
            deviceType: RuntimeNaming.friendlyDeviceType(deviceTypeRaw, fallback: name),
            deviceTypeIdentifier: deviceTypeRaw,
            runtime: RuntimeNaming.friendlyRuntime(runtimeRaw),
            runtimeIdentifier: runtimeRaw,
            runtimeGroup: RuntimeNaming.runtimeGroup(runtimeRaw),
            category: DeviceCategory.from(deviceType: deviceTypeRaw),
            udid: udid,
            plistState: state,
            lastUsedAt: lastUsedAtPlist ?? fetchStateLastUsed(at: url),
            hasBootedBefore: hasBootedBefore,
            lastModifiedAt: lastModified,
            footprint: DiskUsage.measure(url),
            apps: apps,
            rootPath: url,
            isDefault: defaultDeviceUDIDs.contains(udid),
            deviceSet: set
        )
    }

    static func loadDefaultDeviceUDIDs(at devicesRoot: URL) -> Set<String> {
        guard let data = try? Data(contentsOf: devicesRoot.appending(path: "device_set.plist")) else { return [] }
        var format = PropertyListSerialization.PropertyListFormat.binary
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: &format) as? [String: Any],
              let defaults = plist["DefaultDevices"] as? [String: Any] else { return [] }

        var udids = Set<String>()
        for (_, runtimeValue) in defaults {
            guard let runtimeDict = runtimeValue as? [String: Any] else { continue }
            for (key, value) in runtimeDict where key != "version" {
                if let udid = value as? String { udids.insert(udid) }
            }
        }
        return udids
    }

    static func fetchInstalledApps(at url: URL) -> ([SimulatorApp], Date?) {
        let bundleRoot = url.appending(path: "data/Containers/Bundle/Application")
        let dataRoot = url.appending(path: "data/Containers/Data/Application")
        let fm = FileManager.default

        guard let bundleContainers = try? fm.contentsOfDirectory(at: bundleRoot, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) else {
            return ([], nil)
        }

        let dataContainerMap = buildDataContainerMap(at: dataRoot)
        var apps: [SimulatorApp] = []
        var newestDate: Date?

        for container in bundleContainers where container.isDirectory {
            let bundleId = readBundleId(from: container)
            guard let bundles = try? fm.contentsOfDirectory(at: container, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) else { continue }

            for bundle in bundles where bundle.pathExtension == "app" {
                let dataContainerURL = bundleId.flatMap { dataContainerMap[$0] }
                apps.append(SimulatorApp(
                    name: bundle.deletingPathExtension().lastPathComponent,
                    bundleId: bundleId ?? "unknown",
                    bundlePath: bundle,
                    dataContainerPath: dataContainerURL,
                    icon: findAppIcon(in: bundle),
                    bundleFootprint: DiskUsage.measure(bundle),
                    dataFootprint: dataContainerURL.map(DiskUsage.measure) ?? .zero
                ))
                if let modified = bundle.contentModificationDate, modified > (newestDate ?? .distantPast) {
                    newestDate = modified
                }
            }
        }

        return (apps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }, newestDate)
    }

    /// Maps bundle IDs to their data containers using the container manager's metadata.
    static func buildDataContainerMap(at dataRoot: URL) -> [String: URL] {
        guard let containers = try? FileManager.default.contentsOfDirectory(at: dataRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
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

    /// Reads MCMMetadataIdentifier (the bundle ID) from a container's metadata plist.
    static func readBundleId(from containerURL: URL) -> String? {
        let metadataURL = containerURL.appending(path: ".com.apple.mobile_container_manager.metadata.plist")
        guard let data = try? Data(contentsOf: metadataURL) else { return nil }
        var format = PropertyListSerialization.PropertyListFormat.binary
        let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: &format) as? [String: Any]
        return plist?["MCMMetadataIdentifier"] as? String
    }

    /// The largest AppIcon image at the top level of the bundle. Embedded watch apps and extensions keep
    /// their own icons deeper inside, and those must not win.
    static func findAppIcon(in bundle: URL) -> URL? {
        guard let entries = try? FileManager.default.contentsOfDirectory(at: bundle, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey], options: [.skipsHiddenFiles]) else {
            return nil
        }
        var best: (url: URL, size: Int)?
        for entry in entries {
            let name = entry.lastPathComponent.lowercased()
            guard name.hasPrefix("appicon"), entry.pathExtension.lowercased() == "png" else { continue }
            let values = try? entry.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values?.isRegularFile == true else { continue }
            let size = values?.fileSize ?? 0
            if size > (best?.size ?? -1) { best = (entry, size) }
        }
        return best?.url
    }

    static func fetchStateLastUsed(at deviceURL: URL) -> Date? {
        guard let data = try? Data(contentsOf: deviceURL.appending(path: "state.plist")) else { return nil }
        var format = PropertyListSerialization.PropertyListFormat.binary
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: &format) as? [String: Any] else { return nil }
        return plistDate(plist["lastUsedAt"]) ?? plistDate(plist["lastBootedAt"])
    }
}

extension URL {
    var isDirectory: Bool {
        (try? resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
    }

    var contentModificationDate: Date? {
        try? resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}
