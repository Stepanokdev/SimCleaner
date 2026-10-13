//
//  FreedSpaceBadge.swift
//  XCode Devices
//

import Pow
import SwiftUI

/// "Freed about 15 GB +5 GB": what this session's cleanups gave back, as an estimate (see `Reclaimed`).
/// Each cleanup sends its share floating up
/// out of the badge, rolls the total and sweeps a shine across it; with Reduce Motion the numbers just
/// change. The effects hang on a container that's always there, so the very first cleanup gets them too.
struct FreedSpaceBadge: View {
    @ObservedObject var session: CleanupSession
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            if let totals = session.totals {
                badge(totals)
                    .transition(reduceMotion ? AnyTransition.opacity : AnyTransition(.blurReplace).combined(with: .scale(scale: 0.9)))
            }
        }
        .changeEffect(.shine(duration: 1.2), value: session.cleanupsThisLaunch, isEnabled: !reduceMotion)
        .changeEffect(
            .rise(origin: UnitPoint(x: 0.5, y: 0)) {
                Text("+\(ByteText.string(session.totals?.lastFreedBytes ?? 0))")
                    .font(.headline)
                    .foregroundStyle(.green)
            },
            value: session.cleanupsThisLaunch,
            isEnabled: !reduceMotion
        )
        .animation(reduceMotion ? .linear(duration: 0.15) : .smooth(duration: 0.5), value: session.totals)
    }

    private func badge(_ totals: CleanupSession.Totals) -> some View {
        HStack(spacing: 5) {
            Image(systemName: "sparkles")
                .foregroundStyle(.green)
                .symbolEffect(.bounce, value: reduceMotion ? 0 : session.cleanupsThisLaunch)
            Text("Freed about")
                .foregroundStyle(.secondary)
            Text(ByteText.string(totals.freedBytes))
                .fontWeight(.semibold)
                .monospacedDigit()
                .contentTransition(.numericText(value: Double(totals.freedBytes)))
            if totals.lastFreedBytes < totals.freedBytes {
                Text("+\(ByteText.string(totals.lastFreedBytes))")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .contentTransition(.numericText(value: Double(totals.lastFreedBytes)))
                    .transition(.opacity)
            }
        }
        .font(.callout)
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .background(Capsule(style: .continuous).fill(Color.green.opacity(0.13)))
        .help("An estimate of the space this session's cleanups gave back. Each removed item counts the bytes it held alone where APFS can tell, so clones aren't counted twice, and its size on disk where it can't; a runtime counts the size Xcode reports for it. A local Time Machine snapshot can keep deleted files on disk for a while. The count starts again an hour after your last cleanup.")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(session.announcement(for: totals))
    }
}
