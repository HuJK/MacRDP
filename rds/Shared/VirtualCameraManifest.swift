//
//  VirtualCameraManifest.swift
//  MacRDP — shared between rds (main app) and virtualcamera (CMIO extension).
//
//  Verbatim copy of virtualcamera/VirtualCameraManifest.swift. The two targets
//  live in separate synchronized folders, so (like SharedManifest) we keep a
//  copy in each — if you change one, update the other.
//
//  The host owns which virtual cameras should currently exist (one per
//  redirected RDP client webcam). It writes that list into the shared App Group
//  container and pings a Darwin notification; the extension reads it and
//  adds/removes CMIO devices to match.
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
        /// UUID string per logical client camera, not a fresh one each connect.
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
