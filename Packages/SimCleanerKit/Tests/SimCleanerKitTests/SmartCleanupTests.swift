//
//  SmartCleanupTests.swift
//  SimCleanerKitTests
//

import Foundation
import Testing
@testable import SimCleanerKit

struct SmartCleanupTests {
    private let day: TimeInterval = 86_400
    /// Whole seconds: info.plist keeps dates to the second, so a fraction would move them across the cutoff.
    private let now = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))

    private func setModified(_ url: URL, _ date: Date) throws {
        try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
    }

    /// A DerivedData project folder; `accessed` nil leaves info.plist without LastAccessedDate.
    @discardableResult
    private func addProject(_ fixture: Fixture, _ name: String, accessed: Date?) throws -> URL {
        let folder = fixture.url("Library/Developer/Xcode/DerivedData/\(name)-abcdefghijklmnopqrstuvwxyz")
        try FileManager.default.createDirectory(at: folder.appending(path: "Build"), withIntermediateDirectories: true)
        try Data(repeating: 2, count: 50_000).write(to: folder.appending(path: "Build/app.o"))
        var info: [String: Any] = ["WorkspacePath": "/Users/dev/\(name)/\(name).xcodeproj"]
        if let accessed { info["LastAccessedDate"] = accessed }
        (info as NSDictionary).write(to: folder.appending(path: "info.plist"), atomically: true)
        return folder
    }

    private func plan(_ fixture: Fixture, idleDays: Int = 30, devices: [SimulatorDevice] = []) -> SmartCleanupPlan {
        let storage = DeveloperStorageScanner.scan(developerFolder: fixture.url("Library/Developer"), now: now, fileExists: { _ in true })
        return SmartCleanupPlan.make(devices: devices, storage: storage, idleDays: idleDays, now: now)
    }

    @Test func derivedDataGoesOnlyWhenXcodeLastOpenedItLongEnoughAgo() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try addProject(fixture, "Old", accessed: now.addingTimeInterval(-40 * day))
        try addProject(fixture, "Recent", accessed: now.addingTimeInterval(-3 * day))
        // No LastAccessedDate: the folder's own date says nothing about use, so it's never automatic.
        let undated = try addProject(fixture, "Undated", accessed: nil)
        try setModified(undated, now.addingTimeInterval(-400 * day))

        let plan = plan(fixture)
        #expect(plan.targets(in: .derivedData).map(\.name) == ["Old"])
    }

    @Test func theCutoffIsStrict() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try addProject(fixture, "Exactly", accessed: now.addingTimeInterval(-30 * day))
        try addProject(fixture, "JustOver", accessed: now.addingTimeInterval(-30 * day - 1))

        #expect(plan(fixture).targets.map(\.name) == ["JustOver"])
    }

    @Test func xcodesSharedCachesAreNeverAutomatic() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        for shared in DeveloperStorageScanner.sharedDerivedDataFolders.keys {
            let folder = fixture.url("Library/Developer/Xcode/DerivedData/\(shared)")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(repeating: 3, count: 10_000).write(to: folder.appending(path: "cache.bin"))
            (["LastAccessedDate": now.addingTimeInterval(-400 * day)] as NSDictionary).write(to: folder.appending(path: "info.plist"), atomically: true)
            try setModified(folder, now.addingTimeInterval(-400 * day))
        }
        #expect(DeveloperStorageScanner.sharedDerivedDataFolders.count == 5)
        #expect(plan(fixture).targets.isEmpty)
    }

    @Test func onlyOlderDeviceSupportThatSatUnusedGoes() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let root = fixture.url("Library/Developer/Xcode/iOS DeviceSupport")
        for (name, age) in [("iPhone15,2 18.5 (22F76)", 60.0), ("iPhone15,2 26.1 (23B85)", 60.0), ("iPhone16,1 17.4 (21E219)", 60.0), ("iPhone16,1 26.0 (23A341)", 1.0), ("iPhone14,7 16.0 (20A362)", 2.0), ("iPhone14,7 26.0 (23A341)", 1.0)] {
            let folder = root.appending(path: name, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try Data(repeating: 4, count: 20_000).write(to: folder.appending(path: "Symbols.bin"))
            try setModified(folder, now.addingTimeInterval(-age * day))
        }
        // 18.5 has a newer version and sat for 60 days; 26.1 is the newest; 16.0 is older but copied two days ago.
        let names = plan(fixture).targets(in: .deviceSupport).map { $0.url.lastPathComponent }.sorted()
        #expect(names == ["iPhone15,2 18.5 (22F76)", "iPhone16,1 17.4 (21E219)"])
    }

    @Test func anAgentWorkspaceCountsItsNewestFileNotItsFolderDate() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let base = fixture.url("Library/Developer/XcodeBuildMCP/workspaces")
        for name in ["Quiet-0001", "Busy-0002"] {
            let logs = base.appending(path: "\(name)/logs", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
            let log = logs.appending(path: "build.log")
            try Data(repeating: 5, count: 1_000).write(to: log)
            for url in [log, logs, logs.deletingLastPathComponent()] {
                try setModified(url, now.addingTimeInterval(-50 * day))
            }
        }
        // An agent appended to a log deep inside: the folder dates don't move, the file's does.
        try setModified(base.appending(path: "Busy-0002/logs/build.log"), now.addingTimeInterval(-60))

        #expect(plan(fixture).targets(in: .agentWorkspaces).map(\.name) == ["Quiet-0001"])
    }

    @Test func toolSimulatorsGoWhenCoreSimulatorSaysTheyreShutDownAndTheyreOld() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let old = now.addingTimeInterval(-45 * day)
        let previews = "Library/Developer/Xcode/UserData/Previews/Simulator Devices"
        try fixture.addDevice(in: previews, name: "Old preview", extra: ["lastUsedAt": old])
        try fixture.addDevice(in: previews, name: "Running preview", extra: ["lastUsedAt": old])
        try fixture.addDevice(in: previews, name: "State unknown", extra: ["lastUsedAt": old])
        try fixture.addDevice(in: previews, name: "Never used")
        try fixture.addDevice(in: "Library/Developer/XCTestDevices", name: "Old clone", extra: ["lastUsedAt": old])
        // A simulator someone made and tested in: never automatic, however old.
        try fixture.addDevice(in: "Library/Developer/CoreSimulator/Devices", name: "Old simulator", extra: ["lastUsedAt": old])

        let devices = try SimulatorScanner.loadDevices(at: fixture.url("Library/Developer")).devices.map { device -> SimulatorDevice in
            var device = device
            switch device.name {
            case "Running preview": device.liveState = .booted
            case "State unknown": device.liveState = nil
            default: device.liveState = .shutdown
            }
            return device
        }
        let names = plan(fixture, devices: devices).targets(in: .toolSimulators).map(\.name).sorted()
        #expect(names == ["Old clone", "Old preview"])
    }

    @Test func rightBeforeDeletingAPlannedItemIsReadAgain() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let rebuilt = try addProject(fixture, "Rebuilt", accessed: now.addingTimeInterval(-40 * day))
        let replaced = try addProject(fixture, "Replaced", accessed: now.addingTimeInterval(-40 * day))
        try addProject(fixture, "Untouched", accessed: now.addingTimeInterval(-40 * day))
        let plan = plan(fixture)
        #expect(plan.targets.count == 3)

        // Xcode opened one project since; another folder was deleted and made again at the same path.
        (["LastAccessedDate": Date(), "WorkspacePath": "/Users/dev/Rebuilt/Rebuilt.xcodeproj"] as NSDictionary).write(to: rebuilt.appending(path: "info.plist"), atomically: true)
        try FileManager.default.removeItem(at: replaced)
        try addProject(fixture, "Replaced", accessed: now.addingTimeInterval(-40 * day))

        let verdicts = Dictionary(uniqueKeysWithValues: plan.targets.map { ($0.name, SmartCleanupPlan.recheck($0, idleDays: plan.idleDays)) })
        #expect(verdicts["Untouched"] == .some(nil))
        #expect(verdicts["Rebuilt"]??.contains("used since") == true)
        #expect(verdicts["Replaced"]??.contains("changed on disk") == true)
    }

    @Test func aGoneFolderIsNotRecheckedAsOld() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let folder = try addProject(fixture, "Gone", accessed: now.addingTimeInterval(-40 * day))
        let target = try #require(plan(fixture).targets.first)
        try FileManager.default.removeItem(at: folder)
        #expect(SmartCleanupPlan.recheck(target, idleDays: 30) != nil)
    }
}

struct CleanupAdvisorSafetyTests {
    private func device(_ name: String, set: DeviceSetKind, lastUsed: Date?, modified: Date?) -> SimulatorDevice {
        let setURL: URL
        switch set {
        case .previews: setURL = URL(fileURLWithPath: "/Users/dev/Library/Developer/Xcode/UserData/Previews/Simulator Devices")
        default: setURL = URL(fileURLWithPath: "/Users/dev/Library/Developer/CoreSimulator/Devices")
        }
        return SimulatorDevice(
            id: name, name: name, deviceType: "iPhone", deviceTypeIdentifier: "", runtime: "", runtimeIdentifier: "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
            runtimeGroup: "", category: .iPhone, udid: UUID().uuidString, plistState: .shutdown, lastUsedAt: lastUsed,
            hasBootedBefore: true, lastModifiedAt: modified, footprint: DiskFootprint(allocatedBytes: 3_000_000_000, exclusiveBytes: 3_000_000_000),
            apps: [], rootPath: URL(fileURLWithPath: "/tmp/\(name)"), isDefault: false,
            deviceSet: DeviceSet(url: setURL, kind: set)
        )
    }

    @Test func aSimulatorWithNoReadableDateIsNotCalledIdle() {
        let old = Date().addingTimeInterval(-60 * 86_400)
        let scan = ScanResult(devices: [
            device("Dated", set: .simulators, lastUsed: old, modified: old),
            device("Undated", set: .simulators, lastUsed: nil, modified: nil),
            device("Old preview", set: .previews, lastUsed: old, modified: old),
        ], deviceSets: [], leftovers: [], unreadableLocations: [], unreadableDeviceCount: 0)

        let idle = CleanupAdvisor.suggestions(for: scan, idleDays: 14, deviceHubInstalled: false).first { $0.kind == .idle }
        #expect(idle?.devices.map(\.name) == ["Dated"])
    }
}
