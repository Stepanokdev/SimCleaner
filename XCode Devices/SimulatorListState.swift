//
//  SimulatorListState.swift
//  XCode Devices
//

import Foundation

/// What the simulator list area shows. Kept separate from the view so each state can be tested.
enum SimulatorListState: Equatable {
    case needsAccess
    /// The granted folder is where macOS keeps runtimes (e.g. /System/Library/AssetsV2), not simulators.
    case runtimeFolder
    case error(String)
    case loading
    /// Nothing listed, but some simulator folders couldn't be read: not a definitive "empty".
    case unreadableFolders
    /// The granted folder contains no device sets at all (wrong folder).
    case noDeviceFolders
    /// Device sets exist but hold no simulators.
    case noSimulators
    /// Simulators exist, but the current filter or search hides all of them.
    case noMatches
    case list

    nonisolated static func isRuntimeLocation(_ url: URL) -> Bool {
        let path = url.standardizedFileURL.path
        return path.hasPrefix("/System/") || path.hasPrefix("/Library/Developer/CoreSimulator")
    }

    nonisolated static func resolve(
        hasFolderAccess: Bool,
        scannedURL: URL,
        errorMessage: String?,
        isLoading: Bool,
        hasCompletedScan: Bool,
        deviceCount: Int,
        filteredCount: Int,
        deviceSetCount: Int,
        isScanPartial: Bool
    ) -> SimulatorListState {
        guard hasFolderAccess else { return .needsAccess }
        // Checked before errors: the sandbox may refuse to list a system folder, and the useful answer
        // is still "these are runtimes", not a raw permission error.
        if isRuntimeLocation(scannedURL) && deviceCount == 0 && !isLoading { return .runtimeFolder }
        if let errorMessage { return .error(errorMessage) }
        if isLoading && deviceCount == 0 { return .loading }
        if deviceCount == 0 && hasCompletedScan {
            if isScanPartial { return .unreadableFolders }
            return deviceSetCount == 0 ? .noDeviceFolders : .noSimulators
        }
        if filteredCount == 0 { return .noMatches }
        return .list
    }
}
