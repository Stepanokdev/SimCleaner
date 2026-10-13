//
//  OperationTests.swift
//  SimCleanerKitTests
//

import Darwin
import Foundation
import Testing
@testable import SimCleanerKit

struct DiskUsageTests {
    @Test func clonesCountInFullButFreeAlmostNothing() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = fixture.url("a/original.bin")
        try FileManager.default.createDirectory(at: source.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 7, count: 2_000_000).write(to: source)
        let copy = fixture.url("b/clone.bin")
        try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard clonefile(source.path, copy.path, 0) == 0 else {
            // Not APFS (e.g. a RAM disk temp folder): nothing to prove here.
            return
        }

        let a = DiskUsage.measure(fixture.url("a"))
        let b = DiskUsage.measure(fixture.url("b"))
        #expect(a.allocatedBytes >= 2_000_000)
        #expect(b.allocatedBytes >= 2_000_000)
        // Each copy shares every block with the other.
        #expect(a.exclusiveBytes < 100_000)
        #expect(b.exclusiveBytes < 100_000)

        // Once one copy is gone, the other owns its blocks.
        try FileManager.default.removeItem(at: copy)
        #expect(DiskUsage.measure(fixture.url("a")).exclusiveBytes >= 2_000_000)
    }

    @Test func symlinksAreNotFollowed() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let target = fixture.url("big")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 1_000_000).write(to: target.appending(path: "file.bin"))
        let tree = fixture.url("tree")
        try FileManager.default.createDirectory(at: tree, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: tree.appending(path: "link"), withDestinationURL: target)

        #expect(DiskUsage.measure(tree).allocatedBytes < 100_000)
    }
}

struct FolderGuardTests {
    @Test func refusesFoldersOutsideTheRoot() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let root = fixture.url("root")
        let outside = fixture.url("outside")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)

        #expect(throws: DeviceOperationError.outsideAllowedLocation) { try FolderGuard.check(outside, isInside: root) }
        #expect(throws: DeviceOperationError.outsideAllowedLocation) { try FolderGuard.check(root, isInside: root) }
        #expect(throws: DeviceOperationError.outsideAllowedLocation) { try FolderGuard.check(root.appending(path: "../outside"), isInside: root) }
    }

    @Test func refusesSymlinkPretendingToBeAFolder() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let root = fixture.url("root")
        let elsewhere = fixture.url("elsewhere")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let link = root.appending(path: "looks-like-a-folder")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: elsewhere)

        #expect(throws: DeviceOperationError.outsideAllowedLocation) { try FolderGuard.check(link, isInside: root) }
    }

    @Test func refusesDeviceFS() throws {
        let deviceFS = DeveloperPaths.deviceFSMount.appending(path: "device-1234")
        #expect(throws: DeviceOperationError.outsideAllowedLocation) {
            try FolderGuard.check(deviceFS, isInside: DeveloperPaths.developerFolder)
        }
    }
}

struct DeviceControllerTests {
    private let set = "Library/Developer/CoreSimulator/Devices"

    private func scan(_ fixture: Fixture) throws -> [SimulatorDevice] {
        try SimulatorScanner.loadDevices(at: fixture.url("Library/Developer")).devices
    }

    @Test func runningDeviceIsShutDownThenDeletedThroughSimctl() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let udid = UUID().uuidString
        let folder = try fixture.addDevice(in: set, udid: udid, state: 3, booted: true)
        let fake = FakeSimctl(devices: [.init(udid: udid, name: "iPhone", state: "Booted")])
        fake.onCommand = { args in
            if args.first == "delete" { try? FileManager.default.removeItem(at: folder) }
        }
        let controller = DeviceController(simctl: fake.client, canBoot: false, allowedRoot: fixture.url("Library/Developer"))
        let device = try #require(try scan(fixture).first)

        try await controller.delete(device)

        let commands = fake.calls.map { $0.first ?? "" }
        #expect(commands.contains("shutdown"))
        #expect(commands.firstIndex(of: "shutdown")! < commands.firstIndex(of: "delete")!)
        #expect(!FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func simctlFailureNeverFallsBackToDeletingTheFolder() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let udid = UUID().uuidString
        let folder = try fixture.addDevice(in: set, udid: udid, state: 1)
        let fake = FakeSimctl(devices: [.init(udid: udid, name: "iPhone", state: "Shutdown")])
        fake.failures["delete"] = "An error was encountered processing the command (domain=NSPOSIXErrorDomain, code=1):\nOperation not permitted"
        let controller = DeviceController(simctl: fake.client, canBoot: false, allowedRoot: fixture.url("Library/Developer"))
        let device = try #require(try scan(fixture).first)

        await #expect(throws: DeviceOperationError.simctl("Operation not permitted")) {
            try await controller.delete(device)
        }
        #expect(FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func folderUnknownToSimctlIsRemovedOnlyWhenPlistSaysShutDown() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let off = try fixture.addDevice(in: set, name: "Off", state: 1)
        let running = try fixture.addDevice(in: set, name: "Running", state: 3)
        let unknown = try fixture.addDevice(in: set, name: "Unknown", state: nil)
        let fake = FakeSimctl(devices: [])
        let controller = DeviceController(simctl: fake.client, canBoot: false, allowedRoot: fixture.url("Library/Developer"))
        let devices = try scan(fixture)

        try await controller.delete(try #require(devices.first { $0.name == "Off" }))
        await #expect(throws: DeviceOperationError.stateUnknown) { try await controller.delete(try #require(devices.first { $0.name == "Running" })) }
        await #expect(throws: DeviceOperationError.stateUnknown) { try await controller.delete(try #require(devices.first { $0.name == "Unknown" })) }

        #expect(!FileManager.default.fileExists(atPath: off.path))
        #expect(FileManager.default.fileExists(atPath: running.path))
        #expect(FileManager.default.fileExists(atPath: unknown.path))
        #expect(!fake.calls.contains { $0.first == "delete" })
    }

    @Test func folderThatChangedSinceTheScanIsLeftAlone() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let folder = try fixture.addDevice(in: set, name: "Original", state: 1)
        let device = try #require(try scan(fixture).first)
        try PropertyListSerialization.data(fromPropertyList: ["UDID": UUID().uuidString, "name": "Other", "state": 1], format: .binary, options: 0)
            .write(to: folder.appending(path: "device.plist"))
        let controller = DeviceController(simctl: nil, canBoot: false, allowedRoot: fixture.url("Library/Developer"), coreSimulatorInstalled: false)

        await #expect(throws: DeviceOperationError.folderChanged) { try await controller.delete(device) }
        #expect(FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func folderOutsideTheGrantedRootIsLeftAlone() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let outside = try fixture.addDevice(in: "Elsewhere/Devices", name: "Outside", state: 1)
        let device = try #require(try SimulatorScanner.loadDevices(at: fixture.url("Elsewhere/Devices")).devices.first)
        let controller = DeviceController(simctl: nil, canBoot: false, allowedRoot: fixture.url("Library/Developer"), coreSimulatorInstalled: false)

        await #expect(throws: DeviceOperationError.outsideAllowedLocation) { try await controller.delete(device) }
        #expect(FileManager.default.fileExists(atPath: outside.path))
    }

    @Test(arguments: [
        SimctlUnavailable.licenseNotAccepted,
        .probeFailed("simctl didn't answer in time (list)."),
        .coreSimulatorNeedsSetup(installed: "1100", required: "1171.7"),
        .unsupportedToolchain("unrecognized simctl script"),
        .noDeveloperDirectory,
    ])
    func withoutSimctlNothingIsDeletedWhileCoreSimulatorIsInstalled(problem: SimctlUnavailable) async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let folder = try fixture.addDevice(in: set, name: "Off", state: 1)
        let controller = DeviceController(simctl: nil, canBoot: false, allowedRoot: fixture.url("Library/Developer"), simctlProblem: problem, coreSimulatorInstalled: true)

        let error = await #expect(throws: DeviceOperationError.self) { try await controller.delete(try #require(try scan(fixture).first)) }
        #expect(error?.localizedDescription.hasPrefix(problem.explanation) == true)
        #expect(FileManager.default.fileExists(atPath: folder.path))
    }

    @Test func withoutCoreSimulatorOnlyShutDownFoldersAreRemoved() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let off = try fixture.addDevice(in: set, name: "Off", state: 1)
        let running = try fixture.addDevice(in: set, name: "Running", state: 3)
        let controller = DeviceController(simctl: nil, canBoot: false, allowedRoot: fixture.url("Library/Developer"), simctlProblem: .noDeveloperDirectory, coreSimulatorInstalled: false)
        let devices = try scan(fixture)

        try await controller.delete(try #require(devices.first { $0.name == "Off" }))
        await #expect(throws: DeviceOperationError.stateUnknown) { try await controller.delete(try #require(devices.first { $0.name == "Running" })) }
        #expect(!FileManager.default.fileExists(atPath: off.path))
        #expect(FileManager.default.fileExists(atPath: running.path))
    }

    @Test func aTimeoutWhileCheckingTheDeviceStopsTheDeletion() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let udid = UUID().uuidString
        let folder = try fixture.addDevice(in: set, udid: udid, state: 1)
        let fake = FakeSimctl(devices: [.init(udid: udid, name: "iPhone", state: "Shutdown")])
        fake.timeouts = ["list"]
        let controller = DeviceController(simctl: fake.client, canBoot: false, allowedRoot: fixture.url("Library/Developer"))

        await #expect(throws: DeviceOperationError.simctl("simctl didn't answer in time (list).")) {
            try await controller.delete(try #require(try scan(fixture).first))
        }
        #expect(FileManager.default.fileExists(atPath: folder.path))
        #expect(!fake.calls.contains { $0.first == "delete" })
    }

    @Test func uninstallNeedsARunningDeviceWithoutPro() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let udid = UUID().uuidString
        let folder = try fixture.addDevice(in: set, udid: udid, state: 1, booted: true)
        try fixture.addApp(to: folder, name: "Demo", bundleId: "com.example.demo")
        let fake = FakeSimctl(devices: [.init(udid: udid, name: "iPhone", state: "Shutdown")])
        let device = try #require(try scan(fixture).first)
        let app = try #require(device.apps.first)

        let appStore = DeviceController(simctl: fake.client, canBoot: false, allowedRoot: fixture.url("Library/Developer"))
        await #expect(throws: DeviceOperationError.requiresRunningDevice) { try await appStore.uninstall(app, from: device) }
        #expect(!fake.calls.contains { $0.first == "boot" || $0.first == "bootstatus" })

        let pro = DeviceController(simctl: fake.client, canBoot: true, allowedRoot: fixture.url("Library/Developer"))
        try await pro.uninstall(app, from: device)
        let commands = fake.calls.map { $0.first ?? "" }
        #expect(commands.contains("bootstatus"))
        #expect(commands.contains("uninstall"))
        // Pro started it for the uninstall, so it shuts it down again.
        #expect(commands.last { $0 != "list" } == "shutdown")
        #expect(fake.devices.first?.state == "Shutdown")
    }

    /// A shut-down device with one app, and the fake simctl that knows it.
    private func shutDownDeviceWithApp(_ fixture: Fixture) throws -> (SimulatorDevice, SimulatorApp, FakeSimctl) {
        let udid = UUID().uuidString
        let folder = try fixture.addDevice(in: set, udid: udid, state: 1, booted: true)
        try fixture.addApp(to: folder, name: "Demo", bundleId: "com.example.demo")
        let device = try #require(try scan(fixture).first)
        return (device, try #require(device.apps.first), FakeSimctl(devices: [.init(udid: udid, name: "iPhone", state: "Shutdown")]))
    }

    @Test func uninstallShutsDownAgainWhenStartingTimesOut() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let (device, app, fake) = try shutDownDeviceWithApp(fixture)
        fake.timeouts = ["bootstatus"]
        fake.onCommand = { args in if args.first == "bootstatus" { fake.setState(args[1], "Booting") } }
        let pro = DeviceController(simctl: fake.client, canBoot: true, allowedRoot: fixture.url("Library/Developer"))

        await #expect(throws: DeviceOperationError.simctl("simctl didn't answer in time (bootstatus).")) { try await pro.uninstall(app, from: device) }
        #expect(fake.devices.first?.state == "Shutdown")
        #expect(!fake.calls.contains { $0.first == "uninstall" })
    }

    @Test func cancelledUninstallStillShutsDown() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let (device, app, fake) = try shutDownDeviceWithApp(fixture)
        fake.delays["uninstall"] = .seconds(30)
        let pro = DeviceController(simctl: fake.client, canBoot: true, allowedRoot: fixture.url("Library/Developer"))

        let task = Task { try await pro.uninstall(app, from: device) }
        try await waitUntil { fake.calls.contains { $0.first == "uninstall" } }
        task.cancel()

        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(fake.devices.first?.state == "Shutdown")
        #expect(fake.calls.last { $0.first != "list" }?.first == "shutdown")
    }

    @Test func uninstallSaysWhenTheSimulatorWontShutDownAgain() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let (device, app, fake) = try shutDownDeviceWithApp(fixture)
        fake.inert = ["shutdown"]
        var pro = DeviceController(simctl: fake.client, canBoot: true, allowedRoot: fixture.url("Library/Developer"))
        pro.stateTimeout = 0.3
        pro.pollInterval = 0.05

        let error = await #expect(throws: DeviceOperationError.self) { try await pro.uninstall(app, from: device) }
        guard case .leftRunning(let message) = error else { Issue.record("expected leftRunning, got \(String(describing: error))"); return }
        #expect(message.contains("couldn't shut it down again"))
        #expect(message.contains("still running"))
        #expect(fake.calls.contains { $0.first == "uninstall" })
    }

    @Test func eraseShutsDownARunningDeviceFirst() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let udid = UUID().uuidString
        try fixture.addDevice(in: set, udid: udid, state: 3, booted: true)
        let fake = FakeSimctl(devices: [.init(udid: udid, name: "iPhone", state: "Booted")])
        let controller = DeviceController(simctl: fake.client, canBoot: false, allowedRoot: fixture.url("Library/Developer"))

        try await controller.erase(try #require(try scan(fixture).first))
        let commands = fake.calls.map { $0.first ?? "" }.filter { $0 != "list" }
        #expect(commands == ["shutdown", "erase"])
    }

    @Test func nonDefaultSetsAreAddressedWithSet() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let udid = UUID().uuidString
        try fixture.addDevice(in: "Library/Developer/XCTestDevices", udid: udid, state: 1)
        let recorder = RecordingRunner()
        let client = SimctlClient(tool: FakeSimctl.tool, runner: recorder)
        let device = try #require(try scan(fixture).first)

        _ = try? await client.listDevices(in: device.deviceSet)
        let arguments = try #require(recorder.arguments.first)
        #expect(arguments.prefix(3) == ["simctl", "--set", device.deviceSet.url.path])
    }
}

/// Polls until `condition` holds, for tests that cancel work at a known point.
func waitUntil(timeout: Duration = .seconds(5), _ condition: @Sendable () -> Bool) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while !condition() {
        guard clock.now < deadline else { Issue.record("Timed out waiting"); return }
        try await Task.sleep(for: .milliseconds(10))
    }
}

/// Records arguments and answers every command with an empty device list.
final class RecordingRunner: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [[String]] = []
    var arguments: [[String]] { lock.withLock { recorded } }

    func run(_ executable: URL, arguments: [String], environment: [String: String]?, standardInput: Data?, timeout: TimeInterval) async throws -> CommandResult {
        lock.withLock { recorded.append(arguments) }
        return CommandResult(status: 0, stdout: Data(#"{"devices":{}}"#.utf8), stderr: Data())
    }
}
