//
//  InstallTests.swift
//  SimCleanerKitTests
//

import Foundation
import Testing
@testable import SimCleanerKit

struct AppBundleInfoTests {
    private func makeApp(_ fixture: Fixture, platforms: [String], minimumOS: String? = "17.0") throws -> URL {
        let app = fixture.url("Build/Demo.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        var info: [String: Any] = ["CFBundleIdentifier": "com.example.demo", "CFBundleExecutable": "Demo", "CFBundleName": "Demo", "CFBundleSupportedPlatforms": platforms]
        if let minimumOS { info["MinimumOSVersion"] = minimumOS }
        (info as NSDictionary).write(to: app.appending(path: "Info.plist"), atomically: true)
        // A real Mach-O so the architecture check has something to read.
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: app.appending(path: "Demo"))
        return app
    }

    private func device(runtime: String) -> SimulatorDevice {
        CleanupAdvisorTests().deviceForRuntime(runtime)
    }

    @Test func readsTheBundle() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let info = try AppBundleInfo.read(try makeApp(fixture, platforms: ["iPhoneSimulator"]))
        #expect(info.bundleIdentifier == "com.example.demo")
        #expect(info.minimumOSVersion == OperatingSystemVersion(majorVersion: 17, minorVersion: 0, patchVersion: 0))
        #expect(info.architectures.contains(MachOArchitectures.host))
    }

    @Test func compatibilityChecksPlatformAndOSVersion() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let simulatorApp = try AppBundleInfo.read(try makeApp(fixture, platforms: ["iPhoneSimulator"], minimumOS: "18.0"))
        #expect(simulatorApp.compatibility(with: device(runtime: "com.apple.CoreSimulator.SimRuntime.iOS-27-0")) == .compatible)
        #expect(simulatorApp.compatibility(with: device(runtime: "com.apple.CoreSimulator.SimRuntime.iOS-17-5")) == .incompatible("Needs iOS 18.0 or later."))
        #expect(simulatorApp.compatibility(with: device(runtime: "com.apple.CoreSimulator.SimRuntime.watchOS-11-0")).reason != nil)

        try FileManager.default.removeItem(at: fixture.url("Build"))
        let deviceBuild = try AppBundleInfo.read(try makeApp(fixture, platforms: ["iPhoneOS"]))
        #expect(deviceBuild.compatibility(with: device(runtime: "com.apple.CoreSimulator.SimRuntime.iOS-27-0")) == .incompatible("Built for a physical device, not the simulator."))
    }

    @Test func notAnAppIsRejected() {
        #expect(throws: AppBundleInfo.ReadError.notAnApp) { _ = try AppBundleInfo.read(URL(fileURLWithPath: "/tmp/Demo.ipa")) }
    }

    @Test func fatBinariesListEverySlice() {
        // /usr/bin/true ships as a universal binary on Apple silicon Macs.
        let archs = MachOArchitectures.read(URL(fileURLWithPath: "/usr/bin/true"))
        #expect(archs.contains(MachOArchitectures.host))
    }
}

struct BatchInstallerTests {
    private func makeDevices(_ fixture: Fixture, states: [String]) throws -> ([SimulatorDevice], FakeSimctl) {
        var fakes: [FakeSimctl.Device] = []
        for (index, state) in states.enumerated() {
            let udid = UUID().uuidString
            try fixture.addDevice(in: "Library/Developer/CoreSimulator/Devices", udid: udid, name: "Device \(index)", state: state == "Booted" ? 3 : 1)
            fakes.append(.init(udid: udid, name: "Device \(index)", state: state))
        }
        let devices = try SimulatorScanner.loadDevices(at: fixture.url("Library/Developer")).devices.sorted { $0.name < $1.name }
        return (devices, FakeSimctl(devices: fakes))
    }

    private func app(_ fixture: Fixture) throws -> AppBundleInfo {
        let url = fixture.url("Build/Demo.app")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        (["CFBundleIdentifier": "com.example.demo", "CFBundleSupportedPlatforms": ["iPhoneSimulator"], "MinimumOSVersion": "18.0"] as NSDictionary)
            .write(to: url.appending(path: "Info.plist"), atomically: true)
        return try AppBundleInfo.read(url)
    }

    @Test func runningDevicesStayRunningAndShutDownOnesAreReturnedToShutDown() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let (devices, fake) = try makeDevices(fixture, states: ["Booted", "Shutdown", "Shutdown"])
        let installer = BatchInstaller(simctl: fake.client, canBoot: true, maxConcurrentBoots: 2)

        let results = await installer.install(try app(fixture), on: devices) { _, _ in }

        #expect(results.values.allSatisfy { $0 == .installed })
        #expect(fake.calls.filter { $0.first == "install" }.count == 3)
        #expect(fake.devices.first { $0.name == "Device 0" }?.state == "Booted")
        #expect(fake.devices.filter { $0.name != "Device 0" }.allSatisfy { $0.state == "Shutdown" })
        // The running device was never booted or shut down.
        let runningUDID = devices[0].udid
        #expect(!fake.calls.contains { ($0.first == "bootstatus" || $0.first == "shutdown") && $0.contains(runningUDID) })
    }

    @Test func withoutProShutDownSimulatorsAreSkippedNotBooted() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let (devices, fake) = try makeDevices(fixture, states: ["Booted", "Shutdown"])
        let installer = BatchInstaller(simctl: fake.client, canBoot: false)

        let results = await installer.install(try app(fixture), on: devices) { _, _ in }

        #expect(results[devices[0].udid] == .installed)
        #expect(results[devices[1].udid] == .skipped("Not running. Start it first, or use SimCleaner Pro."))
        #expect(!fake.calls.contains { $0.first == "bootstatus" || $0.first == "boot" })
    }

    @Test func aFailedInstallStillShutsDownWhatItStarted() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let (devices, fake) = try makeDevices(fixture, states: ["Shutdown"])
        fake.failures["install"] = "An error was encountered processing the command (domain=IXUserPresentableErrorDomain, code=4):\nThis app could not be installed at this time."
        let installer = BatchInstaller(simctl: fake.client, canBoot: true)

        let results = await installer.install(try app(fixture), on: devices) { _, _ in }

        #expect(results[devices[0].udid] == .failed("This app could not be installed at this time."))
        #expect(fake.devices.first?.state == "Shutdown")
    }

    @Test func cancellingMidInstallShutsDownWhatItStarted() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let (devices, fake) = try makeDevices(fixture, states: ["Shutdown"])
        fake.delays["install"] = .seconds(30)
        let installer = BatchInstaller(simctl: fake.client, canBoot: true)
        let app = try app(fixture)

        let task = Task { await installer.install(app, on: devices) { _, _ in } }
        try await waitUntil { fake.calls.contains { $0.first == "install" } }
        task.cancel()
        let results = await task.value

        #expect(results[devices[0].udid] == .cancelled)
        #expect(fake.devices.first?.state == "Shutdown")
        #expect(fake.calls.last { $0.first != "list" }?.first == "shutdown")
    }

    @Test func aStartThatTimesOutIsShutDownAndReported() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let (devices, fake) = try makeDevices(fixture, states: ["Shutdown"])
        fake.timeouts = ["bootstatus"]
        fake.onCommand = { args in if args.first == "bootstatus" { fake.setState(args[1], "Booting") } }

        let results = await BatchInstaller(simctl: fake.client, canBoot: true).install(try app(fixture), on: devices) { _, _ in }

        #expect(results[devices[0].udid] == .failed("simctl didn't answer in time (bootstatus)."))
        #expect(fake.devices.first?.state == "Shutdown")
        #expect(!fake.calls.contains { $0.first == "install" })
    }

    @Test func aSimulatorThatWontShutDownAgainIsReported() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let (devices, fake) = try makeDevices(fixture, states: ["Shutdown"])
        fake.inert = ["shutdown"]
        var installer = BatchInstaller(simctl: fake.client, canBoot: true)
        installer.restoreTimeout = 0.3
        installer.pollInterval = 0.05

        let results = await installer.install(try app(fixture), on: devices) { _, _ in }

        guard case .leftRunning(let installed, let reason)? = results[devices[0].udid] else {
            Issue.record("expected leftRunning, got \(String(describing: results[devices[0].udid]))"); return
        }
        #expect(installed)
        #expect(reason.hasPrefix("Installed, but SimCleaner started it for the install and couldn't shut it down again"))
        #expect(!InstallPhase.allFulfilled(results, for: devices))
    }

    @Test func everyTargetHasToGetTheApp() {
        let devices = (0..<3).map { _ in CleanupAdvisorTests().deviceForRuntime("com.apple.CoreSimulator.SimRuntime.iOS-27-0") }
        let all = Dictionary(uniqueKeysWithValues: devices.map { ($0.udid, InstallPhase.installed) })
        #expect(InstallPhase.allFulfilled(all, for: devices))

        var someSkipped = all
        someSkipped[devices[1].udid] = .skipped("Needs iOS 28.0 or later.")
        #expect(!InstallPhase.allFulfilled(someSkipped, for: devices))

        let allSkipped = all.mapValues { _ in InstallPhase.skipped("Needs iOS 28.0 or later.") }
        #expect(!InstallPhase.allFulfilled(allSkipped, for: devices))

        var missing = all
        missing[devices[2].udid] = nil
        #expect(!InstallPhase.allFulfilled(missing, for: devices))
        #expect(!InstallPhase.allFulfilled([:], for: []))
    }

    @Test func incompatibleTargetsAreSkippedBeforeAnythingBoots() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let udid = UUID().uuidString
        try fixture.addDevice(in: "Library/Developer/CoreSimulator/Devices", udid: udid, runtime: "com.apple.CoreSimulator.SimRuntime.iOS-17-5", state: 1)
        let devices = try SimulatorScanner.loadDevices(at: fixture.url("Library/Developer")).devices
        let fake = FakeSimctl(devices: [.init(udid: udid, name: "Old", state: "Shutdown", runtime: "com.apple.CoreSimulator.SimRuntime.iOS-17-5")])

        let results = await BatchInstaller(simctl: fake.client, canBoot: true).install(try app(fixture), on: devices) { _, _ in }

        #expect(results[udid] == .skipped("Needs iOS 18.0 or later."))
        #expect(fake.calls.isEmpty)
    }
}
