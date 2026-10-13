//
//  RuntimeInventory.swift
//  SimCleanerKit
//

import Foundation

/// A downloaded simulator runtime: the OS image every simulator of that version shares.
public struct RuntimeEntry: Identifiable, Hashable, Sendable {
    public enum Source: Hashable, Sendable {
        /// From `simctl runtime list`; the ID is what `simctl runtime delete` takes.
        case simctl(imageID: String)
        /// Read from the asset folder, where the App Sandbox can still see sizes.
        case assetFolder(URL)
    }

    public let source: Source
    public let platform: SimulatorPlatform?
    public let version: String?
    public let build: String?
    public let runtimeIdentifier: String?
    public let sizeBytes: Int64
    public let lastUsedAt: Date?
    public let isDeletable: Bool?
    public let state: String?
    public var deviceCount: Int

    public init(source: Source, platform: SimulatorPlatform?, version: String?, build: String?, runtimeIdentifier: String?, sizeBytes: Int64, lastUsedAt: Date?, isDeletable: Bool?, state: String?, deviceCount: Int = 0) {
        self.source = source
        self.platform = platform
        self.version = version
        self.build = build
        self.runtimeIdentifier = runtimeIdentifier
        self.sizeBytes = sizeBytes
        self.lastUsedAt = lastUsedAt
        self.isDeletable = isDeletable
        self.state = state
        self.deviceCount = deviceCount
    }

    public var id: String {
        switch source {
        case .simctl(let imageID): return imageID
        case .assetFolder(let url): return url.path
        }
    }

    public var title: String {
        let name = [platform?.rawValue ?? "Runtime", version].compactMap { $0 }.joined(separator: " ")
        return build.map { "\(name) (\($0))" } ?? name
    }

    public var simctlImageID: String? {
        if case .simctl(let imageID) = source { return imageID }
        return nil
    }
}

/// The per-runtime dyld shared cache CoreSimulator builds for each macOS version.
public struct DyldCacheEntry: Identifiable, Hashable, Sendable {
    public var id: String { url.path }
    public let url: URL
    public let macOSBuild: String
    public let runtimeName: String
    public let footprint: DiskFootprint
    /// Caches built for an older macOS are never used again after a macOS update.
    public let isForCurrentMacOS: Bool
}

public enum RuntimeInventory {
    public static let assetsRoot = URL(fileURLWithPath: "/System/Library/AssetsV2", isDirectory: true)
    public static let dyldCachesRoot = URL(fileURLWithPath: "/Library/Developer/CoreSimulator/Caches/dyld", isDirectory: true)

    /// Runtimes as `simctl runtime list` reports them. Outside the sandbox only.
    public static func entries(from images: [SimctlRuntimeImage], devices: [SimulatorDevice]) -> [RuntimeEntry] {
        images.map { image in
            RuntimeEntry(
                source: .simctl(imageID: image.identifier),
                platform: image.platform,
                version: image.version,
                build: image.build,
                runtimeIdentifier: image.runtimeIdentifier,
                sizeBytes: image.sizeBytes ?? 0,
                lastUsedAt: image.lastUsedDate,
                isDeletable: image.deletable,
                state: image.state,
                deviceCount: devices.filter { $0.runtimeIdentifier == image.runtimeIdentifier }.count
            )
        }
    }

    /// Runtimes read straight from /System/Library/AssetsV2. Works inside the App Sandbox, which can
    /// read the folders but can't ask CoreSimulator about them. A folder that isn't there holds no
    /// runtimes; one that is there but can't be read throws, so an unreadable list is never taken for an
    /// empty one.
    public static func entriesFromAssetFolders(devices: [SimulatorDevice], root: URL = assetsRoot) throws -> [RuntimeEntry] {
        let fm = FileManager.default
        if DiskUsage.isGone(root) { return [] }
        let collections = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        var entries: [RuntimeEntry] = []
        for collection in collections where collection.lastPathComponent.contains("SimulatorRuntime") {
            let platform = platform(fromAssetCollection: collection.lastPathComponent)
            let assets = try fm.contentsOfDirectory(at: collection, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            for asset in assets where asset.pathExtension == "asset" {
                let properties = (NSDictionary(contentsOf: asset.appending(path: "Info.plist"))?["MobileAssetProperties"] as? [String: Any]) ?? [:]
                let version = properties["SimulatorVersion"] as? String
                let build = properties["Build"] as? String
                let identifier = platform.flatMap { platform in
                    version.map { "com.apple.CoreSimulator.SimRuntime.\(platform.identifierName)-\($0.replacingOccurrences(of: ".", with: "-"))" }
                }
                entries.append(RuntimeEntry(
                    source: .assetFolder(asset),
                    platform: platform,
                    version: version,
                    build: build,
                    runtimeIdentifier: identifier,
                    sizeBytes: DiskUsage.measure(asset).allocatedBytes,
                    lastUsedAt: nil,
                    isDeletable: nil,
                    state: nil,
                    deviceCount: identifier.map { id in devices.filter { $0.runtimeIdentifier == id }.count } ?? 0
                ))
            }
        }
        return entries.sorted { ($0.platform?.rawValue ?? "", $0.version ?? "") > ($1.platform?.rawValue ?? "", $1.version ?? "") }
    }

    static func platform(fromAssetCollection name: String) -> SimulatorPlatform? {
        let lower = name.lowercased()
        if lower.contains("watchos") { return .watchOS }
        if lower.contains("tvos") || lower.contains("appletv") { return .tvOS }
        if lower.contains("xros") || lower.contains("visionos") { return .visionOS }
        if lower.contains("ios") { return .iOS }
        return nil
    }

    /// dyld caches CoreSimulator keeps per macOS build and runtime. No folder means no caches, as on a
    /// Mac whose runtimes ship with their own; a folder that can't be read throws.
    public static func dyldCaches(root: URL = dyldCachesRoot, currentMacOSBuild: String? = currentMacOSBuild()) throws -> [DyldCacheEntry] {
        let fm = FileManager.default
        if DiskUsage.isGone(root) { return [] }
        let builds = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        var entries: [DyldCacheEntry] = []
        for build in builds where build.isDirectory {
            let runtimes = try fm.contentsOfDirectory(at: build, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
            for runtime in runtimes where runtime.isDirectory && runtime.lastPathComponent.hasPrefix("com.apple.CoreSimulator.SimRuntime.") {
                let name = runtime.lastPathComponent.replacingOccurrences(of: "com.apple.CoreSimulator.SimRuntime.", with: "")
                let parts = name.split(separator: ".", maxSplits: 1)
                let friendly = RuntimeNaming.friendlyRuntime("com.apple.CoreSimulator.SimRuntime." + (parts.first.map(String.init) ?? name))
                entries.append(DyldCacheEntry(
                    url: runtime,
                    macOSBuild: build.lastPathComponent,
                    runtimeName: parts.count > 1 ? "\(friendly) (\(parts[1]))" : friendly,
                    footprint: DiskUsage.measure(runtime),
                    isForCurrentMacOS: build.lastPathComponent == currentMacOSBuild
                ))
            }
        }
        return entries
    }

    public static func currentMacOSBuild() -> String? {
        var size = 0
        guard sysctlbyname("kern.osversion", nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname("kern.osversion", &buffer, &size, nil, 0) == 0 else { return nil }
        return buffer.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
    }
}

extension SimulatorPlatform {
    /// The platform name inside runtime identifiers, e.g. "xrOS" in com.apple.CoreSimulator.SimRuntime.xrOS-26-0.
    var identifierName: String {
        switch self {
        case .iOS: return "iOS"
        case .tvOS: return "tvOS"
        case .watchOS: return "watchOS"
        case .visionOS: return "xrOS"
        }
    }
}
