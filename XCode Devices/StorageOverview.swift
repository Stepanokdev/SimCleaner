//
//  StorageOverview.swift
//  XCode Devices
//
//  What the storage bar under every page shows, worked out from what the scanner has measured.

import AppKit
import SimCleanerKit
import SwiftUI

struct StorageOverview: Equatable {
    enum Measurement: Equatable {
        case measuring
        /// The App Store edition hasn't been given the folder this lives in.
        case noAccess
        /// Nothing in it could be read, or the scan failed: the size is unknown, which is not zero.
        case unreadable
        /// `isPartial`: some folders couldn't be read, so there may be more.
        case measured(Int64, isPartial: Bool)

        /// What the scan found, kept apart from what SimCleaner couldn't read.
        init(_ line: StorageLine) {
            switch line.coverage {
            case .complete:
                self = .measured(line.footprint.allocatedBytes, isPartial: false)
            case .partial where line.footprint.allocatedBytes > 0:
                self = .measured(line.footprint.allocatedBytes, isPartial: true)
            case .partial, .unreadable:
                // "At least zero" says nothing; this is a category SimCleaner couldn't read.
                self = .unreadable
            }
        }

        var bytes: Int64? {
            if case .measured(let bytes, _) = self { return bytes }
            return nil
        }

        /// Fully measured: the figure is the whole of it.
        var isExact: Bool {
            if case .measured(_, isPartial: false) = self { return true }
            return false
        }

        /// Known to be incomplete or unknown, as opposed to still being measured.
        var isUncertain: Bool {
            switch self {
            case .unreadable, .measured(_, isPartial: true): return true
            default: return false
            }
        }
    }

    struct Category: Identifiable, Equatable {
        let kind: StorageCategory
        let measurement: Measurement
        /// Folders or simulators counted, for the help text.
        let count: Int

        var id: StorageCategory { kind }
        var bytes: Int64 { measurement.bytes ?? 0 }
    }

    /// The categories worth listing: everything measured that takes space, and the main ones while
    /// they're still unknown. Unknown is never shown as zero.
    let categories: [Category]
    let volume: VolumeSpace

    /// What all measured categories take, the way Finder adds up sizes.
    var measuredBytes: Int64 { categories.reduce(0) { $0 + $1.bytes } }

    var isComplete: Bool { categories.allSatisfy { $0.measurement.bytes != nil } }

    /// Every category was measured in full, so `measuredBytes` is the whole of Xcode's data rather than
    /// the least of it.
    var isExact: Bool { categories.allSatisfy(\.measurement.isExact) }

    /// The categories that get a segment in the bar.
    var segments: [Category] { categories.filter { $0.bytes > 0 } }

    /// What the bar stands for: Xcode's data and the space still available. Everything else on the disk
    /// is left out, so the categories stay readable on a large disk, and a cleanup moves space from the
    /// coloured part to the empty part while the whole stays the same.
    var barCapacity: Int64 { measuredBytes + volume.availableBytes }
}

extension StorageOverview {
    /// The main categories are listed even before they're measured; the rest only once they take space.
    static let alwaysListed: Set<StorageCategory> = [.simulators, .runtimes, .derivedData, .deviceSupport]

    /// `simulatorScanFailed`: the last simulator scan ended in an error, so there is no list to count.
    /// `runtimes` and `simulatorCaches` are nil when they couldn't be read.
    static func make(
        hasFolderAccess: Bool,
        coversDeveloperFolder: Bool,
        hasScannedSimulators: Bool,
        simulatorScanFailed: Bool,
        scan: ScanResult,
        hasScannedDeveloperStorage: Bool,
        developerStorage: DeveloperStorageReport,
        hasLoadedRuntimes: Bool,
        runtimes: [RuntimeEntry]?,
        simulatorCaches: [DyldCacheEntry]?,
        volume: VolumeSpace
    ) -> StorageOverview {
        var categories: [Category] = []
        for line in StorageBreakdown.lines(scan: scan, caches: developerStorage, runtimes: runtimes, simulatorCaches: simulatorCaches) {
            let kind = line.category
            let measurement: Measurement
            switch kind {
            case .simulators, .leftovers:
                if !hasFolderAccess {
                    measurement = .noAccess
                } else if simulatorScanFailed {
                    measurement = .unreadable
                } else if !hasScannedSimulators {
                    measurement = .measuring
                } else {
                    measurement = Measurement(line)
                }
            case .runtimes, .simulatorCaches:
                // Read from system folders and CoreSimulator, so they don't depend on the folder grant.
                measurement = hasLoadedRuntimes ? Measurement(line) : .measuring
            case .derivedData, .deviceSupport, .agentWorkspaces:
                if !hasFolderAccess || !coversDeveloperFolder {
                    measurement = .noAccess
                } else if !hasScannedDeveloperStorage {
                    measurement = .measuring
                } else {
                    measurement = Measurement(line)
                }
            }
            // Space taken earns a segment. What couldn't be read is listed too, so it's never taken for
            // zero, and the main categories stay listed while they're still being measured.
            let takesSpace = (measurement.bytes ?? 0) > 0
            if takesSpace || measurement.isUncertain || (measurement.bytes == nil && alwaysListed.contains(kind)) {
                categories.append(Category(kind: kind, measurement: measurement, count: line.count))
            }
        }
        return StorageOverview(categories: categories, volume: volume)
    }
}

extension StorageCategory {
    /// Fixed per category, so a colour means the same thing on every page and after every scan. Neighbours
    /// in this order stay apart for colour-blind readers (checked with the dataviz palette validator);
    /// green, yellow and red are left for states.
    var color: Color {
        switch self {
        case .simulators: return Color(nsColor: .systemBlue)
        case .leftovers: return Color(nsColor: .systemMint)
        case .runtimes: return Color(nsColor: .systemPurple)
        case .derivedData: return Color(nsColor: .systemOrange)
        case .deviceSupport: return Color(nsColor: .systemTeal)
        case .agentWorkspaces: return Color(nsColor: .systemPink)
        case .simulatorCaches: return Color(nsColor: .systemIndigo)
        }
    }

    /// The name in the legend, where space is short.
    var shortTitle: String {
        switch self {
        case .leftovers: return "Leftover folders"
        case .deviceSupport: return "Device support"
        case .agentWorkspaces: return "Agent workspaces"
        default: return title
        }
    }

    /// What the category is, for its help tag.
    var explanation: String {
        switch self {
        case .simulators: return "Simulators, SwiftUI Preview devices and test clones."
        case .leftovers: return "Simulator folders CoreSimulator no longer knows about."
        case .runtimes: return "The OS images simulators run on. Every simulator of a version shares one."
        case .derivedData: return "Build products, indexes and caches. Xcode rebuilds them when needed."
        case .deviceSupport: return "Debug symbols Xcode copied from devices you connected."
        case .agentWorkspaces: return "Build folders coding agents left behind."
        case .simulatorCaches: return "System caches CoreSimulator builds for each runtime."
        }
    }

    /// Where clicking the category leads.
    var destination: String {
        switch self {
        case .simulators: return "Show simulators"
        case .leftovers: return "Show suggestions"
        case .runtimes, .simulatorCaches: return "Show runtimes"
        case .derivedData, .deviceSupport, .agentWorkspaces: return "Show in Xcode caches"
        }
    }
}
