//
//  DeviceScanner.swift
//  XCode Devices
//
//  Created by Ivan Stepanok on 22.11.2025.
//

import AppKit
import Combine
import Foundation
import SimCleanerKit

/// Progress of a batch of operations, shown above the list without blocking the window.
struct BulkProgress: Equatable {
    let title: String
    let completed: Int
    let total: Int
    let current: String

    var fraction: Double { total > 0 ? Double(completed) / Double(total) : 0 }
}

/// What the Xcode caches page can show right now.
enum DeveloperStorageState: Equatable {
    /// The App Store edition hasn't been given a folder yet.
    case needsAccess
    /// The granted folder is inside ~/Library/Developer, so the caches next to it are out of reach.
    case notCovered
    case measuring
    case ready
}

/// How a cleanup tells what it freed. `prepare` runs right before the operation, once this window holds
/// the item, and looks at the disk as it is then: another window may already have deleted or erased what
/// this window's list still shows at its old size, and counting from that list would count the same space
/// twice. It returns how to count once the operation is over, given whether it succeeded, or nil when
/// there's nothing there to free.
struct FreedSpace<Item> {
    let prepare: (Item) async -> ((_ succeeded: Bool) async -> Int64)?

    /// For cleanups that remove folders: each folder counts what it held right before, once it's gone,
    /// even when the operation then failed, as an app can be removed before its simulator fails to stop.
    static func removing(_ folders: @escaping (Item) -> [URL]) -> FreedSpace {
        FreedSpace { item in
            var before: [(URL, DiskFootprint)] = []
            for folder in folders(item) {
                if let footprint = await Reclaimed.measure(folder) { before.append((folder, footprint)) }
            }
            guard !before.isEmpty else { return nil }
            return { _ in before.reduce(0) { $0 + Reclaimed.ifGone($1.0, $1.1) } }
        }
    }
}

/// What went wrong in the last batch, so the window can say it instead of failing silently.
struct OperationReport: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let failures: [String]
}

@MainActor
final class DeviceScanner: ObservableObject {
    // Simulators
    @Published private(set) var devices: [SimulatorDevice] = []
    @Published private(set) var leftovers: [LeftoverFolder] = []
    @Published private(set) var deviceSets: [DeviceSet] = []
    @Published private(set) var unreadableLocations: [URL] = []
    @Published private(set) var unreadableDeviceCount = 0
    @Published private(set) var hasCompletedScan = false
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?
    @Published private(set) var scanProgress: ScanProgress?
    @Published private(set) var volume: VolumeSpace = .unknown

    // Folder access. The App Store edition only sees the folder the person picked.
    @Published var devicesURL: URL
    @Published private(set) var hasFolderAccess = false

    // What this copy of SimCleaner can do on this Mac. Nil until detected.
    @Published private(set) var capabilities: Capabilities?

    // Xcode data beyond the simulators
    @Published private(set) var developerStorage: DeveloperStorageReport = .empty
    @Published private(set) var isScanningDeveloperStorage = false
    @Published private(set) var hasScannedDeveloperStorage = false
    @Published private(set) var runtimes: [RuntimeEntry] = []
    @Published private(set) var dyldCaches: [DyldCacheEntry] = []
    /// False when nothing could list the runtimes: the list is unknown, not empty.
    @Published private(set) var canReadRuntimes = true
    /// False when CoreSimulator's caches folder is there but couldn't be read.
    @Published private(set) var canReadSimulatorCaches = true
    @Published private(set) var runtimesError: String?
    @Published private(set) var isLoadingRuntimes = false
    @Published private(set) var hasLoadedRuntimes = false

    // Work in progress: item ID → what is happening to it. Simulators are keyed by `SimulatorDevice.id`,
    // their folder, which names both the device set and the UDID.
    @Published private(set) var busy: [String: String] = [:]
    @Published private(set) var bulkProgress: BulkProgress?
    @Published var report: OperationReport?

    let isSandboxed: Bool
    /// ~/Library/Developer; Xcode caches are measured here.
    let developerFolder: URL
    /// Adds up what cleanups free, for every window. Nil in tests that don't look at it.
    let cleanupSession: CleanupSession?
    private var activeSecurityScopedURL: URL?
    private var scanGeneration = 0
    private var developerStorageGeneration = 0
    private var runtimesGeneration = 0
    private var hasStarted = false
    private let runner: CommandRunning

    nonisolated private static var bookmarkFileURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.appending(path: "devices.bookmark")
    }

    init(
        devicesURL: URL? = nil,
        sandboxed: Bool = Capabilities.currentProcessIsSandboxed,
        runner: CommandRunning = ProcessRunner(),
        capabilities: Capabilities? = nil,
        developerFolder: URL = DeveloperPaths.developerFolder,
        restoresBookmark: Bool = true,
        cleanupSession: CleanupSession? = nil
    ) {
        self.isSandboxed = sandboxed
        self.runner = runner
        self.capabilities = capabilities
        self.developerFolder = developerFolder
        self.cleanupSession = cleanupSession
        if let devicesURL {
            self.devicesURL = devicesURL
            hasFolderAccess = true
        } else if !sandboxed {
            // Outside the sandbox there's nothing to grant: Pro reads ~/Library/Developer directly.
            self.devicesURL = developerFolder
            hasFolderAccess = true
        } else if restoresBookmark, let bookmarked = Self.restoreBookmarkedURL() {
            self.devicesURL = bookmarked
            beginAccessing(url: bookmarked)
        } else {
            self.devicesURL = developerFolder
        }
    }

    // MARK: - Derived state

    /// Some simulator folders couldn't be read, so the list may be missing devices.
    var isScanPartial: Bool { !unreadableLocations.isEmpty || unreadableDeviceCount > 0 }

    /// What a partial scan couldn't read: "Couldn't open XCTestDevices." / "Couldn't read 2 simulators."
    var unreadableSummary: String {
        var parts: [String] = []
        if let first = unreadableLocations.first {
            let name = first.lastPathComponent
            parts.append(unreadableLocations.count == 1 ? "Couldn't open \(name)." : "Couldn't open \(name) and \(unreadableLocations.count - 1) more \(unreadableLocations.count == 2 ? "folder" : "folders").")
        }
        if unreadableDeviceCount > 0 {
            parts.append("Couldn't read \(unreadableDeviceCount) \(unreadableDeviceCount == 1 ? "simulator" : "simulators").")
        }
        return parts.joined(separator: " ")
    }

    /// True when the granted folder is ~/Library/Developer or one of its parents.
    var coversDeveloperFolder: Bool {
        let granted = devicesURL.standardizedFileURL.path
        let developer = developerFolder.standardizedFileURL.path
        return developer == granted || developer.hasPrefix(granted.hasSuffix("/") ? granted : granted + "/")
    }

    /// A scan after a cleanup keeps showing the last result, already without what was removed, so the page
    /// doesn't blank out while the caches are measured again.
    var developerStorageState: DeveloperStorageState {
        if !hasFolderAccess { return .needsAccess }
        if !coversDeveloperFolder { return .notCovered }
        return hasScannedDeveloperStorage ? .ready : .measuring
    }

    var footprint: DiskFootprint { devices.reduce(.zero) { $0 + $1.footprint } }
    var totalSizeBytes: Int64 { footprint.allocatedBytes }
    var leftoversFootprint: DiskFootprint { leftovers.reduce(.zero) { $0 + $1.footprint } }

    var canBoot: Bool { capabilities?.canBoot ?? false }
    var canManageDevices: Bool { capabilities?.canManageDevices ?? false }
    var canDeleteDevices: Bool { capabilities?.canDeleteDevices ?? false }

    /// An operation is running on this simulator or on one of its apps.
    func isBusy(_ device: SimulatorDevice) -> Bool { busy[device.id] != nil }
    func busyLabel(for device: SimulatorDevice) -> String? { busy[device.id] }
    var canManageRuntimes: Bool { capabilities?.canManageRuntimes ?? false }
    var deviceHubInstalled: Bool { NSWorkspace.shared.urlForApplication(withBundleIdentifier: SimulatorLauncher.deviceHubBundleID) != nil }

    var runtimesFootprintBytes: Int64 { runtimes.reduce(0) { $0 + $1.sizeBytes } }

    func cleanupSuggestions(idleDays: Int) -> [CleanupSuggestion] {
        let scan = ScanResult(devices: devices, deviceSets: deviceSets, leftovers: leftovers, unreadableLocations: unreadableLocations, unreadableDeviceCount: unreadableDeviceCount)
        return CleanupAdvisor.suggestions(for: scan, idleDays: idleDays, deviceHubInstalled: deviceHubInstalled)
    }

    // MARK: - Loading

    /// Detects what this Mac allows, then measures everything the storage bar shows. Safe to call more
    /// than once.
    func start() {
        guard !hasStarted else { return }
        hasStarted = true
        Task {
            if capabilities == nil {
                capabilities = await Capabilities.detect(runner: runner)
            }
            refresh()
            refreshDeveloperStorage()
            refreshRuntimes()
        }
    }

    /// Measures everything again: simulators, Xcode caches and runtimes.
    func refreshEverything() {
        refresh()
        refreshDeveloperStorage(force: true)
        refreshRuntimes(force: true)
    }

    /// The last simulator scan failed, so there's no list: not the same as no simulators.
    var simulatorScanFailed: Bool { errorMessage != nil }

    /// Something is still being measured, so the storage bar's total is still growing.
    var isMeasuring: Bool {
        isLoading || isScanningDeveloperStorage || isLoadingRuntimes
    }

    func refresh() {
        guard hasFolderAccess else { return }
        let scanURL = devicesURL
        scanGeneration += 1
        let generation = scanGeneration
        isLoading = true
        errorMessage = nil
        scanProgress = nil
        let simctl = capabilities?.simctlTool.map { SimctlClient(tool: $0, runner: runner) }

        Task.detached(priority: .userInitiated) { [weak self] in
            let outcome = Result {
                try SimulatorScanner.loadDevices(at: scanURL) { progress in
                    Task { @MainActor [weak self] in self?.updateScanProgress(progress, generation: generation) }
                }
            }
            var merged = outcome
            if case .success(let result) = outcome, let simctl {
                merged = .success(await Self.mergeLiveState(into: result, using: simctl))
            }
            let volume = VolumeSpace.of(scanURL)
            await self?.finishScan(merged, volume: volume, generation: generation)
        }
    }

    /// Adds what CoreSimulator reports right now: running state and availability. A set simctl can't
    /// list keeps the state from device.plist instead of being treated as empty.
    nonisolated static func mergeLiveState(into result: ScanResult, using simctl: SimctlClient) async -> ScanResult {
        var live: [String: SimctlDevice] = [:]
        var listedSets: Set<String> = []
        for set in result.deviceSets {
            guard let devices = try? await simctl.listDevices(in: set) else { continue }
            listedSets.insert(set.url.path)
            for device in devices { live[device.udid] = device }
        }
        let devices = result.devices.map { device -> SimulatorDevice in
            var device = device
            guard listedSets.contains(device.deviceSet.url.path) else { return device }
            if let listed = live[device.udid] {
                device.liveState = listed.deviceState
                device.isAvailable = listed.isAvailable
                device.availabilityError = listed.availabilityError
                device.isKnownToSimctl = true
            } else {
                device.isKnownToSimctl = false
            }
            return device
        }
        return ScanResult(devices: devices, deviceSets: result.deviceSets, leftovers: result.leftovers, unreadableLocations: result.unreadableLocations, unreadableDeviceCount: result.unreadableDeviceCount)
    }

    private func updateScanProgress(_ progress: ScanProgress, generation: Int) {
        guard scanGeneration == generation else { return }
        scanProgress = progress
    }

    private func finishScan(_ outcome: Result<ScanResult, Error>, volume: VolumeSpace, generation: Int) {
        // A newer refresh or an operation started meanwhile; its result wins.
        guard scanGeneration == generation else { return }
        switch outcome {
        case .success(let result):
            apply(result)
            self.volume = volume
        case .failure(let error):
            // Nothing could be read. Every page says so instead of showing an empty list, which would
            // read as "no simulators" and put a zero in the storage bar.
            devices = []
            leftovers = []
            deviceSets = []
            unreadableLocations = []
            unreadableDeviceCount = 0
            hasCompletedScan = false
            self.volume = volume
            errorMessage = error.localizedDescription
        }
        isLoading = false
        scanProgress = nil
    }

    private func apply(_ result: ScanResult) {
        devices = result.devices
        leftovers = result.leftovers
        deviceSets = result.deviceSets
        unreadableLocations = result.unreadableLocations
        unreadableDeviceCount = result.unreadableDeviceCount
        hasCompletedScan = true
        // Runtimes may have been read before the devices; keep their counts in step with the list.
        runtimes = runtimes.map { runtime in
            var runtime = runtime
            runtime.deviceCount = result.devices.filter { $0.runtimeIdentifier == runtime.runtimeIdentifier }.count
            return runtime
        }
    }

    /// DerivedData, device support files and agent workspaces. Needs ~/Library/Developer.
    ///
    /// `force` starts over even when a scan is running: after a cleanup that scan may have counted what
    /// was just removed, so its result is thrown away.
    func refreshDeveloperStorage(force: Bool = false) {
        guard hasFolderAccess, coversDeveloperFolder else { return }
        let developer = developerFolder
        // A scan is already running and nothing changed since it started; its result is current.
        if isScanningDeveloperStorage && !force { return }
        developerStorageGeneration += 1
        let generation = developerStorageGeneration
        isScanningDeveloperStorage = true
        // Inside the sandbox a missing project only means "can't see it", so don't flag it as gone.
        let checksProjects = !isSandboxed
        Task.detached(priority: .utility) { [weak self] in
            let report = DeveloperStorageScanner.scan(developerFolder: developer, fileExists: checksProjects ? { FileManager.default.fileExists(atPath: $0) } : nil)
            await self?.finishDeveloperStorage(report, generation: generation)
        }
    }

    private func finishDeveloperStorage(_ report: DeveloperStorageReport, generation: Int) {
        // Access changed meanwhile and a newer scan is running.
        guard generation == developerStorageGeneration else { return }
        developerStorage = report
        isScanningDeveloperStorage = false
        hasScannedDeveloperStorage = true
    }

    /// Runtimes from `simctl runtime list` in Pro, or from their asset folders in the App Store edition.
    /// `force` starts over even when a listing is running, as after deleting a runtime.
    func refreshRuntimes(force: Bool = false) {
        if isLoadingRuntimes && !force { return }
        runtimesGeneration += 1
        let generation = runtimesGeneration
        isLoadingRuntimes = true
        runtimesError = nil
        let devices = devices
        let simctl = canManageRuntimes ? capabilities?.simctlTool.map { SimctlClient(tool: $0, runner: runner) } : nil
        Task.detached(priority: .utility) { [weak self] in
            var entries: [RuntimeEntry]?
            var failureMessage: String?
            if let simctl {
                do {
                    entries = RuntimeInventory.entries(from: try await simctl.listRuntimeImages(), devices: devices)
                } catch {
                    // Still show sizes from the asset folders, and say why deleting isn't offered.
                    failureMessage = error.localizedDescription
                    entries = try? RuntimeInventory.entriesFromAssetFolders(devices: devices)
                }
            } else {
                do {
                    entries = try RuntimeInventory.entriesFromAssetFolders(devices: devices)
                } catch {
                    failureMessage = "SimCleaner couldn't read the folder macOS keeps runtimes in: \(error.localizedDescription)"
                }
            }
            let caches = try? RuntimeInventory.dyldCaches()
            await self?.finishRuntimes(entries, caches: caches, error: failureMessage, generation: generation)
        }
    }

    /// `entries` and `caches` are nil when they couldn't be read.
    private func finishRuntimes(_ entries: [RuntimeEntry]?, caches: [DyldCacheEntry]?, error: String?, generation: Int) {
        // A newer listing started meanwhile, after a runtime was deleted; this one may still show it.
        guard generation == runtimesGeneration else { return }
        runtimes = entries ?? []
        canReadRuntimes = entries != nil
        dyldCaches = caches ?? []
        canReadSimulatorCaches = caches != nil
        runtimesError = error
        isLoadingRuntimes = false
        hasLoadedRuntimes = true
    }

    // MARK: - Operations

    /// Installs one build on many simulators. Nil when Xcode's simulator tools aren't available.
    func makeBatchInstaller() -> BatchInstaller? {
        guard let tool = capabilities?.simctlTool else { return nil }
        return BatchInstaller(simctl: SimctlClient(tool: tool, runner: runner), canBoot: canBoot)
    }

    private var controller: DeviceController {
        if let capabilities {
            return DeviceController(capabilities: capabilities, runner: runner, allowedRoot: devicesURL)
        }
        // Still detecting what this Mac allows: nothing may be deleted by files until that's known.
        return DeviceController(simctl: nil, canBoot: false, allowedRoot: devicesURL, coreSimulatorInstalled: true)
    }

    func delete(_ devices: [SimulatorDevice]) async {
        let controller = controller
        let deleted = await perform("Deleting", title: "Some simulators weren't deleted", items: devices, id: \.id, name: \.name, freed: .removing { [$0.rootPath] }) { device in
            try await controller.delete(device)
        }
        // The rescan below confirms it; until then the list and the storage bar don't show what's gone.
        let ids = Set(deleted.map(\.id))
        self.devices.removeAll { ids.contains($0.id) }
    }

    func erase(_ devices: [SimulatorDevice]) async {
        let controller = controller
        await perform("Erasing", title: "Some simulators weren't erased", items: devices, id: \.id, name: \.name, freed: FreedSpace { device in
            guard let before = await Reclaimed.measure(device.rootPath) else { return nil }
            return { erased in await Reclaimed.byErasing(device.rootPath, before: before, erased: erased) }
        }) { device in
            try await controller.erase(device)
        }
    }

    func shutDown(_ devices: [SimulatorDevice]) async {
        let controller = controller
        await perform("Shutting down", title: "Some simulators didn't shut down", items: devices, id: \.id, name: \.name) { device in
            try await controller.shutDown(device)
        }
    }

    func boot(_ device: SimulatorDevice) async {
        let controller = controller
        await perform("Starting", title: "The simulator didn't start", items: [device], id: \.id, name: \.name) { device in
            try await controller.boot(device)
        }
    }

    func duplicate(_ device: SimulatorDevice, name: String) async {
        let controller = controller
        await perform("Duplicating", title: "The simulator wasn't duplicated", items: [device], id: \.id, name: \.name) { device in
            _ = try await controller.duplicate(device, name: name)
        }
    }

    func rename(_ device: SimulatorDevice, to name: String) async {
        let controller = controller
        await perform("Renaming", title: "The simulator wasn't renamed", items: [device], id: \.id, name: \.name) { device in
            try await controller.rename(device, to: name)
        }
    }

    /// Holds the whole simulator, not only the app: removing an app may start and stop the device, so
    /// nothing else may change it meanwhile. An app that's gone counts as freed even when shutting the
    /// simulator down again failed afterwards.
    func uninstall(_ app: SimulatorApp, from device: SimulatorDevice) async {
        let controller = controller
        await perform("Removing", title: "\(app.name) wasn't removed", items: [app], id: \.id, name: \.name, locks: { [device.id, $0.id] }, freed: .removing { [$0.bundlePath] + ($0.dataContainerPath.map { [$0] } ?? []) }) { app in
            try await controller.uninstall(app, from: device)
        }
    }

    func removeLeftovers(_ items: [LeftoverFolder]) async {
        let controller = controller
        let removed = await perform("Removing", title: "Some leftover folders weren't removed", items: items, id: \.id, name: { $0.url.lastPathComponent }, freed: .removing { [$0.url] }) { item in
            try controller.removeLeftover(item)
        }
        let ids = Set(removed.map(\.id))
        leftovers.removeAll { ids.contains($0.id) }
    }

    func remove(_ items: [DeveloperStorageItem]) async {
        let developer = developerFolder
        let removed = await perform("Removing", title: "Some items weren't removed", items: items, id: \.id, name: \.title, freed: .removing { [$0.url] }, rescanDevices: false) { item in
            try DeveloperStorageScanner.remove(item, developerFolder: developer)
        }
        let ids = Set(removed.map(\.id))
        developerStorage = DeveloperStorageReport(items: developerStorage.items.filter { !ids.contains($0.id) }, unreadableLocations: developerStorage.unreadableLocations)
        refreshDeveloperStorage(force: true)
    }

    func deleteRuntime(_ runtime: RuntimeEntry) async {
        guard let imageID = runtime.simctlImageID, let tool = capabilities?.simctlTool, canManageRuntimes else { return }
        let simctl = SimctlClient(tool: tool, runner: runner)
        // CoreSimulator's own list is the proof here, before and after: the image lives where SimCleaner
        // doesn't look. One another window already deleted isn't listed any more and counts nothing.
        let deleted = await perform("Deleting", title: "\(runtime.title) wasn't deleted", items: [runtime], id: \.id, name: \.title, freed: FreedSpace { runtime in
            guard let listed = try? await simctl.listRuntimeImages().first(where: { $0.identifier == imageID }) else { return nil }
            let size = listed.sizeBytes ?? runtime.sizeBytes
            return { deleted in deleted ? size : 0 }
        }) { _ in
            _ = try await simctl.deleteRuntime(imageID, dryRun: false)
            // Xcode 27.0 sometimes reports success and brings the runtime back; check before claiming it's gone.
            if try await simctl.listRuntimeImages().contains(where: { $0.identifier == imageID }) {
                throw DeviceOperationError.simctl("CoreSimulator still lists \(runtime.title). It may be removed after a restart; if it stays, delete it in Xcode › Settings › Components.")
            }
        }
        let ids = Set(deleted.map(\.id))
        runtimes.removeAll { ids.contains($0.id) }
        refreshRuntimes(force: true)
    }

    /// Runs `operation` on each item in turn, marks each row busy while it runs, collects failures
    /// instead of stopping at the first one, then rescans so the list shows what's really left.
    /// An item something else is still working on is refused, never run twice at once: `locks` lists
    /// every key an item holds while it runs (by default its `id`).
    ///
    /// For a cleanup, `freed` measures each item right before it runs, once this window holds it, and then
    /// says how much space it gave back. It's asked even when the operation failed, because files can be
    /// gone by then, but never about an item that wasn't there to begin with. The batch's total goes to the
    /// cleanup session once, and the items that freed something are returned.
    @discardableResult
    private func perform<Item>(
        _ verb: String,
        title: String,
        items: [Item],
        id: KeyPath<Item, String>,
        name: (Item) -> String,
        locks: ((Item) -> [String])? = nil,
        freed: FreedSpace<Item>? = nil,
        rescanDevices: Bool = true,
        operation: (Item) async throws -> Void
    ) async -> [Item] {
        guard !items.isEmpty else { return [] }
        report = nil
        // A simulator scan that started before this would list what's about to change; the rescan below
        // replaces it.
        if rescanDevices { scanGeneration += 1 }
        var failures: [String] = []
        var cleaned: [Item] = []
        var freedBytes: Int64 = 0
        for (index, item) in items.enumerated() {
            let keys = locks?(item) ?? [item[keyPath: id]]
            // Another window has its own list and could start the same work; the claim is app-wide.
            guard !keys.contains(where: { busy[$0] != nil }), Self.claim(keys) else {
                failures.append("\(name(item)): another action on it hasn't finished yet. Try again when it's done.")
                continue
            }
            for key in keys { busy[key] = "\(verb)…" }
            bulkProgress = items.count > 1 ? BulkProgress(title: "\(verb) \(items.count) items", completed: index, total: items.count, current: name(item)) : nil
            let credit = await freed?.prepare(item)
            var succeeded = true
            do {
                try await operation(item)
            } catch {
                succeeded = false
                failures.append("\(name(item)): \(error.localizedDescription)")
            }
            if let credit {
                let bytes = await credit(succeeded)
                if bytes > 0 {
                    freedBytes += bytes
                    cleaned.append(item)
                }
            }
            for key in keys { busy[key] = nil }
            Self.release(keys)
        }
        bulkProgress = nil
        if !failures.isEmpty {
            report = OperationReport(title: title, failures: failures)
        } else if freed != nil {
            EditionHooks.cleanupSucceeded()
        }
        if freed != nil {
            volume = VolumeSpace.of(devicesURL)
            cleanupSession?.add(freedBytes)
        }
        if rescanDevices { refresh() }
        return cleaned
    }

    /// Keys of everything any window is working on.
    private static var claimedKeys: Set<String> = []

    private static func claim(_ keys: [String]) -> Bool {
        guard claimedKeys.isDisjoint(with: keys) else { return false }
        claimedKeys.formUnion(keys)
        return true
    }

    private static func release(_ keys: [String]) {
        claimedKeys.subtract(keys)
    }

    // MARK: - Folder access (App Store edition)

    func chooseDevicesDirectory() {
        let panel = NSOpenPanel()
        panel.title = "Allow access to the Developer folder"
        panel.message = "Choose the Developer folder in your Library. SimCleaner finds simulators, Preview devices, test clones and Xcode caches inside it."
        panel.directoryURL = DeveloperPaths.developerFolder
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Use This Folder"

        guard panel.runModal() == .OK, let url = panel.url, beginAccessing(url: url) else { return }
        Self.saveBookmark(for: url)
        useGrantedFolder(url)
    }

    /// Switches to a folder the person just granted and scans everything it covers right away, so a
    /// page that was waiting for access fills in by itself.
    func useGrantedFolder(_ url: URL) {
        devicesURL = url
        hasFolderAccess = true
        hasScannedDeveloperStorage = false
        developerStorage = .empty
        refresh()
        refreshDeveloperStorage(force: true)
    }

    @discardableResult
    private func beginAccessing(url: URL) -> Bool {
        if url.startAccessingSecurityScopedResource() {
            // Release the previous folder only once the new one is open, so a failed switch keeps working access.
            activeSecurityScopedURL?.stopAccessingSecurityScopedResource()
            activeSecurityScopedURL = url
            hasFolderAccess = true
            return true
        }
        hasFolderAccess = activeSecurityScopedURL != nil
        return false
    }

    nonisolated private static func restoreBookmarkedURL() -> URL? {
        guard let location = bookmarkFileURL, let data = try? Data(contentsOf: location) else { return nil }
        var isStale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &isStale) else { return nil }
        if isStale {
            try? FileManager.default.removeItem(at: location)
            return nil
        }
        return url
    }

    nonisolated private static func saveBookmark(for url: URL) {
        guard let destination = bookmarkFileURL,
              let data = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) else { return }
        try? FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: destination, options: [.atomic])
    }
}
