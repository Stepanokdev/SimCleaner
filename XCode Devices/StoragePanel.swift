//
//  StoragePanel.swift
//  XCode Devices
//

import SimCleanerKit
import SwiftUI

/// The bar under every page: what each kind of Xcode data takes next to the space still available, and
/// what this session has freed. Clicking a category opens the page that cleans it.
struct StoragePanel: View {
    @ObservedObject var scanner: DeviceScanner
    @ObservedObject var session: CleanupSession
    let onSelect: (StorageCategory) -> Void
    let onRequestAccess: () -> Void

    /// The category under the pointer, in the bar or the legend; the others dim.
    @State private var highlighted: StorageCategory?

    var body: some View {
        let overview = scanner.storageOverview
        VStack(alignment: .leading, spacing: 8) {
            header(overview)
            if scanner.hasFolderAccess {
                StorageBar(overview: overview, highlighted: $highlighted, onSelect: onSelect)
                    .frame(height: 14)
                StorageLegend(overview: overview, highlighted: $highlighted, onSelect: onSelect)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 12)
    }

    private func header(_ overview: StorageOverview) -> some View {
        HStack(alignment: .center, spacing: 8) {
            Text("Xcode data")
                .font(.headline)
            if scanner.hasFolderAccess {
                Text(Self.total(of: overview))
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(overview.measuredBytes)))
                    .animation(.smooth, value: overview.measuredBytes)
                    .help(overview.isExact ? "Everything SimCleaner measures in Xcode's folders" : "Some of Xcode's data isn't measured yet or couldn't be read, so there's at least this much")
                if scanner.isMeasuring {
                    ProgressView()
                        .controlSize(.mini)
                        .help("Measuring…")
                }
            } else {
                Text("Give SimCleaner access to your Developer folder to measure it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Button("Allow Access…", action: onRequestAccess)
                    .buttonStyle(.link)
                    .font(.callout)
            }
            Spacer(minLength: 12)
            FreedSpaceBadge(session: session)
            if overview.volume.availableBytes > 0 {
                Text("\(ByteText.string(overview.volume.availableBytes)) available")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(overview.volume.availableBytes)))
                    .animation(.smooth, value: overview.volume.availableBytes)
                    .help("Free space on this disk, as Finder counts it")
            }
        }
    }
}

extension StoragePanel {
    /// The total, as the least there is while anything is unmeasured or couldn't be read.
    static func total(of overview: StorageOverview) -> String {
        let bytes = ByteText.orDash(overview.measuredBytes)
        return overview.isExact || overview.measuredBytes == 0 ? bytes : "at least \(bytes)"
    }
}

extension DeviceScanner {
    var storageOverview: StorageOverview {
        StorageOverview.make(
            hasFolderAccess: hasFolderAccess,
            coversDeveloperFolder: coversDeveloperFolder,
            hasScannedSimulators: hasCompletedScan,
            simulatorScanFailed: simulatorScanFailed,
            scan: ScanResult(devices: devices, deviceSets: deviceSets, leftovers: leftovers, unreadableLocations: unreadableLocations, unreadableDeviceCount: unreadableDeviceCount),
            hasScannedDeveloperStorage: hasScannedDeveloperStorage,
            developerStorage: developerStorage,
            hasLoadedRuntimes: hasLoadedRuntimes,
            runtimes: canReadRuntimes ? runtimes : nil,
            simulatorCaches: canReadSimulatorCaches ? dyldCaches : nil,
            volume: volume
        )
    }
}
