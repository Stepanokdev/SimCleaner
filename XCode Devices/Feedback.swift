//
//  Feedback.swift
//  XCode Devices
//
//  How both editions reach the developer: the Help menu and the About panel.

import AppKit
import SwiftUI

enum Feedback {
    static let address = "stepanokdev@gmail.com"
    static let websiteURL = URL(string: "https://simcleaner.com")!

    /// A new message to the developer. The edition, version and macOS go at the bottom, so a bug report
    /// says what it ran on without anyone having to ask.
    static func mailURL(edition: String, version: String, build: String, system: OperatingSystemVersion) -> URL {
        var macOS = "\(system.majorVersion).\(system.minorVersion)"
        if system.patchVersion > 0 { macOS += ".\(system.patchVersion)" }
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = address
        components.queryItems = [
            URLQueryItem(name: "subject", value: "\(edition) \(version) feedback"),
            // RFC 6068 wants CRLF line breaks in a mailto body.
            URLQueryItem(name: "body", value: "\r\n\r\n\(edition) \(version) (\(build)) on macOS \(macOS)\r\n"),
        ]
        return components.url!
    }

    /// The message for this copy of SimCleaner.
    static var mailURL: URL {
        let info = Bundle.main.infoDictionary ?? [:]
        return mailURL(
            edition: AppEdition.current.displayName,
            version: info["CFBundleShortVersionString"] as? String ?? "?",
            build: info["CFBundleVersion"] as? String ?? "?",
            system: ProcessInfo.processInfo.operatingSystemVersion
        )
    }

    /// Opens the message in the person's mail app. Without one, the address goes to the clipboard and an alert
    /// says where it is, so the menu item never does nothing.
    static func compose() {
        guard !NSWorkspace.shared.open(mailURL) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(address, forType: .string)
        let alert = NSAlert()
        alert.messageText = "No mail app is set up"
        alert.informativeText = "\(address) is on the clipboard. Paste it into the mail service you use."
        alert.runModal()
    }

    /// The line under the version in the About panel, with the address and the site as links.
    static var aboutCredits: NSAttributedString {
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        let plain: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: centered,
        ]
        let credits = NSMutableAttributedString(string: "Feedback and bug reports: ", attributes: plain)
        credits.append(NSAttributedString(string: address, attributes: plain.merging([.link: mailURL]) { $1 }))
        credits.append(NSAttributedString(string: "\n", attributes: plain))
        credits.append(NSAttributedString(string: "simcleaner.com", attributes: plain.merging([.link: websiteURL]) { $1 }))
        return credits
    }
}

/// About, with a way to write to the developer, and a Help menu that leads somewhere: SwiftUI's own Help item
/// only says that help isn't available.
struct FeedbackCommands: Commands {
    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About \(AppEdition.current.displayName)") {
                NSApplication.shared.orderFrontStandardAboutPanel(options: [.credits: Feedback.aboutCredits])
                NSApplication.shared.activate()
            }
        }
        CommandGroup(replacing: .help) {
            Button("SimCleaner Website") {
                NSWorkspace.shared.open(Feedback.websiteURL)
            }
            Button("Send Feedback…") {
                Feedback.compose()
            }
        }
    }
}
