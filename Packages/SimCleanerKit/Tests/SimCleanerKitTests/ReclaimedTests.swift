//
//  ReclaimedTests.swift
//  SimCleanerKitTests
//
//  What a cleanup counts as freed, and how the storage categories add up.

import Foundation
import Testing
@testable import SimCleanerKit

struct ReclaimedTests {
    @Test func onlySomethingThatIsReallyGoneCounts() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let folder = fixture.url("Library/Developer/Xcode/DerivedData/App-abcdefghijklmnop")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 64_000).write(to: folder.appending(path: "build.o"))
        let footprint = DiskUsage.measure(folder)

        #expect(!DiskUsage.isGone(folder))
        #expect(Reclaimed.ifGone(folder, footprint) == 0)
        try FileManager.default.removeItem(at: folder)
        #expect(DiskUsage.isGone(folder))
        #expect(Reclaimed.ifGone(folder, footprint) == footprint.exclusiveBytes)
    }

    @Test func aFolderSimCleanerCantSeeIntoIsNotGone() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let parent = fixture.url("Locked")
        let child = parent.appending(path: "inside", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: parent.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: parent.path) }

        // lstat fails with EACCES, not ENOENT: unknown is not gone.
        #expect(!DiskUsage.isGone(child))
        #expect(Reclaimed.ifGone(child, DiskFootprint(allocatedBytes: 100, exclusiveBytes: 100)) == 0)
    }

    @Test func measuringRightBeforeSeesOnlyWhatIsThere() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let folder = fixture.url("Library/Developer/Xcode/DerivedData/App-abcdefghijklmnop")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 64_000).write(to: folder.appending(path: "build.o"))

        let before = try #require(await Reclaimed.measure(folder))
        #expect(before == DiskUsage.measure(folder))
        #expect(before.exclusiveBytes >= 64_000)
        // Something another window already removed has nothing left to give back.
        try FileManager.default.removeItem(at: folder)
        #expect(await Reclaimed.measure(folder) == nil)
    }

    @Test func erasingCountsWhatTheSimulatorNoLongerHolds() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let folder = try fixture.addDevice(in: "Devices", payloadBytes: 400_000)
        let before = try #require(await Reclaimed.measure(folder))
        // An erase leaves a fresh device behind: the plist and a little data.
        try FileManager.default.removeItem(at: folder.appending(path: "data/payload.bin"))
        try Data(repeating: 2, count: 8192).write(to: folder.appending(path: "data/fresh.bin"))
        let after = DiskUsage.measure(folder)

        let freed = await Reclaimed.byErasing(folder, before: before, erased: true)
        #expect(freed == before.exclusiveBytes - after.allocatedBytes)
        #expect(freed > 300_000)
        // A failed erase counts nothing, even if some files went.
        #expect(await Reclaimed.byErasing(folder, before: before, erased: false) == 0)
        // Erasing the fresh simulator again, measured as it is now, gives nothing more back.
        let again = try #require(await Reclaimed.measure(folder))
        #expect(await Reclaimed.byErasing(folder, before: again, erased: true) == 0)
    }
}

struct StorageBreakdownTests {
    @Test func everyCategoryIsCountedInTheSameOrderForTheAppAndTheCommandLine() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let developer = fixture.url("Library/Developer")
        try fixture.addDevice(in: "Library/Developer/CoreSimulator/Devices", payloadBytes: 50_000)
        try fixture.addLeftover(in: "Library/Developer/CoreSimulator/Devices")
        let project = fixture.url("Library/Developer/Xcode/DerivedData/App-abcdefghijklmnop")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data(repeating: 7, count: 30_000).write(to: project.appending(path: "build.o"))

        let scan = try SimulatorScanner.loadDevices(at: developer)
        let caches = DeveloperStorageScanner.scan(developerFolder: developer)
        let runtime = RuntimeEntry(source: .simctl(imageID: "A"), platform: .iOS, version: "27.0", build: nil, runtimeIdentifier: nil, sizeBytes: 9_000_000, lastUsedAt: nil, isDeletable: true, state: nil)
        let lines = StorageBreakdown.lines(scan: scan, caches: caches, runtimes: [runtime], simulatorCaches: [])

        #expect(lines.map(\.category) == StorageCategory.allCases)
        #expect(lines[0].count == 1)
        #expect(lines[0].footprint == scan.footprint)
        #expect(lines[1].count == 1)
        #expect(lines[2].footprint == DiskFootprint(allocatedBytes: 9_000_000, exclusiveBytes: 9_000_000))
        #expect(lines[3].footprint == caches.footprint(of: .derivedData))
        #expect(lines[3].count == 1)
        #expect(lines.last?.footprint == .zero)
    }

    @Test func whatCouldntBeReadIsUnknownNotZero() {
        let derivedData = URL(fileURLWithPath: "/D/Xcode/DerivedData")
        let item = DeveloperStorageItem(category: .derivedData, url: derivedData.appending(path: "A"), title: "A", detail: nil, footprint: DiskFootprint(allocatedBytes: 10, exclusiveBytes: 10), lastModifiedAt: nil, recommendation: nil)
        let closed = DeveloperStorageReport(items: [], unreadableLocations: [derivedData])
        let halfOpen = DeveloperStorageReport(items: [item], unreadableLocations: [derivedData])

        #expect(StorageBreakdown.developer(closed, .derivedData).coverage == .unreadable)
        #expect(StorageBreakdown.developer(halfOpen, .derivedData).coverage == .partial)
        // Another category's unreadable folder doesn't touch this one.
        #expect(StorageBreakdown.developer(closed, .deviceSupport).coverage == .complete)
        #expect(StorageBreakdown.runtimes(nil).coverage == .unreadable)
        #expect(StorageBreakdown.runtimes([]).coverage == .complete)
        #expect(StorageBreakdown.simulatorCaches(nil).coverage == .unreadable)

        let blindScan = ScanResult(devices: [], deviceSets: [], leftovers: [], unreadableLocations: [URL(fileURLWithPath: "/D/CoreSimulator/Devices")], unreadableDeviceCount: 0)
        #expect(StorageBreakdown.simulators(blindScan).coverage == .unreadable)
        #expect(StorageBreakdown.simulators(.empty).coverage == .complete)
    }

    @Test func emptyLeftoverFoldersCostNothingAndArentCounted() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let set = fixture.url("Devices")
        try FileManager.default.createDirectory(at: set.appending(path: UUID().uuidString), withIntermediateDirectories: true)
        let scan = try SimulatorScanner.loadDevices(at: set)
        #expect(StorageBreakdown.leftovers(scan).count == 0)
    }
}
