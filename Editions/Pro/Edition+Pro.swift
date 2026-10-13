//
//  Edition+Pro.swift
//  SimCleaner Pro
//

import AppKit
import SwiftUI

extension AppEdition {
    static let current: AppEdition = .pro
}

/// The Pro build's toolbar button: set up the `simcleaner` command line tool.
struct EditionToolbarButton: View {
    @State private var showCommandLineSheet = false

    var body: some View {
        Button {
            showCommandLineSheet = true
        } label: {
            Label("Command Line", systemImage: "terminal")
                .labelStyle(.titleAndIcon)
        }
        .help("Use SimCleaner from Terminal or a coding agent")
        .sheet(isPresented: $showCommandLineSheet) {
            CommandLineToolSheet()
        }
    }
}

@MainActor
enum EditionHooks {
    /// Starts Sparkle, whose schedule runs from launch.
    static func launched() {
        _ = Updater.shared
    }

    static func cleanupSucceeded() {}
}

/// Shows where the bundled `simcleaner` tool lives and how to put it on the PATH.
struct CommandLineToolSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var copied: String?

    private var toolURL: URL {
        Bundle.main.bundleURL.appending(path: "Contents/MacOS/simcleaner")
    }

    /// Run from a disk image or a translocated copy, the path changes on the next launch.
    private var isInstalledInApplications: Bool {
        let path = Bundle.main.bundleURL.path
        return path.hasPrefix("/Applications/") || path.hasPrefix(NSHomeDirectory() + "/Applications/")
    }

    private var linkCommand: String {
        "sudo ln -sf \"\(toolURL.path)\" /usr/local/bin/simcleaner"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Command line tool")
                .font(.title3.weight(.semibold))

            Text("SimCleaner Pro includes `simcleaner`, a command line tool with the same rules as the app: it lists simulators and storage, suggests what to clean, and only deletes what you name. Add `--json` for scripts and coding agents.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if isInstalledInApplications {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Make it available in Terminal")
                        .font(.headline)
                    commandRow(linkCommand)
                    Text("Then try:")
                        .font(.callout)
                    commandRow("simcleaner storage")
                    commandRow("simcleaner list --json")
                }
            } else {
                Label("Move SimCleaner Pro to the Applications folder first. Opened from a disk image or Downloads, macOS runs it from a temporary location, and a link to it would break.", systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private func commandRow(_ command: String) -> some View {
        HStack(spacing: 8) {
            Text(command)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                copied = command
            } label: {
                Image(systemName: copied == command ? "checkmark" : "doc.on.doc")
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.borderless)
            .help("Copy")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.gray.opacity(0.08)))
    }
}
