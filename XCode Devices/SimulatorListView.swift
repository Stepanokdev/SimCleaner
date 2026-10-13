//
//  SimulatorListView.swift
//  XCode Devices
//

import SimCleanerKit
import SwiftUI

/// The simulator table with its header, notices and empty states.
struct SimulatorListView: View {
    @ObservedObject var scanner: DeviceScanner
    let devices: [SimulatorDevice]
    let totalCount: Int
    @Binding var searchText: String
    let selection: Binding<Set<String>>
    @Binding var sortOrder: [KeyPathComparator<SimulatorDevice>]
    /// Set when the sidebar shows one OS version, so the header can offer "Select All".
    let runtimeFilter: String?
    let onSelectAll: () -> Void
    let onRequestAccess: () -> Void

    /// The list, not the search field, has focus when the window opens, as in Finder: arrow keys move
    /// through simulators and typing doesn't land in the search by accident.
    @FocusState private var isListFocused: Bool

    private let stateColumnWidth: CGFloat = 84
    private let sizeColumnWidth: CGFloat = 90
    private let lastUsedColumnWidth: CGFloat = 116
    private let appsColumnWidth: CGFloat = 116

    var body: some View {
        VStack(spacing: 0) {
            header
            if let progress = scanner.scanProgress {
                ProgressView(value: Double(progress.completed), total: Double(max(progress.total, 1))) {
                    Text("Scanning simulators…")
                } currentValueLabel: {
                    Text(progress.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                .progressViewStyle(.linear)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
            }
            if let bulk = scanner.bulkProgress {
                BulkProgressStrip(progress: bulk)
            }
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .defaultFocus($isListFocused, true)
        .task {
            // AppKit hands the window's first focus to the first text field; take it back once.
            isListFocused = true
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(runtimeFilter.map { "\($0) simulators" } ?? "Simulators")
                        .font(.headline)
                    Text("\(devices.count) of \(totalCount) • \(ByteText.orDash(scanner.totalSizeBytes)) total")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if runtimeFilter != nil, !devices.isEmpty {
                    Button("Select All", action: onSelectAll)
                        .buttonStyle(.link)
                        .font(.callout)
                        .help("Select every simulator of this version, then delete or erase them together")
                }
                Spacer()
                TextField("Search by name, OS, UDID or app", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
            }
            if scanner.isSandboxed && scanner.hasFolderAccess {
                scanLocationRow
            }
            if let problem = scanner.capabilities?.simctlProblem {
                Label(scanner.canDeleteDevices
                    ? "\(problem.explanation) CoreSimulator isn't on this Mac either, so nothing can be running these simulators: SimCleaner deletes shut-down ones by removing their folders."
                    : "\(problem.explanation) Until then SimCleaner only shows simulators and removes leftover folders: shutting down, erasing and deleting go through those tools.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
                    Text(displayPath(scanner.devicesURL))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(scanner.devicesURL.path)
                }
                .foregroundStyle(.secondary)
                Button("Change…", action: onRequestAccess)
                    .buttonStyle(.link)
                    .disabled(scanner.isLoading)
            }
            .font(.caption)

            if scanner.hasCompletedScan && !scanner.coversDeveloperFolder && !scanner.devices.isEmpty {
                HStack(spacing: 6) {
                    Group {
                        Image(systemName: "info.circle")
                        Text("Xcode also keeps Preview devices, test clones and build caches elsewhere in ~/Library/Developer.")
                    }
                    .foregroundStyle(.secondary)
                    Button("Include them…", action: onRequestAccess)
                        .buttonStyle(.link)
                        .disabled(scanner.isLoading)
                }
                .font(.caption)
            }

            if scanner.isScanPartial && !scanner.devices.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("\(scanner.unreadableSummary) Some simulators may be missing.")
                        .foregroundStyle(.secondary)
                    Button("Choose Folder Again…", action: onRequestAccess)
                        .buttonStyle(.link)
                        .disabled(scanner.isLoading)
                }
                .font(.caption)
            }
        }
    }

    // MARK: Content

    private var listState: SimulatorListState {
        SimulatorListState.resolve(
            hasFolderAccess: scanner.hasFolderAccess,
            scannedURL: scanner.devicesURL,
            errorMessage: scanner.errorMessage,
            isLoading: scanner.isLoading,
            hasCompletedScan: scanner.hasCompletedScan,
            deviceCount: scanner.devices.count,
            filteredCount: devices.count,
            deviceSetCount: scanner.deviceSets.count,
            isScanPartial: scanner.isScanPartial
        )
    }

    @ViewBuilder
    private var content: some View {
        switch listState {
        case .needsAccess:
            FolderAccessNeededView(onRequestAccess: onRequestAccess)
        case .error(let message):
            ContentUnavailableView {
                Label(message, systemImage: "exclamationmark.triangle")
            } description: {
                Text("SimCleaner needs read and write access to your Developer folder.")
            } actions: {
                Button("Choose Developer Folder…", action: onRequestAccess)
                    .buttonStyle(.borderedProminent)
            }
        case .loading:
            Color.clear
        case .runtimeFolder, .unreadableFolders, .noDeviceFolders, .noSimulators:
            emptyPlaceholder(listState)
        case .noMatches:
            ContentUnavailableView {
                Label("No matching simulators", systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text("Try another filter or clear the search.")
            }
        case .list:
            table
        }
    }

    private var table: some View {
        Table(devices, selection: selection, sortOrder: $sortOrder) {
            TableColumn("Type", value: \.deviceType) { device in
                HStack(spacing: 10) {
                    DeviceIconView(device: device, size: 28, weight: .medium)
                        .frame(width: 40, height: 52)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(device.name)
                            .font(.headline)
                            .lineLimit(1)
                            .help(device.name)
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
                    Spacer(minLength: 0)
                    if let work = scanner.busyLabel(for: device) {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text(work)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            TableColumn("State", value: \.stateDescription) { device in
                HStack(spacing: 6) {
                    StateDot(color: stateColor(device))
                    Text(device.stateDescription)
                        .font(.callout)
                        .foregroundStyle(device.state.isRunning ? .primary : .secondary)
                        .lineLimit(1)
                }
                .optionalHelp(device.availabilityError)
            }
            .width(stateColumnWidth)
            TableColumn("Size", value: \.sizeBytes) { device in
                Text(device.sizeDescription)
                    .font(.callout.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .help(sizeHelp(device))
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
                let icons = Array(device.apps.prefix(4))
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        ForEach(icons) { app in
                            AppIconView(app: app)
                                .frame(width: 22, height: 22)
                        }
                    }
                    if device.appCount > icons.count {
                        Text("and \(device.appCount - icons.count) more")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .width(appsColumnWidth)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .focused($isListFocused)
    }

    private func stateColor(_ device: SimulatorDevice) -> Color {
        if device.isAvailable == false { return .orange }
        switch device.state {
        case .booted: return .green
        case .booting, .shuttingDown: return .yellow
        default: return Color(nsColor: .tertiaryLabelColor)
        }
    }

    private func sizeHelp(_ device: SimulatorDevice) -> String {
        let shared = device.footprint.sharedBytes
        guard shared > 0 else { return "\(device.sizeDescription) on disk" }
        return "\(device.sizeDescription) on disk, of which \(ByteText.string(shared)) is shared with other files (APFS clones). Deleting frees \(ByteText.freed(device.footprint))."
    }

    @ViewBuilder
    private func emptyPlaceholder(_ state: SimulatorListState) -> some View {
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
                Text("Runtimes are the OS images simulators run on. See Clean Up › Runtimes. To find your simulators, choose the Developer folder in your Library.")
            case .unreadableFolders:
                Text("\(scanner.unreadableSummary) Your simulators may be there. Choose ~/Library/Developer again to give SimCleaner access.")
            case .noDeviceFolders:
                Text("Xcode keeps simulators in the Developer folder inside your Library (~/Library/Developer). Choose that folder and SimCleaner will find all of them.")
            default:
                Text("Xcode hasn't created any simulators here. If gigabytes are still missing, look at Clean Up › Runtimes and Xcode caches.")
            }
        } actions: {
            if state != .noSimulators && scanner.isSandboxed {
                Button("Choose Developer Folder…", action: onRequestAccess)
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    /// Shows the path with ~ for the real home folder (the sandbox would otherwise abbreviate the container path).
    private func displayPath(_ url: URL) -> String {
        let home = DeveloperPaths.realHomeDirectory.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        if path == home { return "~" }
        if path.hasPrefix(home + "/") { return "~" + path.dropFirst(home.count) }
        return path
    }
}

/// A simulator's state colour. A grey dot would vanish on the highlight of a selected row in a focused
/// list, so there it turns white.
private struct StateDot: View {
    let color: Color
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        Circle()
            .fill(prominence == .increased && color == Color(nsColor: .tertiaryLabelColor) ? Color.white.opacity(0.7) : color)
            .frame(width: 7, height: 7)
    }
}
