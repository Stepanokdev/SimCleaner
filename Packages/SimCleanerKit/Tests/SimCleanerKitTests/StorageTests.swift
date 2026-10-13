//
//  StorageTests.swift
//  SimCleanerKitTests
//

import Foundation
import Testing
@testable import SimCleanerKit

struct DeveloperStorageTests {
    private func makeFolder(_ fixture: Fixture, _ path: String, bytes: Int = 4096) throws -> URL {
        let folder = fixture.url(path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(repeating: 5, count: bytes).write(to: folder.appending(path: "content.bin"))
        return folder
    }

    @Test func derivedDataNamesProjectsAndFlagsMissingOnes() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let developer = fixture.url("Library/Developer")
        let present = try makeFolder(fixture, "Library/Developer/Xcode/DerivedData/Present-abcdefghijklmnop")
        let gone = try makeFolder(fixture, "Library/Developer/Xcode/DerivedData/Gone-qrstuvwxyzabcdef")
        try makeFolder(fixture, "Library/Developer/Xcode/DerivedData/ModuleCache.noindex")
        let project = try makeFolder(fixture, "Projects/Present.xcodeproj")
        (["WorkspacePath": project.path] as NSDictionary).write(to: present.appending(path: "info.plist"), atomically: true)
        (["WorkspacePath": fixture.url("Projects/Gone.xcodeproj").path] as NSDictionary).write(to: gone.appending(path: "info.plist"), atomically: true)

        let report = DeveloperStorageScanner.scan(developerFolder: developer)
        let items = report.items(in: .derivedData)
        #expect(items.count == 3)
        #expect(items.first { $0.url.isSame(as: present) }?.title == "Present")
        #expect(items.first { $0.url.isSame(as: present) }?.isRecommended == false)
        #expect(items.first { $0.url.isSame(as: gone) }?.recommendation == "The project is no longer at this location.")
        #expect(items.first { $0.title == "Shared module cache" } != nil)

        // Inside the sandbox SimCleaner can't see projects, so it must not guess they're gone.
        let sandboxed = DeveloperStorageScanner.scan(developerFolder: developer, fileExists: nil)
        #expect(sandboxed.items(in: .derivedData).allSatisfy { !$0.isRecommended })
    }

    @Test func olderDeviceSupportVersionsOfTheSameModelAreSuggested() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let base = "Library/Developer/Xcode/iOS DeviceSupport"
        try makeFolder(fixture, "\(base)/iPhone12,5 26.4.2 (23E261)")
        try makeFolder(fixture, "\(base)/iPhone12,5 27.0 (24A437)")
        try makeFolder(fixture, "\(base)/iPhone16,1 26.4.2 (23E261)")

        let items = DeveloperStorageScanner.scan(developerFolder: fixture.url("Library/Developer")).items(in: .deviceSupport)
        #expect(items.count == 3)
        let old = try #require(items.first { $0.url.lastPathComponent == "iPhone12,5 26.4.2 (23E261)" })
        #expect(old.recommendation == "There's a newer iOS 27.0 for this device.")
        #expect(old.title == "iOS 26.4.2 (23E261)")
        #expect(old.detail == "iPhone12,5")
        #expect(items.first { $0.url.lastPathComponent == "iPhone12,5 27.0 (24A437)" }?.isRecommended == false)
        // The only version Xcode has for another model is kept.
        #expect(items.first { $0.url.lastPathComponent == "iPhone16,1 26.4.2 (23E261)" }?.isRecommended == false)
    }

    @Test func deviceSupportNamesInEveryKnownFormat() {
        #expect(DeveloperStorageScanner.DeviceSupportName("iPhone12,5 26.4.2 (23E261)")?.model == "iPhone12,5")
        #expect(DeveloperStorageScanner.DeviceSupportName("17.0 (21A329)")?.model == nil)
        #expect(DeveloperStorageScanner.DeviceSupportName("17.0 (21A329)")?.version == OperatingSystemVersion(majorVersion: 17, minorVersion: 0, patchVersion: 0))
        #expect(DeveloperStorageScanner.DeviceSupportName("Not a version") == nil)
    }

    @Test func staleAgentWorkspacesAreSuggested() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let fresh = try makeFolder(fixture, "Library/Developer/XcodeBuildMCP/workspaces/task-fresh")
        let stale = try makeFolder(fixture, "Library/Developer/XcodeBuildMCP/workspaces/task-stale")
        let old = Date().addingTimeInterval(-10 * 86_400)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: stale.path)

        let items = DeveloperStorageScanner.scan(developerFolder: fixture.url("Library/Developer")).items(in: .agentWorkspaces)
        #expect(items.first { $0.url.isSame(as: fresh) }?.isRecommended == false)
        #expect(items.first { $0.url.isSame(as: stale) }?.isRecommended == true)
        #expect(items.allSatisfy { $0.detail == "XcodeBuildMCP" })
    }

    @Test func removalStaysInsideTheExpectedFolders() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let developer = fixture.url("Library/Developer")
        let folder = try makeFolder(fixture, "Library/Developer/Xcode/DerivedData/App-abcdefghij")
        let report = DeveloperStorageScanner.scan(developerFolder: developer)
        let item = try #require(report.items.first)

        try DeveloperStorageScanner.remove(item, developerFolder: developer)
        #expect(!FileManager.default.fileExists(atPath: folder.path))

        // An item whose path was tampered with to point elsewhere is refused.
        let elsewhere = try makeFolder(fixture, "Library/Developer/CoreSimulator/Devices/ABC")
        let forged = DeveloperStorageItem(category: .derivedData, url: elsewhere, title: "x", detail: nil, footprint: .zero, lastModifiedAt: nil, recommendation: nil)
        #expect(throws: DeviceOperationError.outsideAllowedLocation) { try DeveloperStorageScanner.remove(forged, developerFolder: developer) }
        #expect(FileManager.default.fileExists(atPath: elsewhere.path))
    }
}

struct CleanupAdvisorTests {
    private func device(name: String, lastUsed: Date?, state: DeviceState = .shutdown, exclusive: Int64 = 3_000_000_000, runtime: String = "com.apple.CoreSimulator.SimRuntime.iOS-27-0", available: Bool? = true) -> SimulatorDevice {
        var device = SimulatorDevice(
            id: name, name: name, deviceType: "iPhone", deviceTypeIdentifier: "", runtime: "", runtimeIdentifier: runtime,
            runtimeGroup: "", category: .iPhone, udid: UUID().uuidString, plistState: state, lastUsedAt: lastUsed,
            hasBootedBefore: true, lastModifiedAt: lastUsed, footprint: DiskFootprint(allocatedBytes: exclusive, exclusiveBytes: exclusive),
            apps: [], rootPath: URL(fileURLWithPath: "/tmp/\(name)"), isDefault: false,
            deviceSet: DeviceSet(url: URL(fileURLWithPath: "/Users/dev/Library/Developer/CoreSimulator/Devices"), kind: .simulators)
        )
        device.isAvailable = available
        return device
    }

    @Test func idleDevicesAreSuggestedForErasing() {
        let now = Date()
        let scan = ScanResult(devices: [
            device(name: "Old", lastUsed: now.addingTimeInterval(-20 * 86_400)),
            device(name: "Recent", lastUsed: now.addingTimeInterval(-2 * 86_400)),
            device(name: "OldButRunning", lastUsed: now.addingTimeInterval(-20 * 86_400), state: .booted),
            device(name: "OldButTiny", lastUsed: now.addingTimeInterval(-20 * 86_400), exclusive: 20_000_000),
        ], deviceSets: [], leftovers: [], unreadableLocations: [], unreadableDeviceCount: 0)

        let suggestions = CleanupAdvisor.suggestions(for: scan, now: now, idleDays: 7, deviceHubInstalled: false)
        let idle = suggestions.first { $0.kind == .idle }
        #expect(idle?.devices.map(\.name) == ["Old"])
        #expect(idle?.action == .erase)
    }

    @Test func unavailableAndPreDeviceHubDevicesAreFlagged() {
        let scan = ScanResult(devices: [
            device(name: "Gone runtime", lastUsed: Date(), available: false),
            device(name: "iOS 17", lastUsed: Date(), runtime: "com.apple.CoreSimulator.SimRuntime.iOS-17-5"),
            device(name: "iOS 27", lastUsed: Date()),
        ], deviceSets: [], leftovers: [], unreadableLocations: [], unreadableDeviceCount: 0)

        let withHub = CleanupAdvisor.suggestions(for: scan, idleDays: 7, deviceHubInstalled: true)
        #expect(withHub.first { $0.kind == .unavailable }?.devices.map(\.name) == ["Gone runtime"])
        #expect(withHub.first { $0.kind == .unsupportedByDeviceHub }?.devices.map(\.name) == ["iOS 17"])
        let withoutHub = CleanupAdvisor.suggestions(for: scan, idleDays: 7, deviceHubInstalled: false)
        #expect(!withoutHub.contains { $0.kind == .unsupportedByDeviceHub })
    }
}

struct RuntimeInventoryTests {
    @Test func assetFoldersBecomeRuntimesWithDeviceCounts() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let asset = fixture.url("AssetsV2/com_apple_MobileAsset_iOSSimulatorRuntime/abc.asset")
        try FileManager.default.createDirectory(at: asset.appending(path: "AssetData"), withIntermediateDirectories: true)
        try Data(repeating: 1, count: 100_000).write(to: asset.appending(path: "AssetData/image.dmg"))
        (["MobileAssetProperties": ["SimulatorVersion": "26.5", "Build": "23F77"]] as NSDictionary).write(to: asset.appending(path: "Info.plist"), atomically: true)

        let device = CleanupAdvisorTests().deviceForRuntime("com.apple.CoreSimulator.SimRuntime.iOS-26-5")
        let entries = try RuntimeInventory.entriesFromAssetFolders(devices: [device], root: fixture.url("AssetsV2"))
        let entry = try #require(entries.first)
        #expect(entry.platform == .iOS)
        #expect(entry.title == "iOS 26.5 (23F77)")
        #expect(entry.deviceCount == 1)
        #expect(entry.sizeBytes >= 100_000)
        #expect(entry.simctlImageID == nil)
    }

    @Test func dyldCachesFromOlderMacOSBuildsAreMarked() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        for build in ["25A100", "26A428"] {
            let folder = fixture.url("dyld/\(build)/com.apple.CoreSimulator.SimRuntime.iOS-26-5.23F77")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(repeating: 1, count: 4096).write(to: folder.appending(path: "dyld_sim_shared_cache_arm64e"))
        }
        let caches = try RuntimeInventory.dyldCaches(root: fixture.url("dyld"), currentMacOSBuild: "26A428")
        #expect(caches.count == 2)
        #expect(caches.first { $0.macOSBuild == "25A100" }?.isForCurrentMacOS == false)
        #expect(caches.first { $0.macOSBuild == "26A428" }?.isForCurrentMacOS == true)
        #expect(caches.first?.runtimeName == "iOS 26.5 (23F77)")
    }

    @Test func aMissingFolderHoldsNothingButAnUnreadableOneIsAnError() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        // Not there at all: no runtimes downloaded there, no caches built.
        #expect(try RuntimeInventory.entriesFromAssetFolders(devices: [], root: fixture.url("Missing")).isEmpty)
        #expect(try RuntimeInventory.dyldCaches(root: fixture.url("Missing"), currentMacOSBuild: nil).isEmpty)

        // There, but closed to SimCleaner: that's not the same as empty.
        let assets = fixture.url("AssetsV2/com_apple_MobileAsset_iOSSimulatorRuntime")
        let caches = fixture.url("dyld/26A428")
        for folder in [assets, caches] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: folder.path)
        }
        defer {
            for folder in [assets, caches] { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: folder.path) }
        }
        #expect(throws: (any Error).self) { try RuntimeInventory.entriesFromAssetFolders(devices: [], root: fixture.url("AssetsV2")) }
        #expect(throws: (any Error).self) { try RuntimeInventory.dyldCaches(root: fixture.url("dyld"), currentMacOSBuild: nil) }
    }
}

extension CleanupAdvisorTests {
    func deviceForRuntime(_ runtime: String) -> SimulatorDevice {
        device(name: "x", lastUsed: nil, runtime: runtime)
    }
}


extension URL {
    /// Same file, whatever the trailing slash or /var vs /private/var spelling.
    func isSame(as other: URL) -> Bool {
        resolvingSymlinksInPath().standardizedFileURL.path == other.resolvingSymlinksInPath().standardizedFileURL.path
    }
}
