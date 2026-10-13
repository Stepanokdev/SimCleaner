//
//  StorageBar.swift
//  XCode Devices
//

import SimCleanerKit
import SwiftUI

/// One coloured segment per category, then the empty track for the space still available. The whole bar
/// is Xcode's data plus that space (`StorageOverview.barCapacity`), so freeing something visibly moves it
/// from the colour to the track.
struct StorageBar: View {
    let overview: StorageOverview
    @Binding var highlighted: StorageCategory?
    let onSelect: (StorageCategory) -> Void

    var body: some View {
        GeometryReader { geometry in
            let layout = StorageBarLayout(overview: overview, width: geometry.size.width)
            HStack(spacing: StorageBarLayout.spacing) {
                ForEach(layout.segments) { segment in
                    segmentView(segment.category)
                        .frame(width: segment.width)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background {
                Rectangle()
                    .fill(.quaternary)
                    .help(overview.volume.availableBytes > 0 ? "\(ByteText.string(overview.volume.availableBytes)) available on this disk" : "")
            }
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }
        .animation(.smooth(duration: 0.6), value: overview)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private func segmentView(_ category: StorageOverview.Category) -> some View {
        Rectangle()
            .fill(category.kind.color)
            .opacity(highlighted == nil || highlighted == category.kind ? 1 : 0.35)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { highlighted = category.kind } else if highlighted == category.kind { highlighted = nil }
            }
            .onTapGesture { onSelect(category.kind) }
            .pointerStyle(.link)
            .help(StorageLegend.helpText(for: category))
    }

    private var accessibilitySummary: String {
        var text = "Xcode data takes \(StoragePanel.total(of: overview))."
        let unreadable = overview.categories.filter { $0.measurement == .unreadable }.map(\.kind.title)
        if !unreadable.isEmpty {
            text += " Couldn't read \(unreadable.joined(separator: ", "))."
        }
        if overview.volume.availableBytes > 0 {
            text += " \(ByteText.string(overview.volume.availableBytes)) available."
        }
        return text
    }
}

/// Where each segment of the storage bar goes. A tiny category still gets a sliver, taken from the empty
/// track; only when the categories alone overflow the bar are they scaled down together.
struct StorageBarLayout: Equatable {
    struct Segment: Identifiable, Equatable {
        let category: StorageOverview.Category
        let width: CGFloat
        var id: StorageCategory { category.kind }
    }

    /// The surface gap between segments.
    static let spacing: CGFloat = 2
    static let minimumWidth: CGFloat = 3

    let segments: [Segment]

    init(overview: StorageOverview, width: CGFloat) {
        let categories = overview.segments
        let capacity = Double(max(overview.barCapacity, 1))
        let gaps = Self.spacing * CGFloat(max(categories.count - 1, 0))
        let usable = max(width - gaps, 0)
        var widths = categories.map { max(usable * CGFloat(Double($0.bytes) / capacity), Self.minimumWidth) }
        let total = widths.reduce(0, +)
        if total > usable, total > 0 {
            widths = widths.map { $0 * usable / total }
        }
        segments = zip(categories, widths).map { Segment(category: $0, width: $1) }
    }

    /// What's left for the empty track.
    func trackWidth(in width: CGFloat) -> CGFloat {
        let used = segments.reduce(0) { $0 + $1.width } + Self.spacing * CGFloat(max(segments.count - 1, 0))
        return max(width - used, 0)
    }
}

// MARK: - Legend

struct StorageLegend: View {
    let overview: StorageOverview
    @Binding var highlighted: StorageCategory?
    let onSelect: (StorageCategory) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 16) {
                ForEach(overview.categories) { category in
                    item(category)
                }
            }
            .font(.caption)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private func item(_ category: StorageOverview.Category) -> some View {
        Button {
            onSelect(category.kind)
        } label: {
            HStack(spacing: 6) {
                if category.measurement == .unreadable {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor)
                        .imageScale(.small)
                        .accessibilityHidden(true)
                } else {
                    Circle()
                        .fill(category.kind.color)
                        .frame(width: 8, height: 8)
                }
                Text(category.kind.shortTitle)
                Text(Self.value(of: category.measurement))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(category.bytes)))
            }
            .opacity(highlighted == nil || highlighted == category.kind ? 1 : 0.5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .pointerStyle(.link)
        .onHover { inside in
            if inside { highlighted = category.kind } else if highlighted == category.kind { highlighted = nil }
        }
        .help(Self.helpText(for: category))
        .accessibilityLabel("\(category.kind.title), \(Self.value(of: category.measurement))")
        .accessibilityHint(category.kind.destination)
    }

    static func value(of measurement: StorageOverview.Measurement) -> String {
        switch measurement {
        case .measuring: return "Measuring…"
        case .noAccess: return "No access"
        case .unreadable: return "Couldn't read"
        case .measured(let bytes, let isPartial): return isPartial ? "at least \(ByteText.string(bytes))" : ByteText.string(bytes)
        }
    }

    static func helpText(for category: StorageOverview.Category) -> String {
        var text = "\(category.kind.title): \(value(of: category.measurement)). \(category.kind.explanation)"
        if case .measured(_, true) = category.measurement {
            text += " Some folders couldn't be read, so there may be more."
        }
        if category.measurement == .noAccess {
            text += " SimCleaner needs access to ~/Library/Developer to measure it."
        }
        if category.measurement == .unreadable {
            text += " SimCleaner couldn't read it, so its size is unknown. Its page says why."
        }
        return text
    }
}
