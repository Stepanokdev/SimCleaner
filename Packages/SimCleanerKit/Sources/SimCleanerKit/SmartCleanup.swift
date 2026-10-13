//
//  SmartCleanup.swift
//  SimCleanerKit
//

import Foundation

/// Which folder on disk an item is. A folder that was removed and made again at the same path is a different
/// one, and a cleanup confirmed for the first never touches the second.
public struct FileIdentity: Hashable, Sendable {
    public let volume: UInt64
    public let inode: UInt64

    /// Nil when nothing is there, or it isn't a folder.
    public init?(of url: URL) {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return nil }
        volume = UInt64(truncatingIfNeeded: info.st_dev)
        inode = UInt64(info.st_ino)
    }
}

/// Why a cleanup left something alone that it had planned to remove: it changed or came into use since the
/// plan. Not a failure; the item simply isn't old and unused any more.
public struct CleanupSkip: LocalizedError, Sendable, Equatable {
    public let reason: String

    public init(_ reason: String) {
        self.reason = reason
    }

    public var errorDescription: String? { reason }
}

/// What Smart Cleanup removes in one go, the way CleanMyMac's Smart Care preselects only what's safe: things
/// Xcode builds, copies or creates again by itself when they're needed, and only once they've gone unused for
/// the chosen number of days. A date SimCleaner can't read never counts as old. Simulators people install
/// and test in, and folders whose contents nobody can vouch for, stay suggestions that someone acts on.
public struct SmartCleanupPlan: Sendable {
    public enum Group: String, CaseIterable, Sendable, Identifiable {
        /// A project's build products, indexes and logs in DerivedData. The next build makes them again.
        case derivedData
        /// Symbols for an older OS of a device model Xcode also has a newer one for. Copied again on connect.
        case deviceSupport
        /// Simulators Xcode makes by itself for SwiftUI Previews, parallel tests and playgrounds.
        case toolSimulators
        /// Build folders XcodeBuildMCP and MobileBuildMCP keep per project. The next agent build makes them again.
        case agentWorkspaces

        public var id: String { rawValue }
    }

    public struct Target: Identifiable, Sendable, Hashable {
        public enum Item: Sendable, Hashable {
            case folder(DeveloperStorageItem)
            case simulator(SimulatorDevice)
        }

        public let group: Group
        public let item: Item
        /// When it was last used, as read for the plan.
        public let lastActivity: Date
        /// The folder the plan was made for.
        public let identity: FileIdentity

        /// The item's own ID, so the window's other pages and this cleanup claim the same thing.
        public var id: String {
            switch item {
            case .folder(let folder): return folder.id
            case .simulator(let device): return device.id
            }
        }

        public var url: URL {
            switch item {
            case .folder(let folder): return folder.url
            case .simulator(let device): return device.rootPath
            }
        }

        public var name: String {
            switch item {
            case .folder(let folder): return folder.title
            case .simulator(let device): return device.name
            }
        }

        public var footprint: DiskFootprint {
            switch item {
            case .folder(let folder): return folder.footprint
            case .simulator(let device): return device.footprint
            }
        }
    }

    public let idleDays: Int
    public let targets: [Target]

    public func targets(in group: Group) -> [Target] {
        targets.filter { $0.group == group }
    }

    public var footprint: DiskFootprint {
        targets.reduce(.zero) { $0 + $1.footprint }
    }

    /// The plan for what was scanned. `idleDays` is how long something has to go unused.
    public static func make(devices: [SimulatorDevice], storage: DeveloperStorageReport, idleDays: Int, now: Date = Date()) -> SmartCleanupPlan {
        let cutoff = cutoff(idleDays: idleDays, now: now)
        var targets: [Target] = []
        for folder in storage.items {
            guard let group = group(of: folder),
                  let activity = lastActivity(group: group, url: folder.url),
                  activity < cutoff,
                  let identity = FileIdentity(of: folder.url) else { continue }
            // An older OS version of a device is the only kind of device support that's safe to drop.
            if group == .deviceSupport && !folder.isRecommended { continue }
            targets.append(Target(group: group, item: .folder(folder), lastActivity: activity, identity: identity))
        }
        for device in devices where toolSets.contains(device.setKind) {
            // CoreSimulator has to say it's shut down: a state read from device.plist may be stale.
            guard device.liveState == .shutdown,
                  let activity = lastActivity(group: .toolSimulators, url: device.rootPath),
                  activity < cutoff,
                  let identity = FileIdentity(of: device.rootPath) else { continue }
            targets.append(Target(group: .toolSimulators, item: .simulator(device), lastActivity: activity, identity: identity))
        }
        return SmartCleanupPlan(idleDays: idleDays, targets: targets.sorted { $0.footprint.allocatedBytes > $1.footprint.allocatedBytes })
    }

    /// Reads the disk again right before `target` goes. Nil when it still qualifies; otherwise why it was
    /// left alone. A plan can be minutes old by the time it runs: a project gets built, a preview runs, a
    /// folder is replaced. Whether a simulator is still shut down is CoreSimulator's to say, at deletion.
    public static func recheck(_ target: Target, idleDays: Int, now: Date = Date()) -> String? {
        guard FileIdentity(of: target.url) == target.identity else {
            return "It changed on disk since SimCleaner looked."
        }
        guard let activity = lastActivity(group: target.group, url: target.url) else {
            return "SimCleaner can't tell any more when it was last used."
        }
        guard activity < cutoff(idleDays: idleDays, now: now) else {
            return "It was used since SimCleaner looked."
        }
        return nil
    }

    // MARK: - Rules

    /// Sets CoreSimulator fills by itself, not by someone picking a device and running an app on it.
    static let toolSets: Set<DeviceSetKind> = [.previews, .testClones, .playgrounds]

    static func cutoff(idleDays: Int, now: Date) -> Date {
        now.addingTimeInterval(-Double(idleDays) * 86_400)
    }

    static func group(of folder: DeveloperStorageItem) -> Group? {
        switch folder.category {
        case .derivedData:
            // Every project shares these; clearing them slows every next build, so they're never automatic.
            return DeveloperStorageScanner.sharedDerivedDataFolders[folder.url.lastPathComponent] == nil ? .derivedData : nil
        case .deviceSupport:
            return .deviceSupport
        case .agentWorkspaces:
            return .agentWorkspaces
        }
    }

    /// When something was last used, or nil when that can't be read.
    static func lastActivity(group: Group, url: URL) -> Date? {
        switch group {
        case .derivedData:
            // Xcode writes this whenever it opens the project. A folder date only says when the folder was made.
            return NSDictionary(contentsOf: url.appending(path: "info.plist"))?["LastAccessedDate"] as? Date
        case .deviceSupport:
            // Xcode writes these folders once, when it copies the symbols.
            return url.contentModificationDate
        case .agentWorkspaces:
            // Agents write logs and results deep inside, which doesn't change the top folder's date.
            return newestModification(in: url)
        case .toolSimulators:
            let plist = SimulatorScanner.readDevicePlist(in: url)
            return SimulatorScanner.plistDate(plist?["lastUsedAt"]) ?? SimulatorScanner.plistDate(plist?["lastBootedAt"])
                ?? SimulatorScanner.fetchStateLastUsed(at: url)
        }
    }

    /// The newest modification date of anything in `folder`, or nil when it can't all be read or holds more
    /// than `limit` entries: then nobody can say it's been left alone.
    static func newestModification(in folder: URL, limit: Int = 50_000) -> Date? {
        guard var newest = folder.contentModificationDate else { return nil }
        var failed = false
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.contentModificationDateKey], options: [], errorHandler: { _, _ in
            failed = true
            return false
        }) else { return nil }
        var count = 0
        for case let url as URL in walker {
            count += 1
            guard count <= limit, let modified = url.contentModificationDate else { return nil }
            newest = max(newest, modified)
        }
        return failed ? nil : newest
    }
}
