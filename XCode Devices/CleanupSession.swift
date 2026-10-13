//
//  CleanupSession.swift
//  XCode Devices
//

import AppKit
import Combine
import Foundation
import SwiftUI

/// What SimCleaner has freed since the person started cleaning up: the total and the last cleanup.
///
/// Each cleanup adds to the same total until an hour passes without one; the next cleanup after that
/// starts again from zero. The hour runs from the last cleanup, not the first, so a long tidy-up isn't
/// reset halfway through. One session serves every window and survives a relaunch: reopening SimCleaner
/// within the hour shows the same total, without celebrating it again.
@MainActor
final class CleanupSession: ObservableObject {
    static let shared = CleanupSession()

    /// How long a session lasts after its last cleanup.
    static let length: TimeInterval = 60 * 60

    struct Totals: Codable, Equatable {
        /// Everything freed in this session.
        var freedBytes: Int64
        /// What the last cleanup added.
        var lastFreedBytes: Int64
        var lastCleanupAt: Date
    }

    /// Nil when there's no session: nothing freed yet, or the hour has passed.
    @Published private(set) var totals: Totals?
    /// Cleanups added while this copy of SimCleaner runs. Views animate when it changes, so a total
    /// restored at launch appears without its animation.
    @Published private(set) var cleanupsThisLaunch = 0

    private let defaults: UserDefaults
    private let now: () -> Date
    private var expiry: Task<Void, Never>?
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []
    private static let defaultsKey = "cleanupSession"

    init(defaults: UserDefaults = .standard, now: @escaping () -> Date = Date.init) {
        self.defaults = defaults
        self.now = now
        totals = defaults.data(forKey: Self.defaultsKey).flatMap { try? JSONDecoder().decode(Totals.self, from: $0) }
        endIfExpired()
        scheduleExpiry()
        // The timer below keeps counting while the Mac sleeps, but someone can also set the clock; look
        // again whenever either happens. Both observers are delivered on the main queue.
        let recheck: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                self?.endIfExpired()
                self?.scheduleExpiry()
            }
        }
        observers = [
            NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main, using: recheck),
            NotificationCenter.default.addObserver(forName: .NSSystemClockDidChange, object: nil, queue: .main, using: recheck),
        ]
    }

    deinit {
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            NotificationCenter.default.removeObserver(observer)
        }
    }

    /// When the session ends unless something else is cleaned, or nil without a session.
    var endsAt: Date? {
        totals.map { $0.lastCleanupAt.addingTimeInterval(Self.length) }
    }

    /// Adds one cleanup that freed `bytes`. After an hour without cleanups this starts a new session.
    func add(_ bytes: Int64) {
        guard bytes > 0 else { return }
        endIfExpired()
        let date = now()
        var totals = self.totals ?? Totals(freedBytes: 0, lastFreedBytes: 0, lastCleanupAt: date)
        totals.freedBytes += bytes
        totals.lastFreedBytes = bytes
        totals.lastCleanupAt = date
        self.totals = totals
        cleanupsThisLaunch += 1
        save()
        scheduleExpiry()
        // Once per cleanup, not once per window showing it.
        AccessibilityNotification.Announcement(announcement(for: totals)).post()
    }

    func announcement(for totals: Totals) -> String {
        totals.freedBytes == totals.lastFreedBytes
            ? "Freed about \(ByteText.string(totals.lastFreedBytes))."
            : "Freed about \(ByteText.string(totals.lastFreedBytes)). About \(ByteText.string(totals.freedBytes)) freed in this session."
    }

    /// Ends the session once its hour is over, or when the clock was set back to before its last cleanup:
    /// then nobody can say how long ago that was.
    func endIfExpired() {
        guard let totals else { return }
        let elapsed = now().timeIntervalSince(totals.lastCleanupAt)
        guard elapsed >= Self.length || elapsed < 0 else { return }
        self.totals = nil
        save()
    }

    private func save() {
        if let totals, let data = try? JSONEncoder().encode(totals) {
            defaults.set(data, forKey: Self.defaultsKey)
        } else {
            defaults.removeObject(forKey: Self.defaultsKey)
        }
    }

    /// Hides the total by itself when the hour is over, even if nothing else happens in the window.
    private func scheduleExpiry() {
        expiry?.cancel()
        guard let endsAt else { return }
        let delay = max(endsAt.timeIntervalSince(now()), 0)
        expiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.endIfExpired()
            // Still running means the clock moved; wait for the new end.
            if self.totals != nil { self.scheduleExpiry() }
        }
    }
}
