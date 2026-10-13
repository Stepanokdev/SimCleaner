//
//  XCode_DevicesTests.swift
//  XCode DevicesTests
//
//  Created by Ivan Stepanok on 22.11.2025.
//
//  The scanner, sizes and simulator operations are tested in Packages/SimCleanerKit. These tests
//  cover what the app adds on top: list states and the view model's operation flow.

import AppKit
import Foundation
import SimCleanerKit
import SwiftUI
import Testing
@testable import SimCleaner

/// Builds throwaway ~/Library/Developer-shaped folders on disk.
private struct Fixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: "SimCleanerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    /// Adds an app bundle and its data container the way CoreSimulator lays them out.
    func addApp(to device: URL, bundleId: String) throws {
        let name = bundleId.components(separatedBy: ".").last ?? "App"
        let bundleContainer = device.appending(path: "data/Containers/Bundle/Application/\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bundleContainer.appending(path: "\(name).app"), withIntermediateDirectories: true)
        try Data(repeating: 3, count: 8192).write(to: bundleContainer.appending(path: "\(name).app/\(name)"))
        try PropertyListSerialization.data(fromPropertyList: ["MCMMetadataIdentifier": bundleId], format: .binary, options: 0)
            .write(to: bundleContainer.appending(path: ".com.apple.mobile_container_manager.metadata.plist"))
    }

    @discardableResult
    func addDevice(in setPath: String, name: String, state: Int = 1) throws -> URL {
        let udid = UUID().uuidString
        let folder = url(setPath).appending(path: udid, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder.appending(path: "data"), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4096).write(to: folder.appending(path: "data/payload.bin"))
        let plist: [String: Any] = [
            "UDID": udid,
            "name": name,
            "deviceType": "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro",
            "runtime": "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
            "state": state,
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
            .write(to: folder.appending(path: "device.plist"))
        return folder
    }

    func url(_ path: String) -> URL {
        root.appending(path: path, directoryHint: .isDirectory)
    }
}

/// No simctl. With CoreSimulator still installed, as on any Mac that has run Xcode.
private let filesOnly = Capabilities(isSandboxed: true, simctl: .failure(.noDeveloperDirectory), coreSimulatorInstalled: true)
/// No simctl and no CoreSimulator either: nothing can be running a simulator, so folders may go.
private let noCoreSimulator = Capabilities(isSandboxed: true, simctl: .failure(.noDeveloperDirectory), coreSimulatorInstalled: false)

@MainActor
struct DeletionFlowTests {
    @Test func simctlTroubleNeverDeletesFoldersWhileCoreSimulatorIsInstalled() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let root = fixture.url("Library/Developer")
        let folder = try fixture.addDevice(in: "Library/Developer/CoreSimulator/Devices", name: "Off")
        let scanned = try SimulatorScanner.loadDevices(at: root).devices
        let license = Capabilities(isSandboxed: true, simctl: .failure(.licenseNotAccepted), coreSimulatorInstalled: true)

        let scanner = DeviceScanner(devicesURL: root, sandboxed: true, capabilities: license)
        #expect(!scanner.canDeleteDevices)
        await scanner.delete(scanned)

        #expect(FileManager.default.fileExists(atPath: folder.path))
        #expect(scanner.report?.failures.first?.contains("license") == true)
    }

    @Test func partialDeletionStillRescansAndReportsFailure() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let root = fixture.url("Library/Developer")
        let removable = try fixture.addDevice(in: "Library/Developer/CoreSimulator/Devices", name: "Removable")
        let changed = try fixture.addDevice(in: "Library/Developer/CoreSimulator/Devices", name: "Changed")
        let scanned = try SimulatorScanner.loadDevices(at: root).devices
        // The second device's folder now belongs to something else, so its deletion must fail.
        try PropertyListSerialization.data(fromPropertyList: ["UDID": UUID().uuidString, "name": "Other", "state": 1], format: .binary, options: 0)
            .write(to: changed.appending(path: "device.plist"))

        let scanner = DeviceScanner(devicesURL: root, sandboxed: true, capabilities: noCoreSimulator)
        await scanner.delete(scanned)
        try await waitForScan(scanner)

        #expect(!FileManager.default.fileExists(atPath: removable.path))
        #expect(FileManager.default.fileExists(atPath: changed.path))
        // The list reflects the disk after the partial deletion instead of the stale pre-delete list.
        #expect(scanner.devices.map(\.name) == ["Other"])
        #expect(scanner.report?.failures.contains { $0.contains("Changed") } == true)
        #expect(scanner.busy.isEmpty)
    }

    @Test func runningSimulatorIsNotDeletedWithoutSimctl() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let root = fixture.url("Library/Developer")
        let running = try fixture.addDevice(in: "Library/Developer/CoreSimulator/Devices", name: "Running", state: 3)
        let scanned = try SimulatorScanner.loadDevices(at: root).devices

        let scanner = DeviceScanner(devicesURL: root, sandboxed: true, capabilities: noCoreSimulator)
        await scanner.delete(scanned)

        #expect(FileManager.default.fileExists(atPath: running.path))
        #expect(scanner.report != nil)
    }

    /// `refresh()` scans in the background; wait for it the way the window does.
    private func waitForScan(_ scanner: DeviceScanner) async throws {
        try await waitUntil { !scanner.isLoading }
    }
}

/// Waits for something the view model does in the background.
@MainActor
private func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<500 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Timed out waiting")
}

/// Answers simctl for one simulator the way CoreSimulator would, taking its time to remove an app.
private final class SlowSimctl: CommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private let udid: String
    private var state: String
    private var log: [String] = []

    init(udid: String, state: String) {
        self.udid = udid
        self.state = state
    }

    var commands: [String] { lock.withLock { log } }

    func run(_ executable: URL, arguments: [String], environment: [String: String]?, standardInput: Data?, timeout: TimeInterval) async throws -> CommandResult {
        let command = arguments.dropFirst().first ?? ""
        lock.withLock { log.append(command) }
        switch command {
        case "list":
            let device: [String: Any] = ["udid": udid, "name": "iPhone", "state": lock.withLock { state }, "isAvailable": true]
            let json = try JSONSerialization.data(withJSONObject: ["devices": ["com.apple.CoreSimulator.SimRuntime.iOS-27-0": [device]]])
            return CommandResult(status: 0, stdout: json, stderr: Data())
        case "uninstall":
            try await Task.sleep(for: .milliseconds(800))
        case "shutdown":
            lock.withLock { state = "Shutdown" }
        default:
            break
        }
        return CommandResult(status: 0, stdout: Data(), stderr: Data())
    }
}

/// Answers simctl for one shut-down simulator and erases it the way CoreSimulator does: its data goes,
/// the device stays.
private final class ErasingSimctl: CommandRunning, @unchecked Sendable {
    private let udid: String
    private let folder: URL

    init(udid: String, folder: URL) {
        self.udid = udid
        self.folder = folder
    }

    func run(_ executable: URL, arguments: [String], environment: [String: String]?, standardInput: Data?, timeout: TimeInterval) async throws -> CommandResult {
        switch arguments.first(where: { $0 == "list" || $0 == "erase" }) {
        case "list":
            let device: [String: Any] = ["udid": udid, "name": "iPhone", "state": "Shutdown", "isAvailable": true]
            let json = try JSONSerialization.data(withJSONObject: ["devices": ["com.apple.CoreSimulator.SimRuntime.iOS-27-0": [device]]])
            return CommandResult(status: 0, stdout: json, stderr: Data())
        case "erase":
            let data = folder.appending(path: "data", directoryHint: .isDirectory)
            try? FileManager.default.removeItem(at: data)
            try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        default:
            break
        }
        return CommandResult(status: 0, stdout: Data(), stderr: Data())
    }
}

@MainActor
struct OperationLockTests {
    @Test func aSimulatorStaysLockedWhileOneOfItsAppsIsRemoved() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let root = fixture.url("Library/Developer")
        let folder = try fixture.addDevice(in: "Library/Developer/CoreSimulator/Devices", name: "Running", state: 3)
        try fixture.addApp(to: folder, bundleId: "com.example.one")
        try fixture.addApp(to: folder, bundleId: "com.example.two")
        let device = try #require(try SimulatorScanner.loadDevices(at: root).devices.first)
        let apps = device.apps
        try #require(apps.count == 2)
        let simctl = SlowSimctl(udid: device.udid, state: "Booted")
        let tool = SimctlTool(executable: URL(fileURLWithPath: "/usr/bin/xcrun"), leadingArguments: ["simctl"], developerDirectory: nil, source: .xcrun)
        let scanner = DeviceScanner(devicesURL: root, sandboxed: false, runner: simctl, capabilities: Capabilities(isSandboxed: false, simctl: .success(tool), coreSimulatorInstalled: true))

        let first = Task { await scanner.uninstall(apps[0], from: device) }
        try await waitUntil { scanner.isBusy(device) }

        await scanner.delete([device])
        #expect(scanner.report?.failures.first?.contains("another action on it hasn't finished") == true)
        await scanner.erase([device])
        #expect(scanner.report?.failures.first?.contains("another action on it hasn't finished") == true)
        await scanner.uninstall(apps[1], from: device)
        #expect(scanner.report?.failures.first?.contains("another action on it hasn't finished") == true)

        await first.value
        #expect(!scanner.isBusy(device))
        #expect(simctl.commands.filter { $0 == "uninstall" }.count == 1)
        #expect(!simctl.commands.contains("delete"))
        #expect(!simctl.commands.contains("erase"))
    }
}

@MainActor
struct CachesAccessTests {
    private func developerFolder(_ fixture: Fixture) throws -> URL {
        let developer = fixture.url("Library/Developer")
        let project = developer.appending(path: "Xcode/DerivedData/Demo-abcdefghijklmnopqrstuvwxyz", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: project.appending(path: "Build"), withIntermediateDirectories: true)
        try Data(repeating: 5, count: 64_000).write(to: project.appending(path: "Build/products.bin"))
        (["WorkspacePath": "/Users/dev/Demo/Demo.xcodeproj"] as NSDictionary).write(to: project.appending(path: "info.plist"), atomically: true)
        try FileManager.default.createDirectory(at: developer.appending(path: "CoreSimulator/Devices"), withIntermediateDirectories: true)
        return developer
    }

    @Test func withoutAccessThePageAsksForItInsteadOfMeasuringForever() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let developer = try developerFolder(fixture)
        let scanner = DeviceScanner(sandboxed: true, capabilities: filesOnly, developerFolder: developer, restoresBookmark: false)

        #expect(!scanner.hasFolderAccess)
        #expect(scanner.developerStorageState == .needsAccess)
        // The page asks for a scan; without access none can start, and the state says so.
        scanner.refreshDeveloperStorage()
        #expect(!scanner.isScanningDeveloperStorage)
        #expect(scanner.developerStorageState == .needsAccess)
    }

    @Test func grantingAccessMeasuresTheCachesRightAway() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let developer = try developerFolder(fixture)
        let scanner = DeviceScanner(sandboxed: true, capabilities: filesOnly, developerFolder: developer, restoresBookmark: false)

        scanner.useGrantedFolder(developer)
        #expect(scanner.developerStorageState == .measuring)
        try await waitUntil { scanner.developerStorageState == .ready }
        #expect(scanner.developerStorage.items(in: .derivedData).map(\.title) == ["Demo"])
        try await waitUntil { scanner.hasCompletedScan }
    }

    @Test func aFolderInsideDeveloperCantShowTheCaches() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let developer = try developerFolder(fixture)
        let scanner = DeviceScanner(sandboxed: true, capabilities: filesOnly, developerFolder: developer, restoresBookmark: false)

        scanner.useGrantedFolder(developer.appending(path: "CoreSimulator", directoryHint: .isDirectory))
        #expect(scanner.developerStorageState == .notCovered)
        #expect(!scanner.isScanningDeveloperStorage)
    }
}

@MainActor
struct ListStateTests {
    private let developer = URL(fileURLWithPath: "/Users/dev/Library/Developer")

    private func state(
        access: Bool = true,
        url: URL? = nil,
        error: String? = nil,
        loading: Bool = false,
        scanned: Bool = true,
        devices: Int = 0,
        filtered: Int = 0,
        sets: Int = 0,
        partial: Bool = false
    ) -> SimulatorListState {
        SimulatorListState.resolve(
            hasFolderAccess: access,
            scannedURL: url ?? developer,
            errorMessage: error,
            isLoading: loading,
            hasCompletedScan: scanned,
            deviceCount: devices,
            filteredCount: filtered,
            deviceSetCount: sets,
            isScanPartial: partial
        )
    }

    @Test func eachEmptySituationGetsItsOwnState() {
        #expect(state(access: false) == .needsAccess)
        #expect(state(sets: 0) == .noDeviceFolders)
        #expect(state(sets: 2) == .noSimulators)
        #expect(state(sets: 1, partial: true) == .unreadableFolders)
        #expect(state(sets: 0, partial: true) == .unreadableFolders)
        #expect(state(devices: 5, filtered: 0, sets: 1) == .noMatches)
        #expect(state(devices: 5, filtered: 3, sets: 1) == .list)
        #expect(state(devices: 5, filtered: 3, sets: 1, partial: true) == .list)
        #expect(state(loading: true, scanned: false) == .loading)
        #expect(state(error: "Can't read") == .error("Can't read"))
    }

    @Test func runtimeFolderExplainsRuntimesEvenWhenTheSandboxRefusesIt() {
        let assets = URL(fileURLWithPath: "/System/Library/AssetsV2/com_apple_MobileAsset_iOSSimulatorRuntime")
        #expect(state(url: assets, sets: 0) == .runtimeFolder)
        #expect(state(url: assets, error: "Operation not permitted") == .runtimeFolder)
        #expect(state(url: URL(fileURLWithPath: "/Library/Developer/CoreSimulator/Volumes"), sets: 0) == .runtimeFolder)
        #expect(state(url: assets, loading: true, scanned: false) == .loading)
    }
}

struct SandboxLocationTests {
    @Test func sandboxedHomeIsTheContainerSoTheRealHomeIsUsed() {
        let real = DeveloperPaths.realHomeDirectory.path
        #expect(!real.contains("/Library/Containers/"))
        #expect(DeveloperPaths.developerFolder.path == real + "/Library/Developer")
    }
}

/// The split view sizes its columns from each page's minimum size, which SwiftUI measures with a zero
/// proposal. A page whose minimum is taller than the window pushes every column's content off screen,
/// so the page looks empty. Text with a vertical fixedSize outside a scroll view does exactly that.
@MainActor
struct PageLayoutTests {
    /// The window's minimum height in XCode_DevicesApp.
    private let windowMinimumHeight: CGFloat = 640
    /// The title bar and toolbar above the columns.
    private let toolbarHeight: CGFloat = 52

    private func minimumHeight(of view: some View) -> CGFloat {
        NSHostingController(rootView: view).sizeThatFits(in: .zero).height
    }

    @Test func everyPageFitsTheSmallestWindowAboveTheStorageBar() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        // Files only, so the App Store notes about runtimes and simctl are on screen too.
        let scanner = DeviceScanner(devicesURL: fixture.url("Library/Developer"), sandboxed: true, capabilities: filesOnly)
        let session = SessionHarness().makeSession()
        session.add(5 * gigabyte)
        // The storage bar sits under every page; measure it with everything it can show.
        let bar = minimumHeight(of: StoragePanel(scanner: scanner, session: session, onSelect: { _ in }, onRequestAccess: {}))
        #expect(bar < 110, "The storage bar needs \(bar) pt")
        let room = windowMinimumHeight - toolbarHeight - bar
        let pages: [(String, AnyView)] = [
            ("Simulators", AnyView(SimulatorListView(scanner: scanner, devices: [], totalCount: 0, searchText: .constant(""), selection: .constant([]), sortOrder: .constant([]), runtimeFilter: nil, onSelectAll: {}, onRequestAccess: {}))),
            ("Suggestions", AnyView(SuggestionsView(scanner: scanner, idleDays: .constant(14), onAction: { _ in }, showDevice: { _ in }))),
            ("Xcode caches", AnyView(XcodeCachesView(scanner: scanner, category: .constant(.derivedData)))),
            ("Runtimes", AnyView(RuntimesView(scanner: scanner))),
            ("Suggestions detail", AnyView(CleanupDetailView(scanner: scanner, page: .suggestions))),
            ("Xcode caches detail", AnyView(CleanupDetailView(scanner: scanner, page: .xcodeCaches))),
            ("Runtimes detail", AnyView(CleanupDetailView(scanner: scanner, page: .runtimes))),
        ]
        for (name, view) in pages {
            let height = minimumHeight(of: view)
            #expect(height < room, "\(name) needs at least \(height) pt, and \(room) pt are left above the storage bar")
        }
    }
}

struct DisplayTests {
    @Test func aMomentAgoOrAheadIsJustNow() {
        #expect(Date().relativeDescription == "Just now")
        // A folder written a moment ago by a clock that runs a little early.
        #expect(Date().addingTimeInterval(5).relativeDescription == "Just now")
        #expect(Date().addingTimeInterval(-3 * 86_400).relativeDescription != "Just now")
    }

    @Test func freedSpaceIsARangeOnlyWhenSharingMatters() {
        #expect(ByteText.freed(DiskFootprint(allocatedBytes: 1_000_000_000, exclusiveBytes: 990_000_000)) == ByteText.string(1_000_000_000))
        #expect(ByteText.freed(DiskFootprint(allocatedBytes: 1_000_000_000, exclusiveBytes: 100_000_000)).contains("–"))
        #expect(ByteText.freed(.zero) == "nothing")
    }
}

/// Runs inside the test host, which is the App Store build with its sandbox entitlements. Off by
/// default because it needs Xcode 27; run with TEST_RUNNER_SIMCLEANER_INTEGRATION=1 xcodebuild test.
struct SandboxedSimctlTests {
    static let enabled = ProcessInfo.processInfo.environment["SIMCLEANER_INTEGRATION"] == "1"

    @Test(.enabled(if: SandboxedSimctlTests.enabled))
    func appStoreBuildReachesCoreSimulatorButNotRuntimes() async throws {
        let capabilities = await Capabilities.detect()
        #expect(capabilities.isSandboxed)
        let tool = try #require(capabilities.simctlTool, "simctl unavailable: \(String(describing: capabilities.simctlProblem))")
        #expect(tool.source == .coreSimulatorFramework || tool.source == .xcodeBinary)
        #expect(capabilities.canManageDevices)
        #expect(!capabilities.canBoot)
        #expect(!capabilities.canManageRuntimes)

        let client = SimctlClient(tool: tool)
        let devices = try await client.listDevices(in: nil)
        #expect(!devices.isEmpty)
        // The sandbox hides runtimes from CoreSimulator's disk image service.
        await #expect(throws: SimctlError.self) { _ = try await client.listRuntimeImages() }
    }
}

/// A simulator in the default device set, known only by its UDID: inside the sandbox the test can't read
/// ~/Library/Developer, and the operations only need the UDID and the set.
private func defaultSetSimulator(_ udid: String) -> SimulatorDevice {
    let set = DeveloperPaths.developerFolder.appending(path: "CoreSimulator/Devices", directoryHint: .isDirectory)
    let folder = set.appending(path: udid, directoryHint: .isDirectory)
    return SimulatorDevice(
        id: folder.path, name: udid, deviceType: "iPhone", deviceTypeIdentifier: "", runtime: "", runtimeIdentifier: "",
        runtimeGroup: "", category: .iPhone, udid: udid, plistState: .unknown(""), lastUsedAt: nil, hasBootedBefore: true,
        lastModifiedAt: nil, footprint: .zero, apps: [], rootPath: folder, isDefault: false,
        deviceSet: DeviceSet(url: set, kind: .simulators)
    )
}

/// Real simulators, changed from inside the App Store build's sandbox. A check script creates them, runs
/// this with TEST_RUNNER_SIMCLEANER_SANDBOX_OPS="<running UDID>,<UDID to erase>,<UDID to delete>,<bundle ID>"
/// and verifies the result from outside. Off otherwise.
struct SandboxedOperationsTests {
    static let plan = ProcessInfo.processInfo.environment["SIMCLEANER_SANDBOX_OPS"]?.split(separator: ",").map(String.init)

    @Test(.enabled(if: SandboxedOperationsTests.plan?.count == 4))
    func appStoreBuildRemovesAnAppShutsDownErasesAndDeletes() async throws {
        let plan = try #require(Self.plan)
        let capabilities = await Capabilities.detect()
        #expect(capabilities.isSandboxed)
        #expect(!capabilities.canBoot)
        try #require(capabilities.canManageDevices, "simctl unavailable: \(String(describing: capabilities.simctlProblem))")
        let controller = DeviceController(capabilities: capabilities, allowedRoot: DeveloperPaths.developerFolder)
        let running = defaultSetSimulator(plan[0])
        let app = SimulatorApp(name: "CheckApp", bundleId: plan[3], bundlePath: URL(fileURLWithPath: "/CheckApp.app"), dataContainerPath: nil, icon: nil, bundleFootprint: .zero, dataFootprint: .zero)

        try await controller.uninstall(app, from: running)
        try await controller.shutDown(running)
        try await controller.erase(defaultSetSimulator(plan[1]))
        try await controller.delete(defaultSetSimulator(plan[2]))
    }
}

/// Opens one simulator through the same launcher the window uses, from inside the App Store build's sandbox.
/// The check script passes TEST_RUNNER_SIMCLEANER_OPEN_UDID and then looks at Device Hub's windows.
struct DeviceHubLaunchTests {
    static let udid = ProcessInfo.processInfo.environment["SIMCLEANER_OPEN_UDID"]

    @Test(.enabled(if: DeviceHubLaunchTests.udid != nil))
    func opensTheRequestedSimulator() async throws {
        let udid = try #require(Self.udid)
        try await SimulatorLauncher.open(defaultSetSimulator(udid))
    }
}

/// A clock the tests move by hand, and defaults nobody else reads.
@MainActor
private final class SessionHarness {
    var now = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let defaults: UserDefaults
    private let suite = "SimCleanerTests.session.\(UUID().uuidString)"

    init() {
        defaults = UserDefaults(suiteName: suite)!
    }

    func makeSession() -> CleanupSession {
        // Holds on to the harness, so a test can keep only the session.
        CleanupSession(defaults: defaults) { self.now }
    }

    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }

    deinit { UserDefaults().removePersistentDomain(forName: suite) }
}

private let gigabyte: Int64 = 1_000_000_000

@MainActor
struct CleanupSessionTests {
    @Test func cleanupsAddUpAndRememberTheLastOne() {
        let harness = SessionHarness()
        let session = harness.makeSession()
        #expect(session.totals == nil)

        session.add(10 * gigabyte)
        harness.advance(60)
        session.add(5 * gigabyte)

        #expect(session.totals?.freedBytes == 15 * gigabyte)
        #expect(session.totals?.lastFreedBytes == 5 * gigabyte)
        #expect(session.cleanupsThisLaunch == 2)
    }

    @Test func nothingFreedIsNotACleanup() {
        let harness = SessionHarness()
        let session = harness.makeSession()
        session.add(0)
        session.add(-5)
        #expect(session.totals == nil)
        #expect(session.cleanupsThisLaunch == 0)
    }

    @Test func theSessionEndsAnHourAfterTheLastCleanup() {
        let harness = SessionHarness()
        let session = harness.makeSession()
        session.add(10 * gigabyte)

        harness.advance(3599)
        session.endIfExpired()
        #expect(session.totals?.freedBytes == 10 * gigabyte)

        harness.advance(1)
        session.endIfExpired()
        #expect(session.totals == nil)

        // The next cleanup starts from zero.
        session.add(5 * gigabyte)
        #expect(session.totals?.freedBytes == 5 * gigabyte)
        #expect(session.totals?.lastFreedBytes == 5 * gigabyte)
    }

    @Test func aCleanupKeepsTheSessionGoing() {
        let harness = SessionHarness()
        let session = harness.makeSession()
        session.add(gigabyte)
        harness.advance(3000)
        session.add(gigabyte)
        // 6,000 seconds since the first cleanup, 3,000 since the last.
        harness.advance(3000)
        session.endIfExpired()
        #expect(session.totals?.freedBytes == 2 * gigabyte)
        harness.advance(600)
        session.endIfExpired()
        #expect(session.totals == nil)
    }

    @Test func aRelaunchWithinTheHourShowsTheTotalWithoutCelebratingAgain() {
        let harness = SessionHarness()
        harness.makeSession().add(10 * gigabyte)

        harness.advance(1800)
        let relaunched = harness.makeSession()
        #expect(relaunched.totals?.freedBytes == 10 * gigabyte)
        #expect(relaunched.cleanupsThisLaunch == 0)

        harness.advance(1800)
        #expect(harness.makeSession().totals == nil)
    }

    @Test func aClockSetBackEndsTheSession() {
        let harness = SessionHarness()
        let session = harness.makeSession()
        session.add(gigabyte)
        harness.advance(-120)
        session.endIfExpired()
        #expect(session.totals == nil)
        // And it stays ended after a relaunch.
        #expect(harness.makeSession().totals == nil)
    }

    @Test func expiryRemovesTheSavedTotal() {
        let harness = SessionHarness()
        let session = harness.makeSession()
        session.add(gigabyte)
        harness.advance(3600)
        session.endIfExpired()
        harness.advance(-3600)
        // Back inside the old hour, nothing comes back: the total was deleted, not hidden.
        #expect(harness.makeSession().totals == nil)
    }
}

@MainActor
struct StorageOverviewTests {
    private func overview(access: Bool = true, covers: Bool = true, simulatorsScanned: Bool = true, scanFailed: Bool = false, cachesScanned: Bool = true, runtimesLoaded: Bool = true, devices: [SimulatorDevice] = [], unreadableSets: [URL] = [], caches: DeveloperStorageReport = .empty, runtimeBytes: Int64 = 0, runtimesReadable: Bool = true, simulatorCachesReadable: Bool = true, available: Int64 = 100 * gigabyte) -> StorageOverview {
        let runtimes = runtimeBytes > 0 ? [RuntimeEntry(source: .simctl(imageID: "R"), platform: .iOS, version: "27.0", build: nil, runtimeIdentifier: nil, sizeBytes: runtimeBytes, lastUsedAt: nil, isDeletable: true, state: nil)] : []
        return StorageOverview.make(
            hasFolderAccess: access,
            coversDeveloperFolder: covers,
            hasScannedSimulators: simulatorsScanned,
            simulatorScanFailed: scanFailed,
            scan: ScanResult(devices: devices, deviceSets: [], leftovers: [], unreadableLocations: unreadableSets, unreadableDeviceCount: 0),
            hasScannedDeveloperStorage: cachesScanned,
            developerStorage: caches,
            hasLoadedRuntimes: runtimesLoaded,
            runtimes: runtimesReadable ? runtimes : nil,
            simulatorCaches: simulatorCachesReadable ? [] : nil,
            volume: VolumeSpace(totalBytes: 1_000 * gigabyte, availableBytes: available)
        )
    }

    private func category(_ kind: StorageCategory, in overview: StorageOverview) -> StorageOverview.Category? {
        overview.categories.first { $0.kind == kind }
    }

    @Test func whatIsntMeasuredYetIsNeverShownAsZero() {
        let waiting = overview(simulatorsScanned: false, cachesScanned: false, runtimesLoaded: false)
        #expect(category(.simulators, in: waiting)?.measurement == .measuring)
        #expect(category(.derivedData, in: waiting)?.measurement == .measuring)
        #expect(category(.runtimes, in: waiting)?.measurement == .measuring)
        #expect(waiting.measuredBytes == 0)
        #expect(waiting.segments.isEmpty)
        #expect(!waiting.isComplete)

        let locked = overview(access: false)
        #expect(category(.simulators, in: locked)?.measurement == .noAccess)
        #expect(category(.derivedData, in: locked)?.measurement == .noAccess)
        // Runtimes are read from system folders, so they're measured even without the grant.
        #expect(category(.runtimes, in: locked)?.measurement != .noAccess)

        // A grant inside ~/Library/Developer still measures simulators (none here, so none listed) but
        // can't reach the caches next to them.
        let insideDeveloper = overview(covers: false)
        #expect(category(.simulators, in: insideDeveloper) == nil)
        #expect(category(.deviceSupport, in: insideDeveloper)?.measurement == .noAccess)
    }

    @Test func emptyCategoriesDisappearOnceMeasured() {
        let measured = overview(runtimeBytes: 8 * gigabyte)
        #expect(measured.categories.map(\.kind) == [.runtimes])
        #expect(measured.measuredBytes == 8 * gigabyte)
        #expect(measured.isComplete)
        #expect(measured.barCapacity == 108 * gigabyte)
    }

    @Test func unreadableCacheFoldersMakeTheirCategoryPartial() {
        let report = DeveloperStorageReport(
            items: [DeveloperStorageItem(category: .derivedData, url: URL(fileURLWithPath: "/D/Xcode/DerivedData/A"), title: "A", detail: nil, footprint: DiskFootprint(allocatedBytes: gigabyte, exclusiveBytes: gigabyte), lastModifiedAt: nil, recommendation: nil)],
            unreadableLocations: [URL(fileURLWithPath: "/D/Xcode/DerivedData")]
        )
        let partial = overview(caches: report)
        #expect(category(.derivedData, in: partial)?.measurement == .measured(gigabyte, isPartial: true))
        #expect(StorageLegend.value(of: .measured(gigabyte, isPartial: true)).hasPrefix("at least"))
        // The total is then the least there is.
        #expect(!partial.isExact)
        #expect(StoragePanel.total(of: partial).hasPrefix("at least"))
    }

    @Test func aCategoryNothingCouldBeReadFromSaysSoInsteadOfVanishing() {
        // DerivedData is there but closed to SimCleaner, and nothing in it was measured.
        let closed = DeveloperStorageReport(items: [], unreadableLocations: [URL(fileURLWithPath: "/D/Xcode/DerivedData")])
        let derivedData = overview(caches: closed)
        #expect(category(.derivedData, in: derivedData)?.measurement == .unreadable)
        #expect(derivedData.segments.isEmpty)
        #expect(StorageLegend.value(of: .unreadable) == "Couldn't read")
        // Device support was read and is empty, so it's simply not there.
        #expect(category(.deviceSupport, in: derivedData) == nil)

        // A device set that couldn't be opened, and no simulators anywhere else: not "no simulators".
        let sets = overview(unreadableSets: [URL(fileURLWithPath: "/D/CoreSimulator/Devices")])
        #expect(category(.simulators, in: sets)?.measurement == .unreadable)
        #expect(category(.leftovers, in: sets)?.measurement == .unreadable)

        // Runtimes and CoreSimulator's caches that couldn't be listed.
        let system = overview(runtimesReadable: false, simulatorCachesReadable: false)
        #expect(category(.runtimes, in: system)?.measurement == .unreadable)
        #expect(category(.simulatorCaches, in: system)?.measurement == .unreadable)
        #expect(!system.isExact)
    }

    @Test func aFailedSimulatorScanIsNotAnEmptyOne() {
        let failed = overview(scanFailed: true, runtimeBytes: 8 * gigabyte)
        #expect(category(.simulators, in: failed)?.measurement == .unreadable)
        #expect(category(.leftovers, in: failed)?.measurement == .unreadable)
        #expect(failed.measuredBytes == 8 * gigabyte)
        #expect(StoragePanel.total(of: failed) == "at least \(ByteText.string(8 * gigabyte))")
        // The App Store edition without its folder grant is still "no access", not a failure.
        #expect(category(.simulators, in: overview(access: false, scanFailed: true))?.measurement == .noAccess)
    }

    @Test func theBarKeepsTinyCategoriesVisibleAndNeverOverflows() {
        let report = DeveloperStorageReport(
            items: [
                DeveloperStorageItem(category: .derivedData, url: URL(fileURLWithPath: "/D/Xcode/DerivedData/A"), title: "A", detail: nil, footprint: DiskFootprint(allocatedBytes: 40 * gigabyte, exclusiveBytes: 40 * gigabyte), lastModifiedAt: nil, recommendation: nil),
                DeveloperStorageItem(category: .agentWorkspaces, url: URL(fileURLWithPath: "/D/XcodeBuildMCP/workspaces/w"), title: "w", detail: nil, footprint: DiskFootprint(allocatedBytes: 120_000, exclusiveBytes: 120_000), lastModifiedAt: nil, recommendation: nil),
            ],
            unreadableLocations: []
        )
        let width: CGFloat = 600
        let roomy = StorageBarLayout(overview: overview(caches: report, runtimeBytes: 10 * gigabyte, available: 50 * gigabyte), width: width)
        #expect(roomy.segments.map(\.category.kind) == [.runtimes, .derivedData, .agentWorkspaces])
        #expect(roomy.segments.allSatisfy { $0.width >= StorageBarLayout.minimumWidth })
        #expect(roomy.trackWidth(in: width) > 0)
        // 40 GB of 100 GB (data plus available) is close to 40% of what's left after the gaps.
        let derivedData = roomy.segments[1].width
        #expect(abs(derivedData - (width - 2 * StorageBarLayout.spacing) * 0.4) < 2)

        // A full disk: nothing available, so the categories fill the bar exactly.
        let full = StorageBarLayout(overview: overview(caches: report, runtimeBytes: 10 * gigabyte, available: 0), width: width)
        let used = full.segments.reduce(0) { $0 + $1.width } + StorageBarLayout.spacing * CGFloat(full.segments.count - 1)
        #expect(used <= width + 0.001)
        #expect(full.trackWidth(in: width) < 1)
    }
}

struct SuggestionsStateTests {
    private func state(access: Bool = true, error: String? = nil, scanned: Bool = true, partial: Bool = false, count: Int = 0) -> SuggestionsState {
        SuggestionsState.resolve(hasFolderAccess: access, errorMessage: error, hasCompletedScan: scanned, isScanPartial: partial, suggestionCount: count)
    }

    @Test func eachSituationGetsItsOwnState() {
        #expect(state(access: false) == .needsAccess)
        #expect(state(error: "Permission denied") == .failed("Permission denied"))
        #expect(state(scanned: false) == .scanning)
        #expect(state() == .nothingToClean)
        // Nothing found by a scan that couldn't read everything is not an all-clear.
        #expect(state(partial: true) == .nothingInWhatWasRead)
        #expect(state(count: 2) == .suggestions(isPartial: false))
        #expect(state(partial: true, count: 2) == .suggestions(isPartial: true))
        #expect(SuggestionsState.nothingInWhatWasRead.subtitle(total: .zero) != SuggestionsState.nothingToClean.subtitle(total: .zero))
    }
}

@MainActor
struct PartialScanSuggestionsTests {
    private func scanned(_ developer: URL) async throws -> DeviceScanner {
        let scanner = DeviceScanner(devicesURL: developer, sandboxed: true, capabilities: noCoreSimulator)
        scanner.refresh()
        try await waitUntil { !scanner.isLoading }
        return scanner
    }

    private func state(of scanner: DeviceScanner) -> SuggestionsState {
        SuggestionsState.resolve(hasFolderAccess: scanner.hasFolderAccess, errorMessage: scanner.errorMessage, hasCompletedScan: scanner.hasCompletedScan, isScanPartial: scanner.isScanPartial, suggestionCount: scanner.cleanupSuggestions(idleDays: 14).count)
    }

    @Test func aFolderThatCouldntBeOpenedIsNoAllClear() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let developer = fixture.url("Library/Developer")
        try fixture.addDevice(in: "Library/Developer/CoreSimulator/Devices", name: "Fresh")
        let clones = fixture.url("Library/Developer/XCTestDevices")
        try FileManager.default.createDirectory(at: clones, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: clones.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: clones.path) }

        let scanner = try await scanned(developer)

        // The scan finished, without an error, but couldn't read everything.
        #expect(scanner.hasCompletedScan)
        #expect(scanner.errorMessage == nil)
        #expect(scanner.isScanPartial)
        #expect(scanner.cleanupSuggestions(idleDays: 14).isEmpty)
        #expect(state(of: scanner) == .nothingInWhatWasRead)
        #expect(scanner.unreadableSummary == "Couldn't open XCTestDevices.")
    }

    @Test func suggestionsStayWhenASimulatorCouldntBeRead() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let developer = fixture.url("Library/Developer")
        let locked = try fixture.addDevice(in: "Library/Developer/CoreSimulator/Devices", name: "Locked")
        let plist = locked.appending(path: "device.plist")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: plist.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: plist.path) }
        // A folder CoreSimulator forgot is worth cleaning whatever else couldn't be read.
        let leftover = fixture.url("Library/Developer/CoreSimulator/Devices/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: leftover, withIntermediateDirectories: true)
        try Data(repeating: 4, count: 100_000).write(to: leftover.appending(path: "data.bin"))

        let scanner = try await scanned(developer)

        #expect(scanner.unreadableDeviceCount == 1)
        #expect(scanner.unreadableSummary == "Couldn't read 1 simulator.")
        let suggestions = scanner.cleanupSuggestions(idleDays: 14)
        #expect(suggestions.contains { $0.kind == .leftovers })
        #expect(state(of: scanner) == .suggestions(isPartial: true))
        let total = suggestions.reduce(DiskFootprint.zero) { $0 + $1.footprint }
        #expect(state(of: scanner).subtitle(total: total).hasSuffix("in what SimCleaner could read"))
    }
}

@MainActor
struct ScanFailureTests {
    @Test func aScanThatFailsIsAFailureEverywhereNotAnEmptyList() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        // A file where the Developer folder should be: nothing in it can be listed.
        let notAFolder = fixture.root.appending(path: "Developer")
        try Data("not a folder".utf8).write(to: notAFolder)
        let scanner = DeviceScanner(devicesURL: notAFolder, sandboxed: true, capabilities: noCoreSimulator)

        scanner.refresh()
        try await waitUntil { !scanner.isLoading }

        #expect(scanner.simulatorScanFailed)
        // Not a finished scan that found nothing: Suggestions and the list say what went wrong.
        #expect(!scanner.hasCompletedScan)
        #expect(scanner.devices.isEmpty)
        let simulators = scanner.storageOverview.categories.first { $0.kind == .simulators }
        #expect(simulators?.measurement == .unreadable)
        let message = try #require(scanner.errorMessage)
        let state = SimulatorListState.resolve(hasFolderAccess: true, scannedURL: notAFolder, errorMessage: message, isLoading: false, hasCompletedScan: scanner.hasCompletedScan, deviceCount: 0, filteredCount: 0, deviceSetCount: 0, isScanPartial: false)
        #expect(state == .error(message))
    }
}

@MainActor
struct CleanupCreditTests {
    @Test func aPartlyFailedBatchCreditsOnlyWhatWentAway() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let root = fixture.url("Library/Developer")
        let removable = try fixture.addDevice(in: "Library/Developer/CoreSimulator/Devices", name: "Removable")
        let changed = try fixture.addDevice(in: "Library/Developer/CoreSimulator/Devices", name: "Changed")
        let scanned = try SimulatorScanner.loadDevices(at: root).devices
        try PropertyListSerialization.data(fromPropertyList: ["UDID": UUID().uuidString, "name": "Other", "state": 1], format: .binary, options: 0)
            .write(to: changed.appending(path: "device.plist"))
        let harness = SessionHarness()
        let session = harness.makeSession()

        let scanner = DeviceScanner(devicesURL: root, sandboxed: true, capabilities: noCoreSimulator, cleanupSession: session)
        await scanner.delete(scanned)

        let gone = try #require(scanned.first { $0.rootPath.lastPathComponent == removable.lastPathComponent })
        #expect(session.totals?.freedBytes == gone.footprint.exclusiveBytes)
        #expect(session.cleanupsThisLaunch == 1)
        #expect(scanner.report != nil)
        // The deleted simulator leaves the list right away; the rescan confirms the rest.
        #expect(!scanner.devices.contains { $0.id == gone.id })
    }

    @Test func somethingAlreadyGoneIsNotCountedAgain() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let root = fixture.url("Library/Developer")
        try fixture.addDevice(in: "Library/Developer/CoreSimulator/Devices", name: "Once")
        let scanned = try SimulatorScanner.loadDevices(at: root).devices
        let session = SessionHarness().makeSession()
        let scanner = DeviceScanner(devicesURL: root, sandboxed: true, capabilities: noCoreSimulator, cleanupSession: session)

        await scanner.delete(scanned)
        let first = session.totals?.freedBytes
        #expect((first ?? 0) > 0)
        // A stale selection or a second confirmation runs the same deletion again.
        await scanner.delete(scanned)
        #expect(session.totals?.freedBytes == first)
        #expect(session.cleanupsThisLaunch == 1)
    }

    @Test func aRefusedOrFailedCleanupCreditsNothing() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let root = fixture.url("Library/Developer")
        let folder = try fixture.addDevice(in: "Library/Developer/CoreSimulator/Devices", name: "Kept")
        let scanned = try SimulatorScanner.loadDevices(at: root).devices
        let session = SessionHarness().makeSession()
        // CoreSimulator is installed and simctl isn't available: SimCleaner refuses to delete by files.
        let scanner = DeviceScanner(devicesURL: root, sandboxed: true, capabilities: filesOnly, cleanupSession: session)

        await scanner.delete(scanned)
        #expect(FileManager.default.fileExists(atPath: folder.path))
        #expect(session.totals == nil)
        // Neither does an operation that frees nothing by design.
        await scanner.shutDown(scanned)
        #expect(session.totals == nil)
    }

    @Test func removingCachesCreditsThemAndDropsThemAtOnce() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let developer = fixture.url("Library/Developer")
        try FileManager.default.createDirectory(at: developer.appending(path: "CoreSimulator/Devices"), withIntermediateDirectories: true)
        for name in ["One-abcdefghijklmnop", "Two-qrstuvwxyzabcdef"] {
            let project = developer.appending(path: "Xcode/DerivedData/\(name)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            try Data(repeating: 9, count: 200_000).write(to: project.appending(path: "build.o"))
        }
        let session = SessionHarness().makeSession()
        let scanner = DeviceScanner(sandboxed: true, capabilities: filesOnly, developerFolder: developer, restoresBookmark: false, cleanupSession: session)
        scanner.useGrantedFolder(developer)
        try await waitUntil { scanner.developerStorageState == .ready && !scanner.isScanningDeveloperStorage }
        let items = scanner.developerStorage.items(in: .derivedData)
        try #require(items.count == 2)

        await scanner.remove([items[0]])

        #expect(session.totals?.freedBytes == items[0].footprint.exclusiveBytes)
        #expect(scanner.developerStorage.items(in: .derivedData).map(\.id) == [items[1].id])
        // The page keeps its list while the caches are measured again.
        #expect(scanner.developerStorageState == .ready)
        try await waitUntil { !scanner.isScanningDeveloperStorage }
        #expect(scanner.developerStorage.items(in: .derivedData).map(\.id) == [items[1].id])
        #expect(scanner.volume.totalBytes > 0)
    }

    @Test func erasingFromTwoWindowsWithTheSameOldListCountsTheSpaceOnce() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let root = fixture.url("Library/Developer")
        let folder = try fixture.addDevice(in: "Library/Developer/CoreSimulator/Devices", name: "Erased twice")
        try Data(repeating: 5, count: 2_000_000).write(to: folder.appending(path: "data/app-data.bin"))
        // Both windows scanned before anything was erased, so both lists show the full simulator.
        let device = try #require(try SimulatorScanner.loadDevices(at: root).devices.first)
        let simctl = ErasingSimctl(udid: device.udid, folder: folder)
        let tool = SimctlTool(executable: URL(fileURLWithPath: "/usr/bin/xcrun"), leadingArguments: ["simctl"], developerDirectory: nil, source: .xcrun)
        let capabilities = Capabilities(isSandboxed: false, simctl: .success(tool), coreSimulatorInstalled: true)
        let session = SessionHarness().makeSession()
        let first = DeviceScanner(devicesURL: root, sandboxed: false, runner: simctl, capabilities: capabilities, cleanupSession: session)
        let second = DeviceScanner(devicesURL: root, sandboxed: false, runner: simctl, capabilities: capabilities, cleanupSession: session)

        await first.erase([device])
        #expect(first.report == nil)
        let credited = try #require(session.totals?.freedBytes)
        #expect(credited >= 2_000_000)

        // The second window still shows the simulator at its old size; erasing it again frees nothing.
        await second.erase([device])
        #expect(second.report == nil)
        #expect(session.totals?.freedBytes == credited)
        #expect(session.cleanupsThisLaunch == 1)
    }

    @Test func eachRemovedFolderCountsWhatItHeldRightBefore() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let bundle = fixture.url("App/Bundle")
        let data = fixture.url("App/Data")
        for (folder, size) in [(bundle, 30_000), (data, 50_000)] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(repeating: 1, count: size).write(to: folder.appending(path: "file"))
        }
        let bundleBefore = DiskUsage.measure(bundle)
        let freed = FreedSpace<[URL]>.removing { $0 }
        let credit = try #require(await freed.prepare([bundle, data]))

        // The bundle went and the data container stayed, as when removing an app fails halfway.
        try FileManager.default.removeItem(at: bundle)
        #expect(await credit(false) == bundleBefore.exclusiveBytes)
        // What's already gone has nothing to give back.
        let nothing = await freed.prepare([bundle])
        #expect(nothing == nil)
    }

    @Test func removingCachesDoesntLeaveTheSimulatorListLoading() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let developer = fixture.url("Library/Developer")
        try fixture.addDevice(in: "Library/Developer/CoreSimulator/Devices", name: "Stays")
        let project = developer.appending(path: "Xcode/DerivedData/One-abcdefghijklmnop", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data(repeating: 9, count: 10_000).write(to: project.appending(path: "build.o"))
        let scanner = DeviceScanner(sandboxed: true, capabilities: filesOnly, developerFolder: developer, restoresBookmark: false)
        scanner.useGrantedFolder(developer)
        try await waitUntil { scanner.developerStorageState == .ready && !scanner.isScanningDeveloperStorage }

        // A simulator scan is running when the caches go.
        scanner.refresh()
        await scanner.remove(scanner.developerStorage.items(in: .derivedData))

        try await waitUntil { !scanner.isLoading }
        #expect(scanner.devices.map(\.name) == ["Stays"])
    }
}

struct FeedbackTests {
    @Test func theMessageGoesToTheDeveloperWithWhatItRanOn() throws {
        let system = OperatingSystemVersion(majorVersion: 27, minorVersion: 0, patchVersion: 1)
        let url = Feedback.mailURL(edition: "SimCleaner Pro", version: "1.0", build: "7", system: system)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.scheme == "mailto")
        #expect(components.path == "stepanokdev@gmail.com")
        let fields = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(fields["subject"] == "SimCleaner Pro 1.0 feedback")
        #expect(fields["body"] == "\r\n\r\nSimCleaner Pro 1.0 (7) on macOS 27.0.1\r\n")
        // Encoded, so a mail app reads the whole subject and keeps the line breaks.
        #expect(!url.absoluteString.contains(" "))
        #expect(url.absoluteString.contains("%0D%0A"))
    }

    @Test func aMacOSWithoutAPatchVersionIsWrittenShort() throws {
        let system = OperatingSystemVersion(majorVersion: 15, minorVersion: 6, patchVersion: 0)
        let url = Feedback.mailURL(edition: "SimCleaner", version: "1.3", build: "6", system: system)
        let body = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "body" }?.value
        #expect(body == "\r\n\r\nSimCleaner 1.3 (6) on macOS 15.6\r\n")
    }

    @MainActor
    @Test func theAboutPanelShowsTheAddressAsALink() throws {
        let credits = Feedback.aboutCredits
        let range = (credits.string as NSString).range(of: Feedback.address)
        #expect(range.location != NSNotFound)
        let link = credits.attribute(.link, at: range.location, effectiveRange: nil) as? URL
        #expect(link?.scheme == "mailto")
        #expect(link.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.path } == Feedback.address)
    }
}
