//
//  BatchInstallSheet.swift
//  XCode Devices
//

import AppKit
import SimCleanerKit
import SwiftUI
import UniformTypeIdentifiers

/// Installs one build on several simulators. Each copy is a normal install with its own data; APFS
/// shares the bundle's blocks, so extra copies cost almost no disk space.
struct BatchInstallSheet: View {
    @ObservedObject var scanner: DeviceScanner
    let initialTargets: [SimulatorDevice]

    @Environment(\.dismiss) private var dismiss
    @State private var app: AppBundleInfo?
    @State private var appError: String?
    @State private var recentBuilds: [URL] = []
    @State private var chosen: Set<String> = []
    @State private var phases: [String: InstallPhase] = [:]
    @State private var installTask: Task<Void, Never>?
    @State private var isDropTargeted = false

    private var isRunning: Bool { installTask != nil }
    private var isFinished: Bool { !phases.isEmpty && !isRunning }

    /// Simulators of the right platform first, then by name.
    private var candidates: [SimulatorDevice] {
        scanner.devices
            .filter { $0.isAvailable != false }
            .sorted { lhs, rhs in
                let l = app.map { $0.compatibility(with: lhs) == .compatible } ?? true
                let r = app.map { $0.compatibility(with: rhs) == .compatible } ?? true
                if l != r { return l }
                if lhs.isBooted != rhs.isBooted { return lhs.isBooted }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
    }

    private func blocker(for device: SimulatorDevice) -> String? {
        if let reason = app?.compatibility(with: device).reason { return reason }
        if !scanner.canBoot && device.state != .booted { return "Not running" }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Install an app on several simulators")
                .font(.title3.weight(.semibold))
            buildSection
            Divider()
            targetsSection
            footer
        }
        .padding(22)
        .frame(width: 620, height: 600)
        .onAppear {
            recentBuilds = scanner.coversDeveloperFolder ? RecentBuilds.find(in: DeveloperPaths.developerFolder) : []
            chosen = Set(initialTargets.map(\.udid))
        }
        .onDisappear { installTask?.cancel() }
    }

    // MARK: Build

    @ViewBuilder
    private var buildSection: some View {
        if let app {
            HStack(spacing: 12) {
                Image(systemName: "app.dashed")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(app.name).font(.headline)
                    Text([app.bundleIdentifier, app.shortVersion.map { "Version \($0)" }, app.minimumOSVersion.map { "Requires \($0.shortDescription)+" }].compactMap { $0 }.joined(separator: " • "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button("Change…", action: chooseApp)
                    .disabled(isRunning)
            }
        } else {
            VStack(alignment: .leading, spacing: 10) {
                VStack(spacing: 8) {
                    Image(systemName: "square.and.arrow.down")
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)
                    Text("Drop a simulator build (.app) here")
                        .font(.callout)
                    Button("Choose App…", action: chooseApp)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .background(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.35), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                )
                .onDrop(of: [.fileURL], isTargeted: $isDropTargeted, perform: handleDrop)

                if let appError {
                    Label(appError, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                if !recentBuilds.isEmpty {
                    Text("Recent builds")
                        .font(.subheadline.weight(.semibold))
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(recentBuilds, id: \.self) { url in
                                Button {
                                    load(url)
                                } label: {
                                    HStack {
                                        Text(url.deletingPathExtension().lastPathComponent)
                                        Text(url.deletingLastPathComponent().lastPathComponent)
                                            .foregroundStyle(.secondary)
                                        Spacer()
                                        Text((try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)?.relativeDescription ?? "")
                                            .foregroundStyle(.secondary)
                                    }
                                    .font(.callout)
                                    .padding(.vertical, 4)
                                    .padding(.horizontal, 8)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(maxHeight: 120)
                }
            }
        }
    }

    // MARK: Targets

    private var targetsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Simulators")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Button("Select Compatible") {
                    chosen = Set(candidates.filter { blocker(for: $0) == nil }.map(\.udid))
                }
                .buttonStyle(.link)
                .disabled(app == nil || isRunning)
            }
            if !scanner.canBoot {
                ProFeatureNote(text: "The App Store edition installs on running simulators only: macOS doesn't let it start them. Start the ones you need in Device Hub, or use SimCleaner Pro, which starts and stops them for you.")
            }
            List(candidates) { device in
                targetRow(device)
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
        }
    }

    private func targetRow(_ device: SimulatorDevice) -> some View {
        let reason = blocker(for: device)
        let isChosen = Binding(
            get: { chosen.contains(device.udid) },
            set: { isOn in
                if isOn { chosen.insert(device.udid) } else { chosen.remove(device.udid) }
            }
        )
        return HStack(spacing: 10) {
            Toggle(isOn: isChosen) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .disabled(reason != nil || isRunning)
            DeviceIconView(device: device, size: 16, weight: .regular)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(device.name).lineLimit(1)
                Text("\(device.runtime) • \(device.stateDescription)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let phase = phases[device.udid] {
                phaseLabel(phase)
            } else if let reason {
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .opacity(reason != nil && phases[device.udid] == nil ? 0.55 : 1)
    }

    @ViewBuilder
    private func phaseLabel(_ phase: InstallPhase) -> some View {
        switch phase {
        case .waiting:
            Text("Waiting").font(.caption).foregroundStyle(.secondary)
        case .starting:
            HStack(spacing: 4) { ProgressView().controlSize(.mini); Text("Starting").font(.caption) }
        case .installing:
            HStack(spacing: 4) { ProgressView().controlSize(.mini); Text("Installing").font(.caption) }
        case .shuttingDown:
            HStack(spacing: 4) { ProgressView().controlSize(.mini); Text("Shutting down").font(.caption) }
        case .installed:
            Label("Installed", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
        case .skipped(let reason):
            Text(reason).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(reason)
        case .failed(let reason):
            Label("Failed", systemImage: "xmark.octagon.fill").font(.caption).foregroundStyle(.red).help(reason)
        case .cancelled:
            Text("Cancelled").font(.caption).foregroundStyle(.secondary)
        case .leftRunning(let installed, let reason):
            Label(installed ? "Installed, still running" : "Still running", systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .help(reason)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            if isFinished {
                let installed = phases.values.filter { $0 == .installed }.count
                let leftRunning = phases.values.filter { if case .leftRunning = $0 { return true } else { return false } }.count
                Text("Installed on \(installed) of \(phases.count)" + (leftRunning > 0 ? " • \(leftRunning) couldn't be shut down again" : ""))
                    .font(.callout)
                    .foregroundStyle(leftRunning > 0 ? .orange : .secondary)
            }
            Spacer()
            if isRunning {
                Button("Stop") { installTask?.cancel() }
                    .help("Finishes the simulators already in progress and shuts down any it started")
            } else {
                Button(isFinished ? "Done" : "Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Install on \(chosen.count) \(chosen.count == 1 ? "Simulator" : "Simulators")", action: install)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(app == nil || chosen.isEmpty || !scanner.canManageDevices)
            }
        }
    }

    // MARK: Actions

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.title = "Choose a simulator build"
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        if scanner.coversDeveloperFolder {
            panel.directoryURL = DeveloperPaths.developerFolder.appending(path: "Xcode/DerivedData")
        }
        if panel.runModal() == .OK, let url = panel.url {
            load(url)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            guard let url else { return }
            Task { @MainActor in load(url) }
        }
        return true
    }

    private func load(_ url: URL) {
        do {
            let info = try AppBundleInfo.read(url)
            app = info
            appError = nil
            phases = [:]
            // Keep only the chosen simulators the build can actually go on.
            chosen = chosen.filter { udid in
                scanner.devices.first { $0.udid == udid }.map { blocker(for: $0) == nil } ?? false
            }
            if chosen.isEmpty {
                chosen = Set(candidates.filter { blocker(for: $0) == nil && $0.isBooted }.map(\.udid))
            }
        } catch {
            appError = error.localizedDescription
        }
    }

    private func install() {
        guard let app, let installer = scanner.makeBatchInstaller() else { return }
        let targets = scanner.devices.filter { chosen.contains($0.udid) }
        phases = Dictionary(uniqueKeysWithValues: targets.map { ($0.udid, InstallPhase.waiting) })
        installTask = Task {
            await installer.install(app, on: targets) { udid, phase in
                Task { @MainActor in phases[udid] = phase }
            }
            installTask = nil
            scanner.refresh()
        }
    }
}
