//
//  ContentView.swift
//  XCode Devices
//
//  Created by Ivan Stepanok on 22.11.2025.
//

import AppKit
import SimCleanerKit
import SwiftUI

enum SidebarSelection: Hashable {
    case all
    case category(DeviceCategory)
    case runtime(String)
    case recentlyUsed
    case running
    case withApps
    case empty
    case suggestions
    case xcodeCaches
    case runtimes

    var isCleanupPage: Bool {
        switch self {
        case .suggestions, .xcodeCaches, .runtimes: return true
        default: return false
        }
    }

    /// How the page is remembered between launches.
    var storageKey: String {
        switch self {
        case .all: return "all"
        case .category(let category): return "category:\(category.rawValue)"
        case .runtime(let name): return "runtime:\(name)"
        case .recentlyUsed: return "recentlyUsed"
        case .running: return "running"
        case .withApps: return "withApps"
        case .empty: return "empty"
        case .suggestions: return "suggestions"
        case .xcodeCaches: return "xcodeCaches"
        case .runtimes: return "runtimes"
        }
    }

    init(storageKey: String) {
        let parts = storageKey.split(separator: ":", maxSplits: 1).map(String.init)
        switch (parts.first ?? "", parts.count > 1 ? parts[1] : "") {
        case ("category", let raw): self = DeviceCategory(rawValue: raw).map(SidebarSelection.category) ?? .all
        case ("runtime", let name) where !name.isEmpty: self = .runtime(name)
        case ("recentlyUsed", _): self = .recentlyUsed
        case ("running", _): self = .running
        case ("withApps", _): self = .withApps
        case ("empty", _): self = .empty
        case ("suggestions", _): self = .suggestions
        case ("xcodeCaches", _): self = .xcodeCaches
        case ("runtimes", _): self = .runtimes
        default: self = .all
        }
    }
}

/// A destructive action waiting for confirmation.
struct PendingDeviceAction: Identifiable {
    enum Kind { case delete, erase }
    let id = UUID()
    let kind: Kind
    let devices: [SimulatorDevice]
}

struct PendingUninstall: Identifiable {
    let id = UUID()
    let app: SimulatorApp
    let device: SimulatorDevice
}

/// Asks for a name before duplicating or renaming.
struct NamePrompt: Identifiable {
    enum Kind { case duplicate, rename }
    let id = UUID()
    let kind: Kind
    let device: SimulatorDevice
}

#if DEBUG
/// Debug builds can measure another folder laid out like ~/Library/Developer, for screenshots with
/// sample projects and for trying changes on throwaway data: SIMCLEANER_DEVELOPER_FOLDER=/path.
private let developerFolder = ProcessInfo.processInfo.environment["SIMCLEANER_DEVELOPER_FOLDER"]
    .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? DeveloperPaths.developerFolder
#else
private let developerFolder = DeveloperPaths.developerFolder
#endif

struct ContentView: View {
    @StateObject private var scanner = DeviceScanner(developerFolder: developerFolder, cleanupSession: .shared)
    @ObservedObject private var session = CleanupSession.shared
    @AppStorage("lastPage") private var lastPage = SidebarSelection.all.storageKey
    @State private var selection: SidebarSelection = .all
    /// The Xcode caches page's category, so the storage bar can open the right one.
    @State private var cachesCategory: DeveloperStorageCategory = .derivedData
    @State private var searchText = ""
    @State private var selectedDeviceIDs: Set<String> = []
    @State private var sortOrder: [KeyPathComparator<SimulatorDevice>] = [KeyPathComparator(\.sizeBytes, order: .reverse)]
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @State private var showPermissionSheet = false
    @State private var batchInstall: BatchInstallTargets?
    @State private var pendingAction: PendingDeviceAction?
    @State private var pendingUninstall: PendingUninstall?
    @State private var namePrompt: NamePrompt?
    @AppStorage("idleDays") private var idleDays = 14

    private let recentThreshold: TimeInterval = 60 * 60 * 24 * 14

    var body: some View {
        // The storage panel below covers the bottom of all three columns: NavigationSplitView doesn't hand the
        // window's bottom inset on to them. Each column keeps its last rows and its buttons clear of it.
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .clearsStoragePanel()
                .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 280)
        } content: {
            contentColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clearsStoragePanel()
                .navigationSplitViewColumnWidth(min: 560, ideal: 760)
        } detail: {
            detailColumn
                .clearsStoragePanel()
                .navigationSplitViewColumnWidth(min: 300, ideal: 320, max: 380)
        }
        .navigationSplitViewStyle(.balanced)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                StoragePanel(scanner: scanner, session: session, onSelect: show) {
                    scanner.chooseDevicesDirectory()
                }
            }
            .background(.background)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                EditionToolbarButton()
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    batchInstall = BatchInstallTargets(devices: selectedDevices)
                } label: {
                    Label("Install App", systemImage: "square.and.arrow.down.on.square")
                }
                .help("Install one build on several simulators")
                .disabled(!scanner.canManageDevices)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    scanner.refreshEverything()
                } label: {
                    if scanner.isMeasuring {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .help("Measure everything again")
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(scanner.isMeasuring)
            }
        }
        .onAppear {
            selection = SidebarSelection(storageKey: lastPage)
            // The sidebar shows what Smart Cleanup can remove before its page is ever opened.
            scanner.smartIdleDays = idleDays
            scanner.start()
            if !scanner.hasFolderAccess { showPermissionSheet = true }
        }
        .onChange(of: selection) { _, page in
            lastPage = page.storageKey
        }
        .onChange(of: idleDays) { _, days in
            scanner.smartIdleDays = days
        }
        .onChange(of: scanner.hasFolderAccess) { _, hasAccess in
            if hasAccess { showPermissionSheet = false }
        }
        .onChange(of: filteredDeviceIDs, initial: false) { _, ids in
            let valid = selectedDeviceIDs.intersection(ids)
            if !valid.isEmpty {
                selectedDeviceIDs = valid
            } else if let first = ids.first {
                selectedDeviceIDs = [first]
            } else {
                selectedDeviceIDs = []
            }
        }
        .confirmationDialog(confirmationTitle, isPresented: isConfirming, titleVisibility: .visible, presenting: pendingAction) { action in
            switch action.kind {
            case .delete:
                Button("Delete", role: .destructive) { run { await scanner.delete(action.devices) } }
            case .erase:
                Button("Erase", role: .destructive) { run { await scanner.erase(action.devices) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: { action in
            Text(confirmationMessage(for: action))
        }
        .confirmationDialog("Remove \(pendingUninstall?.app.name ?? "app")?", isPresented: isConfirmingUninstall, titleVisibility: .visible, presenting: pendingUninstall) { pending in
            Button("Remove", role: .destructive) { run { await scanner.uninstall(pending.app, from: pending.device) } }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            Text(uninstallMessage(for: pending))
        }
        .alert(scanner.report?.title ?? "", isPresented: hasReport, presenting: scanner.report) { _ in
            Button("OK", role: .cancel) {}
        } message: { report in
            Text("The list now shows what's left.\n\n" + report.failures.joined(separator: "\n"))
        }
        .sheet(isPresented: $showPermissionSheet) {
            PermissionRequestSheet {
                showPermissionSheet = false
                scanner.chooseDevicesDirectory()
            } onCancel: {
                showPermissionSheet = false
            }
            .presentationDetents([.fraction(0.6)])
            .interactiveDismissDisabled()
        }
        .sheet(item: $namePrompt) { prompt in
            switch prompt.kind {
            case .duplicate:
                NamePromptSheet(
                    title: "Duplicate \(prompt.device.name)",
                    message: "The copy gets the same apps, data and settings. APFS shares the files, so it takes almost no extra space until either simulator changes them.",
                    confirmTitle: "Duplicate",
                    name: "\(prompt.device.name) copy"
                ) { name in
                    run { await scanner.duplicate(prompt.device, name: name) }
                }
            case .rename:
                NamePromptSheet(title: "Rename simulator", message: "Xcode and Device Hub show the new name right away.", confirmTitle: "Rename", name: prompt.device.name) { name in
                    run { await scanner.rename(prompt.device, to: name) }
                }
            }
        }
        .sheet(item: $batchInstall) { targets in
            BatchInstallSheet(scanner: scanner, initialTargets: targets.devices)
        }
    }

    // MARK: - Columns

    @ViewBuilder
    private var contentColumn: some View {
        switch selection {
        case .suggestions:
            SmartCleanupView(scanner: scanner, idleDays: $idleDays) { action in
                pendingAction = action
            } showDevice: { device in
                selection = .all
                selectedDeviceIDs = [device.id]
            }
        case .xcodeCaches:
            XcodeCachesView(scanner: scanner, category: $cachesCategory)
        case .runtimes:
            RuntimesView(scanner: scanner)
        default:
            SimulatorListView(
                scanner: scanner,
                devices: sortedDevices,
                totalCount: scanner.devices.count,
                searchText: $searchText,
                selection: tableSelection,
                sortOrder: $sortOrder,
                runtimeFilter: runtimeFilterName,
                onSelectAll: { selectedDeviceIDs = Set(filteredDeviceIDs) },
                onRequestAccess: { scanner.chooseDevicesDirectory() }
            )
        }
    }

    @ViewBuilder
    private var detailColumn: some View {
        if selection.isCleanupPage {
            CleanupDetailView(scanner: scanner, page: selection)
        } else if selectedDevices.count > 1 {
            MultiSelectionPanel(
                scanner: scanner,
                devices: selectedDevices,
                onDelete: { pendingAction = PendingDeviceAction(kind: .delete, devices: selectedDevices) },
                onErase: { pendingAction = PendingDeviceAction(kind: .erase, devices: selectedDevices) },
                onShutDown: { run { await scanner.shutDown(selectedDevices.filter { $0.state.isRunning }) } },
                onInstall: { batchInstall = BatchInstallTargets(devices: selectedDevices) }
            )
        } else if let device = selectedDevices.first {
            DeviceDetailView(
                scanner: scanner,
                device: device,
                onDelete: { pendingAction = PendingDeviceAction(kind: .delete, devices: [device]) },
                onErase: { pendingAction = PendingDeviceAction(kind: .erase, devices: [device]) },
                onUninstall: { app in pendingUninstall = PendingUninstall(app: app, device: device) },
                onDuplicate: { namePrompt = NamePrompt(kind: .duplicate, device: device) },
                onRename: { namePrompt = NamePrompt(kind: .rename, device: device) },
                onInstall: { batchInstall = BatchInstallTargets(devices: [device]) }
            )
        } else {
            ContentUnavailableView {
                Label("No simulator selected", systemImage: "iphone")
            } description: {
                Text("Select a simulator to see its apps and what deleting it frees.")
            }
        }
    }

    /// Opens the page that cleans a category of the storage bar.
    private func show(_ category: StorageCategory) {
        switch category {
        case .simulators:
            selection = .all
        case .leftovers:
            selection = .suggestions
        case .runtimes, .simulatorCaches:
            selection = .runtimes
        case .derivedData, .deviceSupport, .agentWorkspaces:
            if let caches = category.developerStorageCategory { cachesCategory = caches }
            selection = .xcodeCaches
        }
    }

    // MARK: - Sidebar

    /// A standard source list: sections, counts as badges, arrow keys and VoiceOver work like in Finder or Mail.
    private var sidebar: some View {
        List(selection: sidebarSelection) {
            Section("Devices") {
                sidebarRow("All devices", systemImage: "square.stack.3d.up", count: scanner.devices.count, for: .all)
                sidebarRow("iPhone", systemImage: "iphone", count: count(for: .category(.iPhone)), for: .category(.iPhone))
                sidebarRow("iPad", systemImage: "ipad", count: count(for: .category(.iPad)), for: .category(.iPad))
                sidebarRow("Apple TV", systemImage: "appletv", count: count(for: .category(.TV)), for: .category(.TV))
                sidebarRow("Apple Watch", systemImage: "applewatch", count: count(for: .category(.Watch)), for: .category(.Watch))
                sidebarRow("Vision Pro", systemImage: "visionpro", count: count(for: .category(.Vision)), for: .category(.Vision))
            }

            Section("OS Versions") {
                if runtimeFilters.isEmpty {
                    Text("No versions found")
                        .foregroundStyle(.secondary)
                        .selectionDisabled()
                } else {
                    ForEach(runtimeFilters, id: \.name) { runtime in
                        sidebarRow(runtime.name, systemImage: platformSymbol(for: runtime.name), count: runtime.count, for: .runtime(runtime.name))
                            .contextMenu {
                                Button("Select All \(runtime.name) Simulators") {
                                    selection = .runtime(runtime.name)
                                    selectedDeviceIDs = Set(scanner.devices.filter { $0.runtimeGroup == runtime.name }.map(\.id))
                                }
                            }
                    }
                }
            }

            Section("Statuses") {
                sidebarRow("Running", systemImage: "play.circle", count: count(for: .running), for: .running)
                sidebarRow("Recently used", systemImage: "clock", count: count(for: .recentlyUsed), for: .recentlyUsed)
                sidebarRow("With apps", systemImage: "app.badge", count: count(for: .withApps), for: .withApps)
                sidebarRow("Empty", systemImage: "tray", count: count(for: .empty), for: .empty)
            }

            Section("Clean Up") {
                sidebarRow("Smart Cleanup", systemImage: "wand.and.sparkles", detail: suggestionsSubtitle, for: .suggestions)
                    .help("What can go without a second thought, and suggestions for the rest")
                sidebarRow("Xcode caches", systemImage: "hammer", detail: xcodeCachesSubtitle, for: .xcodeCaches)
                    .help("DerivedData, device support files and coding agent workspaces")
                sidebarRow("Runtimes", systemImage: "externaldrive", detail: scanner.runtimes.isEmpty ? "" : ByteText.string(scanner.runtimesFootprintBytes), for: .runtimes)
                    .help("The OS images simulators run on")
            }
        }
        .listStyle(.sidebar)
        .onChange(of: selection) { _, page in
            switch page {
            case .xcodeCaches where !scanner.hasScannedDeveloperStorage:
                scanner.refreshDeveloperStorage()
            case .runtimes:
                scanner.refreshRuntimes()
            default:
                break
            }
        }
    }

    /// A page is always selected; clicking empty space in the sidebar doesn't clear it.
    private var sidebarSelection: Binding<SidebarSelection?> {
        Binding(get: { selection }, set: { if let page = $0 { selection = page } })
    }

    /// What Smart Cleanup can remove now; the page says how sharing makes it a range.
    private var suggestionsSubtitle: String {
        let total = scanner.smartPlan?.footprint ?? .zero
        return total.allocatedBytes > 0 ? ByteText.string(total.allocatedBytes) : ""
    }

    private var xcodeCachesSubtitle: String {
        guard scanner.hasScannedDeveloperStorage else { return "" }
        return ByteText.string(scanner.developerStorage.footprint.allocatedBytes)
    }

    private func sidebarRow(_ title: String, systemImage: String, count: Int, for target: SidebarSelection) -> some View {
        Label(title, systemImage: systemImage)
            .badge(count)
            .tag(target)
    }

    private func sidebarRow(_ title: String, systemImage: String, detail: String, for target: SidebarSelection) -> some View {
        Label(title, systemImage: systemImage)
            .badge(detail.isEmpty ? nil : Text(detail).monospacedDigit())
            .tag(target)
    }

    /// "iOS 27.0" → the iPhone symbol, so versions of different platforms read apart at a glance.
    private func platformSymbol(for runtimeName: String) -> String {
        switch runtimeName.split(separator: " ").first.map(String.init) {
        case "watchOS": return "applewatch"
        case "tvOS": return "appletv"
        case "visionOS", "xrOS": return "visionpro"
        default: return "iphone"
        }
    }

    // MARK: - Filtering

    private var filteredDevices: [SimulatorDevice] {
        let words = searchText.lowercased().split(whereSeparator: \.isWhitespace)
        return scanner.devices.filter { device in
            guard passes(device, selection) else { return false }
            guard !words.isEmpty else { return true }
            let haystack = ([device.name, device.deviceType, device.runtime, device.udid, device.setKind.badge ?? ""] + device.apps.map(\.name))
                .joined(separator: " ")
                .lowercased()
            return words.allSatisfy { haystack.contains($0) }
        }
    }

    private var sortedDevices: [SimulatorDevice] { filteredDevices.sorted(using: sortOrder) }
    private var filteredDeviceIDs: [String] { sortedDevices.map(\.id) }

    private var selectedDevices: [SimulatorDevice] {
        guard !selectedDeviceIDs.isEmpty else { return [] }
        return sortedDevices.filter { selectedDeviceIDs.contains($0.id) }
    }

    private var tableSelection: Binding<Set<String>> {
        Binding(
            get: { selectedDeviceIDs.intersection(filteredDeviceIDs) },
            set: { selectedDeviceIDs = $0.intersection(filteredDeviceIDs) }
        )
    }

    private var runtimeFilterName: String? {
        if case .runtime(let name) = selection { return name }
        return nil
    }

    private var runtimeFilters: [(name: String, count: Int)] {
        Dictionary(grouping: scanner.devices, by: \.runtimeGroup)
            .filter { !$0.key.isEmpty }
            .map { (name: $0.key, count: $0.value.count) }
            .sorted { RuntimeSortKey($0.name) > RuntimeSortKey($1.name) }
    }

    private func passes(_ device: SimulatorDevice, _ filter: SidebarSelection) -> Bool {
        switch filter {
        case .all, .suggestions, .xcodeCaches, .runtimes:
            return true
        case .category(let category):
            return device.category == category
        case .runtime(let runtime):
            return device.runtimeGroup == runtime || device.runtime == runtime
        case .recentlyUsed:
            guard let last = device.lastUsed else { return false }
            return Date().timeIntervalSince(last) <= recentThreshold
        case .running:
            return device.state.isRunning
        case .withApps:
            return device.appCount > 0
        case .empty:
            return device.appCount == 0
        }
    }

    private func count(for filter: SidebarSelection) -> Int {
        scanner.devices.filter { passes($0, filter) }.count
    }

    // MARK: - Confirmations

    private var isConfirming: Binding<Bool> {
        Binding(get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } })
    }

    private var isConfirmingUninstall: Binding<Bool> {
        Binding(get: { pendingUninstall != nil }, set: { if !$0 { pendingUninstall = nil } })
    }

    private var hasReport: Binding<Bool> {
        Binding(get: { scanner.report != nil }, set: { if !$0 { scanner.report = nil } })
    }

    private var confirmationTitle: String {
        guard let action = pendingAction else { return "" }
        let noun = action.devices.count == 1 ? "\u{201C}\(action.devices[0].name)\u{201D}" : "\(action.devices.count) simulators"
        switch action.kind {
        case .delete: return "Delete \(noun)?"
        case .erase: return "Erase \(noun)?"
        }
    }

    private func confirmationMessage(for action: PendingDeviceAction) -> String {
        let footprint = action.devices.reduce(DiskFootprint.zero) { $0 + $1.footprint }
        let running = action.devices.filter { $0.state.isRunning }.count
        var lines: [String] = []
        switch action.kind {
        case .delete:
            lines.append("Frees \(ByteText.freed(footprint)). Xcode and Device Hub stop listing \(action.devices.count == 1 ? "it" : "them").")
        case .erase:
            lines.append("Removes apps, data and settings and frees about \(ByteText.freed(footprint)). The \(action.devices.count == 1 ? "simulator stays" : "simulators stay") in Xcode and Device Hub, as fresh as when created.")
        }
        if running > 0 {
            if scanner.canManageDevices {
                lines.append("\(running) \(running == 1 ? "is" : "are") running and will be shut down first.")
            } else {
                lines.append("\(running) \(running == 1 ? "is" : "are") running. Shut \(running == 1 ? "it" : "them") down first; SimCleaner won't delete a running simulator's files.")
            }
        }
        return lines.joined(separator: "\n\n")
    }

    private func uninstallMessage(for pending: PendingUninstall) -> String {
        var text = "Removes the app and its data from \(pending.device.name). Frees about \(ByteText.freed(pending.app.footprint))."
        if !pending.device.isBooted {
            text += " SimCleaner starts the simulator for this and shuts it down afterwards."
        }
        return text
    }

    private func run(_ work: @escaping @MainActor () async -> Void) {
        Task { await work() }
    }
}

/// Identifies one batch install sheet, possibly with no preselected simulators.
struct BatchInstallTargets: Identifiable {
    let id = UUID()
    let devices: [SimulatorDevice]
}

/// Asks the App Store edition's one-time permission for ~/Library/Developer.
struct PermissionRequestSheet: View {
    let onChoose: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Image("iPhone-folder")
                .resizable()
                .scaledToFit()
                .frame(width: 120, height: 120)
                .padding(.top, 8)
            VStack(spacing: 6) {
                Text("Allow access to your Developer folder")
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text("Xcode stores simulators, build caches and device support files inside ~/Library/Developer. Give SimCleaner access to that folder and it will find all of them. It only deletes what you choose.")
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 420)
            }
            Spacer()
            HStack(spacing: 12) {
                Button("Cancel", action: onCancel)
                    .buttonStyle(.bordered)
                Button("Select Folder", action: onChoose)
                    .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(28)
        .background(Color(.windowBackgroundColor))
    }
}
