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
    @State private var sortOption: SortOption = .size
    @State private var searchText: String = ""
    @State private var hideEmptyApps: Bool = false
    @State private var groupOption: GroupOption = .runtime
    @State private var devicePendingDeletion: SimulatorDevice?
    @State private var showDeleteConfirmation: Bool = false
    @State private var deletionInProgress: String?

    private let gridColumns = [
        GridItem(.adaptive(minimum: 340), spacing: 16, alignment: .top)
    ]

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                header
                controls
                content
            }
            .padding(20)
            .navigationTitle("Симуляторы Xcode")
            .searchable(text: $searchText, prompt: "Фильтр по имени, OS или UDID")
            .onAppear {
                viewModel.refresh()
            }
            .alert(
                "Удалить симулятор?",
                isPresented: $showDeleteConfirmation,
                presenting: devicePendingDeletion
            ) { device in
                Button("Удалить", role: .destructive) {
                    deletionInProgress = device.udid
                    Task {
                        await viewModel.delete(device: device)
                        deletionInProgress = nil
                        devicePendingDeletion = nil
                    }
                }
                Button("Отмена", role: .cancel) {
                    devicePendingDeletion = nil
                }
            } message: { device in
                Text("\(device.name)\n\(device.runtime)\nUDID: \(device.udid)")
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 4) {
                Text("CoreSimulator/Devices")
                    .font(.title)
                    .fontWeight(.semibold)
                Text(viewModel.devicesURL.path)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                HStack(spacing: 8) {
                    Button {
                        revealFolder(viewModel.devicesURL)
                    } label: {
                        Label("Открыть в Finder", systemImage: "folder")
                    }
                    Button {
                        viewModel.refresh()
                    } label: {
                        if viewModel.isLoading {
                            ProgressView()
                                .controlSize(.small)
                                .padding(.trailing, 4)
                        }
                        Label("Обновить", systemImage: "arrow.clockwise")
                    }
                    .keyboardShortcut("r", modifiers: [.command])
                    .disabled(viewModel.isLoading)
                }
                HStack(spacing: 12) {
                    Label("\(viewModel.devices.count) симуляторов", systemImage: "iphone")
                        .foregroundStyle(.secondary)
                    Label(totalSizeDescription, systemImage: "internaldrive")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Picker("Сортировка", selection: $sortOption) {
                ForEach(SortOption.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 520)

            Toggle("Скрывать без приложений", isOn: $hideEmptyApps)
                .toggleStyle(.switch)
                .frame(width: 240, alignment: .leading)

            Picker("Группировка", selection: $groupOption) {
                ForEach(GroupOption.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.menu)

            Spacer()
        }
    }

    private var content: some View {
        Group {
            if let errorMessage = viewModel.errorMessage {
                VStack(spacing: 8) {
                    Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text("Проверь путь и права доступа.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else if viewModel.isLoading && viewModel.devices.isEmpty {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Сканирование симуляторов...")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else if filteredDevices.isEmpty {
                VStack(spacing: 8) {
                    Label("Симуляторы не найдены", systemImage: "archivebox")
                        .foregroundStyle(.secondary)
                    Text("Проверьте фильтры или обновите список.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                ScrollView {
                    contentBody
                }
            }
        }
    }

    private var filteredDevices: [SimulatorDevice] {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let devices = viewModel.devices.filter { device in
            if hideEmptyApps && device.appCount == 0 { return false }
            guard !trimmed.isEmpty else { return true }
            let haystack = "\(device.name) \(device.deviceType) \(device.runtime) \(device.udid)".lowercased()
            return haystack.contains(trimmed.lowercased())
        }

        return devices.sorted(by: sortComparator)
    }

    private var groupedDevices: [(title: String, devices: [SimulatorDevice])] {
        switch groupOption {
        case .none, .category, .runtime:
            return [(title: "", devices: filteredDevices)]
        }
    }

    private var runtimeSections: [RuntimeSection] {
        let grouped = Dictionary(grouping: filteredDevices, by: { $0.runtimeGroup })
        var sections: [RuntimeSection] = []

        for (runtime, devices) in grouped {
            let categories = DeviceCategory.ordered.compactMap { category -> RuntimeSection.CategoryEntry? in
                let list = devices.filter { $0.category == category }
                guard !list.isEmpty else { return nil }
                return .init(category: category, devices: list.sorted(by: sortComparator))
            }
            guard !categories.isEmpty else { continue }
            sections.append(.init(title: runtime, categories: categories, sortKey: RuntimeSection.sortKey(from: runtime)))
        }

        return sections.sorted { $0.sortKey > $1.sortKey }
    }

    private var contentBody: some View {
        Group {
            if groupOption == .runtime {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(runtimeSections) { section in
                        VStack(alignment: .leading, spacing: 10) {
                            Text(section.title)
                                .font(.title3)
                                .fontWeight(.semibold)
                                .padding(.horizontal, 4)

                            ForEach(section.categories) { categoryEntry in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(categoryEntry.category.title.lowercased() == "other" ? "Other devices" : categoryEntry.category.title)
                                        .font(.headline)
                                        .foregroundStyle(.secondary)
                                        .padding(.horizontal, 4)

                                    LazyVGrid(columns: gridColumns, spacing: 16) {
                                        ForEach(categoryEntry.devices) { device in
                                            DeviceCard(
                                                device: device,
                                                onReveal: { revealFolder(device.rootPath) },
                                                onDelete: {
                                                    devicePendingDeletion = device
                                                    showDeleteConfirmation = true
                                                },
                                                isDeleting: deletionInProgress == device.udid
                                            )
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            } else {
                LazyVGrid(columns: gridColumns, spacing: 16) {
                    ForEach(filteredDevices) { device in
                        DeviceCard(
                            device: device,
                            onReveal: { revealFolder(device.rootPath) },
                            onDelete: {
                                devicePendingDeletion = device
                                showDeleteConfirmation = true
                            },
                            isDeleting: deletionInProgress == device.udid
                        )
                    }
                }
            }
        }
    }

    private func sortComparator(_ lhs: SimulatorDevice, _ rhs: SimulatorDevice) -> Bool {
        switch sortOption {
        case .size: return lhs.sizeBytes > rhs.sizeBytes
        case .lastUsed:
            let l = lhs.lastUsed ?? .distantPast
            let r = rhs.lastUsed ?? .distantPast
            return l > r
        case .apps:
            if lhs.appCount == rhs.appCount {
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            return lhs.appCount > rhs.appCount
        case .name:
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private var totalSizeDescription: String {
        guard viewModel.totalSizeBytes > 0 else { return "Общий размер: —" }
        let formatted = ByteCountFormatter.string(fromByteCount: viewModel.totalSizeBytes, countStyle: .file)
        return "Общий размер: \(formatted)"
    }

    private func revealFolder(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

struct DeviceCard: View {
    let device: SimulatorDevice
    let onReveal: () -> Void
    let onDelete: () -> Void
    let isDeleting: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                DeviceIconView(device: device)

                VStack(alignment: .leading, spacing: 4) {
                    Text(device.name)
                        .font(.headline)
                    Text(device.deviceType)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Tag(text: device.runtime)
            }

            HStack(spacing: 12) {
                Label(device.sizeDescription, systemImage: "internaldrive")
                Label(device.lastUsedDescription, systemImage: "clock.arrow.circlepath")
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("\(device.appCount) установленных", systemImage: "square.stack.3d.up.fill")
                    Spacer()
                    Button {
                        onReveal()
                    } label: {
                        Label("Показать в Finder", systemImage: "folder")
                    }
                    .buttonStyle(.borderless)
                    .font(.callout)
                    Button {
                        onDelete()
                    } label: {
                        if isDeleting {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label("Удалить", systemImage: "trash")
                        }
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
                    .font(.callout)
                    .disabled(isDeleting)
                }

                if device.apps.isEmpty {
                    Text("Приложения не найдены.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    AppList(apps: device.apps)
                }
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.gray.opacity(0.07))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.gray.opacity(0.12), lineWidth: 1)
        )
    }
}

struct AppList: View {
    let apps: [SimulatorApp]

    var body: some View {
        let shownApps = Array(apps.prefix(12))
        let columns = [GridItem(.adaptive(minimum: 80), spacing: 8)]

        VStack(alignment: .leading, spacing: 8) {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                ForEach(shownApps) { app in
                    VStack(spacing: 6) {
                        AppIconView(app: app)
                            .frame(width: 32, height: 32)
                        Text(app.name)
                            .font(.caption)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
            }

            if apps.count > shownApps.count {
                Text("+ ещё \(apps.count - shownApps.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
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

struct DeviceIconView: View {
    let device: SimulatorDevice

    var body: some View {
        let visual = DeviceIcon.for(category: device.category)
        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(visual.background.opacity(0.15))
            Image(systemName: visual.symbol)
                .resizable()
                .scaledToFit()
                .frame(width: 36, height: 36)
                .foregroundStyle(visual.foreground)
        }
        .frame(width: 64, height: 64)
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
            return NSWorkspace.shared.icon(forFile: app.path.path)
        }()

        if let image {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .cornerRadius(6)
        } else {
            Image(systemName: "app.fill")
                .resizable()
                .scaledToFit()
        }
    }
}

struct RuntimeSection: Identifiable {
    struct CategoryEntry: Identifiable {
        let category: DeviceCategory
        let devices: [SimulatorDevice]
        var id: String { category.rawValue }
    }

    let id = UUID()
    let title: String
    let categories: [CategoryEntry]
    let sortKey: RuntimeSortKey

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

    static func sortKey(from runtime: String) -> RuntimeSortKey {
        // runtime like "iOS 26.1" or "iOS 18.5"
        let comps = runtime.split(separator: " ")
        let platform = comps.first.map(String.init) ?? "iOS"
        let version = comps.count > 1 ? comps[1] : ""
        let parts = version.split(separator: ".")
        let major = Int(parts.first ?? "0") ?? 0
        let minor = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
        return RuntimeSortKey(platform: platform, major: major, minor: minor)
    }
}

enum SortOption: String, CaseIterable, Identifiable {
    case size
    case lastUsed
    case apps
    case name

    var id: Self { self }

    var title: String {
        switch self {
        case .size: return "Размер"
        case .lastUsed: return "Последний запуск"
        case .apps: return "По приложениям"
        case .name: return "Имя"
        }
    }
}

enum GroupOption: String, CaseIterable, Identifiable {
    case none
    case category
    case runtime

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "Без групп"
        case .category: return "По типу девайса"
        case .runtime: return "По версии OS"
        }
    }
}
