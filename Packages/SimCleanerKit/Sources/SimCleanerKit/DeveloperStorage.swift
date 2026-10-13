//
//  DeveloperStorage.swift
//  SimCleanerKit
//

import Foundation

/// Xcode data outside the simulators that grows without anyone noticing.
public enum DeveloperStorageCategory: String, CaseIterable, Sendable, Codable {
    /// Build products and indexes per project. Xcode rebuilds them on the next build.
    case derivedData
    /// Symbols copied from physical devices, one folder per device model and OS build.
    case deviceSupport
    /// Per-task build folders that coding agents (XcodeBuildMCP / MobileBuildMCP) leave behind.
    case agentWorkspaces

    public var title: String {
        switch self {
        case .derivedData: return "DerivedData"
        case .deviceSupport: return "Device support files"
        case .agentWorkspaces: return "Coding agent workspaces"
        }
    }

    public var explanation: String {
        switch self {
        case .derivedData:
            return "Build products, indexes and module caches. Xcode rebuilds what it needs on the next build, so the first build after cleaning takes longer."
        case .deviceSupport:
            return "Debug symbols Xcode copies from each iPhone, iPad, Watch or Apple TV you connect, one folder per OS version. Xcode copies them again when you connect a device on that version."
        case .agentWorkspaces:
            return "Build folders that coding agents create for each task through XcodeBuildMCP or MobileBuildMCP. Finished tasks don't clean them up."
        }
    }
}

public struct DeveloperStorageItem: Identifiable, Hashable, Sendable {
    public var id: String { url.path }
    public let category: DeveloperStorageCategory
    public let url: URL
    public let title: String
    public let detail: String?
    public let footprint: DiskFootprint
    public let lastModifiedAt: Date?
    /// Why this item is suggested for removal, or nil when it's just listed.
    public let recommendation: String?

    public init(category: DeveloperStorageCategory, url: URL, title: String, detail: String?, footprint: DiskFootprint, lastModifiedAt: Date?, recommendation: String?) {
        self.category = category
        self.url = url
        self.title = title
        self.detail = detail
        self.footprint = footprint
        self.lastModifiedAt = lastModifiedAt
        self.recommendation = recommendation
    }

    public var isRecommended: Bool { recommendation != nil }
}

extension DeveloperStorageCategory {
    /// Whether `location` is one of the folders this category is read from.
    public func contains(_ location: URL) -> Bool {
        let path = location.path
        switch self {
        case .derivedData: return path.hasSuffix("/Xcode/DerivedData")
        case .deviceSupport: return path.hasSuffix(" DeviceSupport")
        case .agentWorkspaces: return path.hasSuffix("/workspaces")
        }
    }
}

public struct DeveloperStorageReport: Sendable {
    public let items: [DeveloperStorageItem]
    /// Locations that exist but couldn't be listed.
    public let unreadableLocations: [URL]

    public init(items: [DeveloperStorageItem], unreadableLocations: [URL]) {
        self.items = items
        self.unreadableLocations = unreadableLocations
    }

    public static let empty = DeveloperStorageReport(items: [], unreadableLocations: [])

    public func items(in category: DeveloperStorageCategory) -> [DeveloperStorageItem] {
        items.filter { $0.category == category }
    }

    public func footprint(of category: DeveloperStorageCategory) -> DiskFootprint {
        items(in: category).reduce(.zero) { $0 + $1.footprint }
    }

    public var footprint: DiskFootprint { items.reduce(.zero) { $0 + $1.footprint } }
}

public enum DeveloperStorageScanner {
    /// Agent workspaces older than this are suggested for removal.
    public static let staleAgentWorkspaceAge: TimeInterval = 60 * 60 * 24 * 3

    /// Scans DerivedData, device support folders and agent workspaces inside `developerFolder`
    /// (~/Library/Developer). `fileExists` decides whether a project folder still exists; inside the
    /// App Sandbox it can't see outside the granted folder, so pass nil there and SimCleaner won't
    /// guess that projects are gone.
    public static func scan(developerFolder: URL, now: Date = Date(), fileExists: ((String) -> Bool)? = { FileManager.default.fileExists(atPath: $0) }) -> DeveloperStorageReport {
        var items: [DeveloperStorageItem] = []
        var unreadable: [URL] = []

        let derivedData = developerFolder.appending(path: "Xcode/DerivedData", directoryHint: .isDirectory)
        switch children(of: derivedData) {
        case .success(let folders):
            items += folders.map { derivedDataItem($0, fileExists: fileExists) }
        case .failure(.unreadable):
            unreadable.append(derivedData)
        case .failure(.missing):
            break
        }

        for platform in ["iOS", "watchOS", "tvOS", "visionOS", "macOS"] {
            let location = developerFolder.appending(path: "Xcode/\(platform) DeviceSupport", directoryHint: .isDirectory)
            switch children(of: location) {
            case .success(let folders):
                items += deviceSupportItems(folders, platform: platform)
            case .failure(.unreadable):
                unreadable.append(location)
            case .failure(.missing):
                break
            }
        }

        for tool in ["XcodeBuildMCP", "MobileBuildMCP"] {
            let location = developerFolder.appending(path: "\(tool)/workspaces", directoryHint: .isDirectory)
            switch children(of: location) {
            case .success(let folders):
                items += folders.map { folder in
                    let modified = folder.contentModificationDate
                    // A workspace whose date can't be read hasn't been shown to be stale.
                    let isStale = modified.map { now.timeIntervalSince($0) > staleAgentWorkspaceAge } ?? false
                    return DeveloperStorageItem(
                        category: .agentWorkspaces,
                        url: folder,
                        title: folder.lastPathComponent,
                        detail: tool,
                        footprint: DiskUsage.measure(folder),
                        lastModifiedAt: modified,
                        recommendation: isStale ? "Not touched for more than 3 days." : nil
                    )
                }
            case .failure(.unreadable):
                unreadable.append(location)
            case .failure(.missing):
                break
            }
        }

        return DeveloperStorageReport(items: items.sorted { $0.footprint.allocatedBytes > $1.footprint.allocatedBytes }, unreadableLocations: unreadable)
    }

    enum ListingFailure: Error { case missing, unreadable }

    static func children(of folder: URL) -> Result<[URL], ListingFailure> {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else { return .failure(.missing) }
        guard let entries = try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else {
            return .failure(.unreadable)
        }
        return .success(entries.filter { entry in
            let values = try? entry.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            return values?.isDirectory == true && values?.isSymbolicLink != true
        })
    }

    /// Xcode's shared caches that sit next to the per-project folders.
    static let sharedDerivedDataFolders: [String: String] = [
        "ModuleCache.noindex": "Shared module cache",
        "SDKExplicitPrecompiledModules": "Precompiled SDK modules",
        "SymbolCache.noindex": "Symbol cache",
        "SDKStatCaches.noindex": "SDK stat cache",
        "CompilationCache.noindex": "Compilation cache",
    ]

    static func derivedDataItem(_ folder: URL, fileExists: ((String) -> Bool)?) -> DeveloperStorageItem {
        let name = folder.lastPathComponent
        let footprint = DiskUsage.measure(folder)
        if let sharedTitle = sharedDerivedDataFolders[name] {
            return DeveloperStorageItem(category: .derivedData, url: folder, title: sharedTitle, detail: "Shared by all projects", footprint: footprint, lastModifiedAt: folder.contentModificationDate, recommendation: nil)
        }

        let info = NSDictionary(contentsOf: folder.appending(path: "info.plist"))
        let workspacePath = info?["WorkspacePath"] as? String
        let lastAccessed = info?["LastAccessedDate"] as? Date ?? folder.contentModificationDate
        // "MyApp-abcdefghijklmnopqrstuvwxyz" → "MyApp"
        let projectName = workspacePath.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
            ?? name.split(separator: "-").dropLast().joined(separator: "-")

        var recommendation: String?
        if let workspacePath, let fileExists, !fileExists(workspacePath) {
            recommendation = "The project is no longer at this location."
        }
        return DeveloperStorageItem(
            category: .derivedData,
            url: folder,
            title: projectName.isEmpty ? name : projectName,
            detail: workspacePath.map(abbreviateHome),
            footprint: footprint,
            lastModifiedAt: lastAccessed,
            recommendation: recommendation
        )
    }

    /// A device support folder name: "iPhone12,5 26.4.2 (23E261)", "26.4.2 (23E261) arm64e" or "17.0 (21A329)".
    struct DeviceSupportName: Equatable {
        let model: String?
        let version: OperatingSystemVersion
        let build: String?

        init?(_ name: String) {
            guard let regex = try? NSRegularExpression(pattern: #"^(?:(\S+)\s+)?([0-9]+(?:\.[0-9]+){0,2})(?:\s+\(([^)]+)\))?"#),
                  let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
                  let versionRange = Range(match.range(at: 2), in: name),
                  let version = RuntimeNaming.parseVersion(String(name[versionRange])) else { return nil }
            self.version = version
            self.model = Range(match.range(at: 1), in: name).map { String(name[$0]) }
            self.build = Range(match.range(at: 3), in: name).map { String(name[$0]) }
        }
    }

    /// Lists device support folders and suggests every version older than the newest one Xcode has for
    /// the same device model: the device has moved on, and Xcode copies symbols again if it's needed.
    static func deviceSupportItems(_ folders: [URL], platform: String) -> [DeveloperStorageItem] {
        let parsed = folders.map { ($0, DeviceSupportName($0.lastPathComponent)) }
        var newestByModel: [String: OperatingSystemVersion] = [:]
        for case (_, let name?) in parsed {
            let key = name.model ?? platform
            if newestByModel[key].map({ name.version > $0 }) ?? true { newestByModel[key] = name.version }
        }
        return parsed.map { folder, name in
            var recommendation: String?
            var title = folder.lastPathComponent
            if let name {
                let key = name.model ?? platform
                if let newest = newestByModel[key], name.version < newest {
                    recommendation = "There's a newer \(platform) \(newest.shortDescription) for this device."
                }
                title = "\(platform) \(name.version.shortDescription)" + (name.build.map { " (\($0))" } ?? "")
            }
            return DeveloperStorageItem(
                category: .deviceSupport,
                url: folder,
                title: title,
                detail: name?.model,
                footprint: DiskUsage.measure(folder),
                lastModifiedAt: folder.contentModificationDate,
                recommendation: recommendation
            )
        }
    }

    static func abbreviateHome(_ path: String) -> String {
        let home = DeveloperPaths.realHomeDirectory.path
        return path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
    }

    /// Deletes a scanned item after re-checking that it's a real folder in the expected place.
    public static func remove(_ item: DeveloperStorageItem, developerFolder: URL) throws {
        let expectedParents: [String]
        switch item.category {
        case .derivedData:
            expectedParents = ["Xcode/DerivedData"]
        case .deviceSupport:
            expectedParents = ["iOS", "watchOS", "tvOS", "visionOS", "macOS"].map { "Xcode/\($0) DeviceSupport" }
        case .agentWorkspaces:
            expectedParents = ["XcodeBuildMCP/workspaces", "MobileBuildMCP/workspaces"]
        }
        let parent = item.url.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL.path
        let allowedParents = expectedParents.map { developerFolder.appending(path: $0).resolvingSymlinksInPath().standardizedFileURL.path }
        guard allowedParents.contains(parent) else { throw DeviceOperationError.outsideAllowedLocation }
        try FolderGuard.check(item.url, isInside: developerFolder)
        do {
            try FileManager.default.removeItem(at: item.url)
        } catch {
            throw DeviceOperationError.filesystem(error.localizedDescription)
        }
    }
}
