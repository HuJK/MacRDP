//
//  VirtualCameraManifest.swift
//  virtualcamera (shared contract — also compile into the rds host target)
//
//  The host app owns the truth about which virtual cameras should currently
//  exist (one per redirected RDP client webcam). It writes that list into the
//  shared App Group container and pings a Darwin notification; the camera
//  extension reads the list and adds/removes CMIO devices to match.
//
//  This indirection exists because the extension is launched on-demand by the
//  system — the host cannot call into it directly, so it leaves the desired
//  state in shared storage and wakes the extension to re-sync.
//

import Foundation

enum VirtualCameraShared {
    static let appGroup = "group.com.mac-rdp.rds"
    static let manifestFilename = "virtualcameras.json"

    /// Darwin notification posted by the host whenever the manifest changes.
    static let didChangeNotification = "com.mac-rdp.rds.virtualcamera.manifestChanged"

    /// Suggested name for a single always-on camera, if the host chooses to
    /// keep one present rather than mirroring the client set exactly.
    static let defaultCameraName = "MacRDP Camera"

    static var manifestURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroup)?
            .appendingPathComponent(manifestFilename)
    }

    /// Host calls this after writing the manifest to wake the extension.
    static func postDidChange() {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(didChangeNotification as CFString),
            nil, nil, true)
    }
}

struct VirtualCameraManifest: Codable, Equatable {

    struct Camera: Codable, Equatable {
        /// Stable identifier — reused as the CMIO device UID so consumer apps
        /// can remember the user's selection across relaunches. Use a fixed
        /// UUID string per logical client camera (e.g. derived from the RDP
        /// camera's device id), not a fresh one each connect.
        var id: String
        /// User-visible name shown in the system camera picker.
        var name: String
    }

    var cameras: [Camera]

    static let empty = VirtualCameraManifest(cameras: [])

    static func load() -> VirtualCameraManifest {
        guard let url = VirtualCameraShared.manifestURL,
            let data = try? Data(contentsOf: url),
            let manifest = try? JSONDecoder().decode(VirtualCameraManifest.self, from: data)
        else { return .empty }
        return manifest
    }

    func save() throws {
        guard let url = VirtualCameraShared.manifestURL else {
            throw CocoaError(.fileNoSuchFile)
        }
        let data = try JSONEncoder().encode(self)
        try data.write(to: url, options: .atomic)
    }
}
