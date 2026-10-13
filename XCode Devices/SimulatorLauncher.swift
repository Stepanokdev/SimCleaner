//
//  SimulatorLauncher.swift
//  XCode Devices
//

import AppKit
import SimCleanerKit

/// Opens a simulator in whatever Xcode ships for it: Device Hub in Xcode 27, Simulator.app before.
enum SimulatorLauncher {
    static let deviceHubBundleID = "com.apple.dt.Devices"
    static let simulatorAppBundleID = "com.apple.iphonesimulator"

    enum LaunchError: LocalizedError {
        case noSimulatorApp
        case openFailed(String)

        var errorDescription: String? {
            switch self {
            case .noSimulatorApp:
                return "Neither Device Hub (Xcode 27) nor Simulator.app (Xcode 26 and earlier) was found. Install Xcode, or open it once so macOS registers its apps."
            case .openFailed(let reason):
                return reason
            }
        }
    }

    /// Device Hub opens the device's window from its `devices://` URL; it doesn't start a shut-down
    /// device by itself, so Pro boots it first. Simulator.app takes the device on the command line.
    static func open(_ device: SimulatorDevice) async throws {
        let workspace = NSWorkspace.shared
        if workspace.urlForApplication(withBundleIdentifier: deviceHubBundleID) != nil,
           let url = URL(string: "devices://device/open?id=\(device.udid)") {
            guard workspace.open(url) else { throw LaunchError.openFailed("Device Hub didn't open the simulator.") }
            return
        }

        let simulatorApp = workspace.urlForApplication(withBundleIdentifier: simulatorAppBundleID)
            ?? workspace.urlForApplication(withBundleIdentifier: "com.apple.dt.Xcode")?
                .appending(path: "Contents/Developer/Applications/Simulator.app")
        guard let simulatorApp, FileManager.default.fileExists(atPath: simulatorApp.path) else {
            throw LaunchError.noSimulatorApp
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = ["-CurrentDeviceUDID", device.udid]
        do {
            try await workspace.openApplication(at: simulatorApp, configuration: configuration)
        } catch {
            throw LaunchError.openFailed(error.localizedDescription)
        }
    }

    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Opens a folder in Finder, creating nothing: a folder that doesn't exist yet is revealed by its parent.
    static func openFolder(_ url: URL) {
        let fm = FileManager.default
        if fm.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([url.deletingLastPathComponent()])
        }
    }
}
