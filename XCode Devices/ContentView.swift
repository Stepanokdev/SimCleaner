//
//  ContentView.swift
//  XCode Devices
//
//  Created by Ivan Stepanok on 22.11.2025.
//

import AppKit
import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = DeviceScanner()
    @StateObject private var ratingManager = RatingManager()
    @State private var sortOrder: [KeyPathComparator<SimulatorDevice>] = [KeyPathComparator(\.sizeBytes, order: .reverse)]
    @State private var searchText: String = ""
    @State private var selectedFilter: SidebarSelection = .all
    @State private var selectedDeviceIDs: Set<String> = []
    @State private var devicePendingDeletion: SimulatorDevice?
    @State private var selectionPendingDeletion: [SimulatorDevice]?
    @State private var showDeleteConfirmation: Bool = false
    @State private var showBulkDeleteConfirmation: Bool = false
    @State private var deletionInProgress: Set<String> = []
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @FocusState private var isSearchFocused: Bool
    @State private var showPermissionSheet: Bool = false
    @State private var showSupportSheet: Bool = false
    @State private var showRuntimeSheet: Bool = false

    private let sizeColumnWidth: CGFloat = 90
    private let lastUsedColumnWidth: CGFloat = 150
    private let appsColumnWidth: CGFloat = 140

    private let recentThreshold: TimeInterval = 60 * 60 * 24 * 14

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            sidebar
                .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 280)
        } content: {
            simulatorList
                .frame(maxWidth: .infinity, maxHeight: .infinity)
//                .background(Color(nsColor: .controlBackgroundColor))
        } detail: {
            detailPanel
                .navigationSplitViewColumnWidth(min: 280, ideal: 280, max: 420)
        }
        .navigationSplitViewStyle(.balanced)
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 0) {
                Divider()
                storagePanel
            }
            .background(.background)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showSupportSheet = true
                } label: {
                    HStack {
                        Image(systemName: "heart")
                        Text("Support Author")
                    }
                    .padding(.horizontal)
                }
                .help("Support Author")
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    viewModel.refresh()
                } label: {
                    if viewModel.isLoading {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .help("Refresh simulators")
                .keyboardShortcut("r", modifiers: [.command])
                .disabled(viewModel.isLoading)
            }
        }
//        .background(Color(nsColor: .controlBackgroundColor))
        .onAppear {
            isSearchFocused = false
            if !viewModel.hasFolderAccess {
                showPermissionSheet = true
            }
            if viewModel.devices.isEmpty {
                viewModel.refresh()
            }
        }
        .onChange(of: viewModel.hasFolderAccess) { _, hasAccess in
            if hasAccess {
                showPermissionSheet = false
            }
        }
        .onChange(of: filteredDeviceIDs, initial: false) { _, ids in
            let validSelection = selectedDeviceIDs.intersection(ids)
            if !validSelection.isEmpty {
                selectedDeviceIDs = validSelection
            } else if let first = ids.first {
                selectedDeviceIDs = [first]
            } else {
                selectedDeviceIDs = []
            }
        }
        .alert(
            "Delete simulator?",
            isPresented: $showDeleteConfirmation,
            presenting: devicePendingDeletion
        ) { device in
            Button("Delete", role: .destructive) {
                deletionInProgress.insert(device.udid)
                Task {
                    await viewModel.delete(devices: [device])
                    deletionInProgress.remove(device.udid)
                    devicePendingDeletion = nil
                    if viewModel.errorMessage == nil && viewModel.deletionError == nil {
                        ratingManager.recordSuccessfulDeletion()
                    }
                }
            }
            Button("Cancel", role: .cancel) {
                devicePendingDeletion = nil
            }
        } message: { device in
            let runningNote = device.isBooted ? "\n\nThis simulator is running. Shut it down in Simulator before deleting it." : ""
            Text("\(device.name)\n\(device.runtime)\nUDID: \(device.udid)\(runningNote)")
        }
        .alert(
            "Delete selected simulators?",
            isPresented: $showBulkDeleteConfirmation,
            presenting: selectionPendingDeletion
        ) { selection in
            Button("Delete", role: .destructive) {
                let ids = Set(selection.map(\.udid))
                deletionInProgress.formUnion(ids)
                Task {
                    await viewModel.delete(devices: selection)
                    deletionInProgress.subtract(ids)
                    selectionPendingDeletion = nil
                    if viewModel.errorMessage == nil && viewModel.deletionError == nil {
                        ratingManager.recordSuccessfulDeletion()
                    }
                }
            }
            Button("Cancel", role: .cancel) {
                selectionPendingDeletion = nil
            }
        } message: { selection in
            let totalSize = selection.reduce(0) { $0 + $1.sizeBytes }
            let runningCount = selection.filter(\.isBooted).count
            let runningNote = runningCount > 0 ? "\n\n\(runningCount) of them \(runningCount == 1 ? "is" : "are") running. Shut \(runningCount == 1 ? "it" : "them") down in Simulator first." : ""
            Text("\(selection.count) simulators • \(ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file))\(runningNote)")
        }
        .alert(
            "Some simulators weren't deleted",
            isPresented: Binding(
                get: { viewModel.deletionError != nil },
                set: { if !$0 { viewModel.deletionError = nil } }
            ),
            presenting: viewModel.deletionError
        ) { _ in
            Button("OK", role: .cancel) {}
        } message: { message in
            Text("The list now shows what's left on disk.\n\n\(message)")
        }
        .sheet(isPresented: $showPermissionSheet) {
            permissionRequestSheet
                .presentationDetents([.fraction(0.6)])
                .interactiveDismissDisabled()
        }
        .sheet(isPresented: $showSupportSheet) {
            SupportAuthorView()
        }
        .sheet(isPresented: $showRuntimeSheet) {
            RuntimeStorageSheet(runtimeStorageBytes: viewModel.runtimeStorageBytes)
        }
        .overlay {
            if let progress = viewModel.deletionProgress {
                deletionProgressOverlay(progress: progress)
            }
        }
    }

    private var sidebar: some View {
        ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    sidebarSection(title: "Devices") {
                        sidebarRow(
                            title: "All devices",
                            subtitle: "\(viewModel.devices.count)",
                        systemImage: "tray.full",
                        isSelected: selectedFilter == .all
                    ) { selectedFilter = .all }
                    
                    sidebarRow(
                        title: "iPhone",
                        subtitle: "\(count(for: .category(.iPhone)))",
                        systemImage: "iphone",
                        isSelected: selectedFilter == .category(.iPhone)
                    ) { selectedFilter = .category(.iPhone) }
                    
                    sidebarRow(
                        title: "iPad",
                        subtitle: "\(count(for: .category(.iPad)))",
                        systemImage: "ipad",
                        isSelected: selectedFilter == .category(.iPad)
                    ) { selectedFilter = .category(.iPad) }
                    
                    sidebarRow(
                        title: "tvOS",
                        subtitle: "\(count(for: .category(.TV)))",
                        systemImage: "appletv",
                        isSelected: selectedFilter == .category(.TV)
                    ) { selectedFilter = .category(.TV) }
                    
                    sidebarRow(
                        title: "watchOS",
                        subtitle: "\(count(for: .category(.Watch)))",
                        systemImage: "applewatch",
                        isSelected: selectedFilter == .category(.Watch)
                    ) { selectedFilter = .category(.Watch) }
                    
                    sidebarRow(
                        title: "visionOS",
                        subtitle: "\(count(for: .category(.Vision)))",
                        systemImage: "visionpro",
                        isSelected: selectedFilter == .category(.Vision)
                    ) { selectedFilter = .category(.Vision) }
                }
                
                sidebarSection(title: "iOS Versions") {
                    if runtimeFilters.isEmpty {
                        Text("No versions found.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10)
                    } else {
                        ForEach(runtimeFilters) { runtime in
                            sidebarRow(
                                title: runtime.runtime,
                                subtitle: "\(runtime.count)",
                                systemImage: "chevron.right.circle",
                                isSelected: selectedFilter == .runtime(runtime.runtime)
                            ) { selectedFilter = .runtime(runtime.runtime) }
                        }
                    }
                }
                
                sidebarSection(title: "Statuses") {
                    sidebarRow(
                        title: "Recently used",
                        subtitle: "\(count(for: .recentlyUsed))",
                        systemImage: "clock.badge.checkmark",
                        isSelected: selectedFilter == .recentlyUsed
                    ) { selectedFilter = .recentlyUsed }
                    
                    sidebarRow(
                        title: "With apps",
                        subtitle: "\(count(for: .withApps))",
                        systemImage: "square.stack.3d.up.fill",
                        isSelected: selectedFilter == .withApps
                    ) { selectedFilter = .withApps }
                    
                    sidebarRow(
                        title: "Empty",
                        subtitle: "\(count(for: .empty))",
                        systemImage: "tray",
                        isSelected: selectedFilter == .empty
                    ) { selectedFilter = .empty }
                }
                Spacer(minLength: 160)
            }
            .padding(16)
            .frame(width: 240, alignment: .topLeading)
            .frame(maxHeight: .infinity, alignment: .topLeading)
//            .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    private func sidebarSection<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.caption)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 6, content: content)
        }
    }

    private func sidebarRow(title: String, subtitle: String, systemImage: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.12) : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }

    private var simulatorList: some View {
        VStack(spacing: 0) {
            listHeader
            if viewModel.scanProgress != nil {
                loadingProgressBar
            }
            Divider()

            Group {
                switch listState {
                case .needsAccess:
                    accessPlaceholder
                case .error(let errorMessage):
                    VStack(spacing: 8) {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Text("SimCleaner needs read and write access to your Developer folder.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        VStack(spacing: 6) {
                            Button("Choose Developer Folder…") {
                                viewModel.chooseDevicesDirectory()
                            }
                            .buttonStyle(.borderedProminent)
                            Text(viewModel.devicesURL.path)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                case .loading:
                    EmptyView()
                case .runtimeFolder, .unreadableFolders, .noDeviceFolders, .noSimulators:
                    noSimulatorsPlaceholder(listState)
                case .noMatches:
                    ContentUnavailableView {
                        Label("No matching simulators", systemImage: "line.3.horizontal.decrease.circle")
                    } description: {
                        Text("Try another filter or clear the search.")
                    }
                case .list:
                    Table(sortedDevices, selection: tableSelection, sortOrder: $sortOrder) {
                        TableColumn("Type", value: \.deviceType) { device in
                            HStack(spacing: 12) {
                                DeviceIconView(device: device, size: 32, weight: .medium)
                                    .frame(width: 56, height: 56)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(device.name)
                                        .font(.headline)
                                        .lineLimit(1)
                                    HStack(spacing: 6) {
                                        Text(device.runtime)
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                        if let badge = device.setKind.badge {
                                            Tag(text: badge)
                                        }
                                    }
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        TableColumn("Size", value: \.sizeBytes) { device in
                            Text(device.sizeDescription)
                                .font(.callout.weight(.semibold))
                                .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        .width(sizeColumnWidth)
                        TableColumn("Last used", value: \.lastUsedSortKey) { device in
                            Text(device.lastUsedDescription)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .width(lastUsedColumnWidth)
                        TableColumn("Apps", value: \.appCount) { device in
                            let appIcons = Array(device.apps.prefix(4))
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    ForEach(appIcons) { app in
                                        AppIconView(app: app)
                                            .frame(width: 22, height: 22)
                                            .cornerRadius(6)
                                    }
                                }
                                if device.appCount > appIcons.count {
                                    Text("and \(device.appCount - appIcons.count) more")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .width(appsColumnWidth)
                    }
                    .safeAreaPadding(EdgeInsets(top: 0, leading: 0, bottom: 100, trailing: 0))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .tableStyle(.inset(alternatesRowBackgrounds: true))
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var listHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Simulators")
                        .font(.headline)
                    Text("\(filteredDevices.count) of \(viewModel.devices.count) • \(formatBytes(viewModel.totalSizeBytes)) total")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                TextField("Search by name, OS, or UDID", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                    .focused($isSearchFocused)
            }

            if viewModel.hasFolderAccess {
                scanLocationRow
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var scanLocationRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Group {
                    Image(systemName: "folder")
                    Text(displayPath(viewModel.devicesURL))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(viewModel.devicesURL.path)
                }
                .foregroundStyle(.secondary)
                Button("Change…") {
                    viewModel.chooseDevicesDirectory()
                }
                .buttonStyle(.link)
                .disabled(viewModel.isLoading)
            }
            .font(.caption)

            if viewModel.hasCompletedScan && !viewModel.coversDeveloperFolder && !viewModel.devices.isEmpty {
                HStack(spacing: 6) {
                    Group {
                        Image(systemName: "info.circle")
                        Text("Xcode also keeps Preview devices and test clones elsewhere in ~/Library/Developer.")
                    }
                    .foregroundStyle(.secondary)
                    Button("Include them…") {
                        viewModel.chooseDevicesDirectory()
                    }
                    .buttonStyle(.link)
                    .disabled(viewModel.isLoading)
                }
                .font(.caption)
            }

            if viewModel.isScanPartial && !viewModel.devices.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("\(unreadableSummary) Some simulators may be missing.")
                        .foregroundStyle(.secondary)
                    Button("Choose Folder Again…") {
                        viewModel.chooseDevicesDirectory()
                    }
                    .buttonStyle(.link)
                    .disabled(viewModel.isLoading)
                }
                .font(.caption)
            }

            if viewModel.unrecognizedSizeBytes > 0 {
                Text("\(viewModel.unrecognizedFolderCount) leftover \(viewModel.unrecognizedFolderCount == 1 ? "folder" : "folders") without simulator info (\(formatBytes(viewModel.unrecognizedSizeBytes))) \(viewModel.unrecognizedFolderCount == 1 ? "isn't" : "aren't") listed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var listState: SimulatorListState {
        SimulatorListState.resolve(
            hasFolderAccess: viewModel.hasFolderAccess,
            scannedURL: viewModel.devicesURL,
            errorMessage: viewModel.errorMessage,
            isLoading: viewModel.isLoading,
            hasCompletedScan: viewModel.hasCompletedScan,
            deviceCount: viewModel.devices.count,
            filteredCount: filteredDevices.count,
            deviceSetCount: viewModel.deviceSets.count,
            isScanPartial: viewModel.isScanPartial
        )
    }

    @ViewBuilder
    private func noSimulatorsPlaceholder(_ state: SimulatorListState) -> some View {
        ContentUnavailableView {
            switch state {
            case .runtimeFolder:
                Label("This folder holds simulator runtimes", systemImage: "externaldrive")
            case .unreadableFolders:
                Label("Some simulator folders couldn't be read", systemImage: "exclamationmark.triangle")
            case .noDeviceFolders:
                Label("No simulators in this folder", systemImage: "folder.badge.questionmark")
            default:
                Label("No simulators found", systemImage: "archivebox")
            }
        } description: {
            switch state {
            case .runtimeFolder:
                Text("Runtimes are the iOS system images that simulators run on. Xcode manages them, and SimCleaner can't delete them. To find your simulators, choose the Developer folder in your Library.")
            case .unreadableFolders:
                Text("\(unreadableSummary) Your simulators may be there. Choose ~/Library/Developer again to give SimCleaner access.")
            case .noDeviceFolders:
                Text("Xcode keeps simulators in the Developer folder inside your Library (~/Library/Developer). Choose that folder and SimCleaner will find all of them.")
            default:
                Text("Xcode hasn't created any simulators here. If you're looking for gigabytes of simulator data, it's probably in runtimes, which Xcode manages.")
            }
        } actions: {
            if state != .noSimulators {
                Button("Choose Developer Folder…") {
                    viewModel.chooseDevicesDirectory()
                }
                .buttonStyle(.borderedProminent)
            }
            Button("About Runtimes") {
                showRuntimeSheet = true
            }
        }
    }

    /// "Couldn't open XCTestDevices." / "Couldn't read 2 simulators." for the partial-scan notices.
    private var unreadableSummary: String {
        var parts: [String] = []
        let locations = viewModel.unreadableLocations
        if let first = locations.first {
            let name = first.lastPathComponent
            parts.append(locations.count == 1 ? "Couldn't open \(name)." : "Couldn't open \(name) and \(locations.count - 1) more \(locations.count == 2 ? "folder" : "folders").")
        }
        let devices = viewModel.unreadableDeviceCount
        if devices > 0 {
            parts.append("Couldn't read \(devices) \(devices == 1 ? "simulator" : "simulators").")
        }
        return parts.joined(separator: " ")
    }

    /// Shows the path with ~ for the real home folder (the sandbox would otherwise abbreviate the container path).
    private func displayPath(_ url: URL) -> String {
        let home = DeviceScanner.realHomeDirectory.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }

    @ViewBuilder
    private var loadingProgressBar: some View {
        if let progress = viewModel.scanProgress {
            HStack(spacing: 12) {
                ProgressView(value: Double(progress.completed), total: Double(max(progress.total, 1))) {
                    Text("Scanning simulators...")
                } currentValueLabel: {
                    Text(progress.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .progressViewStyle(.linear)
//                .frame(maxWidth: 420)
//                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
    }

//    @ViewBuilder
//    private var loadingPlaceholder: some View {
//        VStack(spacing: 12) {
//            ProgressView()
////            Text("Scanning simulators...")
////                .foregroundStyle(.secondary)
//        }
//        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
//    }

    private var detailPanel: some View {
        ScrollView {
            VStack(alignment: .center, spacing: 16) {
                if selectedDevices.count > 1 {
                    multiSelectionPanel
                } else if let device = primarySelectedDevice {
                    ZStack {
                        
                        LinearGradient(
                            colors: [DeviceIcon.for(category: device.category).background.opacity(0.2), .clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(minWidth: 0, maxWidth: .infinity, alignment: .top)
                        .padding(-28)
                        
                        VStack(spacing: 14) {
                            DeviceIconView(device: device, size: 128, weight: .ultraLight)
                                .frame(width: 90, height: 120)
                                .padding(.top, 24)
                            VStack(spacing: 4) {
                                Text(device.name)
                                    .font(.title3.bold())
                                Text(device.runtime)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Text(device.deviceType)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                if device.setKind.badge != nil || device.isBooted {
                                    HStack(spacing: 6) {
                                        if let badge = device.setKind.badge {
                                            Tag(text: badge)
                                        }
                                        if device.isBooted {
                                            Tag(text: "Running")
                                        }
                                    }
                                    .padding(.top, 4)
                                }
                            }
                        }
                    }
                    
                    VStack(spacing: 10) {
                        PrimaryActionButton(title: "Launch simulator", systemImage: "play.fill") {
                            runSimulator(device)
                        }
                        
                        SecondaryActionButton(title: "Reveal container", systemImage: "folder") {
                            revealFolder(device.rootPath)
                        }
                        
                        DestructiveActionButton(
                            title: deletionInProgress.contains(device.udid) ? "Deleting..." : "Delete",
                            systemImage: "trash",
                            isDisabled: deletionInProgress.contains(device.udid) || viewModel.isLoading
                        ) {
                            devicePendingDeletion = device
                            showDeleteConfirmation = true
                        }
                    }
                    .padding(.top, 4)
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Storage usage")
                            .font(.headline)
                        ProgressView(value: Double(device.sizeBytes), total: Double(max(viewModel.totalSizeBytes, 1)))
                            .tint(.blue)
                        HStack {
                            Text("\(device.sizeDescription) used")
                                .fontWeight(.bold)
                            Spacer()
                            let free = max(viewModel.totalSizeBytes - device.sizeBytes, 0)
                            Text("\(formatBytes(free)) used by other simulators")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 10)
                    
                    VStack(alignment: .leading, spacing: 10) {
                        if !device.apps.isEmpty {
                            Text("Installed apps")
                                .font(.headline)
                        }
                        if device.apps.isEmpty {
                            Text("No apps in this simulator.")
                                .foregroundStyle(.secondary)
                                .font(.callout)
                                .padding(.top, 64)
                        } else {
                            ForEach(device.apps.sorted { $0.sizeBytes > $1.sizeBytes }) { app in
                                HStack(spacing: 10) {
                                    AppIconView(app: app)
                                        .frame(width: 26, height: 26)
                                        .cornerRadius(6)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(app.name)
                                            .font(.subheadline)
                                        Text(app.sizeDescription)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                                .padding(.vertical, 6)
                                .padding(.horizontal, 10)
                                .background(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .fill(Color.gray.opacity(0.06))
                                )
                            }
                            Spacer(minLength: 160)
                        }
                        
                    }
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Select a simulator")
                            .font(.headline)
                        Text("Click a device or storage segment below to see details.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            }
            .padding(20)
//            .frame(width: 360, alignment: .top)
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private var multiSelectionPanel: some View {
        let selection = selectedDevices
        let namesPreview = Array(selection.prefix(6))
        let remainingCount = max(selection.count - namesPreview.count, 0)

        return VStack(spacing: 14) {
            VStack(spacing: 6) {
                Text("Selected simulators")
                    .font(.title3.weight(.semibold))
                Text("\(selection.count) selected • \(selectedDevicesSizeDescription) total")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 10) {
//                HStack {
//                    Label("\(selection.count) items", systemImage: "rectangle.3.group")
//                        .font(.subheadline)
//                    Spacer()
//                    Label(selectedDevicesSizeDescription, systemImage: "internaldrive")
//                        .font(.subheadline)
//                }
//                .foregroundStyle(.secondary)

                if !namesPreview.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Included")
                            .font(.subheadline.weight(.semibold))
                        ForEach(namesPreview) { device in
                            HStack(spacing: 10) {
                                DeviceIconView(device: device, size: 18, weight: .regular)
                                    .frame(width: 22, height: 22)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(device.name)
                                        .font(.callout)
                                        .lineLimit(1)
                                    Text(device.runtime)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Text(device.sizeDescription)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        if remainingCount > 0 {
                            Text("+ \(remainingCount) more")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.gray.opacity(0.06))
                    )
                }

                if viewModel.totalSizeBytes > 0 {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Storage usage")
                            .font(.subheadline.weight(.semibold))
                        ProgressView(
                            value: Double(selectedDevicesTotalSize),
                            total: Double(max(viewModel.totalSizeBytes, 1))
                        )
                        .tint(.blue)

                        HStack {
                            Text("\(selectedDevicesSizeDescription) selected")
                            Spacer()
                            let remaining = max(viewModel.totalSizeBytes - selectedDevicesTotalSize, 0)
                            Text("\(formatBytes(remaining)) used by other simulators")
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        if viewModel.diskTotalBytes > 0 {
                            Text("\(percentDescription(value: selectedDevicesTotalSize, of: viewModel.diskTotalBytes)) of disk space")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            DestructiveActionButton(
                title: deletionInProgress.isEmpty ? "Delete selected simulators" : "Deleting...",
                systemImage: "trash",
                isDisabled: selection.isEmpty || !deletionInProgress.isEmpty || viewModel.isLoading
            ) {
                selectionPendingDeletion = selection
                showBulkDeleteConfirmation = true
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var storagePanel: some View {
        let nonEmptySegments = storageSegments.filter { !$0.isEmpty }
        let emptySegments = storageSegments.filter { $0.isEmpty }
        let emptyShareOfDisk = emptySegments.reduce(0) { $0 + $1.shareOfDisk }

        let legendItems: [LegendItem] = {
            var items: [LegendItem] = nonEmptySegments.enumerated().map { index, segment in
                LegendItem(id: segment.id, name: segment.name, color: StorageBar.color(forIndex: index))
            }
            if emptyShareOfDisk > 0, let largestEmpty = emptySegments.max(by: { $0.sizeBytes < $1.sizeBytes }) {
                items.append(LegendItem(id: largestEmpty.id, name: "Empty simulators", color: Color(nsColor: .systemGray)))
            }
            return items
        }()

        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                Text("Simulator storage")
                    .font(.headline)
                Spacer()
                Text(storageSummary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button {
                    showRuntimeSheet = true
                } label: {
                    if let runtimeBytes = viewModel.runtimeStorageBytes {
                        Label("Runtimes: \(formatBytes(runtimeBytes))", systemImage: "info.circle")
                    } else {
                        Label("About runtimes", systemImage: "info.circle")
                    }
                }
                .buttonStyle(.link)
                .font(.callout)
                .help("Simulator runtimes are managed by Xcode and aren't counted here")
            }

            StorageBar(
                segments: storageSegments,
                freeShare: freeDiskShare
            ) { id in
                withAnimation {
                    selectedFilter = .all
                    selectedDeviceIDs = [id]
                }
            }
            .frame(height: 32)
            .padding(.trailing, 12)

            if !legendItems.isEmpty {
                Legend(items: legendItems)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
//        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var accessPlaceholder: some View {
        VStack(spacing: 14) {
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(.secondary)
            Text("SimCleaner needs access to your Developer folder.")
                .font(.headline)
            Text("Choose ~/Library/Developer. That's where Xcode keeps simulators, Preview devices and test clones.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            Button("Allow access") {
                showPermissionSheet = true
            }
            .buttonStyle(.borderedProminent)
            Text(displayPath(DeviceScanner.developerFolderURL))
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private var permissionRequestSheet: some View {
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
                Text("Xcode stores simulators in several places inside ~/Library/Developer. Give SimCleaner access to that folder and it will find all of them. It only deletes the simulators you choose.")
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 420)
            }
            Spacer()
            HStack(spacing: 12) {
                Button("Cancel") {
                    showPermissionSheet = false
                }
                .buttonStyle(.bordered)
                Button("Select Folder") {
                    showPermissionSheet = false
                    viewModel.chooseDevicesDirectory()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(28)
        .background(Color(.windowBackgroundColor))
    }

    @ViewBuilder
    private func deletionProgressOverlay(progress: DeletionProgress) -> some View {
        ZStack {
            Color.black.opacity(0.4)
                .ignoresSafeArea()

            VStack(spacing: 20) {
                Image(systemName: "trash")
                    .font(.system(size: 36, weight: .medium))
                    .foregroundStyle(.red)
                    .padding(.bottom, 4)

                VStack(spacing: 8) {
                    Text("Deleting simulators...")
                        .font(.title3.weight(.semibold))

                    Text(progress.label)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                VStack(spacing: 8) {
                    ProgressView(value: Double(progress.completed), total: Double(max(progress.total, 1)))
                        .progressViewStyle(.linear)
                        .frame(width: 280)

                    if !progress.currentDeviceName.isEmpty {
                        Text(progress.currentDeviceName)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Text("Freeing \(progress.sizeDescription)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(32)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.regularMaterial)
                    .shadow(color: .black.opacity(0.2), radius: 20, y: 10)
            )
        }
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.2), value: viewModel.deletionProgress != nil)
    }

    private var filteredDevices: [SimulatorDevice] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let devices = viewModel.devices.filter { device in
            guard passesFilter(device) else { return false }
            guard !trimmed.isEmpty else { return true }
            let haystack = "\(device.name) \(device.deviceType) \(device.runtime) \(device.udid) \(device.setKind.badge ?? "")".lowercased()
            return haystack.contains(trimmed.lowercased())
        }

        return devices
    }

    private var sortedDevices: [SimulatorDevice] {
        filteredDevices.sorted(using: sortOrder)
    }

    private var filteredDeviceIDs: [String] {
        sortedDevices.map(\.id)
    }

    private var selectedDevices: [SimulatorDevice] {
        guard !selectedDeviceIDs.isEmpty else { return [] }
        let selectionSet = selectedDeviceIDs
        return sortedDevices.filter { selectionSet.contains($0.id) }
    }

    private var primarySelectedDevice: SimulatorDevice? {
        if selectedDevices.count == 1 {
            return selectedDevices.first
        }
        return nil
    }

    private var selectedDevicesTotalSize: Int64 {
        selectedDevices.reduce(0) { $0 + $1.sizeBytes }
    }

    private var selectedDevicesSizeDescription: String {
        ByteCountFormatter.string(fromByteCount: selectedDevicesTotalSize, countStyle: .file)
    }

    private var tableSelection: Binding<Set<String>> {
        Binding(
            get: { selectedDeviceIDs.intersection(filteredDeviceIDs) },
            set: { newValue in
                selectedDeviceIDs = newValue.intersection(filteredDeviceIDs)
            }
        )
    }

    private var runtimeFilters: [RuntimeEntry] {
        let grouped = Dictionary(grouping: viewModel.devices.filter { $0.runtimeGroup.lowercased().contains("ios") }, by: { $0.runtimeGroup })
        return grouped.map { runtime, devices in
            RuntimeEntry(runtime: runtime, count: devices.count, sortKey: RuntimeSection.sortKey(from: runtime))
        }
        .sorted { $0.sortKey > $1.sortKey }
    }

    private var storageSegments: [StorageSegment] {
        guard viewModel.diskTotalBytes > 0 else { return [] }
        let totalDisk = Double(viewModel.diskTotalBytes)
        let totalSims = Double(max(viewModel.totalSizeBytes, 1))

        return viewModel.devices
            .sorted { $0.sizeBytes > $1.sizeBytes }
            .compactMap { device in
                guard device.sizeBytes > 0 else { return nil }
                return StorageSegment(
                    id: device.id,
                    name: device.name,
                    sizeBytes: device.sizeBytes,
                    shareOfDisk: Double(device.sizeBytes) / totalDisk,
                    shareOfSims: Double(device.sizeBytes) / totalSims,
                    isEmpty: device.appCount == 0
                )
            }
    }

    private var freeDiskShare: Double {
        guard viewModel.diskTotalBytes > 0 else { return 0 }
        let remaining = max(Double(viewModel.diskTotalBytes - viewModel.totalSizeBytes), 0)
        return remaining / Double(viewModel.diskTotalBytes)
    }

    private var storageSummary: String {
        let sims = formatBytes(viewModel.totalSizeBytes)
        let count = viewModel.devices.count
        let diskPercent = percentDescription(value: viewModel.totalSizeBytes, of: viewModel.diskTotalBytes)
        return "\(sims) across \(count) simulators (\(diskPercent) of disk)"
    }

    private func passesFilter(_ device: SimulatorDevice) -> Bool {
        switch selectedFilter {
        case .all:
            return true
        case .category(let category):
            return device.category == category
        case .runtime(let runtime):
            return device.runtimeGroup == runtime || device.runtime == runtime
        case .recentlyUsed:
            guard let last = device.lastUsed else { return false }
            return Date().timeIntervalSince(last) <= recentThreshold
        case .withApps:
            return device.appCount > 0
        case .empty:
            return device.appCount == 0
        }
    }

    private func count(for filter: SidebarSelection) -> Int {
        viewModel.devices.filter { device in
            switch filter {
            case .all:
                return true
            case .category(let category):
                return device.category == category
            case .runtime(let runtime):
                return device.runtimeGroup == runtime || device.runtime == runtime
            case .recentlyUsed:
                guard let last = device.lastUsed else { return false }
                return Date().timeIntervalSince(last) <= recentThreshold
            case .withApps:
                return device.appCount > 0
            case .empty:
                return device.appCount == 0
            }
        }.count
    }

    private func toggleSidebar() {
        NSApp.keyWindow?.firstResponder?.tryToPerform(#selector(NSSplitViewController.toggleSidebar(_:)), with: nil)
    }

    private func revealFolder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func runSimulator(_ device: SimulatorDevice) {
        // Xcode may be installed as Xcode-beta.app or under another name, so ask Launch Services first.
        let workspace = NSWorkspace.shared
        let simulatorApp = workspace.urlForApplication(withBundleIdentifier: "com.apple.iphonesimulator")
            ?? workspace.urlForApplication(withBundleIdentifier: "com.apple.dt.Xcode")?
                .appending(path: "Contents/Developer/Applications/Simulator.app")
            ?? URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer/Applications/Simulator.app")
        let config = NSWorkspace.OpenConfiguration()
        config.arguments = ["-CurrentDeviceUDID", device.udid]
        NSWorkspace.shared.openApplication(at: simulatorApp, configuration: config)
    }

    private func formatBytes(_ value: Int64) -> String {
        guard value > 0 else { return "—" }
        return ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    private func percentDescription(value: Int64, of total: Int64) -> String {
        guard total > 0 else { return "0%" }
        let pct = Double(value) / Double(total) * 100
        return pct.formatted(.number.precision(.fractionLength(1))) + "%"
    }
}

private struct StorageSegment: Identifiable {
    let id: String
    let name: String
    let sizeBytes: Int64
    let shareOfDisk: Double
    let shareOfSims: Double
    let isEmpty: Bool

    var sizeDescription: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }

    var percentOfSims: String {
        (shareOfSims * 100).formatted(.number.precision(.fractionLength(1)))
    }
}

private struct StorageBar: View {
    let segments: [StorageSegment]
    let freeShare: Double
    let onSelect: (String) -> Void

    private struct BarItem: Identifiable {
        let id: String
        let share: Double
        let minWidth: CGFloat
        let color: Color
        let help: String?
        let tapID: String?
    }

    var body: some View {
        GeometryReader { geometry in
            let totalWidth = geometry.size.width
            let nonEmptySegments = segments.filter { !$0.isEmpty }
            let emptySegments = segments.filter { $0.isEmpty }
            let emptyShareOfDisk = emptySegments.reduce(0) { $0 + $1.shareOfDisk }
            let emptyShareOfSims = emptySegments.reduce(0) { $0 + $1.shareOfSims }
            let emptySizeBytes = emptySegments.reduce(0) { $0 + $1.sizeBytes }
            let emptyTargetID = emptySegments.max { $0.sizeBytes < $1.sizeBytes }?.id

            let items: [BarItem] = {
                var all = nonEmptySegments.enumerated().map { index, segment in
                    BarItem(
                        id: segment.id,
                        share: segment.shareOfDisk,
                        minWidth: 3,
                        color: StorageBar.color(forIndex: index),
                        help: "\(segment.name) • \(segment.sizeDescription) • \(segment.percentOfSims)%",
                        tapID: segment.id
                    )
                }

                if emptyShareOfDisk > 0 {
                    all.append(
                        BarItem(
                            id: "empty",
                            share: emptyShareOfDisk,
                            minWidth: 8,
                            color: Color(nsColor: .systemGray),
                            help: "Empty simulators • \(formatBytes(emptySizeBytes)) • \((emptyShareOfSims * 100).formatted(.number.precision(.fractionLength(1))))%",
                            tapID: emptyTargetID
                        )
                    )
                }

                if freeShare > 0 {
                    all.append(
                        BarItem(
                            id: "free",
                            share: freeShare,
                            minWidth: 8,
                            color: Color.gray.opacity(0.25),
                            help: nil,
                            tapID: nil
                        )
                    )
                }

                return all
            }()

            HStack(spacing: 1) {
                ForEach(Array(items.enumerated()), id: \.1.id) { index, item in
                    Rectangle()
                        .fill(item.color)
                        .frame(width: max(totalWidth * item.share, item.minWidth), height: 22)
                        .optionalHelp(item.help)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            guard let tapID = item.tapID else { return }
                            onSelect(tapID)
                        }
                        .mask(cornerMask(for: index, lastIndex: items.count - 1))
                }
            }
        }
    }

    @ViewBuilder
    private func cornerMask(for index: Int, lastIndex: Int) -> some View {
        let isFirst = index == 0
        let isLast = index == lastIndex

        if isFirst || isLast {
            UnevenRoundedRectangle(
                topLeadingRadius: isFirst ? 4 : 0,
                bottomLeadingRadius: isFirst ? 4 : 0,
                bottomTrailingRadius: isLast ? 4 : 0,
                topTrailingRadius: isLast ? 4 : 0
            )
        } else {
            Rectangle()
        }
    }

    static func color(forIndex index: Int) -> Color {
        let palette = macPalette
        return palette[index % palette.count]
    }

    private func formatBytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    private static let macPalette: [Color] = [
        Color(nsColor: .systemRed),
        Color(nsColor: .systemOrange),
        Color(nsColor: .systemYellow),
        Color(nsColor: .systemGreen),
        Color(nsColor: .systemMint),
        Color(nsColor: .systemTeal),
        Color(nsColor: .systemCyan),
        Color(nsColor: .systemBlue),
        Color(nsColor: .systemIndigo),
        Color(nsColor: .systemPurple),
        Color(nsColor: .systemPink),
        Color(nsColor: .systemBrown),
        Color(nsColor: .systemGray)
    ]
}

private struct LegendItem: Identifiable {
    let id: String
    let name: String
    let color: Color
}

private struct Legend: View {
    let items: [LegendItem]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .center, spacing: 14) {
                ForEach(items) { item in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(item.color)
                            .frame(width: 10, height: 10)
                        Text(item.name)
                            .font(.caption)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private extension View {
    @ViewBuilder
    func optionalHelp(_ text: String?) -> some View {
        if let text, !text.isEmpty {
            self.help(text)
        } else {
            self
        }
    }
}

private enum SidebarSelection: Hashable {
    case all
    case category(DeviceCategory)
    case runtime(String)
    case recentlyUsed
    case withApps
    case empty
}

private struct RuntimeEntry: Identifiable {
    let runtime: String
    let count: Int
    let sortKey: RuntimeSection.RuntimeSortKey

    var id: String { runtime }
}

struct Tag: View {
    let text: String
    let style: TagStyle

    init(text: String, style: TagStyle = .primary) {
        self.text = text
        self.style = style
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(
                Capsule(style: .continuous)
                    .fill(style.background)
            )
            .foregroundStyle(style.foreground)
    }
}

enum TagStyle {
    case primary

    var foreground: Color {
        switch self {
        case .primary: return .blue
        }
    }

    var background: Color {
        foreground.opacity(0.12)
    }
}

private struct PrimaryActionButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }
}

private struct SecondaryActionButton: View {
    let title: String
    let systemImage: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
    }
}

private struct DestructiveActionButton: View {
    let title: String
    let systemImage: String
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .tint(.red)
        .controlSize(.large)
        .disabled(isDisabled)
    }
}

struct DeviceIconView: View {
    let device: SimulatorDevice
    let size: CGFloat
    let weight: Font.Weight
    
    init(device: SimulatorDevice, size: CGFloat, weight: Font.Weight) {
        self.device = device
        self.size = size
        self.weight = weight
    }

    var body: some View {
        let visual = DeviceIcon.for(category: device.category)
        ZStack {
//            RoundedRectangle(cornerRadius: 14, style: .continuous)
//                .fill(visual.background.opacity(0.15))
            Image(systemName: visual.symbol)
                .resizable()
                .scaledToFit()
                .frame(width: size, height: size)
                .foregroundStyle(visual.foreground)
                .fontWeight(weight)
        }
    }
}

struct DeviceIcon {
    let symbol: String
    let foreground: Color
    let background: Color

    static func `for`(category: DeviceCategory) -> DeviceIcon {
        switch category {
        case .iPhone:
            return .init(symbol: "iphone", foreground: .blue, background: .blue)
        case .iPad:
            return .init(symbol: "ipad", foreground: .purple, background: .purple)
        case .Watch:
            return .init(symbol: "applewatch", foreground: .green, background: .green)
        case .TV:
            return .init(symbol: "appletv", foreground: .indigo, background: .indigo)
        case .Vision:
            return .init(symbol: "visionpro", foreground: .orange, background: .orange)
        case .Other:
            return .init(symbol: "questionmark.app", foreground: .gray, background: .gray)
        }
    }
}

struct AppIconView: View {
    let app: SimulatorApp

    var body: some View {
        let image: NSImage? = {
            if let iconURL = app.icon, let img = NSImage(contentsOf: iconURL) {
                return img
            }
            return nil
        }()

        if let image {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .cornerRadius(6)
        } else {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.blue)
                Image(.appGrid)
                    .resizable()
                    .scaledToFit()
                    .padding(4)
                    .foregroundStyle(.white)
            }
        }
    }
}

struct RuntimeSection: Identifiable {
    struct RuntimeSortKey: Comparable {
        let platform: String
        let major: Int
        let minor: Int

        static func < (lhs: RuntimeSortKey, rhs: RuntimeSortKey) -> Bool {
            if lhs.platform != rhs.platform { return lhs.platform < rhs.platform }
            if lhs.major != rhs.major { return lhs.major < rhs.major }
            return lhs.minor < rhs.minor
        }
    }

    let id = UUID()
    let title: String
    let sortKey: RuntimeSortKey

    static func sortKey(from runtime: String) -> RuntimeSortKey {
        let comps = runtime.split(separator: " ")
        let platform = comps.first.map(String.init) ?? "iOS"
        let version = comps.count > 1 ? comps[1] : ""
        let parts = version.split(separator: ".")
        let major = Int(parts.first ?? "0") ?? 0
        let minor = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        return RuntimeSortKey(platform: platform, major: major, minor: minor)
    }
}
