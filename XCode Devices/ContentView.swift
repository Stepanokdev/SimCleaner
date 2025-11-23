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
    @State private var sortOrder: [KeyPathComparator<SimulatorDevice>] = [KeyPathComparator(\.sizeBytes, order: .reverse)]
    @State private var searchText: String = ""
    @State private var selectedFilter: SidebarSelection = .all
    @State private var selectedDeviceID: String?
    @State private var devicePendingDeletion: SimulatorDevice?
    @State private var showDeleteConfirmation: Bool = false
    @State private var deletionInProgress: String?
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

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
                .navigationSplitViewColumnWidth(min: 280, ideal: 340, max: 420)
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
            if viewModel.devices.isEmpty {
                viewModel.refresh()
            }
        }
        .onChange(of: filteredDeviceIDs, initial: false) { _, ids in
            if let current = selectedDeviceID, ids.contains(current) {
                return
            }
            selectedDeviceID = ids.first
        }
        .alert(
            "Delete simulator?",
            isPresented: $showDeleteConfirmation,
            presenting: devicePendingDeletion
        ) { device in
            Button("Delete", role: .destructive) {
                deletionInProgress = device.udid
                Task {
                    await viewModel.delete(device: device)
                    deletionInProgress = nil
                    devicePendingDeletion = nil
                }
            }
            Button("Cancel", role: .cancel) {
                devicePendingDeletion = nil
            }
        } message: { device in
            Text("\(device.name)\n\(device.runtime)\nUDID: \(device.udid)")
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
                        title: "Never launched",
                        subtitle: "\(count(for: .neverLaunched))",
                        systemImage: "sparkles.rectangle.stack",
                        isSelected: selectedFilter == .neverLaunched
                    ) { selectedFilter = .neverLaunched }
                    
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
            Divider()

            Group {
                if let errorMessage = viewModel.errorMessage {
                    VStack(spacing: 8) {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                        Text("Check the path and permissions.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                } else if viewModel.isLoading && viewModel.devices.isEmpty {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Scanning simulators...")
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                } else if filteredDevices.isEmpty {
                    VStack(spacing: 8) {
                        Label("No simulators found", systemImage: "archivebox")
                            .foregroundStyle(.secondary)
                        Text("Check filters or refresh the list.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                } else {
                    Table(sortedDevices, selection: tableSelection, sortOrder: $sortOrder) {
                        TableColumn("Type", value: \.deviceType) { device in
                            HStack(spacing: 12) {
                                DeviceIconView(device: device, size: 32, weight: .medium)
                                    .frame(width: 56, height: 56)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(device.name)
                                        .font(.headline)
                                        .lineLimit(1)
                                    Text(device.runtime)
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
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
                        TableColumn("Last launch", value: \.lastUsedSortKey) { device in
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
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var detailPanel: some View {
        ScrollView {
            VStack(alignment: .center, spacing: 16) {
                if let device = selectedDevice {
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
                            VStack(spacing: 4) {
                                Text(device.name)
                                    .font(.title3.bold())
                                Text(device.runtime)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Text(device.deviceType)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
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
                            title: deletionInProgress == device.udid ? "Deleting..." : "Delete",
                            systemImage: "trash",
                            isDisabled: deletionInProgress == device.udid
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
            }

            StorageBar(
                segments: storageSegments,
                freeShare: freeDiskShare
            ) { id in
                withAnimation {
                    selectedFilter = .all
                    selectedDeviceID = id
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

    private var filteredDevices: [SimulatorDevice] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let devices = viewModel.devices.filter { device in
            guard passesFilter(device) else { return false }
            guard !trimmed.isEmpty else { return true }
            let haystack = "\(device.name) \(device.deviceType) \(device.runtime) \(device.udid)".lowercased()
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

    private var selectedDevice: SimulatorDevice? {
        if let id = selectedDeviceID {
            return sortedDevices.first(where: { $0.id == id })
        }
        return sortedDevices.first
    }

    private var tableSelection: Binding<Set<String>> {
        Binding(
            get: {
                if let id = selectedDeviceID {
                    return [id]
                }
                return []
            },
            set: { newValue in
                selectedDeviceID = newValue.first
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
        case .neverLaunched:
            return device.lastUsed == nil
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
            case .neverLaunched:
                return device.lastUsed == nil
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
        let simulatorApp = URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer/Applications/Simulator.app")
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
    case neverLaunched
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
                Image(systemName: "app.grid")
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
