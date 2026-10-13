//
//  Display.swift
//  XCode Devices
//
//  How sizes, dates and states read in the window.

import Foundation
import SimCleanerKit

/// Pure formatting, so it's usable from any isolation.
nonisolated enum ByteText {
    static func string(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// "—" for zero, so empty rows don't read as "Zero KB".
    static func orDash(_ bytes: Int64) -> String {
        bytes > 0 ? string(bytes) : "—"
    }

    /// What deleting frees: a single figure when shared blocks don't matter, a range when they do.
    static func freed(_ footprint: DiskFootprint) -> String {
        let low = footprint.exclusiveBytes
        let high = footprint.allocatedBytes
        // Within 5% the range is noise; show one number.
        if high == 0 { return "nothing" }
        if Double(high - low) / Double(high) < 0.05 { return string(high) }
        return "\(string(low))–\(string(high))"
    }

    static func percent(_ value: Int64, of total: Int64) -> String {
        guard total > 0 else { return "0%" }
        return (Double(value) / Double(total) * 100).formatted(.number.precision(.fractionLength(1))) + "%"
    }
}

extension RelativeDateTimeFormatter {
    static let shared: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()
}

extension SimulatorDevice {
    var sizeDescription: String { ByteText.string(sizeBytes) }

    var lastUsedDescription: String {
        if let lastUsedAt {
            return lastUsedAt.relativeDescription
        }
        return hasBootedBefore ? "Date unknown" : "Never launched"
    }

    /// Short state shown in the table. Unavailable devices say so before anything else.
    var stateDescription: String {
        if isAvailable == false { return "Unavailable" }
        return state.title
    }
}

extension SimulatorApp {
    var sizeDescription: String { ByteText.string(sizeBytes) }
}

extension Date {
    /// "2 days ago". The last minute, and a moment ahead when a folder's clock runs early, is "Just now"
    /// rather than "in 0 seconds".
    var relativeDescription: String {
        if abs(timeIntervalSinceNow) < 60 { return "Just now" }
        return RelativeDateTimeFormatter.shared.localizedString(for: self, relativeTo: .now)
    }
}
