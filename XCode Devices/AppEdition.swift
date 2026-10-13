//
//  AppEdition.swift
//  XCode Devices
//
//  The App Store build and the Pro build compile the same windows. Each edition folder defines
//  `AppEdition.current`, `EditionToolbarButton`, `EditionCommands` and `EditionHooks` for its own build.

import Foundation

enum AppEdition: Equatable {
    /// Sandboxed, from the Mac App Store.
    case appStore
    /// Outside the sandbox, from a notarized download. Manages runtimes and starts simulators.
    case pro

    var displayName: String {
        switch self {
        case .appStore: return "SimCleaner"
        case .pro: return "SimCleaner Pro"
        }
    }

    /// Both editions are free and open source; this page explains the difference and links the download.
    static let editionsURL = URL(string: "https://github.com/Stepanokdev/SimCleaner#two-editions")!
    static let repositoryURL = URL(string: "https://github.com/Stepanokdev/SimCleaner")!
}
