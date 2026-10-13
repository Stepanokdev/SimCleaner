//
//  Environment.swift
//  SimCleanerKit
//

import Foundation

/// What this copy of SimCleaner can do on this Mac.
///
/// The App Store edition runs in the App Sandbox. There `simctl` can list, shut down, erase, delete,
/// clone and rename simulators, and manage apps on running ones, but it can't see runtimes, so it
/// can't boot or create simulators or delete runtimes. The Pro edition runs outside the sandbox and
/// can do all of it.
public struct Capabilities: Sendable, Equatable {
    public let isSandboxed: Bool
    public let simctl: Result<SimctlTool, SimctlUnavailable>
    /// CoreSimulator.framework is on this Mac, so something may be using any simulator folder.
    public let coreSimulatorInstalled: Bool

    public init(isSandboxed: Bool, simctl: Result<SimctlTool, SimctlUnavailable>, coreSimulatorInstalled: Bool = DeveloperPaths.coreSimulatorInstalled) {
        self.isSandboxed = isSandboxed
        self.simctl = simctl
        self.coreSimulatorInstalled = coreSimulatorInstalled
    }

    public static var currentProcessIsSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    public static func detect(runner: CommandRunning = ProcessRunner(), developerDirectory: URL? = nil) async -> Capabilities {
        let sandboxed = currentProcessIsSandboxed
        let simctl = await SimctlLocator.locate(sandboxed: sandboxed, runner: runner, developerDirectory: developerDirectory)
        return Capabilities(isSandboxed: sandboxed, simctl: simctl)
    }

    public var simctlTool: SimctlTool? {
        if case .success(let tool) = simctl { return tool }
        return nil
    }

    public var simctlProblem: SimctlUnavailable? {
        if case .failure(let problem) = simctl { return problem }
        return nil
    }

    public var hasSimctl: Bool { simctlTool != nil }

    /// Shut down, erase, delete, clone and rename work through CoreSimulator.
    public var canManageDevices: Bool { hasSimctl }
    /// Deleting goes through simctl. Without it a simulator's folder may only be removed when CoreSimulator
    /// isn't on this Mac at all: a timeout or an unaccepted license proves nothing about what's running.
    public var canDeleteDevices: Bool { hasSimctl || !coreSimulatorInstalled }
    /// Install and uninstall work on simulators that are already running.
    public var canManageAppsOnRunningDevices: Bool { hasSimctl }
    /// Booting needs CoreSimulator's runtime service, which the sandbox blocks.
    public var canBoot: Bool { hasSimctl && !isSandboxed }
    public var canCreate: Bool { canBoot }
    public var canManageRuntimes: Bool { canBoot }
}
