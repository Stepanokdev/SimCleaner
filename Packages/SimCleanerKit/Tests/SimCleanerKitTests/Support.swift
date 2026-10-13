//
//  Support.swift
//  SimCleanerKitTests
//

import Foundation
@testable import SimCleanerKit

/// Builds throwaway ~/Library/Developer-shaped folders on disk.
struct Fixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "SimCleanerKitTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    /// Creates `<set>/<udid>/device.plist` plus a small data folder. Returns the device folder.
    @discardableResult
    func addDevice(
        in setPath: String,
        udid: String = UUID().uuidString,
        name: String = "iPhone 18 Pro",
        runtime: String = "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
        state: Int? = 1,
        extra: [String: Any] = [:],
        booted: Bool = false,
        payloadBytes: Int = 4096
    ) throws -> URL {
        let folder = url(setPath).appending(path: udid, directoryHint: .isDirectory)
        let data = folder.appending(path: "data", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        if booted {
            try FileManager.default.createDirectory(at: data.appending(path: "Containers"), withIntermediateDirectories: true)
        }
        try Data(repeating: 1, count: payloadBytes).write(to: data.appending(path: "payload.bin"))

        var plist: [String: Any] = [
            "UDID": udid,
            "name": name,
            "deviceType": "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro",
            "runtime": runtime,
        ]
        if let state { plist["state"] = state }
        plist.merge(extra) { _, new in new }
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
            .write(to: folder.appending(path: "device.plist"))
        return folder
    }

    /// Installs a fake app (bundle + data container with matching metadata) into a device folder.
    @discardableResult
    func addApp(to device: URL, name: String, bundleId: String, iconNames: [String] = []) throws -> URL {
        let bundleContainer = device.appending(path: "data/Containers/Bundle/Application/\(UUID().uuidString)", directoryHint: .isDirectory)
        let app = bundleContainer.appending(path: "\(name).app", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try Data(repeating: 3, count: 8192).write(to: app.appending(path: name))
        for icon in iconNames {
            try Data(repeating: 4, count: icon.count * 100).write(to: app.appending(path: icon))
        }
        try writeMetadata(bundleId, in: bundleContainer)
        let dataContainer = device.appending(path: "data/Containers/Data/Application/\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dataContainer.appending(path: "Documents"), withIntermediateDirectories: true)
        try writeMetadata(bundleId, in: dataContainer)
        return app
    }

    private func writeMetadata(_ identifier: String, in container: URL) throws {
        try PropertyListSerialization.data(fromPropertyList: ["MCMMetadataIdentifier": identifier], format: .binary, options: 0)
            .write(to: container.appending(path: ".com.apple.mobile_container_manager.metadata.plist"))
    }

    /// A UDID-named folder with data but no device.plist, like the leftovers in XCPGDevices.
    @discardableResult
    func addLeftover(in setPath: String) throws -> URL {
        let folder = url(setPath).appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let data = folder.appending(path: "data", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try Data(repeating: 2, count: 4096).write(to: data.appending(path: "leftover.bin"))
        return folder
    }

    func writeDeviceSetPlist(in setPath: String, defaults: [String]) throws {
        let folder = url(setPath)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var runtimeDict: [String: Any] = ["version": 0]
        for (index, udid) in defaults.enumerated() {
            runtimeDict["com.apple.CoreSimulator.SimDeviceType.Device-\(index)"] = udid
        }
        let plist: [String: Any] = ["DefaultDevices": ["com.apple.CoreSimulator.SimRuntime.iOS-27-0": runtimeDict]]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
            .write(to: folder.appending(path: "device_set.plist"))
    }

    func url(_ path: String) -> URL {
        root.appending(path: path, directoryHint: .isDirectory)
    }
}

/// Stands in for simctl: keeps device states and answers the commands SimCleaner sends.
final class FakeSimctl: CommandRunning, @unchecked Sendable {
    struct Device {
        var udid: String
        var name: String
        var state: String
        var runtime: String = "com.apple.CoreSimulator.SimRuntime.iOS-27-0"
        var isAvailable = true
    }

    private let lock = NSLock()
    private var devicesStorage: [Device]
    private var callsStorage: [[String]] = []
    /// Commands (first argument) that should fail, with the stderr simctl would print.
    var failures: [String: String] = [:]
    /// Commands that take this long to answer. Cancelling the task ends the wait with CancellationError,
    /// the way ProcessRunner terminates a real simctl.
    var delays: [String: Duration] = [:]
    /// Commands that never answer in time.
    var timeouts: Set<String> = []
    /// Commands that report success and change nothing, like a shutdown CoreSimulator ignores.
    var inert: Set<String> = []
    /// Called with every command before it's answered; lets a test delete folders like simctl would.
    var onCommand: (@Sendable ([String]) -> Void)?

    init(devices: [Device]) {
        devicesStorage = devices
    }

    var calls: [[String]] { lock.withLock { callsStorage } }
    var devices: [Device] { lock.withLock { devicesStorage } }

    static let tool = SimctlTool(executable: URL(fileURLWithPath: "/usr/bin/xcrun"), leadingArguments: ["simctl"], developerDirectory: nil, source: .xcrun)

    var client: SimctlClient { SimctlClient(tool: Self.tool, runner: self) }

    func run(_ executable: URL, arguments: [String], environment: [String: String]?, standardInput: Data?, timeout: TimeInterval) async throws -> CommandResult {
        var args = Array(arguments.dropFirst()) // "simctl"
        if args.first == "--set" { args.removeFirst(2) }
        lock.withLock { callsStorage.append(args) }
        onCommand?(args)
        let command = args.first ?? ""
        if let delay = delays[command] {
            try await Task.sleep(for: delay)
        }
        if timeouts.contains(command) {
            return CommandResult(status: 15, stdout: Data(), stderr: Data(), timedOut: true)
        }
        if let failure = failures[command] {
            return CommandResult(status: 1, stdout: Data(), stderr: Data(failure.utf8))
        }
        if inert.contains(command) {
            return CommandResult(status: 0, stdout: Data(), stderr: Data())
        }
        switch command {
        case "list":
            return CommandResult(status: 0, stdout: listJSON(), stderr: Data())
        case "shutdown":
            setState(args[1], "Shutdown")
        case "boot", "bootstatus":
            setState(args[1], "Booted")
        case "delete":
            lock.withLock { devicesStorage.removeAll { $0.udid == args[1] } }
        case "erase", "install", "uninstall", "rename":
            break
        case "clone":
            let udid = UUID().uuidString
            lock.withLock { devicesStorage.append(Device(udid: udid, name: args[2], state: "Shutdown")) }
            return CommandResult(status: 0, stdout: Data((udid + "\n").utf8), stderr: Data())
        default:
            return CommandResult(status: 1, stdout: Data(), stderr: Data("Unrecognized subcommand: \(command)".utf8))
        }
        return CommandResult(status: 0, stdout: Data(), stderr: Data())
    }

    func setState(_ udid: String, _ state: String) {
        lock.withLock {
            if let index = devicesStorage.firstIndex(where: { $0.udid == udid }) { devicesStorage[index].state = state }
        }
    }

    private func listJSON() -> Data {
        let grouped = Dictionary(grouping: devices, by: \.runtime).mapValues { devices in
            devices.map { ["udid": $0.udid, "name": $0.name, "state": $0.state, "isAvailable": $0.isAvailable] as [String: Any] }
        }
        return (try? JSONSerialization.data(withJSONObject: ["devices": grouped])) ?? Data()
    }
}
