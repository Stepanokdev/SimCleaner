//
//  BatchInstaller.swift
//  SimCleanerKit
//

import Foundation

/// Where one simulator is in a batch install.
public enum InstallPhase: Equatable, Sendable {
    case waiting
    case starting
    case installing
    case shuttingDown
    case installed
    case skipped(String)
    case failed(String)
    case cancelled
    /// SimCleaner started the simulator for the install and couldn't shut it down again. `installed` says
    /// whether the app got there before that; `reason` says what happened, for people.
    case leftRunning(installed: Bool, reason: String)

    public var isFinished: Bool {
        switch self {
        case .installed, .skipped, .failed, .cancelled, .leftRunning: return true
        default: return false
        }
    }

    /// The app is installed and the simulator is back in the state it was found in.
    public var isFulfilled: Bool { self == .installed }

    /// True only when every simulator asked for got the app and was left as it was found. A target with
    /// no result never got that far.
    public static func allFulfilled(_ results: [String: InstallPhase], for targets: [SimulatorDevice]) -> Bool {
        !targets.isEmpty && targets.allSatisfy { results[$0.udid]?.isFulfilled == true }
    }
}

/// Installs one build on many simulators: the supported replacement for sharing app bundles between
/// simulators. Every copy is a real install with its own data; APFS clones the bundle, so the copies
/// cost almost no disk space.
///
/// Simulators that were shut down are started, get the app and are shut down again, a few at a time.
/// Running ones get the app and keep running. Cancelling stops new work; a simulator that was started
/// for the install is still shut down, and if that fails the result says so.
public struct BatchInstaller: Sendable {
    public let simctl: SimctlClient
    public let maxConcurrentBoots: Int
    /// Starting simulators needs the Pro edition; without it only running simulators are installed on.
    public let canBoot: Bool
    /// How long to wait for a simulator SimCleaner started to shut down again.
    var restoreTimeout: TimeInterval = 90
    var pollInterval: TimeInterval = 1

    public init(simctl: SimctlClient, canBoot: Bool, maxConcurrentBoots: Int = 2) {
        self.simctl = simctl
        self.canBoot = canBoot
        self.maxConcurrentBoots = max(1, maxConcurrentBoots)
    }

    public typealias ProgressHandler = @Sendable (_ udid: String, _ phase: InstallPhase) -> Void

    @discardableResult
    public func install(_ app: AppBundleInfo, on devices: [SimulatorDevice], progress: @escaping ProgressHandler) async -> [String: InstallPhase] {
        var results: [String: InstallPhase] = [:]
        var queue: [SimulatorDevice] = []
        for device in devices {
            if case .incompatible(let reason) = app.compatibility(with: device) {
                results[device.udid] = .skipped(reason)
                progress(device.udid, .skipped(reason))
            } else {
                queue.append(device)
                progress(device.udid, .waiting)
            }
        }

        await withTaskGroup(of: (String, InstallPhase).self) { group in
            var iterator = queue.makeIterator()
            func startNext() -> Bool {
                guard let device = iterator.next() else { return false }
                group.addTask {
                    (device.udid, await installOne(app, on: device, progress: progress))
                }
                return true
            }
            for _ in 0..<maxConcurrentBoots where startNext() {}
            while let (udid, phase) = await group.next() {
                results[udid] = phase
                progress(udid, phase)
                if Task.isCancelled {
                    // Report what never started; the running ones finish and clean up.
                    while let device = iterator.next() {
                        results[device.udid] = .cancelled
                        progress(device.udid, .cancelled)
                    }
                } else {
                    _ = startNext()
                }
            }
        }
        return results
    }

    func installOne(_ app: AppBundleInfo, on device: SimulatorDevice, progress: ProgressHandler) async -> InstallPhase {
        if Task.isCancelled { return .cancelled }
        let listed: SimctlDevice?
        do {
            listed = try await simctl.listDevices(in: device.deviceSet).first { $0.udid == device.udid }
        } catch {
            return .failed(error.localizedDescription)
        }
        guard let listed else { return .failed("CoreSimulator doesn't list this simulator.") }

        let startedHere = listed.deviceState != .booted
        if startedHere {
            guard listed.deviceState == .shutdown else { return .failed("The simulator is \(listed.deviceState.title.lowercased()).") }
            guard canBoot else { return .skipped("Not running. Start it first, or use SimCleaner Pro.") }
            progress(device.udid, .starting)
        }

        var outcome: InstallPhase
        do {
            if startedHere { try await simctl.waitUntilBooted(device.udid, in: device.deviceSet) }
            try Task.checkCancellation()
            progress(device.udid, .installing)
            try await simctl.install(appAt: app.url, on: device.udid, in: device.deviceSet)
            outcome = .installed
        } catch {
            outcome = Task.isCancelled || error is CancellationError ? .cancelled : .failed(error.localizedDescription)
        }
        guard startedHere else { return outcome }

        // Whatever happened above, a simulator SimCleaner started goes back to shut down.
        progress(device.udid, .shuttingDown)
        let restorer = ShutdownRestorer(simctl: simctl, timeout: restoreTimeout, pollInterval: pollInterval)
        guard let problem = await restorer.restore(device) else { return outcome }
        let notShutDown = "SimCleaner started it for the install and couldn't shut it down again: \(problem)"
        switch outcome {
        case .installed:
            return .leftRunning(installed: true, reason: "Installed, but \(notShutDown)")
        case .failed(let reason):
            return .leftRunning(installed: false, reason: "\(reason) \(notShutDown)")
        default:
            return .leftRunning(installed: false, reason: "Cancelled. \(notShutDown)")
        }
    }
}
