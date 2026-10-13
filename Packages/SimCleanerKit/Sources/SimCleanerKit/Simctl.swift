//
//  Simctl.swift
//  SimCleanerKit
//

import Foundation

// MARK: - What simctl reports

/// One device from `simctl list devices -j`.
public struct SimctlDevice: Decodable, Sendable, Equatable {
    public let udid: String
    public let name: String
    public let state: String
    public let isAvailable: Bool?
    public let availabilityError: String?
    public let deviceTypeIdentifier: String?
    public let dataPath: String?
    public let dataPathSize: Int64?
    public let lastUsedAt: String?
    /// Filled in from the dictionary key the device is listed under.
    public var runtimeIdentifier: String = ""

    enum CodingKeys: String, CodingKey {
        case udid, name, state, isAvailable, availabilityError, deviceTypeIdentifier, dataPath, dataPathSize, lastUsedAt
    }

    public init(udid: String, name: String, state: String, isAvailable: Bool? = true, availabilityError: String? = nil, deviceTypeIdentifier: String? = nil, dataPath: String? = nil, dataPathSize: Int64? = nil, lastUsedAt: String? = nil, runtimeIdentifier: String = "") {
        self.udid = udid
        self.name = name
        self.state = state
        self.isAvailable = isAvailable
        self.availabilityError = availabilityError
        self.deviceTypeIdentifier = deviceTypeIdentifier
        self.dataPath = dataPath
        self.dataPathSize = dataPathSize
        self.lastUsedAt = lastUsedAt
        self.runtimeIdentifier = runtimeIdentifier
    }

    public var deviceState: DeviceState { DeviceState(simctl: state) }
}

/// One runtime from `simctl list runtimes -j`.
public struct SimctlRuntime: Decodable, Sendable, Equatable {
    public let identifier: String
    public let name: String
    public let version: String
    public let buildversion: String?
    public let isAvailable: Bool?
    public let platform: String?
}

/// One runtime disk image from `simctl runtime list -j`: the downloads that take gigabytes.
public struct SimctlRuntimeImage: Decodable, Sendable, Equatable, Identifiable {
    /// The image's UUID, used by `simctl runtime delete`.
    public var identifier: String
    public let runtimeIdentifier: String?
    public let version: String?
    public let build: String?
    public let sizeBytes: Int64?
    public let lastUsedAt: String?
    public let deletable: Bool?
    public let state: String?
    public let kind: String?
    public let platformIdentifier: String?
    public let path: String?

    public var id: String { identifier }

    public var lastUsedDate: Date? { lastUsedAt.flatMap(SimctlDates.parse) }

    public var platform: SimulatorPlatform? {
        runtimeIdentifier.flatMap(RuntimeNaming.platform(fromIdentifier:))
    }

    public var displayName: String {
        if let runtimeIdentifier {
            let friendly = RuntimeNaming.friendlyRuntime(runtimeIdentifier)
            return build.map { "\(friendly) (\($0))" } ?? friendly
        }
        return version.map { "Runtime \($0)" } ?? identifier
    }
}

enum SimctlDates {
    nonisolated(unsafe) static let withFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    nonisolated(unsafe) static let plain = ISO8601DateFormatter()

    static func parse(_ string: String) -> Date? {
        withFraction.date(from: string) ?? plain.date(from: string)
    }
}

// MARK: - Errors

public enum SimctlError: LocalizedError, Equatable, Sendable {
    /// simctl ran and refused. `code` is the CoreSimulator error code when it printed one (405 means
    /// the device is in the wrong state, for example shut down when the command needs it running).
    case commandFailed(command: String, status: Int32, message: String, code: Int?)
    case timedOut(command: String)
    case unreadableOutput(command: String)

    public var errorDescription: String? {
        switch self {
        case .commandFailed(_, _, let message, _):
            return message.isEmpty ? "simctl failed." : message
        case .timedOut(let command):
            return "simctl didn't answer in time (\(command))."
        case .unreadableOutput(let command):
            return "simctl printed something SimCleaner couldn't read (\(command))."
        }
    }

    public var coreSimulatorCode: Int? {
        if case .commandFailed(_, _, _, let code) = self { return code }
        return nil
    }

    /// CoreSimulator's "Unable to lookup in current state" — the command needs a different device state.
    public var isWrongDeviceState: Bool { coreSimulatorCode == 405 }
}

// MARK: - Locating simctl

/// How SimCleaner runs simctl on this Mac.
public struct SimctlTool: Sendable, Equatable {
    public enum Source: String, Sendable, Equatable {
        /// `xcrun simctl`, outside the App Sandbox.
        case xcrun
        /// The selected Xcode's own simctl binary (Xcode 26 and earlier).
        case xcodeBinary
        /// CoreSimulator's simctl, which Xcode 27's `usr/bin/simctl` script hands over to.
        case coreSimulatorFramework
    }

    public let executable: URL
    public let leadingArguments: [String]
    public let developerDirectory: URL?
    public let source: Source

    public init(executable: URL, leadingArguments: [String], developerDirectory: URL?, source: Source) {
        self.executable = executable
        self.leadingArguments = leadingArguments
        self.developerDirectory = developerDirectory
        self.source = source
    }

    var environment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        if let developerDirectory { environment["DEVELOPER_DIR"] = developerDirectory.path }
        return environment
    }
}

/// Why simctl can't be used. Each case maps to something the person can do about it.
public enum SimctlUnavailable: Error, Equatable, Sendable {
    case noDeveloperDirectory
    case commandLineToolsOnly(String)
    case simctlMissing(String)
    /// Xcode's setup (first launch) hasn't installed the CoreSimulator it needs.
    case coreSimulatorNeedsSetup(installed: String?, required: String)
    case licenseNotAccepted
    case unsupportedToolchain(String)
    case probeFailed(String)

    public var explanation: String {
        switch self {
        case .noDeveloperDirectory:
            return "Xcode isn't installed or selected."
        case .commandLineToolsOnly:
            return "Only the Command Line Tools are selected. Simulators need Xcode: select it with xcode-select or in Xcode › Settings › Locations."
        case .simctlMissing(let path):
            return "The selected Xcode has no simctl at \(path)."
        case .coreSimulatorNeedsSetup:
            return "Xcode hasn't finished installing its simulator components. Open Xcode once and let it finish."
        case .licenseNotAccepted:
            return "The Xcode license hasn't been accepted. Open Xcode once, or run sudo xcodebuild -license."
        case .unsupportedToolchain(let detail):
            return "This version of Xcode isn't supported yet (\(detail))."
        case .probeFailed(let message):
            return message.isEmpty ? "simctl didn't respond." : message
        }
    }
}

public enum SimctlLocator {
    static let xcrun = URL(fileURLWithPath: "/usr/bin/xcrun")
    static let xcodeSelect = URL(fileURLWithPath: "/usr/bin/xcode-select")

    /// Finds a working simctl. Outside the sandbox that's `xcrun simctl`. Inside it `xcrun` refuses to
    /// run, so the selected Xcode's simctl is run directly, after the same checks Xcode 27's wrapper
    /// script would do.
    public static func locate(sandboxed: Bool, runner: CommandRunning, developerDirectory override: URL? = nil) async -> Result<SimctlTool, SimctlUnavailable> {
        let candidate: Result<SimctlTool, SimctlUnavailable>
        if sandboxed {
            candidate = await locateInsideSandbox(runner: runner, override: override)
        } else {
            candidate = .success(SimctlTool(executable: xcrun, leadingArguments: ["simctl"], developerDirectory: override, source: .xcrun))
        }
        guard case .success(let tool) = candidate else { return candidate }
        return await probe(tool, runner: runner)
    }

    static func locateInsideSandbox(runner: CommandRunning, override: URL?) async -> Result<SimctlTool, SimctlUnavailable> {
        guard let developer = await selectedDeveloperDirectory(runner: runner, override: override) else {
            return .failure(.noDeveloperDirectory)
        }
        if developer.path.contains("/CommandLineTools") {
            return .failure(.commandLineToolsOnly(developer.path))
        }
        let simctl = developer.appending(path: "usr/bin/simctl")
        guard let head = try? FileHandle(forReadingFrom: simctl).read(upToCount: 4) else {
            return .failure(.simctlMissing(simctl.path))
        }
        if head.starts(with: Array("#!".utf8)) {
            guard let script = try? String(contentsOf: simctl, encoding: .utf8) else {
                return .failure(.unsupportedToolchain("unreadable simctl script"))
            }
            return wrapperTarget(script: script, developer: developer)
        }
        if MachO.isMachO(head) {
            return .success(SimctlTool(executable: simctl, leadingArguments: [], developerDirectory: developer, source: .xcodeBinary))
        }
        return .failure(.unsupportedToolchain("unknown simctl format"))
    }

    /// Xcode 27's `usr/bin/simctl` is a script that checks CoreSimulator's version, may run
    /// `xcodebuild -runFirstLaunch`, then execs CoreSimulator's simctl. Reads where it would exec and
    /// which version it expects. Anything else in the script is unknown, and unknown means unsupported.
    static func wrapperTarget(script: String, developer: URL, frameworkVersion: (URL) -> String? = installedVersion) -> Result<SimctlTool, SimctlUnavailable> {
        guard let execPath = firstMatch(in: script, pattern: #"exec\s+"(/[^"]+/simctl)""#),
              let expected = firstMatch(in: script, pattern: #"EXPECTED_VERSION="([0-9.]+)""#) else {
            return .failure(.unsupportedToolchain("unrecognized simctl script"))
        }
        let binary = URL(fileURLWithPath: execPath)
        guard binary.path.hasPrefix("/Library/Developer/PrivateFrameworks/CoreSimulator.framework/") else {
            return .failure(.unsupportedToolchain("simctl script points outside CoreSimulator"))
        }
        let infoPlist = binary.deletingLastPathComponent().deletingLastPathComponent().appending(path: "Info.plist")
        guard let installed = frameworkVersion(infoPlist), !VersionString.isOlder(installed, than: expected) else {
            return .failure(.coreSimulatorNeedsSetup(installed: frameworkVersion(infoPlist), required: expected))
        }
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            return .failure(.coreSimulatorNeedsSetup(installed: installed, required: expected))
        }
        return .success(SimctlTool(executable: binary, leadingArguments: [], developerDirectory: developer, source: .coreSimulatorFramework))
    }

    static func installedVersion(infoPlist: URL) -> String? {
        (NSDictionary(contentsOf: infoPlist)?["CFBundleVersion"] as? String)
    }

    static func selectedDeveloperDirectory(runner: CommandRunning, override: URL?) async -> URL? {
        if let override { return override.standardizedFileURL }
        if let fromEnvironment = ProcessInfo.processInfo.environment["DEVELOPER_DIR"], !fromEnvironment.isEmpty {
            return URL(fileURLWithPath: fromEnvironment, isDirectory: true)
        }
        guard let result = try? await runner.run(xcodeSelect, arguments: ["-p"], timeout: 10), result.succeeded else { return nil }
        let path = result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Runs `list devices -j` once. A tool that can't list devices is reported as unavailable with
    /// the reason simctl gave, never treated as "no simulators".
    static func probe(_ tool: SimctlTool, runner: CommandRunning) async -> Result<SimctlTool, SimctlUnavailable> {
        let client = SimctlClient(tool: tool, runner: runner)
        do {
            _ = try await client.listDevices(in: nil)
            return .success(tool)
        } catch let error as SimctlError {
            let message = error.localizedDescription
            if message.localizedCaseInsensitiveContains("license") { return .failure(.licenseNotAccepted) }
            if message.localizedCaseInsensitiveContains("unable to find utility") { return .failure(.commandLineToolsOnly(message)) }
            return .failure(.probeFailed(message))
        } catch {
            return .failure(.probeFailed(error.localizedDescription))
        }
    }

    static func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }
}

/// Compares dotted version strings the way Xcode's simctl script does ("1107.0" equals "1107").
enum VersionString {
    static func components(_ version: String) -> [Int] {
        var parts = version.split(separator: ".").map { Int($0) ?? 0 }
        while parts.count > 1, parts.last == 0 { parts.removeLast() }
        return parts
    }

    static func isOlder(_ lhs: String, than rhs: String) -> Bool {
        let a = components(lhs), b = components(rhs)
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0
            let y = index < b.count ? b[index] : 0
            if x != y { return x < y }
        }
        return false
    }
}

enum MachO {
    static func isMachO(_ head: Data) -> Bool {
        guard head.count >= 4 else { return false }
        let magic = head.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        return [0xfeedfacf, 0xcffaedfe, 0xfeedface, 0xcefaedfe, 0xcafebabe, 0xbebafeca].contains(magic)
    }
}

// MARK: - Running commands

/// Typed simctl commands. Device sets other than the default one are addressed with `--set`.
public struct SimctlClient: Sendable {
    public let tool: SimctlTool
    let runner: CommandRunning

    public init(tool: SimctlTool, runner: CommandRunning = ProcessRunner()) {
        self.tool = tool
        self.runner = runner
    }

    @discardableResult
    func run(_ arguments: [String], set: DeviceSet? = nil, timeout: TimeInterval = 60, input: Data? = nil) async throws -> CommandResult {
        var full = tool.leadingArguments
        if let set, !set.isDefaultSet {
            full += ["--set", set.url.path]
        }
        full += arguments
        let command = arguments.first ?? "simctl"
        let result = try await runner.run(tool.executable, arguments: full, environment: tool.environment, standardInput: input, timeout: timeout)
        if result.timedOut { throw SimctlError.timedOut(command: command) }
        guard result.status == 0 else {
            throw SimctlError.commandFailed(command: command, status: result.status, message: Self.message(from: result.stderrText), code: Self.coreSimulatorCode(in: result.stderrText))
        }
        return result
    }

    /// The readable part of simctl's error output: the line after "An error was encountered…".
    static func message(from stderr: String) -> String {
        let lines = stderr.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if let headerIndex = lines.firstIndex(where: { $0.hasPrefix("An error was encountered") }), headerIndex + 1 < lines.count {
            return lines[headerIndex + 1]
        }
        return lines.first ?? ""
    }

    static func coreSimulatorCode(in stderr: String) -> Int? {
        SimctlLocator.firstMatch(in: stderr, pattern: #"code=(-?[0-9]+)"#).flatMap { Int($0) }
    }

    // MARK: Listing

    public func listDevices(in set: DeviceSet?) async throws -> [SimctlDevice] {
        let result = try await run(["list", "devices", "-j"], set: set, timeout: 30)
        return try Self.decodeDevices(result.stdout)
    }

    static func decodeDevices(_ data: Data) throws -> [SimctlDevice] {
        struct Listing: Decodable { let devices: [String: [SimctlDevice]] }
        guard let listing = try? JSONDecoder().decode(Listing.self, from: data) else {
            throw SimctlError.unreadableOutput(command: "list devices")
        }
        return listing.devices.flatMap { runtime, devices in
            devices.map { device in
                var device = device
                device.runtimeIdentifier = runtime
                return device
            }
        }
    }

    public func listRuntimes() async throws -> [SimctlRuntime] {
        struct Listing: Decodable { let runtimes: [SimctlRuntime] }
        let result = try await run(["list", "runtimes", "-j"], timeout: 30)
        guard let listing = try? JSONDecoder().decode(Listing.self, from: result.stdout) else {
            throw SimctlError.unreadableOutput(command: "list runtimes")
        }
        return listing.runtimes
    }

    /// Runtime disk images. Needs CoreSimulator's disk image service, which the App Sandbox blocks.
    public func listRuntimeImages() async throws -> [SimctlRuntimeImage] {
        let result = try await run(["runtime", "list", "-j"], timeout: 30)
        return try Self.decodeRuntimeImages(result.stdout)
    }

    static func decodeRuntimeImages(_ data: Data) throws -> [SimctlRuntimeImage] {
        struct Image: Decodable {
            let runtimeIdentifier: String?
            let version: String?
            let build: String?
            let sizeBytes: Int64?
            let lastUsedAt: String?
            let deletable: Bool?
            let state: String?
            let kind: String?
            let platformIdentifier: String?
            let path: String?
        }
        guard let images = try? JSONDecoder().decode([String: Image].self, from: data) else {
            throw SimctlError.unreadableOutput(command: "runtime list")
        }
        return images.map { identifier, image in
            SimctlRuntimeImage(
                identifier: identifier,
                runtimeIdentifier: image.runtimeIdentifier,
                version: image.version,
                build: image.build,
                sizeBytes: image.sizeBytes,
                lastUsedAt: image.lastUsedAt,
                deletable: image.deletable,
                state: image.state,
                kind: image.kind,
                platformIdentifier: image.platformIdentifier,
                path: image.path
            )
        }
        .sorted { ($0.runtimeIdentifier ?? "", $0.build ?? "") > ($1.runtimeIdentifier ?? "", $1.build ?? "") }
    }

    // MARK: Device lifecycle

    public func boot(_ udid: String, in set: DeviceSet?) async throws {
        try await run(["boot", udid], set: set, timeout: 120)
    }

    /// Waits until the device has finished booting (`bootstatus -b` boots it first if needed).
    public func waitUntilBooted(_ udid: String, in set: DeviceSet?, timeout: TimeInterval = 300) async throws {
        try await run(["bootstatus", udid, "-b"], set: set, timeout: timeout)
    }

    public func shutdown(_ udid: String, in set: DeviceSet?) async throws {
        try await run(["shutdown", udid], set: set, timeout: 120)
    }

    public func erase(_ udid: String, in set: DeviceSet?) async throws {
        try await run(["erase", udid], set: set, timeout: 180)
    }

    public func delete(_ udid: String, in set: DeviceSet?) async throws {
        try await run(["delete", udid], set: set, timeout: 180)
    }

    /// Returns the new device's UDID.
    public func clone(_ udid: String, name: String, in set: DeviceSet?) async throws -> String {
        let result = try await run(["clone", udid, name], set: set, timeout: 300)
        let newUDID = result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard UUID(uuidString: newUDID) != nil else { throw SimctlError.unreadableOutput(command: "clone") }
        return newUDID
    }

    public func rename(_ udid: String, to name: String, in set: DeviceSet?) async throws {
        try await run(["rename", udid, name], set: set, timeout: 30)
    }

    // MARK: Apps

    public func install(appAt path: URL, on udid: String, in set: DeviceSet?) async throws {
        try await run(["install", udid, path.path], set: set, timeout: 600)
    }

    public func uninstall(_ bundleId: String, from udid: String, in set: DeviceSet?) async throws {
        try await run(["uninstall", udid, bundleId], set: set, timeout: 120)
    }

    // MARK: Runtimes

    /// `--dry-run` prints what would be deleted without deleting anything.
    public func deleteRuntime(_ identifier: String, dryRun: Bool) async throws -> String {
        var arguments = ["runtime", "delete", identifier]
        if dryRun { arguments.append("--dry-run") }
        return try await run(arguments, timeout: 600).stdoutText
    }
}
