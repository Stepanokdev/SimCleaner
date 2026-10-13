//
//  CleanupAdvisor.swift
//  SimCleanerKit
//

import Foundation

/// A group of simulators worth cleaning up, with the reason and what to do about them.
public struct CleanupSuggestion: Identifiable, Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        /// Used before, untouched for a while. Erasing keeps the device in Xcode's lists and frees its data.
        case idle
        /// CoreSimulator can't run them, usually because their runtime was deleted.
        case unavailable
        /// Xcode 27's Device Hub doesn't take keyboard or mouse input on these.
        case unsupportedByDeviceHub
        /// Folders without a device.plist that CoreSimulator doesn't list.
        case leftovers
    }

    public enum Action: String, Sendable {
        case erase
        case delete
    }

    public let kind: Kind
    public let title: String
    public let detail: String
    public let devices: [SimulatorDevice]
    public let leftovers: [LeftoverFolder]
    public let action: Action

    public var id: Kind { kind }

    public var footprint: DiskFootprint {
        devices.reduce(.zero) { $0 + $1.footprint } + leftovers.reduce(.zero) { $0 + $1.footprint }
    }
}

public enum CleanupAdvisor {
    /// Below this, erasing a simulator isn't worth suggesting: a fresh one takes about 20 MB.
    static let minimumIdleFootprint: Int64 = 100_000_000

    public static func suggestions(for scan: ScanResult, now: Date = Date(), idleDays: Int, deviceHubInstalled: Bool) -> [CleanupSuggestion] {
        var suggestions: [CleanupSuggestion] = []
        let cutoff = now.addingTimeInterval(-Double(idleDays) * 86_400)

        let idle = scan.devices.filter { device in
            guard !device.state.isRunning, device.hasBootedBefore, device.isAvailable != false else { return false }
            guard device.footprint.exclusiveBytes >= minimumIdleFootprint else { return false }
            let lastActivity = device.lastUsedAt ?? device.lastModifiedAt
            return lastActivity.map { $0 < cutoff } ?? true
        }
        if !idle.isEmpty {
            suggestions.append(CleanupSuggestion(
                kind: .idle,
                title: "Not used for \(idleDays) days",
                detail: "Erasing removes their apps, data and caches but keeps the simulators in Xcode and Device Hub, as fresh as when they were created.",
                devices: idle.sorted { $0.footprint.exclusiveBytes > $1.footprint.exclusiveBytes },
                leftovers: [],
                action: .erase
            ))
        }

        let unavailable = scan.devices.filter { $0.isAvailable == false }
        if !unavailable.isEmpty {
            suggestions.append(CleanupSuggestion(
                kind: .unavailable,
                title: "Can't run on this Mac",
                detail: "CoreSimulator can't start these, usually because their runtime was removed. Xcode won't offer them as run destinations.",
                devices: unavailable,
                leftovers: [],
                action: .delete
            ))
        }

        if deviceHubInstalled {
            let old = scan.devices.filter { device in
                device.platform == .iOS && device.isAvailable != false && (device.runtimeVersion.map { $0.majorVersion < 18 } ?? false)
            }
            if !old.isEmpty {
                suggestions.append(CleanupSuggestion(
                    kind: .unsupportedByDeviceHub,
                    title: "Older than iOS 18",
                    detail: "Device Hub in Xcode 27 doesn't accept keyboard or mouse input on simulators older than iOS 18. Keep them only if you test with another tool.",
                    devices: old,
                    leftovers: [],
                    action: .delete
                ))
            }
        }

        // Empty leftover folders cost nothing; listing them would only be noise.
        let leftovers = scan.leftovers.filter { $0.footprint.allocatedBytes > 0 }
        if !leftovers.isEmpty {
            suggestions.append(CleanupSuggestion(
                kind: .leftovers,
                title: "Leftover folders",
                detail: "Folders in a simulator location that have no simulator info. CoreSimulator doesn't list them, so nothing uses them.",
                devices: [],
                leftovers: leftovers,
                action: .delete
            ))
        }

        return suggestions
    }
}
