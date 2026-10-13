//
//  IntegrationTests.swift
//  SimCleanerKitTests
//
//  Runs against the real simctl in a throwaway device set. Off by default because it needs Xcode and
//  a runtime; turn it on with SIMCLEANER_INTEGRATION=1. Nothing outside the throwaway set is touched.

import Foundation
import Testing
@testable import SimCleanerKit

struct RealSimctlTests {
    static let enabled = ProcessInfo.processInfo.environment["SIMCLEANER_INTEGRATION"] == "1"

    @Test(.enabled(if: RealSimctlTests.enabled))
    func lifecycleInAThrowawaySet() async throws {
        let fixture = try Fixture()
        let setURL = fixture.url("Set")
        try FileManager.default.createDirectory(at: setURL, withIntermediateDirectories: true)
        let set = DeviceSet(url: setURL, kind: .simulators)
        let tool = try await SimctlLocator.locate(sandboxed: false, runner: ProcessRunner()).get()
        let client = SimctlClient(tool: tool)
        defer {
            _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/xcrun"), arguments: ["simctl", "--set", setURL.path, "delete", "all"]).waitUntilExit()
            fixture.remove()
        }

        let runtime = try #require(try await client.listRuntimes().last { $0.isAvailable == true && $0.identifier.contains(".iOS-") })
        let created = try await client.run(["create", "SimCleaner integration", "com.apple.CoreSimulator.SimDeviceType.iPhone-17", runtime.identifier], set: set)
        let udid = created.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(UUID(uuidString: udid) != nil)

        // Clones are APFS clones: the copy owns almost none of its bytes.
        let controller = DeviceController(simctl: client, canBoot: true, allowedRoot: fixture.root)
        var scan = try SimulatorScanner.loadDevices(at: setURL)
        let original = try #require(scan.devices.first { $0.udid == udid })
        let cloneUDID = try await controller.duplicate(original, name: "SimCleaner integration copy")
        scan = try SimulatorScanner.loadDevices(at: setURL)
        let clone = try #require(scan.devices.first { $0.udid == cloneUDID })
        #expect(clone.footprint.exclusiveBytes * 100 < max(clone.footprint.allocatedBytes, 1))

        // Install needs a running device: CoreSimulator answers 405 on a shut-down one.
        let app = fixture.url("Empty.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        await #expect(throws: SimctlError.self) { try await client.install(appAt: app, on: udid, in: set) }

        try await controller.rename(clone, to: "Renamed copy")
        #expect(try await client.listDevices(in: set).first { $0.udid == cloneUDID }?.name == "Renamed copy")

        try await controller.erase(original)
        try await controller.delete(clone)
        #expect(try await client.listDevices(in: set).first { $0.udid == cloneUDID } == nil)
        #expect(!FileManager.default.fileExists(atPath: clone.rootPath.path))
    }
}
