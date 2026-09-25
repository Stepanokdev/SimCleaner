//
//  XCode_DevicesTests.swift
//  XCode DevicesTests
//
//  Created by Ivan Stepanok on 22.11.2025.
//

import Foundation
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

    /// Creates `<set>/<udid>/device.plist` plus a small data folder. Returns the device folder.
    @discardableResult
    func addDevice(
        in setPath: String,
        udid: String = UUID().uuidString,
        name: String = "iPhone 18 Pro",
        extra: [String: Any] = [:],
        booted: Bool = false
    ) throws -> URL {
        let folder = root.appending(path: setPath, directoryHint: .isDirectory).appending(path: udid, directoryHint: .isDirectory)
        let data = folder.appending(path: "data", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        if booted {
            try FileManager.default.createDirectory(at: data.appending(path: "Containers"), withIntermediateDirectories: true)
        }
        try Data(repeating: 1, count: 4096).write(to: data.appending(path: "payload.bin"))

        var plist: [String: Any] = [
            "UDID": udid,
            "name": name,
            "deviceType": "com.apple.CoreSimulator.SimDeviceType.iPhone-18-Pro",
            "runtime": "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
            "state": 1,
        ]
        plist.merge(extra) { _, new in new }
        let encoded = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        try encoded.write(to: folder.appending(path: "device.plist"))
        return folder
    }

    /// A UDID-named folder with data but no device.plist, like the leftovers in XCPGDevices.
    @discardableResult
    func addLeftover(in setPath: String) throws -> URL {
        let folder = root.appending(path: setPath, directoryHint: .isDirectory).appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let data = folder.appending(path: "data", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        try Data(repeating: 2, count: 4096).write(to: data.appending(path: "leftover.bin"))
        return folder
    }

    func writeDeviceSetPlist(in setPath: String, defaults: [String]) throws {
        let folder = root.appending(path: setPath, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var runtimeDict: [String: Any] = ["version": 0]
        for (index, udid) in defaults.enumerated() {
            runtimeDict["com.apple.CoreSimulator.SimDeviceType.Device-\(index)"] = udid
        }
        let plist: [String: Any] = ["DefaultDevices": ["com.apple.CoreSimulator.SimRuntime.iOS-27-0": runtimeDict]]
        let encoded = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
        try encoded.write(to: folder.appending(path: "device_set.plist"))
    }

    func url(_ path: String) -> URL {
        root.appending(path: path, directoryHint: .isDirectory)
    }
}

@MainActor
struct LastUsedDateTests {
    private let devices = "Library/Developer/CoreSimulator/Devices"

    private func scanSingle(extra: [String: Any], booted: Bool = false) throws -> SimulatorDevice {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.addDevice(in: devices, extra: extra, booted: booted)
        let result = try DeviceScanner.loadDevices(at: fixture.url(devices))
        return try #require(result.devices.first)
    }

    @Test func readsXcode27LastUsedAt() throws {
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let device = try scanSingle(extra: ["lastUsedAt": date], booted: true)
        #expect(device.lastUsedAt == date)
        #expect(device.lastUsedDescription != "Never launched")
    }

    @Test func fallsBackToLegacyLastBootedAt() throws {
        let date = Date(timeIntervalSince1970: 1_780_000_000)
        let device = try scanSingle(extra: ["lastBootedAt": date], booted: true)
        #expect(device.lastUsedAt == date)
    }

    @Test func prefersLastUsedAtWhenBothExist() throws {
        let newer = Date(timeIntervalSince1970: 1_790_000_000)
        let older = Date(timeIntervalSince1970: 1_700_000_000)
        let device = try scanSingle(extra: ["lastUsedAt": newer, "lastBootedAt": older], booted: true)
        #expect(device.lastUsedAt == newer)
    }

    @Test func acceptsISO8601StringDate() throws {
        let device = try scanSingle(extra: ["lastUsedAt": "2026-09-24T17:27:54Z"], booted: true)
        #expect(device.lastUsedAt == ISO8601DateFormatter().date(from: "2026-09-24T17:27:54Z"))
    }

    @Test func neverBootedDeviceSaysNeverLaunched() throws {
        let device = try scanSingle(extra: [:], booted: false)
        #expect(device.lastUsedAt == nil)
        #expect(device.hasBootedBefore == false)
        #expect(device.lastUsedDescription == "Never launched")
        #expect(device.lastUsedSortKey == .distantPast)
    }

    @Test func bootedDeviceWithoutDateIsUnknownNotNever() throws {
        // No timestamp, but data/Containers exists: it ran before. Don't claim "Never launched",
        // and don't invent a date from file modification times either.
        let device = try scanSingle(extra: [:], booted: true)
        #expect(device.lastUsedAt == nil)
        #expect(device.hasBootedBefore)
        #expect(device.lastUsedDescription == "Date unknown")
        #expect(device.lastUsedSortKey > .distantPast)
    }
}

@MainActor
struct DeviceSetDiscoveryTests {
    /// A full ~/Library/Developer layout with every set Xcode 27 uses.
    private func makeDeveloperFolder() throws -> (Fixture, defaultUDID: String) {
        let fixture = try Fixture()
        let defaultUDID = UUID().uuidString
        try fixture.writeDeviceSetPlist(in: "Library/Developer/CoreSimulator/Devices", defaults: [defaultUDID])
        try fixture.addDevice(in: "Library/Developer/CoreSimulator/Devices", udid: defaultUDID, name: "iPhone 18 Pro")
        try fixture.addDevice(in: "Library/Developer/CoreSimulator/Devices", name: "iPad Air")
        try fixture.addDevice(in: "Library/Developer/Xcode/UserData/Previews/Simulator Devices", name: "Preview iPhone")
        try fixture.addDevice(in: "Library/Developer/XCTestDevices", name: "Clone 1 of iPhone 18 Pro")
        try fixture.addLeftover(in: "Library/Developer/XCTestDevices")
        try fixture.addDevice(in: "Library/Developer/XCPGDevices", name: "Playground iPhone")
        // Not a device set: CoreSimulator keeps caches next to Devices.
        try FileManager.default.createDirectory(at: fixture.url("Library/Developer/CoreSimulator/Caches/dyld"), withIntermediateDirectories: true)
        return (fixture, defaultUDID)
    }

    @Test func developerFolderFindsEverySet() throws {
        let (fixture, defaultUDID) = try makeDeveloperFolder()
        defer { fixture.remove() }

        let result = try DeviceScanner.loadDevices(at: fixture.url("Library/Developer"))

        #expect(result.deviceSets.count == 4)
        #expect(result.devices.count == 5)
        #expect(Set(result.devices.map(\.setKind)) == [.simulators, .previews, .testClones, .playgrounds])
        #expect(result.devices.first { $0.name == "Preview iPhone" }?.setKind == .previews)
        #expect(result.devices.first { $0.name == "Clone 1 of iPhone 18 Pro" }?.setKind == .testClones)
        #expect(result.devices.first { $0.name == "Playground iPhone" }?.setKind == .playgrounds)
        #expect(result.devices.first { $0.udid == defaultUDID }?.isDefault == true)
        #expect(result.devices.filter(\.isDefault).count == 1)
        #expect(result.totalSizeBytes == result.devices.reduce(0) { $0 + $1.sizeBytes })
        #expect(result.unrecognizedFolderCount == 1)
        #expect(result.unrecognizedSizeBytes > 0)
        #expect(Set(result.devices.map(\.id)).count == result.devices.count)
    }

    @Test func homeFolderAndIntermediateFoldersAlsoWork() throws {
        let (fixture, _) = try makeDeveloperFolder()
        defer { fixture.remove() }

        #expect(try DeviceScanner.loadDevices(at: fixture.root).devices.count == 5)
        #expect(try DeviceScanner.loadDevices(at: fixture.url("Library")).devices.count == 5)
        // Picking CoreSimulator used to find nothing: its children are Caches/Devices/Temp.
        #expect(try DeviceScanner.loadDevices(at: fixture.url("Library/Developer/CoreSimulator")).devices.count == 2)
        #expect(try DeviceScanner.loadDevices(at: fixture.url("Library/Developer/CoreSimulator/Devices")).devices.count == 2)
        #expect(try DeviceScanner.loadDevices(at: fixture.url("Library/Developer/Xcode")).devices.map(\.name) == ["Preview iPhone"])
    }

    @Test func symlinkedSetIsNotCountedTwice() throws {
        let (fixture, _) = try makeDeveloperFolder()
        defer { fixture.remove() }
        // Previews set is a symlink to the main Devices set.
        let previews = fixture.url("Library/Developer/Xcode/UserData/Previews/Simulator Devices")
        try FileManager.default.removeItem(at: previews)
        try FileManager.default.createSymbolicLink(at: previews, withDestinationURL: fixture.url("Library/Developer/CoreSimulator/Devices"))

        let result = try DeviceScanner.loadDevices(at: fixture.url("Library/Developer"))
        #expect(result.devices.count == 4)
        #expect(Set(result.devices.map(\.udid)).count == 4)
    }

    @Test func folderWithoutSimulatorsReturnsNoSetsInsteadOfThrowing() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.url("Documents/Projects"), withIntermediateDirectories: true)

        let result = try DeviceScanner.loadDevices(at: fixture.root)
        #expect(result.deviceSets.isEmpty)
        #expect(result.devices.isEmpty)
    }

    @Test func missingFolderThrows() throws {
        let missing = FileManager.default.temporaryDirectory.appending(path: "SimCleaner-missing-\(UUID().uuidString)")
        #expect(throws: (any Error).self) {
            _ = try DeviceScanner.loadDevices(at: missing)
        }
    }

    @Test func unreadableSetIsReportedNotTreatedAsEmpty() throws {
        let (fixture, _) = try makeDeveloperFolder()
        let clones = fixture.url("Library/Developer/XCTestDevices")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: clones.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: clones.path)
            fixture.remove()
        }

        let result = try DeviceScanner.loadDevices(at: fixture.url("Library/Developer"))
        #expect(result.isPartial)
        #expect(result.unreadableLocations.map(\.lastPathComponent) == ["XCTestDevices"])
        #expect(result.devices.count == 4)
        #expect(!result.devices.contains { $0.setKind == .testClones })
    }

    @Test func onlyUnreadableSetMeansPartialNotEmpty() throws {
        let fixture = try Fixture()
        try fixture.writeDeviceSetPlist(in: "Library/Developer/CoreSimulator/Devices", defaults: [])
        try fixture.addDevice(in: "Library/Developer/CoreSimulator/Devices")
        let devices = fixture.url("Library/Developer/CoreSimulator/Devices")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: devices.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: devices.path)
            fixture.remove()
        }

        let result = try DeviceScanner.loadDevices(at: fixture.url("Library/Developer"))
        #expect(result.devices.isEmpty)
        #expect(result.isPartial)
        #expect(result.unreadableLocations.map(\.lastPathComponent) == ["Devices"])
    }

    @Test func unreadableDeviceIsCountedSeparatelyFromLeftovers() throws {
        let fixture = try Fixture()
        let set = "Library/Developer/CoreSimulator/Devices"
        try fixture.addDevice(in: set, name: "Readable")
        let brokenPlist = try fixture.addDevice(in: set, name: "Broken plist")
        try Data("not a plist".utf8).write(to: brokenPlist.appending(path: "device.plist"))
        let lockedFolder = try fixture.addDevice(in: set, name: "Locked")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: lockedFolder.path)
        try fixture.addLeftover(in: set)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: lockedFolder.path)
            fixture.remove()
        }

        let result = try DeviceScanner.loadDevices(at: fixture.url("Library/Developer"))
        #expect(result.devices.map(\.name) == ["Readable"])
        #expect(result.unreadableDeviceCount == 2)
        #expect(result.unrecognizedFolderCount == 1)
        #expect(result.isPartial)
    }

    @Test func setKindComesFromLocation() {
        let home = URL(fileURLWithPath: "/Users/dev")
        #expect(DeviceSetKind.from(setURL: home.appending(path: "Library/Developer/CoreSimulator/Devices")) == .simulators)
        #expect(DeviceSetKind.from(setURL: home.appending(path: "Library/Developer/Xcode/UserData/Previews/Simulator Devices")) == .previews)
        #expect(DeviceSetKind.from(setURL: home.appending(path: "Library/Developer/XCTestDevices")) == .testClones)
        #expect(DeviceSetKind.from(setURL: home.appending(path: "Library/Developer/XCPGDevices")) == .playgrounds)
    }
}

@MainActor
struct DeletionTests {
    @Test func deletesDeviceInNonDefaultSetOnly() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let keep = try fixture.addDevice(in: "Library/Developer/CoreSimulator/Devices", name: "Keep")
        let clone = try fixture.addDevice(in: "Library/Developer/XCTestDevices", name: "Clone")
        let root = fixture.url("Library/Developer")

        let target = try #require(try DeviceScanner.loadDevices(at: root).devices.first { $0.name == "Clone" })
        try DeviceScanner.performDelete(devices: [target], allowedRoot: root)

        #expect(!FileManager.default.fileExists(atPath: clone.path))
        #expect(FileManager.default.fileExists(atPath: keep.path))
        #expect(FileManager.default.fileExists(atPath: fixture.url("Library/Developer/XCTestDevices").path))
    }

    @Test func refusesFolderOutsideGrantedRoot() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let outside = try fixture.addDevice(in: "Elsewhere/Devices", name: "Outside")
        try fixture.addDevice(in: "Library/Developer/CoreSimulator/Devices", name: "Inside")

        let device = try #require(try DeviceScanner.loadDevices(at: fixture.url("Elsewhere/Devices")).devices.first)
        #expect(throws: (any Error).self) {
            try DeviceScanner.performDelete(devices: [device], allowedRoot: fixture.url("Library/Developer"))
        }
        #expect(FileManager.default.fileExists(atPath: outside.path))
    }

    @Test func partialDeletionStillRescansAndReportsFailure() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let root = fixture.url("Library/Developer")
        let removable = try fixture.addDevice(in: "Library/Developer/CoreSimulator/Devices", name: "Removable")
        let changed = try fixture.addDevice(in: "Library/Developer/CoreSimulator/Devices", name: "Changed")
        let scanned = try DeviceScanner.loadDevices(at: root).devices
        // The second device's folder now belongs to something else, so its deletion must fail.
        try PropertyListSerialization.data(fromPropertyList: ["UDID": UUID().uuidString, "name": "Other"], format: .binary, options: 0)
            .write(to: changed.appending(path: "device.plist"))

        let scanner = DeviceScanner()
        scanner.devicesURL = root
        await scanner.delete(devices: scanned)

        #expect(!FileManager.default.fileExists(atPath: removable.path))
        #expect(FileManager.default.fileExists(atPath: changed.path))
        // The list reflects the disk after the partial deletion instead of the stale pre-delete list.
        #expect(scanner.devices.map(\.name) == ["Other"])
        #expect(scanner.deletionError?.contains("Changed") == true)
        #expect(scanner.errorMessage == nil)
        #expect(scanner.isLoading == false)
    }

    @Test func refusesFolderThatChangedSinceScan() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let folder = try fixture.addDevice(in: "Library/Developer/CoreSimulator/Devices", name: "Original")
        let root = fixture.url("Library/Developer")
        let device = try #require(try DeviceScanner.loadDevices(at: root).devices.first)

        // Something else now claims this folder.
        let replaced: [String: Any] = ["UDID": UUID().uuidString, "name": "Other"]
        try PropertyListSerialization.data(fromPropertyList: replaced, format: .binary, options: 0)
            .write(to: folder.appending(path: "device.plist"))

        #expect(throws: (any Error).self) {
            try DeviceScanner.performDelete(devices: [device], allowedRoot: root)
        }
        #expect(FileManager.default.fileExists(atPath: folder.path))
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

/// The tests run inside the app host. A signed build (ad-hoc or real) runs it in the App Sandbox like the
/// shipped app; a build with CODE_SIGNING_ALLOWED=NO carries no entitlements and isn't sandboxed.
@MainActor
struct SandboxLocationTests {
    private static let isSandboxed = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil

    @Test func pickerStartsAtTheRealDeveloperFolderNotTheContainer() throws {
        let entry = try #require(getpwuid(getuid()))
        let realHome = String(cString: entry.pointee.pw_dir)
        #expect(DeviceScanner.developerFolderURL.path == realHome + "/Library/Developer")
        #expect(!DeviceScanner.developerFolderURL.path.contains("/Library/Containers/"))
    }

    @Test(.enabled(if: isSandboxed, "Needs the App Sandbox: build with code signing (ad-hoc is enough)"))
    func sandboxedHomeIsTheContainerSoTheRealHomeIsUsed() {
        // In the sandbox the Foundation home is the app container. The old default path was built from it
        // and pointed at a folder that doesn't exist; developerFolderURL must not follow it.
        let foundationHome = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(foundationHome.contains("/Library/Containers/"))
        #expect(!DeviceScanner.developerFolderURL.path.hasPrefix(foundationHome))
    }
}
