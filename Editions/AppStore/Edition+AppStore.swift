//
//  Edition+AppStore.swift
//  SimCleaner (App Store)
//

import SwiftUI

extension AppEdition {
    static let current: AppEdition = .appStore
}

/// The App Store build's toolbar button: support the author.
struct EditionToolbarButton: View {
    @State private var showSupportSheet = false

    var body: some View {
        Button {
            showSupportSheet = true
        } label: {
            Label("Support Author", systemImage: "heart")
                .labelStyle(.titleAndIcon)
        }
        .help("Support the author")
        .sheet(isPresented: $showSupportSheet) {
            SupportAuthorView()
        }
    }
}

@MainActor
enum EditionHooks {
    /// After a cleanup that worked, the App Store build may ask for a rating.
    static func cleanupSucceeded() {
        RatingManager.shared.recordSuccessfulDeletion()
    }
}
