//
//  VirtualCameraInstaller.swift
//  MacRDP
//
//  Installs (activates) the virtualcamera CMIO system extension embedded in
//  the app, so redirected client webcams can show up as Mac cameras. Its CMIO
//  devices only exist once the extension is installed and approved.
//
//  Activation is idempotent: run at every launch, it replaces an installed
//  copy from an older build and is a no-op otherwise. The first install needs
//  the user's approval (System Settings > General > Login Items & Extensions >
//  Camera Extensions); until then the request waits and webcams can still be
//  viewed from the menu bar, just not used by other apps.
//
//  Needs the com.apple.developer.system-extension.install entitlement and the
//  app in /Applications.
//

import Foundation
import SystemExtensions

@MainActor
final class VirtualCameraInstaller: NSObject {

    static let shared = VirtualCameraInstaller()
    static let extensionIdentifier = "com.mac-rdp.rds.virtualcamera"

    enum State: Equatable { case notRequested, activating, needsApproval, active, failed(String) }
    private(set) var state: State = .notRequested

    func activate() {
        guard state == .notRequested || state.isFailure else { return }
        state = .activating
        let request = OSSystemExtensionRequest.activationRequest(
            forExtensionWithIdentifier: Self.extensionIdentifier, queue: .main)
        request.delegate = self
        OSSystemExtensionManager.shared.submitRequest(request)
        LogTo.server.info("Virtual camera extension: activation requested")
    }

    fileprivate func finish(_ newState: State) {
        state = newState
        switch newState {
        case .active:
            LogTo.server.notice("Virtual camera extension active")
            VirtualCameraRegistry.extensionActivated()
        case .needsApproval:
            LogTo.server.notice("Virtual camera extension waits for approval: System Settings › General › Login Items & Extensions › Camera Extensions › MacRDP")
        case .failed(let why):
            LogTo.server.error("Virtual camera extension: \(why)")
        case .notRequested, .activating:
            break
        }
    }
}

private extension VirtualCameraInstaller.State {
    var isFailure: Bool { if case .failed = self { return true } else { return false } }
}

extension VirtualCameraInstaller: OSSystemExtensionRequestDelegate {

    nonisolated func request(_ request: OSSystemExtensionRequest,
                             actionForReplacingExtension existing: OSSystemExtensionProperties,
                             withExtension ext: OSSystemExtensionProperties)
        -> OSSystemExtensionRequest.ReplacementAction {
        // Each build should run its own copy (the host and the extension share
        // the manifest format), so always take the one in this app.
        LogTo.server.info("Virtual camera extension: replacing \(existing.bundleShortVersion) (\(existing.bundleVersion)) with \(ext.bundleShortVersion) (\(ext.bundleVersion))")
        return .replace
    }

    nonisolated func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) {
        Task { @MainActor in VirtualCameraInstaller.shared.finish(.needsApproval) }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest,
                             didFinishWithResult result: OSSystemExtensionRequest.Result) {
        Task { @MainActor in
            VirtualCameraInstaller.shared.finish(
                result == .completed ? .active : .failed("needs a reboot to finish installing"))
        }
    }

    nonisolated func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) {
        let why = "activation failed: \(error.localizedDescription) (\((error as NSError).code))"
        Task { @MainActor in VirtualCameraInstaller.shared.finish(.failed(why)) }
    }
}
