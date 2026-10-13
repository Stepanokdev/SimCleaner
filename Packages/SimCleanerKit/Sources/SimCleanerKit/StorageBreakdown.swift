//
//  StorageBreakdown.swift
//  SimCleanerKit
//

import Foundation

/// The kinds of Xcode data SimCleaner measures, in the order the app's storage bar and
/// `simcleaner storage` list them.
public enum StorageCategory: String, CaseIterable, Sendable, Codable, Identifiable {
    /// Simulators in every device set: regular ones, SwiftUI Preview devices, test clones and playgrounds.
    case simulators
    /// UDID folders CoreSimulator no longer lists.
    case leftovers
    /// The OS images simulators run on.
    case runtimes
    case derivedData
    case deviceSupport
    case agentWorkspaces
    /// The dyld shared caches CoreSimulator builds per runtime and macOS version.
    case simulatorCaches

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .simulators: return "Simulators"
        case .leftovers: return "Leftover simulator folders"
        case .runtimes: return "Runtimes"
        case .derivedData: return DeveloperStorageCategory.derivedData.title
        case .deviceSupport: return DeveloperStorageCategory.deviceSupport.title
        case .agentWorkspaces: return DeveloperStorageCategory.agentWorkspaces.title
        case .simulatorCaches: return "Simulator caches"
        }
    }

    /// The Xcode caches category this is, for the three that `DeveloperStorageScanner` measures.
    public var developerStorageCategory: DeveloperStorageCategory? {
        switch self {
        case .derivedData: return .derivedData
        case .deviceSupport: return .deviceSupport
        case .agentWorkspaces: return .agentWorkspaces
        default: return nil
        }
    }

    public init(_ category: DeveloperStorageCategory) {
        switch category {
        case .derivedData: self = .derivedData
        case .deviceSupport: self = .deviceSupport
        case .agentWorkspaces: self = .agentWorkspaces
        }
    }
}

/// One category's size: how many items and how much space, and how much of it could be read.
public struct StorageLine: Sendable, Equatable {
    public enum Coverage: Sendable, Equatable {
        /// Everything the category covers was read.
        case complete
        /// Some of its folders couldn't be read, so there may be more than counted.
        case partial
        /// None of it could be read: its size is unknown, which is not the same as zero.
        case unreadable
    }

    public let category: StorageCategory
    public let count: Int
    public let footprint: DiskFootprint
    public let coverage: Coverage

    public init(category: StorageCategory, count: Int, footprint: DiskFootprint, coverage: Coverage = .complete) {
        self.category = category
        self.count = count
        self.footprint = footprint
        self.coverage = coverage
    }
}

/// Adds up each category the same way for the app and the command line tool.
public enum StorageBreakdown {
    public static func simulators(_ scan: ScanResult) -> StorageLine {
        StorageLine(category: .simulators, count: scan.devices.count, footprint: scan.footprint, coverage: coverage(count: scan.devices.count, hasUnreadableParts: scan.isPartial))
    }

    /// Empty leftover folders cost nothing, so they aren't counted.
    public static func leftovers(_ scan: ScanResult) -> StorageLine {
        let leftovers = scan.leftovers.filter { $0.footprint.allocatedBytes > 0 }
        return StorageLine(category: .leftovers, count: leftovers.count, footprint: leftovers.reduce(.zero) { $0 + $1.footprint }, coverage: coverage(count: leftovers.count, hasUnreadableParts: scan.isPartial))
    }

    /// A runtime is a disk image nothing else shares, so all of it is freed when it's deleted. Nil when
    /// the runtimes couldn't be listed.
    public static func runtimes(_ entries: [RuntimeEntry]?) -> StorageLine {
        guard let entries else { return StorageLine(category: .runtimes, count: 0, footprint: .zero, coverage: .unreadable) }
        let bytes = entries.reduce(Int64(0)) { $0 + $1.sizeBytes }
        return StorageLine(category: .runtimes, count: entries.count, footprint: DiskFootprint(allocatedBytes: bytes, exclusiveBytes: bytes))
    }

    public static func developer(_ report: DeveloperStorageReport, _ category: DeveloperStorageCategory) -> StorageLine {
        let count = report.items(in: category).count
        let unreadable = report.unreadableLocations.contains { category.contains($0) }
        return StorageLine(category: StorageCategory(category), count: count, footprint: report.footprint(of: category), coverage: coverage(count: count, hasUnreadableParts: unreadable))
    }

    /// Nil when the caches folder couldn't be read.
    public static func simulatorCaches(_ caches: [DyldCacheEntry]?) -> StorageLine {
        guard let caches else { return StorageLine(category: .simulatorCaches, count: 0, footprint: .zero, coverage: .unreadable) }
        return StorageLine(category: .simulatorCaches, count: caches.count, footprint: caches.reduce(.zero) { $0 + $1.footprint })
    }

    /// Some folders couldn't be read: with nothing counted, the category is unknown rather than empty.
    static func coverage(count: Int, hasUnreadableParts: Bool) -> StorageLine.Coverage {
        guard hasUnreadableParts else { return .complete }
        return count == 0 ? .unreadable : .partial
    }

    /// Every category, in `StorageCategory` order. `runtimes` and `simulatorCaches` are nil when they
    /// couldn't be read.
    public static func lines(scan: ScanResult, caches: DeveloperStorageReport, runtimes: [RuntimeEntry]?, simulatorCaches: [DyldCacheEntry]?) -> [StorageLine] {
        StorageCategory.allCases.map { category in
            switch category {
            case .simulators: return Self.simulators(scan)
            case .leftovers: return Self.leftovers(scan)
            case .runtimes: return Self.runtimes(runtimes)
            case .derivedData: return developer(caches, .derivedData)
            case .deviceSupport: return developer(caches, .deviceSupport)
            case .agentWorkspaces: return developer(caches, .agentWorkspaces)
            case .simulatorCaches: return Self.simulatorCaches(simulatorCaches)
            }
        }
    }
}
