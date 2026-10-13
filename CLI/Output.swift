//
//  Output.swift
//  simcleaner
//
//  Tables for people, JSON for scripts. JSON keys are stable: agents parse them.

import ArgumentParser
import Foundation
import SimCleanerKit

enum Output {
    /// Progress and errors go to stderr so stdout stays clean for JSON.
    static func error(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

enum JSON {
    static func print<T: Encodable>(_ value: T) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        FileHandle.standardOutput.write(try encoder.encode(value))
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}

enum Bytes {
    static func string(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        // "0 bytes" instead of the default "Zero KB", which reads oddly in a table.
        formatter.allowsNonnumericFormatting = false
        return formatter.string(fromByteCount: bytes)
    }

    /// One figure when sharing doesn't matter, otherwise "at least – at most".
    static func freed(_ footprint: DiskFootprint) -> String {
        let high = footprint.allocatedBytes
        guard high > 0 else { return "0 bytes" }
        if Double(high - footprint.exclusiveBytes) / Double(high) < 0.05 { return string(high) }
        return "\(string(footprint.exclusiveBytes))–\(string(high))"
    }
}

enum Dates {
    nonisolated(unsafe) static let formatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()

    /// "2 days ago"; within a minute, or a moment ahead, "just now" rather than "in 0 sec.".
    static func relative(_ date: Date) -> String {
        if abs(date.timeIntervalSinceNow) < 60 { return "just now" }
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

enum Table {
    static func print(headers: [String], rows: [[String]]) {
        guard !rows.isEmpty else {
            Swift.print("Nothing to list.")
            return
        }
        let widths = headers.indices.map { column in
            ([headers[column]] + rows.map { $0[column] }).map(\.count).max() ?? 0
        }
        func line(_ cells: [String]) -> String {
            cells.enumerated().map { index, cell in
                index == cells.count - 1 ? cell : cell.padding(toLength: widths[index], withPad: " ", startingAt: 0)
            }.joined(separator: "  ")
        }
        Swift.print(line(headers))
        rows.forEach { Swift.print(line($0)) }
    }
}

// MARK: - Batch operations

enum Operations {
    static func preview(_ devices: [SimulatorDevice], verb: String) {
        let total = devices.reduce(DiskFootprint.zero) { $0 + $1.footprint }
        print("Would \(verb) \(devices.count) \(devices.count == 1 ? "simulator" : "simulators") and free \(Bytes.freed(total)):")
        for device in devices {
            print("  • \(device.name) (\(device.runtime))\(device.state.isRunning ? ", running: shut down first" : "")  \(device.udid)")
        }
        print("Run again with --yes to do it.")
    }

    /// Runs each operation, reports each failure, and exits non-zero if any failed.
    static func run(_ devices: [SimulatorDevice], verb: String, _ operation: (SimulatorDevice) async throws -> Void) async throws {
        var failures = 0
        for device in devices {
            do {
                try await operation(device)
                print("\(verb) \(device.name) (\(device.udid))")
            } catch {
                failures += 1
                Output.error("\(device.name): \(error.localizedDescription)")
            }
        }
        if failures > 0 { throw ExitCode.failure }
    }
}

// MARK: - Reports

struct RuntimeReport {
    /// Nil when nothing could list the runtimes: unknown, not none.
    let entries: [RuntimeEntry]?
    let note: String?

    static func load(context: Context, devices: [SimulatorDevice]) async -> RuntimeReport {
        if context.capabilities.canManageRuntimes, let simctl = context.simctl {
            do {
                return RuntimeReport(entries: RuntimeInventory.entries(from: try await simctl.listRuntimeImages(), devices: devices), note: nil)
            } catch {
                let reason = error.localizedDescription
                do {
                    return RuntimeReport(entries: try RuntimeInventory.entriesFromAssetFolders(devices: devices), note: "simctl couldn't list runtimes (\(reason)); sizes come from their folders.")
                } catch {
                    return RuntimeReport(entries: nil, note: "Couldn't read the runtimes: simctl failed (\(reason)), and so did reading their folder (\(error.localizedDescription)).")
                }
            }
        }
        do {
            return RuntimeReport(entries: try RuntimeInventory.entriesFromAssetFolders(devices: devices), note: nil)
        } catch {
            return RuntimeReport(entries: nil, note: "Couldn't read the runtimes folder: \(error.localizedDescription)")
        }
    }
}

struct StorageReport: Encodable {
    struct Line: Encodable {
        let name: String
        let count: Int?
        /// Missing when nothing in the category could be read: unknown, never zero.
        let allocatedBytes: Int64?
        let freeableBytesAtLeast: Int64?
        /// "complete"; "partial" when some folders couldn't be read, so there may be more; "unreadable"
        /// when none could.
        let coverage: String
    }

    let lines: [Line]
    let diskFreeBytes: Int64
    let unreadableLocations: [String]
    let notes: [String]

    /// The same categories, counted the same way, as the storage bar in the app. `simulatorCaches` is nil
    /// when their folder couldn't be read.
    init(scan: ScanResult, caches: DeveloperStorageReport, runtimes: RuntimeReport, simulatorCaches: [DyldCacheEntry]?) {
        lines = StorageBreakdown.lines(scan: scan, caches: caches, runtimes: runtimes.entries, simulatorCaches: simulatorCaches).map { line in
            switch line.coverage {
            case .unreadable:
                return Line(name: line.category.title, count: nil, allocatedBytes: nil, freeableBytesAtLeast: nil, coverage: "unreadable")
            case .partial, .complete:
                return Line(name: line.category.title, count: line.count, allocatedBytes: line.footprint.allocatedBytes, freeableBytesAtLeast: line.footprint.exclusiveBytes, coverage: line.coverage == .partial ? "partial" : "complete")
            }
        }
        diskFreeBytes = VolumeSpace.of(DeveloperPaths.developerFolder).availableBytes
        unreadableLocations = (scan.unreadableLocations + caches.unreadableLocations).map(\.path)
        var notes = runtimes.note.map { [$0] } ?? []
        if simulatorCaches == nil {
            notes.append("Couldn't read \(RuntimeInventory.dyldCachesRoot.path).")
        }
        self.notes = notes
    }

    func printTable() {
        Table.print(
            headers: ["WHAT", "ITEMS", "ON DISK", "FREES AT LEAST"],
            rows: lines.map { line in
                guard let count = line.count, let allocated = line.allocatedBytes, let freeable = line.freeableBytesAtLeast else {
                    return [line.name, "—", "couldn't read", "—"]
                }
                let onDisk = line.coverage == "partial" ? "at least \(Bytes.string(allocated))" : Bytes.string(allocated)
                return [line.name, String(count), onDisk, Bytes.string(freeable)]
            }
        )
        print("\nFree on this disk: \(Bytes.string(diskFreeBytes))")
        print("Run `simcleaner suggest` for what's worth cleaning, `simcleaner caches` and `simcleaner runtimes` for the rest.")
        if !unreadableLocations.isEmpty {
            print("Couldn't read: \(unreadableLocations.joined(separator: ", "))")
        }
        for note in notes {
            print(note)
        }
    }
}

// MARK: - JSON shapes

struct DeviceJSON: Encodable {
    let udid: String
    let name: String
    let deviceType: String
    let runtime: String
    let runtimeIdentifier: String
    let state: String
    let available: Bool?
    let availabilityError: String?
    let deviceSet: String
    let allocatedBytes: Int64
    let freeableBytesAtLeast: Int64
    let lastUsedAt: Date?
    let apps: [AppJSON]

    struct AppJSON: Encodable {
        let bundleId: String
        let name: String
        let allocatedBytes: Int64
        let dataContainer: String?
    }

    init(_ device: SimulatorDevice) {
        udid = device.udid
        name = device.name
        deviceType = device.deviceType
        runtime = device.runtime
        runtimeIdentifier = device.runtimeIdentifier
        state = device.state.title.lowercased()
        available = device.isAvailable
        availabilityError = device.availabilityError
        deviceSet = device.deviceSet.kind.rawValue
        allocatedBytes = device.footprint.allocatedBytes
        freeableBytesAtLeast = device.footprint.exclusiveBytes
        lastUsedAt = device.lastUsedAt
        apps = device.apps.map { AppJSON(bundleId: $0.bundleId, name: $0.name, allocatedBytes: $0.sizeBytes, dataContainer: $0.dataContainerPath?.path) }
    }
}

struct SuggestionJSON: Encodable {
    let kind: String
    let title: String
    let detail: String
    let action: String
    let udids: [String]
    let leftoverPaths: [String]
    let allocatedBytes: Int64
    let freeableBytesAtLeast: Int64

    init(_ suggestion: CleanupSuggestion) {
        kind = suggestion.kind.rawValue
        title = suggestion.title
        detail = suggestion.detail
        action = suggestion.action.rawValue
        udids = suggestion.devices.map(\.udid)
        leftoverPaths = suggestion.leftovers.map(\.url.path)
        allocatedBytes = suggestion.footprint.allocatedBytes
        freeableBytesAtLeast = suggestion.footprint.exclusiveBytes
    }
}

struct CacheItemJSON: Encodable {
    let category: String
    let title: String
    let detail: String?
    let path: String
    let allocatedBytes: Int64
    let freeableBytesAtLeast: Int64
    let lastModifiedAt: Date?
    let suggestion: String?

    init(_ item: DeveloperStorageItem) {
        category = item.category.rawValue
        title = item.title
        detail = item.detail
        path = item.url.path
        allocatedBytes = item.footprint.allocatedBytes
        freeableBytesAtLeast = item.footprint.exclusiveBytes
        lastModifiedAt = item.lastModifiedAt
        suggestion = item.recommendation
    }
}

struct RuntimeJSON: Encodable {
    let id: String?
    let title: String
    let platform: String?
    let version: String?
    let build: String?
    let sizeBytes: Int64
    let simulators: Int
    let lastUsedAt: Date?
    let deletable: Bool?

    init(_ entry: RuntimeEntry) {
        id = entry.simctlImageID
        title = entry.title
        platform = entry.platform?.rawValue
        version = entry.version
        build = entry.build
        sizeBytes = entry.sizeBytes
        simulators = entry.deviceCount
        lastUsedAt = entry.lastUsedAt
        deletable = entry.isDeletable
    }
}

struct InstallResultJSON: Encodable {
    let udid: String
    let name: String
    /// installed, skipped, failed, cancelled, left_running or unfinished.
    let result: String
    let detail: String?
    let appInstalled: Bool
    /// False when SimCleaner started the simulator for the install and couldn't shut it down again.
    let stateRestored: Bool

    init(udid: String, name: String, phase: InstallPhase?) {
        self.udid = udid
        self.name = name
        switch phase {
        case .installed?:
            (result, detail, appInstalled, stateRestored) = ("installed", nil, true, true)
        case .skipped(let reason)?:
            (result, detail, appInstalled, stateRestored) = ("skipped", reason, false, true)
        case .failed(let reason)?:
            (result, detail, appInstalled, stateRestored) = ("failed", reason, false, true)
        case .cancelled?:
            (result, detail, appInstalled, stateRestored) = ("cancelled", nil, false, true)
        case .leftRunning(let installed, let reason)?:
            (result, detail, appInstalled, stateRestored) = ("left_running", reason, installed, false)
        default:
            // Never reached the end, so nothing is known about the simulator's state.
            (result, detail, appInstalled, stateRestored) = ("unfinished", nil, false, false)
        }
    }

    static func describe(_ phase: InstallPhase?) -> String {
        switch phase {
        case .installed?: return "installed"
        case .skipped(let reason)?: return "skipped — \(reason)"
        case .failed(let reason)?: return "failed — \(reason)"
        case .cancelled?: return "cancelled"
        case .leftRunning(_, let reason)?: return "left running — \(reason)"
        default: return "unfinished"
        }
    }
}
