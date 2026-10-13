//
//  ScannerTests.swift
//  SimCleanerKitTests
//

import Foundation
import Testing
@testable import SimCleanerKit

struct LastUsedDateTests {
    private let devices = "Library/Developer/CoreSimulator/Devices"

    private func scanSingle(extra: [String: Any], booted: Bool = false) throws -> SimulatorDevice {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.addDevice(in: devices, extra: extra, booted: booted)
        let result = try SimulatorScanner.loadDevices(at: fixture.url(devices))
        return try #require(result.devices.first)
    }

    @Test func readsXcode27LastUsedAt() throws {
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let device = try scanSingle(extra: ["lastUsedAt": date], booted: true)
        #expect(device.lastUsedAt == date)
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

    @Test func neverBootedDeviceHasNoDateAndSortsLast() throws {
        let device = try scanSingle(extra: [:], booted: false)
        #expect(device.lastUsedAt == nil)
        #expect(device.hasBootedBefore == false)
        #expect(device.lastUsedSortKey == .distantPast)
    }

    @Test func bootedDeviceWithoutDateSortsAboveNeverBooted() throws {
        let device = try scanSingle(extra: [:], booted: true)
        #expect(device.lastUsedAt == nil)
        #expect(device.hasBootedBefore)
        #expect(device.lastUsedSortKey > .distantPast)
    }
}

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

        let result = try SimulatorScanner.loadDevices(at: fixture.url("Library/Developer"))

        #expect(result.deviceSets.count == 4)
        #expect(result.devices.count == 5)
        #expect(Set(result.devices.map(\.setKind)) == [.simulators, .previews, .testClones, .playgrounds])
        #expect(result.devices.first { $0.name == "Preview iPhone" }?.setKind == .previews)
        #expect(result.devices.first { $0.udid == defaultUDID }?.isDefault == true)
        #expect(result.devices.filter(\.isDefault).count == 1)
        #expect(result.leftovers.count == 1)
        #expect(result.unrecognizedSizeBytes > 0)
        #expect(Set(result.devices.map(\.id)).count == result.devices.count)
        #expect(result.devices.first { $0.setKind == .simulators }?.deviceSet.isDefaultSet == true)
        #expect(result.devices.first { $0.setKind == .testClones }?.deviceSet.isDefaultSet == false)
    }

    @Test func homeFolderAndIntermediateFoldersAlsoWork() throws {
        let (fixture, _) = try makeDeveloperFolder()
        defer { fixture.remove() }

        #expect(try SimulatorScanner.loadDevices(at: fixture.root).devices.count == 5)
        #expect(try SimulatorScanner.loadDevices(at: fixture.url("Library")).devices.count == 5)
        #expect(try SimulatorScanner.loadDevices(at: fixture.url("Library/Developer/CoreSimulator")).devices.count == 2)
        #expect(try SimulatorScanner.loadDevices(at: fixture.url("Library/Developer/CoreSimulator/Devices")).devices.count == 2)
        #expect(try SimulatorScanner.loadDevices(at: fixture.url("Library/Developer/Xcode")).devices.map(\.name) == ["Preview iPhone"])
    }

    @Test func symlinkedSetIsNotCountedTwice() throws {
        let (fixture, _) = try makeDeveloperFolder()
        defer { fixture.remove() }
        let previews = fixture.url("Library/Developer/Xcode/UserData/Previews/Simulator Devices")
        try FileManager.default.removeItem(at: previews)
        try FileManager.default.createSymbolicLink(at: previews, withDestinationURL: fixture.url("Library/Developer/CoreSimulator/Devices"))

        let result = try SimulatorScanner.loadDevices(at: fixture.url("Library/Developer"))
        #expect(result.devices.count == 4)
        #expect(Set(result.devices.map(\.udid)).count == 4)
    }

    @Test func folderWithoutSimulatorsReturnsNoSets() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(at: fixture.url("Documents/Projects"), withIntermediateDirectories: true)

        let result = try SimulatorScanner.loadDevices(at: fixture.root)
        #expect(result.deviceSets.isEmpty)
        #expect(result.devices.isEmpty)
    }

    @Test func missingFolderThrows() {
        let missing = FileManager.default.temporaryDirectory.appending(path: "SimCleaner-missing-\(UUID().uuidString)")
        #expect(throws: SimulatorScanError.self) {
            _ = try SimulatorScanner.loadDevices(at: missing)
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

        let result = try SimulatorScanner.loadDevices(at: fixture.url("Library/Developer"))
        #expect(result.isPartial)
        #expect(result.unreadableLocations.map(\.lastPathComponent) == ["XCTestDevices"])
        #expect(result.devices.count == 4)
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

        let result = try SimulatorScanner.loadDevices(at: fixture.url("Library/Developer"))
        #expect(result.devices.map(\.name) == ["Readable"])
        #expect(result.unreadableDeviceCount == 2)
        #expect(result.leftovers.count == 1)
        #expect(result.isPartial)
    }

    @Test func setKindComesFromLocation() {
        let home = URL(fileURLWithPath: "/Users/dev")
        #expect(DeviceSetKind.from(setURL: home.appending(path: "Library/Developer/CoreSimulator/Devices")) == .simulators)
        #expect(DeviceSetKind.from(setURL: home.appending(path: "Library/Developer/Xcode/UserData/Previews/Simulator Devices")) == .previews)
        #expect(DeviceSetKind.from(setURL: home.appending(path: "Library/Developer/XCTestDevices")) == .testClones)
        #expect(DeviceSetKind.from(setURL: home.appending(path: "Library/Developer/XCPGDevices")) == .playgrounds)
    }

    @Test func plistStateIsReadAndMissingStateIsUnknown() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let set = "Library/Developer/CoreSimulator/Devices"
        try fixture.addDevice(in: set, name: "Running", state: 3)
        try fixture.addDevice(in: set, name: "Off", state: 1)
        try fixture.addDevice(in: set, name: "NoState", state: nil)

        let devices = try SimulatorScanner.loadDevices(at: fixture.url(set)).devices
        #expect(devices.first { $0.name == "Running" }?.state == .booted)
        #expect(devices.first { $0.name == "Off" }?.state == .shutdown)
        #expect(devices.first { $0.name == "NoState" }?.state == .unknown(""))
    }
}

struct InstalledAppTests {
    @Test func appsGetTheirDataContainerAndTopLevelIcon() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let set = "Library/Developer/CoreSimulator/Devices"
        let device = try fixture.addDevice(in: set, booted: true)
        let app = try fixture.addApp(to: device, name: "Map Alerts", bundleId: "com.example.maps", iconNames: ["AppIcon60x60@2x.png"])
        // An embedded watch app with a bigger icon must not win.
        let watch = app.appending(path: "Watch/Watch.app", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: watch, withIntermediateDirectories: true)
        try Data(repeating: 9, count: 50_000).write(to: watch.appending(path: "AppIcon1024x1024.png"))

        let scanned = try #require(try SimulatorScanner.loadDevices(at: fixture.url(set)).devices.first)
        let found = try #require(scanned.apps.first)
        #expect(found.bundleId == "com.example.maps")
        #expect(found.icon?.lastPathComponent == "AppIcon60x60@2x.png")
        #expect(found.documentsURL?.lastPathComponent == "Documents")
        #expect(found.dataContainerPath != nil)
        #expect(found.id == found.bundlePath.path)
    }
}

struct RuntimeNamingTests {
    @Test func friendlyNamesAndVersions() {
        #expect(RuntimeNaming.friendlyRuntime("com.apple.CoreSimulator.SimRuntime.iOS-26-1") == "iOS 26.1")
        #expect(RuntimeNaming.friendlyRuntime("com.apple.CoreSimulator.SimRuntime.xrOS-26-0") == "visionOS 26.0")
        #expect(RuntimeNaming.runtimeGroup("com.apple.CoreSimulator.SimRuntime.iOS-26-4-1") == "iOS 26.4")
        #expect(RuntimeNaming.version(fromIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-17-5") == OperatingSystemVersion(majorVersion: 17, minorVersion: 5, patchVersion: 0))
        #expect(RuntimeNaming.platform(fromIdentifier: "com.apple.CoreSimulator.SimRuntime.watchOS-11-0") == .watchOS)
        #expect(RuntimeNaming.friendlyDeviceType("com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro", fallback: "x") == "iPhone 17 Pro")
    }
}
