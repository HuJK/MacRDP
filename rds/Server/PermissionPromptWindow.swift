//
//  PermissionPromptWindow.swift
//  MacRDP
//
//  NSWindow that hosts the SwiftUI PermissionPromptView before the
//  listener boots. Because the app is LSUIElement (no Dock icon),
//  we temporarily flip activation policy to .regular so the window
//  comes to the front; flip back to .accessory once the user clicks
//  Continue.
//

import AppKit
import SwiftUI

@MainActor
final class PermissionPromptWindow {

    private var window: NSWindow?

    /// Show the prompt with the given requirements. `onContinue` runs
    /// once the user clicks Continue (all permissions granted).
    /// `onQuit` runs if they choose Quit instead.
    func show(requirements: [PermissionRequirement],
              onContinue: @escaping () -> Void,
              onQuit: @escaping () -> Void) {

        // Bring app to foreground for the duration of the prompt. We're
        // a menu-bar-only app (LSUIElement); without this the window
        // would open behind everything and have no Dock entry to click.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let view = PermissionPromptView(
            requirements: requirements,
            onContinue: { [weak self] in
                self?.dismiss()
                onContinue()
            },
            onQuit: { [weak self] in
                self?.dismiss()
                onQuit()
            }
        )

        let hosting = NSHostingController(rootView: view)
        let window = NSWindow(contentViewController: hosting)
        window.styleMask = [.titled, .closable]
        window.title = "MacRDP"
        window.isReleasedWhenClosed = false
        window.center()
        window.level = .floating
        // Closing the window via the red dot counts as Quit, not as
        // "continue without permission".
        window.standardWindowButton(.zoomButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true

        self.window = window
        window.makeKeyAndOrderFront(nil)
    }

    private func dismiss() {
        window?.orderOut(nil)
        window = nil
        // Return to menu-bar-only mode so we don't keep a Dock icon
        // around after the prompt closes.
        NSApp.setActivationPolicy(.accessory)
    }
}
