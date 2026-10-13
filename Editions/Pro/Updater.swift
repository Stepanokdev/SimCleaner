//
//  Updater.swift
//  SimCleaner Pro
//
//  Sparkle keeps Pro current: once a day it reads https://simcleaner.com/updates/appcast.xml (Info.plist), and
//  it installs only an update signed with SimCleaner's key, from a feed signed with the same key.

import Combine
import Sparkle
import SwiftUI

@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var automaticallyChecksForUpdates = false

    private let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)

    private init() {
        // Both change under Sparkle too: while a check runs, and when the person answers its own prompts.
        controller.updater.publisher(for: \.canCheckForUpdates).assign(to: &$canCheckForUpdates)
        controller.updater.publisher(for: \.automaticallyChecksForUpdates).assign(to: &$automaticallyChecksForUpdates)
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    func setAutomaticallyChecksForUpdates(_ on: Bool) {
        controller.updater.automaticallyChecksForUpdates = on
    }
}

/// Pro's items in the app menu, under About.
struct EditionCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .appInfo) {
            UpdateMenuItems(updater: .shared)
        }
    }
}

/// A view rather than plain commands, so the items follow the updater as it changes.
private struct UpdateMenuItems: View {
    @ObservedObject var updater: Updater

    var body: some View {
        Button("Check for Updates…") {
            updater.checkForUpdates()
        }
        .disabled(!updater.canCheckForUpdates)
        Toggle("Check for Updates Automatically", isOn: Binding(
            get: { updater.automaticallyChecksForUpdates },
            set: { updater.setAutomaticallyChecksForUpdates($0) }
        ))
    }
}
