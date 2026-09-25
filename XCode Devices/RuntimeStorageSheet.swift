//
//  RuntimeStorageSheet.swift
//  XCode Devices
//

import AppKit
import SwiftUI

/// Explains the difference between simulator devices (which SimCleaner deletes) and simulator
/// runtimes (which macOS protects and only Xcode can remove).
struct RuntimeStorageSheet: View {
    let runtimeStorageBytes: Int64?
    @Environment(\.dismiss) private var dismiss

    private let listCommand = "xcrun simctl runtime list"
    /// Copied with a trailing space so the user pastes the runtime ID right after it.
    private let deleteCommand = "xcrun simctl runtime delete "

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                Text("Simulator runtimes")
                    .font(.title3.weight(.semibold))
                Spacer()
                if let runtimeStorageBytes {
                    Text(ByteCountFormatter.string(fromByteCount: runtimeStorageBytes, countStyle: .file))
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Every simulator in SimCleaner is a folder of device data: installed apps, settings and caches. The iOS system it runs is a separate download called a runtime. One runtime takes several gigabytes, and all simulators of that iOS version share it.")
                Text("macOS keeps runtimes in /System/Library/AssetsV2 and protects that folder. SimCleaner can't delete them, and neither can Finder. Deleting simulators here won't free that space.")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 8) {
                Text("Remove runtimes you don't need")
                    .font(.headline)
                Text("In Xcode, open Settings and go to Components. Select a runtime you no longer use and delete it.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Or use Terminal. First list the runtimes:")
                    .font(.callout)
                    .padding(.top, 4)
                commandRow(display: listCommand, copy: listCommand, help: "Copy command")
                Text("Each line ends with the runtime's ID, for example \"iOS 26.5 (23F77) - 113CA62D-9E54-4D00-9F8B-5977A4DFAFA7 (Ready)\". Copy the ID of the one you want to remove, then run this command with the ID pasted at the end:")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                commandRow(display: deleteCommand + "<ID>", copy: deleteCommand, help: "Copy the command, then paste the runtime ID after it")
                Text("Both need Xcode. If you've already removed Xcode, the runtimes stay behind, and reinstalling Xcode is the supported way to delete them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }

            HStack {
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(28)
        .frame(width: 500)
        .background(Color(.windowBackgroundColor))
    }

    private func commandRow(display: String, copy: String, help: String) -> some View {
        HStack(spacing: 8) {
            Text(display)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(1)
            Spacer()
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(copy, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .buttonStyle(.borderless)
            .help(help)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.gray.opacity(0.08))
        )
    }
}

#Preview {
    RuntimeStorageSheet(runtimeStorageBytes: 16_500_000_000)
}
