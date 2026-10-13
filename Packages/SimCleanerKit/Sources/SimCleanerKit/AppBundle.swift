//
//  AppBundle.swift
//  SimCleanerKit
//

import Foundation

/// An app build someone wants to install on simulators, and what it can run on.
public struct AppBundleInfo: Sendable, Equatable {
    public let url: URL
    public let bundleIdentifier: String
    public let name: String
    public let shortVersion: String?
    public let buildNumber: String?
    public let supportedPlatforms: [String]
    public let minimumOSVersion: OperatingSystemVersion?
    public let architectures: [String]

    public enum ReadError: LocalizedError, Equatable {
        case notAnApp
        case missingInfoPlist
        case missingBundleIdentifier

        public var errorDescription: String? {
            switch self {
            case .notAnApp: return "That's not an app bundle (.app)."
            case .missingInfoPlist: return "The app has no Info.plist."
            case .missingBundleIdentifier: return "The app's Info.plist has no bundle identifier."
            }
        }
    }

    public static func read(_ url: URL) throws -> AppBundleInfo {
        guard url.pathExtension == "app" else { throw ReadError.notAnApp }
        guard let info = NSDictionary(contentsOf: url.appending(path: "Info.plist")) as? [String: Any] else { throw ReadError.missingInfoPlist }
        guard let identifier = info["CFBundleIdentifier"] as? String, !identifier.isEmpty else { throw ReadError.missingBundleIdentifier }
        let executable = (info["CFBundleExecutable"] as? String).map { url.appending(path: $0) }
        return AppBundleInfo(
            url: url,
            bundleIdentifier: identifier,
            name: (info["CFBundleDisplayName"] as? String) ?? (info["CFBundleName"] as? String) ?? url.deletingPathExtension().lastPathComponent,
            shortVersion: info["CFBundleShortVersionString"] as? String,
            buildNumber: info["CFBundleVersion"] as? String,
            supportedPlatforms: info["CFBundleSupportedPlatforms"] as? [String] ?? [],
            minimumOSVersion: (info["MinimumOSVersion"] as? String).flatMap(RuntimeNaming.parseVersion),
            architectures: executable.map(MachOArchitectures.read) ?? []
        )
    }

    public enum Compatibility: Equatable, Sendable {
        case compatible
        case incompatible(String)

        public var reason: String? {
            if case .incompatible(let reason) = self { return reason }
            return nil
        }
    }

    /// Whether this build can be installed on `device`, checked before booting anything.
    public func compatibility(with device: SimulatorDevice, hostArchitecture: String = MachOArchitectures.host) -> Compatibility {
        guard let platform = device.platform else { return .incompatible("Unknown simulator platform.") }
        if supportedPlatforms.contains(where: { $0.hasSuffix("OS") && !$0.hasSuffix("SimulatorOS") }) && !supportedPlatforms.contains(platform.bundlePlatformName) {
            return .incompatible("Built for a physical device, not the simulator.")
        }
        guard supportedPlatforms.isEmpty || supportedPlatforms.contains(platform.bundlePlatformName) else {
            return .incompatible("Built for \(supportedPlatforms.joined(separator: ", ")), not \(platform.rawValue) simulators.")
        }
        if let minimum = minimumOSVersion, let runtime = device.runtimeVersion, runtime < minimum {
            return .incompatible("Needs \(platform.rawValue) \(minimum.shortDescription) or later.")
        }
        if !architectures.isEmpty && !architectures.contains(hostArchitecture) {
            return .incompatible("Built for \(architectures.joined(separator: ", ")) only.")
        }
        if device.isAvailable == false {
            return .incompatible(device.availabilityError ?? "This simulator can't run on this Mac.")
        }
        return .compatible
    }
}

/// Reads which CPU architectures a Mach-O executable contains.
public enum MachOArchitectures {
    #if arch(arm64)
    public static let host = "arm64"
    #else
    public static let host = "x86_64"
    #endif

    public static func read(_ executable: URL) -> [String] {
        guard let handle = try? FileHandle(forReadingFrom: executable),
              let header = try? handle.read(upToCount: 4096), header.count >= 8 else { return [] }
        defer { try? handle.close() }

        func uint32(_ offset: Int, bigEndian: Bool) -> UInt32? {
            guard offset + 4 <= header.count else { return nil }
            let value = header.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
            return bigEndian ? UInt32(bigEndian: value) : UInt32(littleEndian: value)
        }

        guard let magic = uint32(0, bigEndian: true) else { return [] }
        switch magic {
        case 0xcafebabe, 0xcafebabf:
            // Fat binary: big-endian header, then one fat_arch (20 bytes) or fat_arch_64 (32 bytes) per slice.
            let entrySize = magic == 0xcafebabe ? 20 : 32
            guard let count = uint32(4, bigEndian: true), count < 32 else { return [] }
            return (0..<Int(count)).compactMap { index in
                uint32(8 + index * entrySize, bigEndian: true).flatMap(name(ofCPUType:))
            }
        case 0xcffaedfe, 0xcefaedfe:
            return uint32(4, bigEndian: false).flatMap(name(ofCPUType:)).map { [$0] } ?? []
        default:
            return []
        }
    }

    static func name(ofCPUType type: UInt32) -> String? {
        switch type {
        case 0x0100000C: return "arm64"
        case 0x01000007: return "x86_64"
        case 0x0200000C: return "arm64_32"
        default: return nil
        }
    }
}

public enum RecentBuilds {
    /// Simulator builds in DerivedData, newest first: the .app bundles Xcode just built, which are what
    /// people want to install on more simulators.
    public static func find(in developerFolder: URL, limit: Int = 8) -> [URL] {
        let fm = FileManager.default
        let derivedData = developerFolder.appending(path: "Xcode/DerivedData", directoryHint: .isDirectory)
        guard let projects = try? fm.contentsOfDirectory(at: derivedData, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        var builds: [(url: URL, date: Date)] = []
        for project in projects {
            let products = project.appending(path: "Build/Products", directoryHint: .isDirectory)
            guard let configurations = try? fm.contentsOfDirectory(at: products, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { continue }
            for configuration in configurations where configuration.lastPathComponent.hasSuffix("simulator") {
                guard let apps = try? fm.contentsOfDirectory(at: configuration, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]) else { continue }
                for app in apps where app.pathExtension == "app" {
                    builds.append((app, app.contentModificationDate ?? .distantPast))
                }
            }
        }
        return builds.sorted { $0.date > $1.date }.prefix(limit).map(\.url)
    }
}
