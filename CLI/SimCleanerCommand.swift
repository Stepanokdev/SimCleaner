//
//  SimCleanerCommand.swift
//  simcleaner
//
//  The command line side of SimCleaner Pro. Same rules as the app: everything goes through
//  CoreSimulator, a failed simctl call never turns into deleting files, and nothing destructive
//  happens without --yes.

import ArgumentParser
import Foundation
import SimCleanerKit

@main
struct SimCleanerCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "simcleaner",
        abstract: "See and clean up Xcode simulators, runtimes and caches.",
        discussion: "Destructive commands print what they would do and stop unless you pass --yes. Add --json to any listing for scripts and coding agents. Feedback and bug reports: stepanokdev@gmail.com",
        version: "1.0",
        subcommands: [Storage.self, List.self, Suggest.self, Runtimes.self, Caches.self, Shutdown.self, Erase.self, Delete.self, Install.self],
        defaultSubcommand: Storage.self
    )
}

// MARK: - Shared options and context

struct OutputOptions: ParsableArguments {
    @Flag(help: "Print JSON instead of a table.")
    var json = false
}

struct ConfirmOptions: ParsableArguments {
    @Flag(help: "Actually do it. Without this the command only shows what it would do.")
    var yes = false
}

/// What every command needs: the developer folder, simctl, and a scan with live states.
struct Context {
    let developerFolder: URL
    let capabilities: Capabilities
    let simctl: SimctlClient?

    static func make() async -> Context {
        let capabilities = await Capabilities.detect()
        return Context(
            developerFolder: DeveloperPaths.developerFolder,
            capabilities: capabilities,
            simctl: capabilities.simctlTool.map { SimctlClient(tool: $0) }
        )
    }

    func scan() async throws -> ScanResult {
        let result = try SimulatorScanner.loadDevices(at: developerFolder)
        guard let simctl else { return result }
        var live: [String: SimctlDevice] = [:]
        var listed: Set<String> = []
        for set in result.deviceSets {
            guard let devices = try? await simctl.listDevices(in: set) else { continue }
            listed.insert(set.url.path)
            for device in devices { live[device.udid] = device }
        }
        let devices = result.devices.map { device -> SimulatorDevice in
            var device = device
            guard listed.contains(device.deviceSet.url.path) else { return device }
            let match = live[device.udid]
            device.liveState = match?.deviceState
            device.isAvailable = match?.isAvailable
            device.availabilityError = match?.availabilityError
            device.isKnownToSimctl = match != nil
            return device
        }
        return ScanResult(devices: devices, deviceSets: result.deviceSets, leftovers: result.leftovers, unreadableLocations: result.unreadableLocations, unreadableDeviceCount: result.unreadableDeviceCount)
    }

    func controller() -> DeviceController {
        DeviceController(capabilities: capabilities, allowedRoot: developerFolder)
    }

    func requireSimctl() throws -> SimctlClient {
        guard let simctl else {
            throw ValidationError(capabilities.simctlProblem?.explanation ?? "Xcode's simulator tools aren't available.")
        }
        return simctl
    }

    /// Resolves UDIDs (or unique name prefixes) to scanned devices; unknown ones are an error, not skipped.
    func devices(matching identifiers: [String], in scan: ScanResult) throws -> [SimulatorDevice] {
        try identifiers.map { identifier in
            if let byUDID = scan.devices.first(where: { $0.udid.caseInsensitiveCompare(identifier) == .orderedSame }) {
                return byUDID
            }
            let byName = scan.devices.filter { $0.name.localizedCaseInsensitiveCompare(identifier) == .orderedSame }
            if byName.count == 1 { return byName[0] }
            if byName.count > 1 { throw ValidationError("\"\(identifier)\" matches \(byName.count) simulators. Use the UDID.") }
            throw ValidationError("No simulator with UDID or name \"\(identifier)\".")
        }
    }
}

// MARK: - Listing

struct Storage: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Where simulator and Xcode space goes, and what's safe to free.")
    @OptionGroup var output: OutputOptions

    func run() async throws {
        let context = await Context.make()
        let scan = try await context.scan()
        let caches = DeveloperStorageScanner.scan(developerFolder: context.developerFolder)
        let runtimes = await RuntimeReport.load(context: context, devices: scan.devices)
        let report = StorageReport(scan: scan, caches: caches, runtimes: runtimes, simulatorCaches: try? RuntimeInventory.dyldCaches())
        if output.json {
            try JSON.print(report)
        } else {
            report.printTable()
        }
    }
}

struct List: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List simulators with their state, size and last use.")
    @OptionGroup var output: OutputOptions
    @Flag(help: "Only running simulators.")
    var running = false

    func run() async throws {
        let context = await Context.make()
        var devices = try await context.scan().devices.sorted { $0.footprint.allocatedBytes > $1.footprint.allocatedBytes }
        if running { devices = devices.filter { $0.state.isRunning } }
        if output.json {
            try JSON.print(devices.map(DeviceJSON.init))
        } else {
            Table.print(
                headers: ["NAME", "RUNTIME", "STATE", "SIZE", "FREES", "LAST USED", "UDID"],
                rows: devices.map { device in
                    [device.name, device.runtime, device.isAvailable == false ? "unavailable" : device.state.title.lowercased(), Bytes.string(device.footprint.allocatedBytes), Bytes.freed(device.footprint), device.lastUsedAt.map(Dates.relative) ?? (device.hasBootedBefore ? "unknown" : "never"), device.udid]
                }
            )
        }
    }
}

struct Suggest: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Simulators worth erasing or deleting, and why.")
    @OptionGroup var output: OutputOptions
    @Option(help: "Suggest simulators not used for this many days.")
    var days = 14

    func run() async throws {
        let context = await Context.make()
        let scan = try await context.scan()
        let deviceHub = FileManager.default.fileExists(atPath: "/Applications/Xcode.app/Contents/Applications/DeviceHub.app")
        let suggestions = CleanupAdvisor.suggestions(for: scan, idleDays: days, deviceHubInstalled: deviceHub)
        if output.json {
            try JSON.print(suggestions.map(SuggestionJSON.init))
            return
        }
        if suggestions.isEmpty {
            print("Nothing to clean up. No simulator has been idle for \(days) days, none is unavailable, and there are no leftover folders.")
            return
        }
        for suggestion in suggestions {
            print("\(suggestion.title) — frees \(Bytes.freed(suggestion.footprint))")
            print("  \(suggestion.detail)")
            for device in suggestion.devices {
                print("  • \(device.name) (\(device.runtime)), \(Bytes.string(device.footprint.allocatedBytes))  \(device.udid)")
            }
            for leftover in suggestion.leftovers {
                print("  • \(leftover.url.path), \(Bytes.string(leftover.footprint.allocatedBytes))")
            }
            let udids = suggestion.devices.map(\.udid).joined(separator: " ")
            if !udids.isEmpty {
                print("  → simcleaner \(suggestion.action == .erase ? "erase" : "delete") \(udids) --yes")
            }
            print("")
        }
    }
}

struct Caches: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "DerivedData, device support files and coding agent workspaces.",
        subcommands: [CachesList.self, CachesRemove.self],
        defaultSubcommand: CachesList.self
    )
}

struct CachesList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List Xcode caches, with suggestions.")
    @OptionGroup var output: OutputOptions

    func run() async throws {
        let report = DeveloperStorageScanner.scan(developerFolder: DeveloperPaths.developerFolder)
        if output.json {
            try JSON.print(report.items.map(CacheItemJSON.init))
        } else {
            Table.print(
                headers: ["CATEGORY", "NAME", "SIZE", "SUGGESTED", "PATH"],
                rows: report.items.map { [$0.category.rawValue, $0.title, Bytes.string($0.footprint.allocatedBytes), $0.recommendation ?? "", $0.url.path] }
            )
        }
    }
}

struct CachesRemove: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "remove", abstract: "Remove Xcode cache folders by path, or every suggested one.")
    @Argument(help: "Paths printed by `simcleaner caches list`.")
    var paths: [String] = []
    @Flag(help: "Remove every item `caches list` marks as suggested.")
    var suggested = false
    @OptionGroup var confirm: ConfirmOptions

    func validate() throws {
        if paths.isEmpty && !suggested { throw ValidationError("Name paths, or pass --suggested.") }
    }

    func run() async throws {
        let developer = DeveloperPaths.developerFolder
        let report = DeveloperStorageScanner.scan(developerFolder: developer)
        let wanted = Set(paths.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
        let items = report.items.filter { (suggested && $0.isRecommended) || wanted.contains($0.url.standardizedFileURL.path) }
        let unknown = wanted.subtracting(items.map { $0.url.standardizedFileURL.path })
        guard unknown.isEmpty else { throw ValidationError("Not an Xcode cache SimCleaner knows: \(unknown.sorted().joined(separator: ", "))") }
        let total = items.reduce(DiskFootprint.zero) { $0 + $1.footprint }
        guard confirm.yes else {
            print("Would remove \(items.count) items and free \(Bytes.freed(total)):")
            items.forEach { print("  • \($0.url.path)") }
            print("Run again with --yes to remove them.")
            throw ExitCode(2)
        }
        var failures = 0
        for item in items {
            do {
                try DeveloperStorageScanner.remove(item, developerFolder: developer)
                print("Removed \(item.url.path)")
            } catch {
                failures += 1
                Output.error("\(item.url.path): \(error.localizedDescription)")
            }
        }
        if failures > 0 { throw ExitCode.failure }
    }
}

// MARK: - Runtimes

struct Runtimes: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Downloaded simulator runtimes.",
        subcommands: [RuntimesList.self, RuntimesDelete.self],
        defaultSubcommand: RuntimesList.self
    )
}

struct RuntimesList: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List runtimes with size, last use and how many simulators use each.")
    @OptionGroup var output: OutputOptions

    func run() async throws {
        let context = await Context.make()
        let scan = try await context.scan()
        let report = await RuntimeReport.load(context: context, devices: scan.devices)
        guard let entries = report.entries else {
            // An empty list would read as "no runtimes".
            Output.error(report.note ?? "Couldn't read the runtimes.")
            throw ExitCode.failure
        }
        if output.json {
            try JSON.print(entries.map(RuntimeJSON.init))
        } else {
            Table.print(
                headers: ["RUNTIME", "SIMULATORS", "LAST USED", "SIZE", "DELETABLE", "ID"],
                rows: entries.map { [$0.title, String($0.deviceCount), $0.lastUsedAt.map(Dates.relative) ?? "—", Bytes.string($0.sizeBytes), $0.isDeletable.map { $0 ? "yes" : "no" } ?? "?", $0.simctlImageID ?? "—"] }
            )
            if let note = report.note { print("\n\(note)") }
        }
    }
}

struct RuntimesDelete: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "delete", abstract: "Delete a runtime by the ID `runtimes list` prints.")
    @Argument(help: "Runtime image ID.")
    var identifier: String
    @Flag(name: .customLong("dry-run"), help: "Ask CoreSimulator what would be deleted, and stop.")
    var dryRun = false
    @OptionGroup var confirm: ConfirmOptions

    func run() async throws {
        let context = await Context.make()
        let simctl = try context.requireSimctl()
        guard context.capabilities.canManageRuntimes else {
            throw ValidationError("Runtimes can't be managed from here (App Sandbox).")
        }
        if dryRun || !confirm.yes {
            print(try await simctl.deleteRuntime(identifier, dryRun: true).trimmingCharacters(in: .whitespacesAndNewlines))
            if !dryRun {
                print("Run again with --yes to delete it.")
                throw ExitCode(2)
            }
            return
        }
        _ = try await simctl.deleteRuntime(identifier, dryRun: false)
        if try await simctl.listRuntimeImages().contains(where: { $0.identifier == identifier }) {
            Output.error("CoreSimulator still lists the runtime. It may disappear after a restart; if it stays, delete it in Xcode › Settings › Components.")
            throw ExitCode.failure
        }
        print("Deleted runtime \(identifier).")
    }
}

// MARK: - Simulator operations

struct Shutdown: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Shut down simulators.")
    @Argument(help: "UDIDs or exact names.")
    var simulators: [String] = []
    @Flag(help: "Every running simulator.")
    var allRunning = false

    func validate() throws {
        if simulators.isEmpty && !allRunning { throw ValidationError("Name simulators, or pass --all-running.") }
    }

    func run() async throws {
        let context = await Context.make()
        _ = try context.requireSimctl()
        let scan = try await context.scan()
        let targets = allRunning ? scan.devices.filter { $0.state.isRunning } : try context.devices(matching: simulators, in: scan)
        try await Operations.run(targets, verb: "Shut down") { try await context.controller().shutDown($0) }
    }
}

struct Erase: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Erase simulators: remove their apps, data and settings but keep them.")
    @Argument(help: "UDIDs or exact names.")
    var simulators: [String]
    @OptionGroup var confirm: ConfirmOptions

    func run() async throws {
        let context = await Context.make()
        _ = try context.requireSimctl()
        let scan = try await context.scan()
        let targets = try context.devices(matching: simulators, in: scan)
        guard confirm.yes else {
            Operations.preview(targets, verb: "erase")
            throw ExitCode(2)
        }
        try await Operations.run(targets, verb: "Erased") { try await context.controller().erase($0) }
    }
}

struct Delete: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Delete simulators. Running ones are shut down first.")
    @Argument(help: "UDIDs or exact names.")
    var simulators: [String]
    @OptionGroup var confirm: ConfirmOptions

    func run() async throws {
        let context = await Context.make()
        let scan = try await context.scan()
        let targets = try context.devices(matching: simulators, in: scan)
        guard confirm.yes else {
            Operations.preview(targets, verb: "delete")
            throw ExitCode(2)
        }
        try await Operations.run(targets, verb: "Deleted") { try await context.controller().delete($0) }
    }
}

struct Install: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Install one simulator build on several simulators. Shut-down ones are started and shut down again.")
    @Argument(help: "Path to the .app built for the simulator.")
    var app: String
    @Option(name: .customLong("to"), parsing: .upToNextOption, help: "UDIDs or exact names.")
    var simulators: [String]
    @OptionGroup var output: OutputOptions

    func run() async throws {
        let context = await Context.make()
        let simctl = try context.requireSimctl()
        let info = try AppBundleInfo.read(URL(fileURLWithPath: app).standardizedFileURL)
        let scan = try await context.scan()
        let targets = try context.devices(matching: simulators, in: scan)
        let installer = BatchInstaller(simctl: simctl, canBoot: context.capabilities.canBoot)
        let quiet = output.json
        let results = await installer.install(info, on: targets) { udid, phase in
            guard !quiet, let name = targets.first(where: { $0.udid == udid })?.name else { return }
            switch phase {
            case .starting: Output.error("\(name): starting…")
            case .installing: Output.error("\(name): installing…")
            case .shuttingDown: Output.error("\(name): shutting down…")
            default: break
            }
        }
        if output.json {
            try JSON.print(targets.map { InstallResultJSON(udid: $0.udid, name: $0.name, phase: results[$0.udid]) })
        } else {
            for target in targets {
                print("\(target.name): \(InstallResultJSON.describe(results[target.udid]))")
            }
        }
        // Every simulator asked for has to end up with the app and in the state it was found in.
        guard InstallPhase.allFulfilled(results, for: targets) else {
            let done = targets.filter { results[$0.udid]?.isFulfilled == true }.count
            Output.error("The app is on \(done) of \(targets.count) \(targets.count == 1 ? "simulator" : "simulators") as asked.")
            throw ExitCode.failure
        }
    }
}
