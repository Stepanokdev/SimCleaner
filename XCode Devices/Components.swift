//
//  Components.swift
//  XCode Devices
//

import AppKit
import SimCleanerKit
import SwiftUI

struct Tag: View {
    let text: String
    let style: TagStyle
    /// Increased in a selected row of a focused list, where tinted text would vanish into the highlight.
    @Environment(\.backgroundProminence) private var prominence

    init(text: String, style: TagStyle = .primary) {
        self.text = text
        self.style = style
    }

    var body: some View {
        Text(text)
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule(style: .continuous).fill(prominence == .increased ? Color.white.opacity(0.22) : style.background))
            .foregroundStyle(prominence == .increased ? Color.white : style.foreground)
    }
}

enum TagStyle {
    case primary
    case running
    case warning

    var foreground: Color {
        switch self {
        case .primary: return .blue
        case .running: return .green
        case .warning: return .orange
        }
    }

    var background: Color { foreground.opacity(0.12) }
}

struct PrimaryActionButton: View {
    let title: String
    let systemImage: String
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(isDisabled)
    }
}

struct SecondaryActionButton: View {
    let title: String
    let systemImage: String
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .disabled(isDisabled)
    }
}

struct DestructiveActionButton: View {
    let title: String
    let systemImage: String
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        Button(role: .destructive, action: action) {
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
    /// In a selected row of a focused list the symbol turns white, like the row's text.
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        let visual = DeviceIcon.for(category: device.category)
        Image(systemName: visual.symbol)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .foregroundStyle(prominence == .increased ? Color.white : visual.foreground)
            .fontWeight(weight)
            .opacity(device.isAvailable == false ? 0.45 : 1)
    }
}

struct DeviceIcon {
    let symbol: String
    let foreground: Color
    let background: Color

    static func `for`(category: DeviceCategory) -> DeviceIcon {
        switch category {
        case .iPhone: return .init(symbol: "iphone", foreground: .blue, background: .blue)
        case .iPad: return .init(symbol: "ipad", foreground: .purple, background: .purple)
        case .Watch: return .init(symbol: "applewatch", foreground: .green, background: .green)
        case .TV: return .init(symbol: "appletv", foreground: .indigo, background: .indigo)
        case .Vision: return .init(symbol: "visionpro", foreground: .orange, background: .orange)
        case .Other: return .init(symbol: "questionmark.app", foreground: .gray, background: .gray)
        }
    }
}

struct AppIconView: View {
    let app: SimulatorApp

    var body: some View {
        if let iconURL = app.icon, let image = NSImage(contentsOf: iconURL) {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .scaledToFit()
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
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

/// Sorts "iOS 27.0" above "iOS 26.5" in the sidebar.
struct RuntimeSortKey: Comparable {
    let platform: String
    let major: Int
    let minor: Int

    static func < (lhs: RuntimeSortKey, rhs: RuntimeSortKey) -> Bool {
        if lhs.platform != rhs.platform { return lhs.platform < rhs.platform }
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        return lhs.minor < rhs.minor
    }

    init(_ runtime: String) {
        let components = runtime.split(separator: " ")
        platform = components.first.map(String.init) ?? "iOS"
        let parts = (components.count > 1 ? components[1] : "").split(separator: ".")
        major = Int(parts.first ?? "0") ?? 0
        minor = parts.count > 1 ? Int(parts[1]) ?? 0 : 0
    }
}

/// The App Store edition before the person has picked ~/Library/Developer: every page says the same thing
/// and offers the same button, instead of waiting for a scan that can't start.
struct FolderAccessNeededView: View {
    let onRequestAccess: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("SimCleaner needs access to your Developer folder", systemImage: "folder.badge.questionmark")
        } description: {
            Text("Choose ~/Library/Developer. That's where Xcode keeps simulators, Preview devices, test clones and build caches.")
        } actions: {
            Button("Allow Access…", action: onRequestAccess)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Shown in the App Store edition where a feature needs the Pro build. Pro is free; this only says where it is.
struct ProFeatureNote: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "sparkles")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(text)
                Link("About SimCleaner Pro", destination: AppEdition.editionsURL)
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.gray.opacity(0.07)))
    }
}

/// Asks for a simulator name, for Duplicate and Rename.
struct NamePromptSheet: View {
    let title: String
    let message: String
    let confirmTitle: String
    @State var name: String
    let onConfirm: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(confirm)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(confirmTitle, action: confirm)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmed.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private func confirm() {
        guard !trimmed.isEmpty else { return }
        onConfirm(trimmed)
        dismiss()
    }
}

/// A thin strip above a list while a batch runs. The window stays usable.
struct BulkProgressStrip: View {
    let progress: BulkProgress

    var body: some View {
        HStack(spacing: 12) {
            ProgressView(value: progress.fraction)
                .progressViewStyle(.linear)
                .frame(maxWidth: 220)
            Text("\(progress.title) · \(progress.completed + 1) of \(progress.total)")
                .font(.caption)
                .monospacedDigit()
            Text(progress.current)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(Color.accentColor.opacity(0.06))
    }
}

extension View {
    @ViewBuilder
    func optionalHelp(_ text: String?) -> some View {
        if let text, !text.isEmpty {
            self.help(text)
        } else {
            self
        }
    }
}
