//
//  DeviceOperations.swift
//  SimCleanerKit
//

import Foundation

public enum DeviceOperationError: LocalizedError, Equatable, Sendable {
    case outsideAllowedLocation
    case folderChanged
    case stateUnknown
    case stillRunning
    case requiresRunningDevice
    case simctlUnavailable(String)
    case simctl(String)
    case notRemoved
    case filesystem(String)
    /// SimCleaner started the simulator for an operation and couldn't shut it down again.
    case leftRunning(String)

    public var errorDescription: String? {
        switch self {
        case .outsideAllowedLocation:
            return "The folder is outside the location SimCleaner was given."
        case .folderChanged:
            return "The folder changed since the last scan."
        case .stateUnknown:
            return "SimCleaner can't confirm the simulator is shut down, so it left it alone."
        case .stillRunning:
            return "The simulator is still running."
        case .requiresRunningDevice:
            return "Start the simulator first. Apps can only be removed from a running simulator."
        case .simctlUnavailable(let reason):
            return reason
        case .simctl(let message):
            return message
        case .notRemoved:
            return "CoreSimulator reported success, but the simulator is still there."
        case .filesystem(let message):
            return message
        case .leftRunning(let message):
            return message
        }
    }
}

/// Changes simulators. Everything goes through CoreSimulator when `simctl` is available, so Xcode,
/// Device Hub and simctl stay in sync with the disk.
///
/// The rule this type exists to keep: when simctl refuses, times out or answers something unexpected,
/// the operation stops. A failed simctl call is no evidence that the device is shut down, so it is
/// never followed by deleting its folder. Folders are removed directly only for devices CoreSimulator
/// confirmed it doesn't list, or when CoreSimulator isn't on this Mac at all, and only when their
/// device.plist says they're shut down.
public struct DeviceController: Sendable {
    public let simctl: SimctlClient?
    /// Why `simctl` is nil, for the message when an operation needs it.
    public let simctlProblem: SimctlUnavailable?
    /// While CoreSimulator is installed, only simctl may delete a simulator.
    public let coreSimulatorInstalled: Bool
    /// Booting needs runtimes, which the App Sandbox hides. Only the Pro edition may boot.
    public let canBoot: Bool
    /// Folders may only be removed inside this location.
    public let allowedRoot: URL
    /// How long to wait for a device to reach a state.
    var stateTimeout: TimeInterval = 90
    var pollInterval: TimeInterval = 1

    public init(
        simctl: SimctlClient?,
        canBoot: Bool,
        allowedRoot: URL,
        simctlProblem: SimctlUnavailable? = nil,
        coreSimulatorInstalled: Bool = DeveloperPaths.coreSimulatorInstalled
    ) {
        self.simctl = simctl
        self.canBoot = canBoot
        self.allowedRoot = allowedRoot
        self.simctlProblem = simctlProblem
        self.coreSimulatorInstalled = coreSimulatorInstalled
    }

    public init(capabilities: Capabilities, runner: CommandRunning = ProcessRunner(), allowedRoot: URL) {
        self.init(
            simctl: capabilities.simctlTool.map { SimctlClient(tool: $0, runner: runner) },
            canBoot: capabilities.canBoot,
            allowedRoot: allowedRoot,
            simctlProblem: capabilities.simctlProblem,
            coreSimulatorInstalled: capabilities.coreSimulatorInstalled
        )
    }

    var restorer: ShutdownRestorer? {
        simctl.map { ShutdownRestorer(simctl: $0, timeout: stateTimeout, pollInterval: pollInterval) }
    }

    // MARK: Deleting

    public func delete(_ device: SimulatorDevice) async throws {
        guard let simctl else {
            // Without simctl nothing proves the simulator isn't in use, unless CoreSimulator isn't on this
            // Mac at all. A timeout, an unaccepted license or a failed check is no such proof.
            guard !coreSimulatorInstalled else {
                throw DeviceOperationError.simctlUnavailable("\(unavailableReason) SimCleaner deletes simulators only through Xcode's tools while CoreSimulator is installed, so it left this one alone.")
            }
            try removeLeftoverDeviceFolder(device)
            return
        }
        guard let current = try await currentState(of: device, using: simctl) else {
            // CoreSimulator doesn't list this folder, so simctl can't delete it either.
            try removeLeftoverDeviceFolder(device)
            return
        }
        if current.deviceState.isRunning {
            try await shutDownAndWait(device, using: simctl)
        }
        do {
            try await simctl.delete(device.udid, in: device.deviceSet)
        } catch let error as SimctlError {
            throw DeviceOperationError.simctl(error.localizedDescription)
        }
        if try await currentState(of: device, using: simctl) != nil {
            throw DeviceOperationError.notRemoved
        }
    }

    /// Removes a device folder nothing can be using: CoreSimulator said it doesn't list it, or isn't on this
    /// Mac. Proves first that it's the same folder that was scanned and that device.plist says shut down.
    public func removeLeftoverDeviceFolder(_ device: SimulatorDevice) throws {
        let folder = device.rootPath
        try FolderGuard.check(folder, isInside: allowedRoot)
        guard folder.lastPathComponent == device.udid else { throw DeviceOperationError.outsideAllowedLocation }
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        guard SimulatorScanner.readUDID(inDeviceFolder: folder) == device.udid else { throw DeviceOperationError.folderChanged }
        guard SimulatorScanner.readPlistState(inDeviceFolder: folder) == .shutdown else { throw DeviceOperationError.stateUnknown }
        do {
            try FileManager.default.removeItem(at: folder)
        } catch {
            throw DeviceOperationError.filesystem(error.localizedDescription)
        }
    }

    /// Removes a UDID-named folder without a device.plist. CoreSimulator never lists these.
    public func removeLeftover(_ leftover: LeftoverFolder) throws {
        let folder = leftover.url
        try FolderGuard.check(folder, isInside: allowedRoot)
        guard UUID(uuidString: folder.lastPathComponent) != nil else { throw DeviceOperationError.outsideAllowedLocation }
        guard !FileManager.default.fileExists(atPath: folder.appending(path: "device.plist").path) else { throw DeviceOperationError.folderChanged }
        do {
            try FileManager.default.removeItem(at: folder)
        } catch {
            throw DeviceOperationError.filesystem(error.localizedDescription)
        }
    }

    // MARK: Other lifecycle operations

    /// Erases contents and settings. The device stays, as fresh as when it was created.
    public func erase(_ device: SimulatorDevice) async throws {
        let simctl = try requireSimctl()
        guard let current = try await currentState(of: device, using: simctl) else { throw DeviceOperationError.stateUnknown }
        if current.deviceState.isRunning {
            try await shutDownAndWait(device, using: simctl)
        }
        do {
            try await simctl.erase(device.udid, in: device.deviceSet)
        } catch let error as SimctlError {
            throw DeviceOperationError.simctl(error.localizedDescription)
        }
    }

    public func shutDown(_ device: SimulatorDevice) async throws {
        let simctl = try requireSimctl()
        try await shutDownAndWait(device, using: simctl)
    }

    public func boot(_ device: SimulatorDevice) async throws {
        let simctl = try requireSimctl()
        guard canBoot else { throw DeviceOperationError.simctlUnavailable("Starting simulators needs SimCleaner Pro.") }
        do {
            try await simctl.waitUntilBooted(device.udid, in: device.deviceSet)
        } catch let error as SimctlError {
            throw DeviceOperationError.simctl(error.localizedDescription)
        }
    }

    /// Returns the clone's UDID. The source must be shut down; CoreSimulator copies it as an APFS clone.
    public func duplicate(_ device: SimulatorDevice, name: String) async throws -> String {
        let simctl = try requireSimctl()
        guard let current = try await currentState(of: device, using: simctl), current.deviceState == .shutdown else {
            throw DeviceOperationError.stillRunning
        }
        do {
            return try await simctl.clone(device.udid, name: name, in: device.deviceSet)
        } catch let error as SimctlError {
            throw DeviceOperationError.simctl(error.localizedDescription)
        }
    }

    public func rename(_ device: SimulatorDevice, to name: String) async throws {
        let simctl = try requireSimctl()
        do {
            try await simctl.rename(device.udid, to: name, in: device.deviceSet)
        } catch let error as SimctlError {
            throw DeviceOperationError.simctl(error.localizedDescription)
        }
    }

    /// Uninstalls one app. CoreSimulator only manages apps on a running device: the App Store edition
    /// asks the person to start it, Pro starts it and shuts it down again afterwards, whether the removal
    /// worked, failed or was cancelled.
    public func uninstall(_ app: SimulatorApp, from device: SimulatorDevice) async throws {
        let simctl = try requireSimctl()
        guard let current = try await currentState(of: device, using: simctl) else { throw DeviceOperationError.stateUnknown }
        let startedHere = current.deviceState != .booted
        if startedHere {
            guard canBoot, current.deviceState == .shutdown else { throw DeviceOperationError.requiresRunningDevice }
        }
        var failure: Error?
        do {
            if startedHere { try await boot(device) }
            try Task.checkCancellation()
            try await simctl.uninstall(app.bundleId, from: device.udid, in: device.deviceSet)
        } catch let error as SimctlError {
            failure = DeviceOperationError.simctl(error.localizedDescription)
        } catch {
            failure = error
        }
        if startedHere, let restorer, let problem = await restorer.restore(device) {
            let before = failure.map { "\($0.localizedDescription) " } ?? ""
            throw DeviceOperationError.leftRunning("\(before)SimCleaner started \(device.name) for this and couldn't shut it down again: \(problem)")
        }
        if let failure { throw failure }
    }

    // MARK: Helpers

    var unavailableReason: String {
        simctlProblem?.explanation ?? "Xcode's simulator tools aren't available."
    }

    func requireSimctl() throws -> SimctlClient {
        guard let simctl else { throw DeviceOperationError.simctlUnavailable("\(unavailableReason) This needs them.") }
        return simctl
    }

    /// The device as CoreSimulator lists it right now, or nil when it isn't listed.
    func currentState(of device: SimulatorDevice, using simctl: SimctlClient) async throws -> SimctlDevice? {
        do {
            return try await simctl.listDevices(in: device.deviceSet).first { $0.udid == device.udid }
        } catch let error as SimctlError {
            throw DeviceOperationError.simctl(error.localizedDescription)
        }
    }

    func shutDownAndWait(_ device: SimulatorDevice, using simctl: SimctlClient) async throws {
        guard let current = try await currentState(of: device, using: simctl) else { throw DeviceOperationError.stateUnknown }
        if current.deviceState == .shutdown { return }
        do {
            try await simctl.shutdown(device.udid, in: device.deviceSet)
        } catch let error as SimctlError where error.isWrongDeviceState {
            // Already shutting down or shut down between the two calls; the wait below decides.
        } catch let error as SimctlError {
            throw DeviceOperationError.simctl(error.localizedDescription)
        }
        let deadline = Date().addingTimeInterval(stateTimeout)
        while Date() < deadline {
            guard let state = try await currentState(of: device, using: simctl)?.deviceState else { return }
            if state == .shutdown { return }
            try await Task.sleep(for: .seconds(pollInterval))
        }
        throw DeviceOperationError.stillRunning
    }
}

/// Shuts down a simulator SimCleaner started for an operation and waits until CoreSimulator reports it shut
/// down. It runs to the end even when the operation was cancelled, and gives up after `timeout`.
struct ShutdownRestorer: Sendable {
    let simctl: SimctlClient
    var timeout: TimeInterval = 90
    var pollInterval: TimeInterval = 1

    /// Nil once the simulator is shut down, or gone; otherwise why it isn't.
    func restore(_ device: SimulatorDevice) async -> String? {
        let simctl = simctl, timeout = timeout, pollInterval = pollInterval
        return await Task.detached {
            var commandError: String?
            do {
                try await simctl.shutdown(device.udid, in: device.deviceSet)
            } catch let error as SimctlError where error.isWrongDeviceState {
                // Shut down or shutting down already; the state below decides.
            } catch {
                commandError = error.localizedDescription
            }
            let deadline = Date().addingTimeInterval(timeout)
            while true {
                let state: DeviceState?
                do {
                    state = try await simctl.listDevices(in: device.deviceSet).first { $0.udid == device.udid }?.deviceState
                } catch {
                    return "CoreSimulator didn't say whether it's shut down (\(error.localizedDescription))"
                }
                guard let state, state != .shutdown else { return nil }
                if let commandError { return commandError }
                if Date() >= deadline { return "it's still \(state.title.lowercased()) after \(Int(timeout)) seconds." }
                try? await Task.sleep(for: .seconds(pollInterval))
            }
        }.value
    }
}

/// Checks that a folder SimCleaner is about to delete is where it should be.
public enum FolderGuard {
    /// Throws unless `folder` is a real directory (not a symlink) strictly inside `root`, on the same
    /// volume, and outside Device Hub's DeviceFS mount.
    public static func check(_ folder: URL, isInside root: URL) throws {
        let fm = FileManager.default
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        // Resolve the parent only, so a symlinked folder is judged by itself, not by its target.
        let parent = folder.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        let candidate = parent.appending(path: folder.lastPathComponent).path
        guard candidate.hasPrefix(rootPrefix) else { throw DeviceOperationError.outsideAllowedLocation }

        let deviceFS = DeveloperPaths.deviceFSMount.resolvingSymlinksInPath().standardizedFileURL.path
        guard !(candidate == deviceFS || candidate.hasPrefix(deviceFS + "/")) else { throw DeviceOperationError.outsideAllowedLocation }

        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: candidate, isDirectory: &isDirectory) else { return }
        let attributes = try? fm.attributesOfItem(atPath: candidate)
        guard attributes?[.type] as? FileAttributeType == .typeDirectory, isDirectory.boolValue else {
            throw DeviceOperationError.outsideAllowedLocation
        }
        if let rootDevice = DiskUsage.deviceID(of: URL(fileURLWithPath: rootPath)),
           let folderDevice = DiskUsage.deviceID(of: URL(fileURLWithPath: candidate)),
           rootDevice != folderDevice {
            throw DeviceOperationError.outsideAllowedLocation
        }
    }
}
