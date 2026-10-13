//
//  RuntimesView.swift
//  XCode Devices
//

import AppKit
import SimCleanerKit
import SwiftUI

/// Downloaded simulator runtimes. Pro deletes them through CoreSimulator; the App Store edition can
/// only show them, because the sandbox hides runtimes from simctl.
struct RuntimesView: View {
    @ObservedObject var scanner: DeviceScanner
    @State private var selection: RuntimeEntry.ID?
    @State private var pendingDeletion: RuntimeEntry?

    private var selected: RuntimeEntry? {
        scanner.runtimes.first { $0.id == selection }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Runtimes")
                        .font(.headline)
                    Text(scanner.runtimes.isEmpty ? "" : "\(scanner.runtimes.count) installed • \(ByteText.string(scanner.runtimesFootprintBytes))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if scanner.canManageRuntimes {
                    Button(role: .destructive) {
                        pendingDeletion = selected
                    } label: {
                        Text("Delete Runtime…")
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                    .disabled(selected?.isDeletable != true || !scanner.busy.isEmpty)
                    .help(selected?.isDeletable == false ? "CoreSimulator says this runtime can't be deleted (it may ship inside Xcode)." : "Delete the selected runtime")
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            if !scanner.canManageRuntimes {
                ProFeatureNote(text: "App Store apps can't remove runtimes: macOS keeps them in a protected location. Delete them in Xcode › Settings › Components, or with SimCleaner Pro, a free download that runs outside the App Store sandbox.")
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            } else if scanner.canReadRuntimes, let error = scanner.runtimesError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 10)
            }
            Divider()

            if scanner.isLoadingRuntimes && scanner.runtimes.isEmpty {
                ProgressView("Reading runtimes…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !scanner.canReadRuntimes {
                // An unreadable list isn't an empty one.
                ContentUnavailableView {
                    Label("Couldn't read runtimes", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(scanner.runtimesError ?? "SimCleaner couldn't list the runtimes on this Mac.")
                } actions: {
                    Button("Try Again") { scanner.refreshRuntimes(force: true) }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if scanner.runtimes.isEmpty {
                ContentUnavailableView {
                    Label("No runtimes found", systemImage: "externaldrive")
                } description: {
                    Text("Xcode downloads runtimes in Settings › Components. Without one, simulators can't start.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(scanner.runtimes, selection: $selection) {
                    TableColumn("Runtime") { runtime in
                        HStack(spacing: 6) {
                            Text(runtime.title)
                            if scanner.busy[runtime.id] != nil {
                                ProgressView().controlSize(.mini)
                            }
                        }
                    }
                    TableColumn("Simulators") { runtime in
                        Text(runtime.deviceCount == 0 ? "None" : "\(runtime.deviceCount)")
                            .foregroundStyle(runtime.deviceCount == 0 ? .secondary : .primary)
                    }
                    .width(90)
                    TableColumn("Last used") { runtime in
                        Text(runtime.lastUsedAt?.relativeDescription ?? "—")
                            .foregroundStyle(.secondary)
                    }
                    .width(140)
                    TableColumn("Size") { runtime in
                        Text(ByteText.string(runtime.sizeBytes))
                            .font(.callout.weight(.semibold))
                            .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    .width(90)
                }
                .tableStyle(.inset(alternatesRowBackgrounds: true))
            }

            if !scanner.canManageRuntimes {
                Divider()
                manualInstructions
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .confirmationDialog("Delete \(pendingDeletion?.title ?? "runtime")?", isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }), titleVisibility: .visible, presenting: pendingDeletion) { runtime in
            Button("Delete", role: .destructive) {
                Task { await scanner.deleteRuntime(runtime) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { runtime in
            Text(deletionMessage(runtime))
        }
    }

    private func deletionMessage(_ runtime: RuntimeEntry) -> String {
        var text = "Frees \(ByteText.string(runtime.sizeBytes))."
        if runtime.deviceCount > 0 {
            text += " \(runtime.deviceCount) \(runtime.deviceCount == 1 ? "simulator uses" : "simulators use") it and will stop working until you download the runtime again in Xcode › Settings › Components."
        }
        return text
    }

    private var manualInstructions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Remove a runtime yourself")
                .font(.headline)
            Text("In Xcode, open Settings › Components, select a runtime you no longer use and delete it. Or list them in Terminal, then delete one by its ID:")
                .font(.callout)
                .foregroundStyle(.secondary)
            CommandRow(command: "xcrun simctl runtime list")
            CommandRow(command: "xcrun simctl runtime delete <ID>", copy: "xcrun simctl runtime delete ")
        }
        .padding(14)
    }
}

/// A Terminal command with a copy button.
struct CommandRow: View {
    let command: String
    var copy: String?
    @State private var copied = false

    var body: some View {
        HStack(spacing: 8) {
            Text(command)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(1)
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(copy ?? command, forType: .string)
                copied = true
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help("Copy command")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.gray.opacity(0.08)))
    }
}
