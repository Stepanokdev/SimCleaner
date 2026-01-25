//
//  RatingManager.swift
//  XCode Devices
//
//  Created by Ivan Stepanok on 25.01.2026.
//

import Combine
import StoreKit
import AppKit

@MainActor
final class RatingManager: ObservableObject {

    private enum Keys {
        static let successfulDeletionCount = "successfulDeletionCount"
        static let lastRatingRequestDate = "lastRatingRequestDate"
        static let hasRequestedRatingBefore = "hasRequestedRatingBefore"
    }

    private let defaults = UserDefaults.standard

    /// Number of deletions required for the first rating request
    private let initialDeletionThreshold = 2

    /// Time interval before showing rating again (3 months)
    private let ratingCooldownInterval: TimeInterval = 60 * 60 * 24 * 90 // 90 days

    var successfulDeletionCount: Int {
        get { defaults.integer(forKey: Keys.successfulDeletionCount) }
        set { defaults.set(newValue, forKey: Keys.successfulDeletionCount) }
    }

    var lastRatingRequestDate: Date? {
        get { defaults.object(forKey: Keys.lastRatingRequestDate) as? Date }
        set { defaults.set(newValue, forKey: Keys.lastRatingRequestDate) }
    }

    var hasRequestedRatingBefore: Bool {
        get { defaults.bool(forKey: Keys.hasRequestedRatingBefore) }
        set { defaults.set(newValue, forKey: Keys.hasRequestedRatingBefore) }
    }

    /// Records a successful deletion and checks if rating should be requested
    func recordSuccessfulDeletion() {
        successfulDeletionCount += 1

        if shouldRequestRating() {
            requestRating()
        }
    }

    /// Determines if a rating request should be shown
    private func shouldRequestRating() -> Bool {
        // First time: show after 2nd deletion
        if !hasRequestedRatingBefore {
            return successfulDeletionCount >= initialDeletionThreshold
        }

        // After first request: show after 1st deletion if 3 months have passed
        guard let lastRequest = lastRatingRequestDate else {
            return true
        }

        let timeSinceLastRequest = Date().timeIntervalSince(lastRequest)
        return timeSinceLastRequest >= ratingCooldownInterval
    }

    /// Requests app rating via StoreKit
    private func requestRating() {
        guard let window = NSApplication.shared.keyWindow,
              let viewController = window.contentViewController else { return }

        AppStore.requestReview(in: viewController)

        lastRatingRequestDate = Date()
        hasRequestedRatingBefore = true

        // Reset deletion count after requesting rating
        successfulDeletionCount = 0
    }
}
