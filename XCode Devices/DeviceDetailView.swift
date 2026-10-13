//
//  DeviceDetailView.swift
//  XCode Devices
//

import SimCleanerKit
import SwiftUI

/// One simulator: what it is, what it holds, and what can be done to it.
struct DeviceDetailView: View {
    @ObservedObject var scanner: DeviceScanner
    let device: SimulatorDevice
    let onDelete: () -> Void
    let onErase: () -> Void
    let onUninstall: (SimulatorApp) -> Void
    let onDuplicate: () -> Void
    let onRename: () -> Void
    let onInstall: () -> Void

    @State private var launchError: String?

    private var isBusy: Bool { scanner.isBusy(device) }
    private var canManage: Bool { scanner.canManageDevices }

    var body: some View {
        ScrollView {
            VStack(alignment: .center, spacing: 16) {
                header
                actions
                if let launchError {
                    Label(launchError, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                storage
                apps
            }
            .padding(20)
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private var header: some View {
        ZStack {
            LinearGradient(
                colors: [DeviceIcon.for(category: device.category).background.opacity(0.2), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .padding(-28)

            VStack(spacing: 14) {
                DeviceIconView(device: device, size: 128, weight: .ultraLight)
                    .frame(width: 90, height: 120)
                    .padding(.top, 24)
                VStack(spacing: 4) {
                    Text(device.name)
                        .font(.title3.bold())
                        .multilineTextAlignment(.center)
                    Text(device.runtime)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(device.deviceType)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        if let badge = device.setKind.badge { Tag(text: badge) }
                        if device.isBooted { Tag(text: "Running", style: .running) }
                        if device.isAvailable == false { Tag(text: "Unavailable", style: .warning) }
                    }
                    .padding(.top, 4)
                    if let error = device.availabilityError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                }
            }
        }
    }

    private var actions: some View {
        VStack(spacing: 10) {
            PrimaryActionButton(title: openTitle, systemImage: "play.fill", isDisabled: isBusy || device.isAvailable == false) {
                Task { await open() }
            }
            HStack(spacing: 10) {
                SecondaryActionButton(title: "Reveal", systemImage: "folder") {
                    SimulatorLauncher.reveal(device.rootPath)
                }
                if device.state.isRunning {
                    SecondaryActionButton(title: "Shut Down", systemImage: "stop.fill", isDisabled: isBusy || !canManage) {
                        Task { await scanner.shutDown([device]) }
                    }
                }
                Menu {
                    Button("Install App…", systemImage: "square.and.arrow.down", action: onInstall)
                        .disabled(!canManage)
                    Button("Duplicate…", systemImage: "plus.square.on.square", action: onDuplicate)
                        .disabled(!canManage || device.state != .shutdown)
                    Button("Rename…", systemImage: "pencil", action: onRename)
                        .disabled(!canManage)
                    Divider()
                    Button("Copy UDID", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(device.udid, forType: .string)
                    }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                        .frame(maxWidth: .infinity)
                }
                .menuStyle(.button)
                .buttonStyle(.bordered)
                .controlSize(.large)
                .help(device.state == .shutdown ? "More actions" : "Duplicating needs the simulator shut down")
            }
            HStack(spacing: 10) {
                DestructiveActionButton(title: "Erase…", systemImage: "eraser", isDisabled: isBusy || !canManage) {
                    onErase()
                }
                .help("Removes apps, data and settings but keeps the simulator in Xcode")
                DestructiveActionButton(title: "Delete…", systemImage: "trash", isDisabled: isBusy || !scanner.canDeleteDevices) {
                    onDelete()
                }
                .optionalHelp(scanner.canDeleteDevices ? nil : "Deleting needs Xcode's simulator tools, which aren't available right now.")
            }
        }
        .padding(.top, 4)
    }

    private var openTitle: String {
        let deviceHub = scanner.deviceHubInstalled
        if device.state == .shutdown && scanner.canBoot {
            return deviceHub ? "Start in Device Hub" : "Start Simulator"
        }
        return deviceHub ? "Open in Device Hub" : "Open in Simulator"
    }

    private func open() async {
        launchError = nil
        // Device Hub opens a shut-down simulator's window without starting it; Pro starts it first.
        if device.state == .shutdown && scanner.canBoot {
            await scanner.boot(device)
        }
        do {
            try await SimulatorLauncher.open(device)
        } catch {
            launchError = error.localizedDescription
        }
    }

    private var storage: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Storage")
                .font(.headline)
            ProgressView(value: Double(device.sizeBytes), total: Double(max(scanner.totalSizeBytes, 1)))
                .tint(.blue)
            HStack {
                Text("\(device.sizeDescription) on disk")
                    .fontWeight(.bold)
                Spacer()
                Text("\(ByteText.string(max(scanner.totalSizeBytes - device.sizeBytes, 0))) in other simulators")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Text(freedDescription)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 10)
    }

    private var freedDescription: String {
        let shared = device.footprint.sharedBytes
        if shared == 0 { return "Deleting it frees \(device.sizeDescription)." }
        return "Deleting it frees \(ByteText.freed(device.footprint)): \(ByteText.string(shared)) of its files share disk blocks with others (APFS clones), and those blocks stay while anything else uses them."
    }

    @ViewBuilder
    private var apps: some View {
        VStack(alignment: .leading, spacing: 10) {
            if device.apps.isEmpty {
                Text("No apps in this simulator.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 48)
            } else {
                Text("Installed apps")
                    .font(.headline)
                if !device.isBooted {
                    Text(scanner.canBoot
                        ? "Removing an app starts the simulator for a moment."
                        : "To remove an app, start the simulator first. Opening its folders works either way.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(device.apps.sorted { $0.sizeBytes > $1.sizeBytes }) { app in
                    AppRow(app: app, isBusy: scanner.busy[app.id] != nil, canUninstall: canUninstall) {
                        onUninstall(app)
                    }
                }
                Spacer(minLength: 160)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var canUninstall: Bool {
        guard canManage, !isBusy else { return false }
        return device.isBooted || (scanner.canBoot && device.state == .shutdown)
    }
}

/// An installed app with quick access to the folders developers look for.
struct AppRow: View {
    let app: SimulatorApp
    let isBusy: Bool
    let canUninstall: Bool
    let onUninstall: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            AppIconView(app: app)
                .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                    .font(.subheadline)
                    .lineLimit(1)
                Text(isBusy ? "Removing…" : app.sizeDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if isBusy {
                ProgressView().controlSize(.small)
            } else {
                Menu {
                    folderButtons
                    Divider()
                    Button("Remove App…", systemImage: "trash", role: .destructive, action: onUninstall)
                        .disabled(!canUninstall)
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Open the app's folders or remove it")
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.gray.opacity(0.06)))
        .contextMenu {
            folderButtons
            Divider()
            Button("Remove App…", role: .destructive, action: onUninstall)
                .disabled(!canUninstall)
        }
        .help(app.bundleId)
    }

    @ViewBuilder
    private var folderButtons: some View {
        if let documents = app.documentsURL {
            Button("Open Documents", systemImage: "doc") { SimulatorLauncher.openFolder(documents) }
        }
        if let caches = app.cachesURL {
            Button("Open Caches", systemImage: "archivebox") { SimulatorLauncher.openFolder(caches) }
        }
        if let preferences = app.preferencesURL {
            Button("Open Preferences (UserDefaults)", systemImage: "gearshape") { SimulatorLauncher.openFolder(preferences) }
        }
        if let container = app.dataContainerPath {
            Button("Reveal Data Container", systemImage: "folder") { SimulatorLauncher.reveal(container) }
        }
        Button("Reveal App Bundle", systemImage: "shippingbox") { SimulatorLauncher.reveal(app.bundlePath) }
        Button("Copy Bundle ID", systemImage: "doc.on.doc") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(app.bundleId, forType: .string)
        }
    }
}

/// Several simulators selected: totals and the actions that apply to all of them.
struct MultiSelectionPanel: View {
    @ObservedObject var scanner: DeviceScanner
    let devices: [SimulatorDevice]
    let onDelete: () -> Void
    let onErase: () -> Void
    let onShutDown: () -> Void
    let onInstall: () -> Void

    private var footprint: DiskFootprint { devices.reduce(.zero) { $0 + $1.footprint } }
    private var isBusy: Bool { !scanner.busy.isEmpty }

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                VStack(spacing: 6) {
                    Text("\(devices.count) simulators selected")
                        .font(.title3.weight(.semibold))
                    Text("\(ByteText.string(footprint.allocatedBytes)) on disk • deleting frees \(ByteText.freed(footprint))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(devices.prefix(8)) { device in
                        HStack(spacing: 10) {
                            DeviceIconView(device: device, size: 18, weight: .regular)
                                .frame(width: 22, height: 22)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.name).font(.callout).lineLimit(1)
                                Text(device.runtime).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                            if scanner.isBusy(device) {
                                ProgressView().controlSize(.small)
                            } else {
                                Text(device.sizeDescription).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if devices.count > 8 {
                        Text("+ \(devices.count - 8) more")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.gray.opacity(0.06)))

                if scanner.volume.totalBytes > 0 {
                    Text("\(ByteText.percent(footprint.allocatedBytes, of: scanner.volume.totalBytes)) of the disk")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(spacing: 10) {
                    SecondaryActionButton(title: "Install App on These…", systemImage: "square.and.arrow.down.on.square", isDisabled: isBusy || !scanner.canManageDevices, action: onInstall)
                    if devices.contains(where: { $0.state.isRunning }) {
                        SecondaryActionButton(title: "Shut Down Running", systemImage: "stop.fill", isDisabled: isBusy || !scanner.canManageDevices, action: onShutDown)
                    }
                    DestructiveActionButton(title: "Erase Selected…", systemImage: "eraser", isDisabled: isBusy || !scanner.canManageDevices, action: onErase)
                    DestructiveActionButton(title: "Delete Selected…", systemImage: "trash", isDisabled: isBusy || !scanner.canDeleteDevices, action: onDelete)
                }
            }
            .padding(20)
        }
    }
}
