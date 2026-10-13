//
//  Models.swift
//  SimCleanerKit
//

import Foundation

/// Disk space taken by a file tree on APFS.
///
/// `allocatedBytes` adds up every file's allocated blocks, the way Finder does. `exclusiveBytes` adds up
/// the bytes no other file shares (APFS clones share blocks). Deleting the tree frees at least
/// `exclusiveBytes` and at most `allocatedBytes`: blocks shared only between files inside the same tree
/// are freed too, but blocks shared with files elsewhere stay.
public struct DiskFootprint: Sendable, Hashable, Codable {
    public var allocatedBytes: Int64
    public var exclusiveBytes: Int64

    public init(allocatedBytes: Int64, exclusiveBytes: Int64) {
        self.allocatedBytes = allocatedBytes
        self.exclusiveBytes = exclusiveBytes
    }

    public static let zero = DiskFootprint(allocatedBytes: 0, exclusiveBytes: 0)

    /// Bytes other files share with this tree.
    public var sharedBytes: Int64 { max(allocatedBytes - exclusiveBytes, 0) }

    public static func + (lhs: DiskFootprint, rhs: DiskFootprint) -> DiskFootprint {
        DiskFootprint(allocatedBytes: lhs.allocatedBytes + rhs.allocatedBytes, exclusiveBytes: lhs.exclusiveBytes + rhs.exclusiveBytes)
    }

    public static func += (lhs: inout DiskFootprint, rhs: DiskFootprint) {
        lhs = lhs + rhs
    }
}

public struct SimulatorApp: Identifiable, Hashable, Sendable {
    /// The bundle path is stable across rescans, unlike a random ID.
    public var id: String { bundlePath.path }
    public let name: String
    public let bundleId: String
    public let bundlePath: URL
    public let dataContainerPath: URL?
    public let icon: URL?
    public let bundleFootprint: DiskFootprint
    public let dataFootprint: DiskFootprint

    public init(
        name: String,
        bundleId: String,
        bundlePath: URL,
        dataContainerPath: URL?,
        icon: URL?,
        bundleFootprint: DiskFootprint,
        dataFootprint: DiskFootprint
    ) {
        self.name = name
        self.bundleId = bundleId
        self.bundlePath = bundlePath
        self.dataContainerPath = dataContainerPath
        self.icon = icon
        self.bundleFootprint = bundleFootprint
        self.dataFootprint = dataFootprint
    }

    public var footprint: DiskFootprint { bundleFootprint + dataFootprint }
    public var sizeBytes: Int64 { footprint.allocatedBytes }

    /// Folders inside the app's data container that developers open most often.
    public var documentsURL: URL? { dataContainerPath?.appending(path: "Documents", directoryHint: .isDirectory) }
    public var cachesURL: URL? { dataContainerPath?.appending(path: "Library/Caches", directoryHint: .isDirectory) }
    public var preferencesURL: URL? { dataContainerPath?.appending(path: "Library/Preferences", directoryHint: .isDirectory) }
}

/// Where a device folder lives. Xcode keeps several independent device sets under ~/Library/Developer.
public enum DeviceSetKind: String, Hashable, Sendable, Codable {
    case simulators
    case previews
    case testClones
    case playgrounds

    public static func from(setURL url: URL) -> DeviceSetKind {
        let path = url.path
        if path.contains("/XCTestDevices") { return .testClones }
        if path.contains("/XCPGDevices") { return .playgrounds }
        if path.contains("/Previews/") || url.lastPathComponent == "Simulator Devices" { return .previews }
        return .simulators
    }

    /// Short label shown next to devices that are not regular simulators.
    public var badge: String? {
        switch self {
        case .simulators: return nil
        case .previews: return "Previews"
        case .testClones: return "Test clone"
        case .playgrounds: return "Playground"
        }
    }
}

public struct DeviceSet: Hashable, Sendable {
    public let url: URL
    public let kind: DeviceSetKind

    public init(url: URL, kind: DeviceSetKind) {
        self.url = url
        self.kind = kind
    }

    /// The set CoreSimulator uses when `simctl` gets no `--set`.
    public var isDefaultSet: Bool {
        url.standardizedFileURL.path.hasSuffix("/Library/Developer/CoreSimulator/Devices")
    }
}

/// A simulator's lifecycle state. CoreSimulator reports it as a string through `simctl` and as a
/// number in device.plist; both map here.
public enum DeviceState: Hashable, Sendable, Codable {
    case creating
    case shutdown
    case booting
    case booted
    case shuttingDown
    case unknown(String)

    public init(simctl value: String) {
        switch value.lowercased().replacingOccurrences(of: " ", with: "") {
        case "creating": self = .creating
        case "shutdown": self = .shutdown
        case "booting": self = .booting
        case "booted": self = .booted
        case "shuttingdown": self = .shuttingDown
        default: self = .unknown(value)
        }
    }

    /// The numbers CoreSimulator writes to device.plist.
    public init(plistValue: Int) {
        switch plistValue {
        case 0: self = .creating
        case 1: self = .shutdown
        case 2: self = .booting
        case 3: self = .booted
        case 4: self = .shuttingDown
        default: self = .unknown(String(plistValue))
        }
    }

    public var isRunning: Bool {
        switch self {
        case .booted, .booting, .shuttingDown: return true
        default: return false
        }
    }

    public var title: String {
        switch self {
        case .creating: return "Creating"
        case .shutdown: return "Shut down"
        case .booting: return "Starting"
        case .booted: return "Running"
        case .shuttingDown: return "Shutting down"
        case .unknown(let raw): return raw.isEmpty ? "Unknown" : raw
        }
    }
}

public enum DeviceCategory: String, CaseIterable, Identifiable, Sendable, Codable {
    case iPhone
    case iPad
    case Watch
    case TV
    case Vision
    case Other

    public var id: String { rawValue }

    public static let ordered: [DeviceCategory] = [.iPhone, .iPad, .Watch, .TV, .Vision, .Other]

    public static func from(deviceType: String) -> DeviceCategory {
        let lower = deviceType.lowercased()
        if lower.contains("iphone") { return .iPhone }
        if lower.contains("ipad") { return .iPad }
        if lower.contains("watch") { return .Watch }
        if lower.contains("appletv") || lower.contains("tv") { return .TV }
        if lower.contains("vision") { return .Vision }
        return .Other
    }

    public var title: String {
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

public struct SimulatorDevice: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let deviceType: String
    public let deviceTypeIdentifier: String
    public let runtime: String
    public let runtimeIdentifier: String
    public let runtimeGroup: String
    public let category: DeviceCategory
    public let udid: String
    /// The state device.plist recorded. Stale while CoreSimulator runs the device; `liveState` wins when known.
    public let plistState: DeviceState
    /// `lastUsedAt` (Xcode 27+) or `lastBootedAt` (older Xcode) from device.plist.
    public let lastUsedAt: Date?
    /// The device has booted at least once, even if CoreSimulator recorded no date for it.
    public let hasBootedBefore: Bool
    public let lastModifiedAt: Date?
    public let footprint: DiskFootprint
    public let apps: [SimulatorApp]
    public let rootPath: URL
    public let isDefault: Bool
    public let deviceSet: DeviceSet

    /// What CoreSimulator reports right now, when `simctl` is available.
    public var liveState: DeviceState?
    /// False when CoreSimulator can't run the device, for example because its runtime is gone.
    public var isAvailable: Bool?
    public var availabilityError: String?
    /// True when `simctl` listed the device. False means CoreSimulator doesn't know the folder.
    public var isKnownToSimctl: Bool?

    public init(
        id: String,
        name: String,
        deviceType: String,
        deviceTypeIdentifier: String,
        runtime: String,
        runtimeIdentifier: String,
        runtimeGroup: String,
        category: DeviceCategory,
        udid: String,
        plistState: DeviceState,
        lastUsedAt: Date?,
        hasBootedBefore: Bool,
        lastModifiedAt: Date?,
        footprint: DiskFootprint,
        apps: [SimulatorApp],
        rootPath: URL,
        isDefault: Bool,
        deviceSet: DeviceSet
    ) {
        self.id = id
        self.name = name
        self.deviceType = deviceType
        self.deviceTypeIdentifier = deviceTypeIdentifier
        self.runtime = runtime
        self.runtimeIdentifier = runtimeIdentifier
        self.runtimeGroup = runtimeGroup
        self.category = category
        self.udid = udid
        self.plistState = plistState
        self.lastUsedAt = lastUsedAt
        self.hasBootedBefore = hasBootedBefore
        self.lastModifiedAt = lastModifiedAt
        self.footprint = footprint
        self.apps = apps
        self.rootPath = rootPath
        self.isDefault = isDefault
        self.deviceSet = deviceSet
    }

    public var setKind: DeviceSetKind { deviceSet.kind }
    public var state: DeviceState { liveState ?? plistState }
    public var isBooted: Bool { state == .booted }
    public var appCount: Int { apps.count }
    public var sizeBytes: Int64 { footprint.allocatedBytes }
    public var lastUsed: Date? { lastUsedAt }

    public var lastUsedSortKey: Date {
        if let lastUsedAt { return lastUsedAt }
        // Used-but-undated devices sort just above ones that never booted.
        return hasBootedBefore ? .distantPast.addingTimeInterval(1) : .distantPast
    }

    /// Major and minor version of the runtime, e.g. (27, 0) for com.apple.CoreSimulator.SimRuntime.iOS-27-0.
    public var runtimeVersion: OperatingSystemVersion? {
        RuntimeNaming.version(fromIdentifier: runtimeIdentifier)
    }

    public var platform: SimulatorPlatform? {
        RuntimeNaming.platform(fromIdentifier: runtimeIdentifier)
    }
}

/// The simulator platforms CoreSimulator ships runtimes for.
public enum SimulatorPlatform: String, Sendable, Codable, CaseIterable {
    case iOS
    case tvOS
    case watchOS
    case visionOS

    /// The `CFBundleSupportedPlatforms` value an app built for this simulator carries.
    public var bundlePlatformName: String {
        switch self {
        case .iOS: return "iPhoneSimulator"
        case .tvOS: return "AppleTVSimulator"
        case .watchOS: return "WatchSimulator"
        case .visionOS: return "XRSimulator"
        }
    }
}

public struct ScanResult: Sendable {
    public let devices: [SimulatorDevice]
    public let deviceSets: [DeviceSet]
    /// UUID folders inside a device set without a device.plist (leftovers, not simulators).
    public let leftovers: [LeftoverFolder]
    /// Device set folders that exist but couldn't be listed. Simulators inside them are missing from `devices`.
    public let unreadableLocations: [URL]
    /// Device folders whose device.plist exists but couldn't be read or parsed.
    public let unreadableDeviceCount: Int

    public init(devices: [SimulatorDevice], deviceSets: [DeviceSet], leftovers: [LeftoverFolder], unreadableLocations: [URL], unreadableDeviceCount: Int) {
        self.devices = devices
        self.deviceSets = deviceSets
        self.leftovers = leftovers
        self.unreadableLocations = unreadableLocations
        self.unreadableDeviceCount = unreadableDeviceCount
    }

    public var isPartial: Bool { !unreadableLocations.isEmpty || unreadableDeviceCount > 0 }
    public var footprint: DiskFootprint { devices.reduce(.zero) { $0 + $1.footprint } }
    public var totalSizeBytes: Int64 { footprint.allocatedBytes }
    public var unrecognizedFolderCount: Int { leftovers.count }
    public var unrecognizedSizeBytes: Int64 { leftovers.reduce(0) { $0 + $1.footprint.allocatedBytes } }

    public static let empty = ScanResult(devices: [], deviceSets: [], leftovers: [], unreadableLocations: [], unreadableDeviceCount: 0)
}

/// A UDID-named folder inside a device set that has no device.plist: data CoreSimulator left behind.
public struct LeftoverFolder: Identifiable, Hashable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let deviceSet: DeviceSet
    public let footprint: DiskFootprint
    public let lastModifiedAt: Date?

    public init(url: URL, deviceSet: DeviceSet, footprint: DiskFootprint, lastModifiedAt: Date?) {
        self.url = url
        self.deviceSet = deviceSet
        self.footprint = footprint
        self.lastModifiedAt = lastModifiedAt
    }
}

public struct ScanProgress: Equatable, Sendable {
    public let completed: Int
    public let total: Int

    public init(completed: Int, total: Int) {
        self.completed = completed
        self.total = total
    }

    public var fraction: Double {
        guard total > 0 else { return 0 }
        return Double(completed) / Double(total)
    }

    public var label: String {
        guard total > 0 else { return "Scanning..." }
        let percent = (fraction * 100).rounded()
        return "\(completed)/\(total) • \(Int(percent))%"
    }
}

/// Turns CoreSimulator identifiers into what people read.
public enum RuntimeNaming {
    /// "com.apple.CoreSimulator.SimRuntime.iOS-26-1" → "iOS 26.1"
    public static func friendlyRuntime(_ identifier: String) -> String {
        guard let suffix = identifier.split(separator: ".").last else { return identifier }
        let parts = suffix.split(separator: "-")
        guard parts.count >= 2 else { return String(suffix) }

        let platform: String
        switch parts[0].lowercased() {
        case "ios": platform = "iOS"
        case "tvos": platform = "tvOS"
        case "watchos": platform = "watchOS"
        case "visionos", "xros": platform = "visionOS"
        default: platform = parts[0].capitalized
        }
        return "\(platform) \(parts.dropFirst().joined(separator: "."))"
    }

    /// "iOS 26.1.2" → "iOS 26.1": groups patch versions under one sidebar entry.
    public static func runtimeGroup(_ identifier: String) -> String {
        let friendly = friendlyRuntime(identifier)
        let components = friendly.split(separator: " ")
        guard components.count >= 2 else { return friendly }
        let parts = components[1].split(separator: ".")
        if parts.count >= 2 { return "\(components[0]) \(parts[0]).\(parts[1])" }
        if let first = parts.first { return "\(components[0]) \(first)" }
        return friendly
    }

    /// "com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro" → "iPhone 17 Pro"
    public static func friendlyDeviceType(_ identifier: String, fallback: String) -> String {
        guard let suffix = identifier.split(separator: ".").last, !suffix.isEmpty else { return fallback }
        return suffix.replacingOccurrences(of: "-", with: " ")
    }

    public static func version(fromIdentifier identifier: String) -> OperatingSystemVersion? {
        guard let suffix = identifier.split(separator: ".").last else { return nil }
        let numbers = suffix.split(separator: "-").dropFirst().compactMap { Int($0) }
        guard let major = numbers.first else { return nil }
        return OperatingSystemVersion(majorVersion: major, minorVersion: numbers.dropFirst().first ?? 0, patchVersion: numbers.dropFirst(2).first ?? 0)
    }

    public static func platform(fromIdentifier identifier: String) -> SimulatorPlatform? {
        guard let suffix = identifier.split(separator: ".").last,
              let name = suffix.split(separator: "-").first?.lowercased() else { return nil }
        switch name {
        case "ios": return .iOS
        case "tvos": return .tvOS
        case "watchos": return .watchOS
        case "visionos", "xros": return .visionOS
        default: return nil
        }
    }

    /// Parses "18.2" or "26.4.1" into an OperatingSystemVersion.
    public static func parseVersion(_ string: String) -> OperatingSystemVersion? {
        let numbers = string.split(separator: ".").map { Int($0) }
        guard let first = numbers.first, let major = first else { return nil }
        let minor = numbers.count > 1 ? (numbers[1] ?? 0) : 0
        let patch = numbers.count > 2 ? (numbers[2] ?? 0) : 0
        return OperatingSystemVersion(majorVersion: major, minorVersion: minor, patchVersion: patch)
    }
}

extension OperatingSystemVersion: @retroactive Comparable, @retroactive Equatable {
    public static func < (lhs: OperatingSystemVersion, rhs: OperatingSystemVersion) -> Bool {
        (lhs.majorVersion, lhs.minorVersion, lhs.patchVersion) < (rhs.majorVersion, rhs.minorVersion, rhs.patchVersion)
    }

    public static func == (lhs: OperatingSystemVersion, rhs: OperatingSystemVersion) -> Bool {
        (lhs.majorVersion, lhs.minorVersion, lhs.patchVersion) == (rhs.majorVersion, rhs.minorVersion, rhs.patchVersion)
    }

    public var shortDescription: String {
        patchVersion == 0 ? "\(majorVersion).\(minorVersion)" : "\(majorVersion).\(minorVersion).\(patchVersion)"
    }
}
