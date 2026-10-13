//
//  CleanupViews.swift
//  XCode Devices
//

import SimCleanerKit
import SwiftUI

// MARK: - Suggestions

/// What the Suggestions page shows. Kept apart from the view so each state can be tested.
nonisolated enum SuggestionsState: Equatable {
    case needsAccess
    /// The scan failed, so there's no list to judge.
    case failed(String)
    case scanning
    /// Everything was read, and nothing is worth cleaning.
    case nothingToClean
    /// Nothing to suggest in what could be read, but some folders or simulators couldn't be: no all-clear.
    case nothingInWhatWasRead
    /// `isPartial`: some folders or simulators couldn't be read, so there may be more to clean.
    case suggestions(isPartial: Bool)

    static func resolve(hasFolderAccess: Bool, errorMessage: String?, hasCompletedScan: Bool, isScanPartial: Bool, suggestionCount: Int) -> SuggestionsState {
        guard hasFolderAccess else { return .needsAccess }
        if let errorMessage { return .failed(errorMessage) }
        guard hasCompletedScan else { return .scanning }
        if suggestionCount == 0 { return isScanPartial ? .nothingInWhatWasRead : .nothingToClean }
        return .suggestions(isPartial: isScanPartial)
    }

    /// The line under the page title. `total` is what the suggestions add up to.
    func subtitle(total: DiskFootprint) -> String {
        switch self {
        case .needsAccess, .failed, .scanning: return ""
        case .nothingToClean: return "Nothing to clean up right now"
        case .nothingInWhatWasRead: return "Nothing to clean up in what SimCleaner could read"
        case .suggestions(let isPartial):
            let freed = "Up to \(ByteText.string(total.allocatedBytes)) can be freed"
            return isPartial ? freed + " in what SimCleaner could read" : freed
        }
    }
}

/// Smart Cleanup on top: one button for what Xcode makes again by itself and nothing used for the chosen
/// period, preselected the way CleanMyMac's Smart Care is. Below it, what's up to the person: simulators and
/// folders that hold something they may want, each with its own button.
struct SmartCleanupView: View {
    @ObservedObject var scanner: DeviceScanner
    @Binding var idleDays: Int
    let onAction: (PendingDeviceAction) -> Void
    let showDevice: (SimulatorDevice) -> Void

    @State private var pendingLeftovers: [LeftoverFolder]?
    @State private var selectedGroups = Set(SmartCleanupPlan.Group.allCases)
    @State private var expandedGroups: Set<SmartCleanupPlan.Group> = []
    /// The plan as it was when Clean Up was pressed: what the dialog lists is exactly what may go.
    @State private var confirming: SmartCleanupConfirmation?

    var body: some View {
        let plan = scanner.smartPlan
        let planned = Set(plan?.targets.map(\.id) ?? [])
        // Smart Cleanup already takes care of these; offering them twice could also mean two actions on one item.
        let suggestions = scanner.cleanupSuggestions(idleDays: idleDays).compactMap { $0.excluding(planned) }
        let state = SuggestionsState.resolve(
            hasFolderAccess: scanner.hasFolderAccess,
            errorMessage: scanner.errorMessage,
            hasCompletedScan: scanner.hasCompletedScan,
            isScanPartial: scanner.isScanPartial,
            suggestionCount: suggestions.count + ((plan?.targets.isEmpty ?? true) ? 0 : 1)
        )

        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Smart Cleanup")
                        .font(.headline)
                    Text(subtitle(state: state, plan: plan, suggestions: suggestions))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer()
                Picker("Not used for", selection: $idleDays) {
                    Text("7 days").tag(7)
                    Text("14 days").tag(14)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                }
                .fixedSize()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            if let bulk = scanner.bulkProgress {
                BulkProgressStrip(progress: bulk)
            }
            if state == .suggestions(isPartial: true) || state == .nothingInWhatWasRead {
                // What's listed stays; it just may not be all of it.
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("\(scanner.unreadableSummary) There may be more to clean up.")
                        .foregroundStyle(.secondary)
                    Button("Scan Again") { scanner.refresh() }
                        .buttonStyle(.link)
                        .disabled(scanner.isLoading)
                }
                .font(.caption)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.bottom, 8)
            }
            Divider()

            switch state {
            case .needsAccess:
                FolderAccessNeededView { scanner.chooseDevicesDirectory() }
            case .failed(let error):
                // Without a list there's nothing to judge; "nothing to clean up" would be a guess.
                ContentUnavailableView {
                    Label("Couldn't read your simulators", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(error)
                } actions: {
                    Button("Try Again") { scanner.refresh() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .scanning:
                ProgressView("Scanning simulators…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .nothingToClean, .nothingInWhatWasRead, .suggestions:
                ScrollView {
                    VStack(alignment: .leading, spacing: 28) {
                        SmartCleanupCard(
                            plan: plan,
                            isPlanning: plan == nil || !scanner.hasScannedDeveloperStorage && scanner.coversDeveloperFolder,
                            isCleaning: scanner.isCleaningUp,
                            canDeleteSimulators: scanner.canManageDevices,
                            result: scanner.lastSmartCleanup,
                            idleDays: idleDays,
                            selectedGroups: $selectedGroups,
                            expandedGroups: $expandedGroups,
                            busy: !scanner.busy.isEmpty
                        ) { plan, groups in
                            confirming = SmartCleanupConfirmation(plan: plan, groups: groups)
                        }
                        if !suggestions.isEmpty {
                            upToYou(suggestions)
                        }
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        // Short content such as an empty state stays under the header instead of floating mid-column.
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .confirmationDialog(confirming?.title ?? "", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }), titleVisibility: .visible, presenting: confirming) { confirmation in
            Button("Clean Up", role: .destructive) {
                Task { await scanner.cleanUp(confirmation.plan, groups: confirmation.groups) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { confirmation in
            Text(confirmation.message)
        }
        .confirmationDialog("Remove \(pendingLeftovers?.count ?? 0) leftover folders?", isPresented: Binding(get: { pendingLeftovers != nil }, set: { if !$0 { pendingLeftovers = nil } }), titleVisibility: .visible, presenting: pendingLeftovers) { leftovers in
            Button("Remove", role: .destructive) {
                Task { await scanner.removeLeftovers(leftovers) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { leftovers in
            Text("Frees \(ByteText.freed(leftovers.reduce(.zero) { $0 + $1.footprint })). CoreSimulator doesn't list these folders, so nothing uses them.")
        }
    }

    private func subtitle(state: SuggestionsState, plan: SmartCleanupPlan?, suggestions: [CleanupSuggestion]) -> String {
        guard case .suggestions(let isPartial) = state else { return state.subtitle(total: .zero) }
        let rest = suggestions.reduce(DiskFootprint.zero) { $0 + $1.footprint }
        var parts: [String] = []
        if let plan, !plan.targets.isEmpty { parts.append("\(ByteText.freed(plan.footprint)) can go now") }
        if rest.allocatedBytes > 0 { parts.append(parts.isEmpty ? "Up to \(ByteText.string(rest.allocatedBytes)) is up to you" : "\(ByteText.string(rest.allocatedBytes)) more is up to you") }
        let text = parts.joined(separator: ", ")
        return isPartial ? text + " in what SimCleaner could read" : text
    }

    private func upToYou(_ suggestions: [CleanupSuggestion]) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Up to you")
                    .font(.title3.weight(.semibold))
                Text("These can hold apps, data or files someone still wants, so Smart Cleanup leaves them for you to decide.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(suggestions) { suggestion in
                SuggestionSection(
                    suggestion: suggestion,
                    scanner: scanner,
                    showDevice: showDevice
                ) {
                    switch suggestion.action {
                    case .erase where scanner.canManageDevices:
                        onAction(PendingDeviceAction(kind: .erase, devices: suggestion.devices))
                    case .erase, .delete:
                        if suggestion.devices.isEmpty {
                            pendingLeftovers = suggestion.leftovers
                        } else {
                            onAction(PendingDeviceAction(kind: .delete, devices: suggestion.devices))
                        }
                    }
                }
            }
        }
    }
}

/// What the Clean Up dialog lists, frozen when the button was pressed.
struct SmartCleanupConfirmation {
    let plan: SmartCleanupPlan
    let groups: Set<SmartCleanupPlan.Group>

    private var targets: [SmartCleanupPlan.Target] {
        plan.targets.filter { groups.contains($0.group) }
    }

    var title: String {
        "Clean up \(ByteText.freed(targets.reduce(.zero) { $0 + $1.footprint }))?"
    }

    var message: String {
        let parts = SmartCleanupPlan.Group.allCases.compactMap { group -> String? in
            let count = targets.filter { $0.group == group }.count
            return count > 0 ? group.countPhrase(count) : nil
        }
        var text = "Removes \(ListFormatter.localizedString(byJoining: parts)). Xcode makes them again when it needs them"
        if groups.contains(.derivedData) && targets.contains(where: { $0.group == .derivedData }) {
            text += "; the next build of each project starts from scratch"
        }
        return text + ". Anything used since SimCleaner looked stays."
    }
}

extension SmartCleanupPlan.Group {
    var title: String {
        switch self {
        case .derivedData: return "DerivedData"
        case .deviceSupport: return "Older device support"
        case .toolSimulators: return "Preview and test simulators"
        case .agentWorkspaces: return "Coding agent workspaces"
        }
    }

    func reason(idleDays: Int) -> String {
        switch self {
        case .derivedData: return "Projects Xcode hasn't opened for \(idleDays) days. The next build of each starts from scratch."
        case .deviceSupport: return "Symbols for OS versions your devices have moved on from. Xcode copies them again if one connects."
        case .toolSimulators: return "Made by Xcode for SwiftUI Previews, tests and playgrounds, and unused for \(idleDays) days."
        case .agentWorkspaces: return "Build folders agents left and haven't touched for \(idleDays) days."
        }
    }

    func countPhrase(_ count: Int) -> String {
        switch self {
        case .derivedData: return count == 1 ? "DerivedData of 1 project" : "DerivedData of \(count) projects"
        case .deviceSupport: return count == 1 ? "1 older device support version" : "\(count) older device support versions"
        case .toolSimulators: return count == 1 ? "1 Preview or test simulator" : "\(count) Preview and test simulators"
        case .agentWorkspaces: return count == 1 ? "1 agent workspace" : "\(count) agent workspaces"
        }
    }

    /// "3 projects", for the row's size.
    func itemCount(_ count: Int) -> String {
        let noun: String
        switch self {
        case .derivedData: noun = count == 1 ? "project" : "projects"
        case .deviceSupport: noun = count == 1 ? "version" : "versions"
        case .toolSimulators: noun = count == 1 ? "simulator" : "simulators"
        case .agentWorkspaces: noun = count == 1 ? "workspace" : "workspaces"
        }
        return "\(count) \(noun)"
    }

    var systemImage: String {
        switch self {
        case .derivedData: return "hammer"
        case .deviceSupport: return "cable.connector.horizontal"
        case .toolSimulators: return "rectangle.on.rectangle"
        case .agentWorkspaces: return "terminal"
        }
    }

    /// The color the storage bar gives the same kind of data.
    var color: Color {
        switch self {
        case .derivedData: return StorageCategory.derivedData.color
        case .deviceSupport: return StorageCategory.deviceSupport.color
        case .toolSimulators: return StorageCategory.simulators.color
        case .agentWorkspaces: return StorageCategory.agentWorkspaces.color
        }
    }
}

/// The summary at the top of Smart Cleanup: how much can go, the groups it comes from, and one button.
private struct SmartCleanupCard: View {
    let plan: SmartCleanupPlan?
    let isPlanning: Bool
    let isCleaning: Bool
    /// Preview and test simulators go through Xcode's simulator tools.
    let canDeleteSimulators: Bool
    let result: SmartCleanupResult?
    let idleDays: Int
    @Binding var selectedGroups: Set<SmartCleanupPlan.Group>
    @Binding var expandedGroups: Set<SmartCleanupPlan.Group>
    let busy: Bool
    let onCleanUp: (SmartCleanupPlan, Set<SmartCleanupPlan.Group>) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var groups: [SmartCleanupPlan.Group] {
        SmartCleanupPlan.Group.allCases.filter { group in
            guard let plan, !plan.targets(in: group).isEmpty else { return false }
            return group != .toolSimulators || canDeleteSimulators
        }
    }

    private var chosen: Set<SmartCleanupPlan.Group> { selectedGroups.intersection(groups) }

    private var chosenFootprint: DiskFootprint {
        plan?.targets.filter { chosen.contains($0.group) }.reduce(.zero) { $0 + $1.footprint } ?? .zero
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: groups.isEmpty && !isPlanning ? "checkmark.seal" : "sparkles")
                    .font(.title2)
                    .foregroundStyle(.tint)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(.tint.opacity(0.12)))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(headline)
                        .font(.title3.weight(.semibold))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(chosenFootprint.allocatedBytes)))
                        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: chosenFootprint.allocatedBytes)
                    Text(explanation)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                if !groups.isEmpty, let plan {
                    Button {
                        onCleanUp(plan, chosen)
                    } label: {
                        HStack(spacing: 6) {
                            if isCleaning {
                                ProgressView().controlSize(.small)
                            }
                            Text(isCleaning ? "Cleaning Up…" : "Clean Up…")
                        }
                        .frame(minWidth: 110)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(chosen.isEmpty || isCleaning || busy)
                }
            }

            if let result {
                SmartCleanupResultRow(result: result)
                    .transition(reduceMotion ? AnyTransition.opacity : AnyTransition(.blurReplace))
            }

            if isPlanning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking at Xcode's folders…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else if !groups.isEmpty, let plan {
                VStack(spacing: 0) {
                    ForEach(groups) { group in
                        if group != groups.first { Divider().padding(.leading, 46) }
                        groupRow(group, targets: plan.targets(in: group))
                    }
                }
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.background))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(.separator))
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.gray.opacity(0.06)))
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: result)
    }

    private var headline: String {
        if isPlanning { return "Smart Cleanup" }
        if groups.isEmpty { return "Nothing can go on its own" }
        if chosen.isEmpty { return "Nothing selected" }
        return "\(ByteText.freed(chosenFootprint)) can go now"
    }

    private var explanation: String {
        if isPlanning { return "SimCleaner is checking when each item was last used." }
        if groups.isEmpty { return "Everything Xcode would make again by itself was used in the last \(idleDays) days." }
        return "Xcode makes all of it again when it's needed, and none of it was used in the last \(idleDays) days."
    }

    private func groupRow(_ group: SmartCleanupPlan.Group, targets: [SmartCleanupPlan.Target]) -> some View {
        let expanded = expandedGroups.contains(group)
        let footprint = targets.reduce(DiskFootprint.zero) { $0 + $1.footprint }
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                Toggle(isOn: Binding(
                    get: { selectedGroups.contains(group) },
                    set: { on in if on { selectedGroups.insert(group) } else { selectedGroups.remove(group) } }
                )) {
                    EmptyView()
                }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .accessibilityLabel(group.title)
                .disabled(isCleaning)
                Image(systemName: group.systemImage)
                    .foregroundStyle(group.color)
                    .frame(width: 18)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.title)
                        .font(.body.weight(.medium))
                    Text(group.reason(idleDays: idleDays))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    Text(ByteText.freed(footprint))
                        .font(.callout.weight(.semibold))
                        .monospacedDigit()
                    Text(group.itemCount(targets.count))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button {
                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) {
                        if expanded { expandedGroups.remove(group) } else { expandedGroups.insert(group) }
                    }
                } label: {
                    Image(systemName: "chevron.right")
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .frame(width: 20, height: 20)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .help(expanded ? "Hide the items" : "Show the items")
                .accessibilityLabel(expanded ? "Hide the \(targets.count) items" : "Show the \(targets.count) items")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            if expanded {
                VStack(spacing: 4) {
                    ForEach(targets) { target in
                        SmartCleanupItemRow(target: target)
                    }
                }
                .padding(.leading, 46)
                .padding(.trailing, 12)
                .padding(.bottom, 10)
            }
        }
    }
}

private struct SmartCleanupItemRow: View {
    let target: SmartCleanupPlan.Target

    private var detail: String? {
        switch target.item {
        case .folder(let folder): return folder.detail
        case .simulator(let device): return [device.setKind.badge, device.runtime].compactMap { $0 }.joined(separator: " · ")
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(target.name)
                    .font(.callout)
                    .lineLimit(1)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 8)
            Text("Last used \(target.lastActivity.relativeDescription.lowercasedFirst)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(ByteText.string(target.footprint.allocatedBytes))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(minWidth: 64, alignment: .trailing)
            Button {
                SimulatorLauncher.reveal(target.url)
            } label: {
                Image(systemName: "magnifyingglass")
            }
            .buttonStyle(.borderless)
            .help("Reveal in Finder")
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 10)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.gray.opacity(0.06)))
    }
}

/// What the last Smart Cleanup did, under the headline until the next one.
private struct SmartCleanupResultRow: View {
    let result: SmartCleanupResult
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var headline: String {
        if result.freedBytes > 0 { return "Freed about \(ByteText.string(result.freedBytes))" }
        return result.failures.isEmpty ? "Nothing was removed" : "Nothing could be removed"
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: result.freedBytes > 0 ? "checkmark.circle.fill" : "info.circle")
                .foregroundStyle(result.freedBytes > 0 ? Color.green : Color.secondary)
                .symbolEffect(.bounce, value: reduceMotion ? 0 : result.freedBytes)
            VStack(alignment: .leading, spacing: 2) {
                Text(headline)
                    .font(.callout.weight(.semibold))
                if !result.skipped.isEmpty {
                    Text(result.skipped.count == 1
                        ? "1 item was used or changed since SimCleaner looked, so it stayed."
                        : "\(result.skipped.count) items were used or changed since SimCleaner looked, so they stayed.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help(result.skipped.joined(separator: "\n"))
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill((result.freedBytes > 0 ? Color.green : Color.gray).opacity(0.08)))
        .accessibilityElement(children: .combine)
    }
}

private extension String {
    /// "2 weeks ago" from "2 weeks ago", "just now" from "Just now".
    var lowercasedFirst: String {
        guard let first else { return self }
        return first.lowercased() + dropFirst()
    }
}

private struct SuggestionSection: View {
    let suggestion: CleanupSuggestion
    @ObservedObject var scanner: DeviceScanner
    let showDevice: (SimulatorDevice) -> Void
    let onAction: () -> Void

    private var actionTitle: String {
        let count = suggestion.devices.isEmpty ? suggestion.leftovers.count : suggestion.devices.count
        let noun = suggestion.devices.isEmpty ? (count == 1 ? "folder" : "folders") : (count == 1 ? "simulator" : "simulators")
        switch suggestion.action {
        case .erase where scanner.canManageDevices: return "Erase \(count) \(noun)…"
        case .erase, .delete: return suggestion.devices.isEmpty ? "Remove \(count) \(noun)…" : "Delete \(count) \(noun)…"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(suggestion.title)
                    .font(.title3.weight(.semibold))
                Spacer()
                Text(ByteText.freed(suggestion.footprint))
                    .font(.callout.weight(.semibold))
                    .monospacedDigit()
            }
            Text(suggestion.detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if !suggestion.devices.isEmpty && !scanner.canManageDevices {
                Text(scanner.canDeleteDevices && suggestion.action == .erase
                    ? "Erasing needs Xcode's simulator tools, which aren't available. Deleting still works."
                    : "This needs Xcode's simulator tools, which aren't available right now.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 6) {
                ForEach(suggestion.devices) { device in
                    Button {
                        showDevice(device)
                    } label: {
                        HStack(spacing: 10) {
                            DeviceIconView(device: device, size: 18, weight: .regular)
                                .frame(width: 24, height: 24)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(device.name).font(.callout).lineLimit(1)
                                Text("\(device.runtime) • \(device.lastUsedDescription)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            if let work = scanner.busyLabel(for: device) {
                                ProgressView().controlSize(.small)
                                Text(work).font(.caption).foregroundStyle(.secondary)
                            } else {
                                Text(device.sizeDescription).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.vertical, 6)
                        .padding(.horizontal, 10)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.gray.opacity(0.06)))
                    .help("Show in the simulator list")
                }
                ForEach(suggestion.leftovers) { leftover in
                    HStack(spacing: 10) {
                        Image(systemName: "folder")
                            .foregroundStyle(.secondary)
                            .frame(width: 24, height: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(leftover.url.lastPathComponent).font(.system(.callout, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                            Text(leftover.deviceSet.kind.badge ?? "Simulators").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(ByteText.string(leftover.footprint.allocatedBytes)).font(.caption).foregroundStyle(.secondary)
                        Button {
                            SimulatorLauncher.reveal(leftover.url)
                        } label: {
                            Image(systemName: "magnifyingglass")
                        }
                        .buttonStyle(.borderless)
                        .help("Reveal in Finder")
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 10)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.gray.opacity(0.06)))
                }
            }

            HStack {
                Spacer()
                Button(role: .destructive, action: onAction) {
                    Text(actionTitle)
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .disabled(!scanner.busy.isEmpty || !canAct)
            }
        }
    }

    /// Leftover folders can always go; simulators need simctl, or no CoreSimulator on the Mac at all.
    private var canAct: Bool {
        if suggestion.devices.isEmpty { return true }
        if suggestion.action == .erase && scanner.canManageDevices { return true }
        return scanner.canDeleteDevices
    }
}

// MARK: - Xcode caches

/// DerivedData, device support files and coding agent workspaces, one category at a time.
struct XcodeCachesView: View {
    @ObservedObject var scanner: DeviceScanner
    /// Owned by the window, so the storage bar can open a category.
    @Binding var category: DeveloperStorageCategory
    @State private var selection: Set<String> = []
    @State private var sortOrder: [KeyPathComparator<DeveloperStorageItem>] = [KeyPathComparator(\.footprint.allocatedBytes, order: .reverse)]
    @State private var pendingRemoval: [DeveloperStorageItem]?

    private var items: [DeveloperStorageItem] {
        scanner.developerStorage.items(in: category).sorted(using: sortOrder)
    }

    private var selectedItems: [DeveloperStorageItem] {
        items.filter { selection.contains($0.id) }
    }

    /// This category's folders that SimCleaner couldn't open, as paths inside ~/Library/Developer.
    private var unreadableFolders: [String] {
        let developer = scanner.developerFolder.standardizedFileURL.path + "/"
        return scanner.developerStorage.unreadableLocations
            .filter { category.contains($0) }
            .map { url in
                let path = url.standardizedFileURL.path
                return path.hasPrefix(developer) ? String(path.dropFirst(developer.count)) : path
            }
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Xcode caches")
                            .font(.headline)
                        HStack(spacing: 6) {
                            Text(headerSubtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                            if scanner.developerStorageState == .ready && scanner.isScanningDeveloperStorage {
                                ProgressView()
                                    .controlSize(.mini)
                                    .help("Measuring again…")
                            }
                        }
                    }
                    Spacer()
                    Picker("Category", selection: $category) {
                        ForEach(DeveloperStorageCategory.allCases, id: \.self) { category in
                            Text(category.title).tag(category)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                Text(category.explanation)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if scanner.developerStorageState == .ready && !items.isEmpty && !unreadableFolders.isEmpty {
                    Label("Couldn't open \(unreadableFolders.joined(separator: ", ")), so there may be more.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            if let bulk = scanner.bulkProgress {
                BulkProgressStrip(progress: bulk)
            }
            Divider()
            content
            if !items.isEmpty {
                Divider()
                footer
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onChange(of: category) { _, _ in selection = [] }
        .confirmationDialog("Remove \(pendingRemoval?.count ?? 0) items?", isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }), titleVisibility: .visible, presenting: pendingRemoval) { removal in
            Button("Remove", role: .destructive) {
                Task { await scanner.remove(removal) }
                selection = []
            }
            Button("Cancel", role: .cancel) {}
        } message: { removal in
            Text(removalMessage(removal))
        }
    }

    private var headerSubtitle: String {
        switch scanner.developerStorageState {
        case .ready:
            let total = ByteText.string(scanner.developerStorage.footprint.allocatedBytes)
            // A folder that couldn't be opened may hold more.
            return scanner.developerStorage.unreadableLocations.isEmpty ? "\(total) in total" : "at least \(total) in total"
        case .measuring: return "Measuring…"
        case .needsAccess, .notCovered: return "Not measured yet"
        }
    }

    @ViewBuilder
    private var content: some View {
        switch scanner.developerStorageState {
        case .needsAccess:
            FolderAccessNeededView { scanner.chooseDevicesDirectory() }
        case .notCovered:
            ContentUnavailableView {
                Label("SimCleaner can't see Xcode's folders", systemImage: "folder.badge.questionmark")
            } description: {
                Text("Xcode caches live in ~/Library/Developer. Choose that folder (not one inside it) to see them.")
            } actions: {
                Button("Choose Developer Folder…") { scanner.chooseDevicesDirectory() }
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .measuring:
            ProgressView("Measuring Xcode caches…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .ready:
            cachesList
        }
    }

    @ViewBuilder
    private var cachesList: some View {
        if items.isEmpty && !unreadableFolders.isEmpty {
            // Nothing is listed because nothing could be read, which is not the same as nothing there.
            ContentUnavailableView {
                Label("Couldn't read \(category.nameInSentence)", systemImage: "exclamationmark.triangle")
            } description: {
                Text("SimCleaner couldn't open \(unreadableFolders.joined(separator: ", ")) in your Developer folder, so it can't say what's there or how much it takes.")
            } actions: {
                Button("Try Again") { scanner.refreshDeveloperStorage(force: true) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if items.isEmpty {
            ContentUnavailableView {
                Label("No \(category.nameInSentence)", systemImage: "checkmark.circle")
            } description: {
                Text(category == .agentWorkspaces ? "No coding agent has left build folders here." : "Nothing here takes space right now.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Table(items, selection: $selection, sortOrder: $sortOrder) {
                TableColumn("Name", value: \.title) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(item.title).lineLimit(1)
                            if scanner.busy[item.id] != nil {
                                ProgressView().controlSize(.mini)
                            }
                        }
                        if let detail = item.detail {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                TableColumn("Suggested", value: \.isRecommendedSortKey) { item in
                    if let recommendation = item.recommendation {
                        Label("Suggested", systemImage: "wand.and.sparkles")
                            .labelStyle(.titleAndIcon)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .help(recommendation)
                    }
                }
                .width(110)
                TableColumn("Last used", value: \.lastModifiedSortKey) { item in
                    Text(item.lastModifiedAt?.relativeDescription ?? "—")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .width(140)
                TableColumn("Size", value: \.footprint.allocatedBytes) { item in
                    Text(ByteText.string(item.footprint.allocatedBytes))
                        .font(.callout.weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .help(item.footprint.sharedBytes > 0 ? "Frees \(ByteText.freed(item.footprint)): some files share disk blocks with others." : "")
                }
                .width(90)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))
            .contextMenu(forSelectionType: String.self) { ids in
                Button("Reveal in Finder") {
                    for item in items where ids.contains(item.id) { SimulatorLauncher.reveal(item.url) }
                }
            }
        }
    }

    private var footer: some View {
        let suggested = items.filter(\.isRecommended)
        let selectedFootprint = selectedItems.reduce(DiskFootprint.zero) { $0 + $1.footprint }
        return HStack(spacing: 12) {
            Button("Select Suggested (\(suggested.count))") {
                selection = Set(suggested.map(\.id))
            }
            .disabled(suggested.isEmpty)
            Button("Select All") {
                selection = Set(items.map(\.id))
            }
            Spacer()
            if !selectedItems.isEmpty {
                Text("\(selectedItems.count) selected • frees \(ByteText.freed(selectedFootprint))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Button(role: .destructive) {
                pendingRemoval = selectedItems
            } label: {
                Text("Remove…")
            }
            .buttonStyle(.bordered)
            .tint(.red)
            .disabled(selectedItems.isEmpty || !scanner.busy.isEmpty)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func removalMessage(_ items: [DeveloperStorageItem]) -> String {
        let footprint = items.reduce(DiskFootprint.zero) { $0 + $1.footprint }
        var text = "Frees \(ByteText.freed(footprint))."
        switch category {
        case .derivedData:
            text += " Quit Xcode first if it's building one of these projects. The next build of each project starts from scratch."
        case .deviceSupport:
            text += " Xcode copies the symbols again the next time you connect a device on that OS version."
        case .agentWorkspaces:
            text += " Make sure no coding agent is still working in them."
        }
        return text
    }
}

extension DeveloperStorageItem {
    var isRecommendedSortKey: Int { isRecommended ? 1 : 0 }
    var lastModifiedSortKey: Date { lastModifiedAt ?? .distantPast }
}

// MARK: - Detail column for the cleanup pages

struct CleanupDetailView: View {
    @ObservedObject var scanner: DeviceScanner
    let page: SidebarSelection

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                switch page {
                case .suggestions:
                    section("What Smart Cleanup picks", "Only what Xcode makes again by itself: DerivedData of projects you haven't opened, symbols for OS versions your devices have moved on from, simulators Xcode created for previews and tests, and the build folders coding agents leave. And only once nothing has used them for the period you choose. If SimCleaner can't read when something was last used, it never picks it.")
                    section("Checked again before it goes", "Right before removing an item, SimCleaner reads it again. Anything opened, rebuilt or replaced since it looked stays where it is, and a simulator goes only while it's shut down.")
                    section("Erase or delete?", "Erasing removes a simulator's apps, data and settings and keeps it in Xcode and Device Hub, as fresh as when it was created. Deleting removes it everywhere; create it again in Device Hub if you need it.")
                    section("Why sizes are ranges", "Simulators share files through APFS clones: installing the same build in several simulators doesn't copy it. Those shared blocks are freed only when nothing uses them anymore, so SimCleaner shows the least and the most a cleanup frees.")
                case .xcodeCaches:
                    section("Safe to remove", "Everything here is rebuilt or copied again by Xcode when it's needed. Removing it costs time later, not data: a full rebuild, or reconnecting a device.")
                    if scanner.isSandboxed {
                        section("Projects that moved", "The App Store edition can only see the folder you granted, so it can't tell whether a project still exists. SimCleaner Pro marks DerivedData whose project is gone.")
                    }
                case .runtimes:
                    section("Runtimes and simulators", "A runtime is the OS image simulators run on. One runtime takes several gigabytes, and every simulator of that OS version shares it. Deleting simulators doesn't free it.")
                    if !scanner.canReadSimulatorCaches {
                        section("Simulator system caches", "SimCleaner couldn't read \(RuntimeInventory.dyldCachesRoot.path), so it can't say how much CoreSimulator's caches take.")
                    } else if !scanner.dyldCaches.isEmpty {
                        dyldCaches
                    }
                default:
                    EmptyView()
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func section(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.headline)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var dyldCaches: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Simulator system caches")
                .font(.headline)
            Text("CoreSimulator builds a cache per runtime for each macOS version, in /Library/Developer/CoreSimulator/Caches. Caches built for an older macOS aren't used after an update.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(scanner.dyldCaches) { cache in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(cache.runtimeName).font(.callout)
                        Text(cache.isForCurrentMacOS ? "For this macOS (\(cache.macOSBuild))" : "For macOS \(cache.macOSBuild), no longer used")
                            .font(.caption)
                            .foregroundStyle(cache.isForCurrentMacOS ? Color.secondary : Color.orange)
                    }
                    Spacer()
                    Text(ByteText.string(cache.footprint.allocatedBytes))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.gray.opacity(0.06)))
            }
            if scanner.dyldCaches.contains(where: { !$0.isForCurrentMacOS }) {
                Text("macOS owns these folders, so SimCleaner leaves them alone. `xcrun simctl runtime dyld_shared_cache remove --all` clears every cache in Terminal; CoreSimulator rebuilds the one it needs the next time a simulator starts, which takes a few minutes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

extension DeveloperStorageCategory {
    /// The name inside a sentence: "No DerivedData", "Couldn't read device support files".
    var nameInSentence: String {
        self == .derivedData ? title : title.lowercased()
    }
}
