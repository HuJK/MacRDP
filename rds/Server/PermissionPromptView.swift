//
//  PermissionPromptView.swift
//  MacRDP
//
//  Chrome-Remote-Desktop-style consent gate: lists missing TCC
//  permissions, lets the user jump to the right System Settings pane,
//  re-polls every second, and only enables "Continue" once everything
//  is green.
//
//  Hosted in an NSWindow by PermissionPromptWindow. AppDelegate shows
//  the window before starting the RDP listener.
//

import SwiftUI
import AppKit

struct PermissionPromptView: View {

    let requirements: [PermissionRequirement]
    let onContinue: () -> Void
    let onQuit: () -> Void

    /// Per-row grant state, refreshed by the polling task below.
    @State private var grants: [PermissionRequirement.Kind: Bool] = [:]
    @State private var lastBumpedRow: PermissionRequirement.Kind?

    private var allGranted: Bool {
        requirements.allSatisfy { grants[$0.id] == true }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // Header.
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 12) {
                    Image(systemName: "lock.shield")
                        .font(.system(size: 36))
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Permissions Required")
                            .font(.title2).bold()
                        Text("MacRDP needs the following access to serve remote desktop sessions.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Divider()

            // Per-permission rows.
            VStack(spacing: 12) {
                ForEach(requirements) { req in
                    permissionRow(req)
                }
            }

            Spacer(minLength: 6)

            // Footer with Quit + Continue.
            HStack {
                Button("Quit") { onQuit() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Text(allGranted ? "All set." : "Waiting for permissions…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Continue") { onContinue() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!allGranted)
            }
        }
        .padding(24)
        .frame(width: 520)
        .onAppear {
            refresh()
            registerMissingWithTCC()
        }
        // Poll once per second. macOS doesn't notify on TCC grants;
        // polling is the standard approach.
        .task { await pollLoop() }
    }

    @ViewBuilder
    private func permissionRow(_ req: PermissionRequirement) -> some View {
        let granted = grants[req.id] == true
        HStack(spacing: 14) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 26))
                .foregroundStyle(granted ? Color.green : Color.orange)
                // Tiny pulse on the row that just flipped to granted —
                // matches the Chrome Remote Desktop "ding!" feeling.
                .scaleEffect(lastBumpedRow == req.id ? 1.2 : 1.0)
                .animation(.spring(response: 0.25, dampingFraction: 0.45),
                           value: lastBumpedRow)

            VStack(alignment: .leading, spacing: 2) {
                Text(req.title).font(.headline)
                Text(req.description).font(.caption).foregroundStyle(.secondary)
            }

            Spacer()

            Button(granted ? "Granted" : "Open Settings") {
                // Re-register on click in case the user dismissed the
                // initial system prompt and TCC dropped us from the list.
                req.registerWithTCCIfNeeded()
                NSWorkspace.shared.open(req.settingsURL)
            }
            .disabled(granted)
            // Re-poll immediately on click so the row flips faster if
            // the user comes back from Settings.
            .simultaneousGesture(TapGesture().onEnded { refresh() })
        }
    }

    private func refresh() {
        for req in requirements {
            let now = req.isGranted()
            let was = grants[req.id]
            if was != true, now {
                lastBumpedRow = req.id
                // Clear the highlight after the animation finishes.
                Task {
                    try? await Task.sleep(nanoseconds: 600_000_000)
                    if lastBumpedRow == req.id { lastBumpedRow = nil }
                }
            }
            grants[req.id] = now
        }
    }

    /// macOS only adds a TCC entry for our app once we call the
    /// prompting API. Without this, the user opens Privacy & Security
    /// → Screen Recording and we're not in the list — there's nothing
    /// to toggle. Calling once at view-appear time registers us. The
    /// extra system dialog is part of the standard flow (Chrome Remote
    /// Desktop, etc. all do the same).
    private func registerMissingWithTCC() {
        for req in requirements where !req.isGranted() {
            req.registerWithTCCIfNeeded()
        }
    }

    private func pollLoop() async {
        while !Task.isCancelled {
            refresh()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
    }
}
