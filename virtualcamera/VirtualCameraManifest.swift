//
//  VirtualCameraManifest.swift
//  MacRDP — shared between rds (main app) and virtualcamera (CMIO extension).
//
//  Verbatim copy of virtualcamera/VirtualCameraManifest.swift. The two targets
//  live in separate synchronized folders, so (like SharedManifest) we keep a
//  copy in each — if you change one, update the other.
//
//  The host owns which virtual cameras should currently exist (one per
//  redirected RDP client webcam). It sets that list, as JSON, on a custom
//  property of the extension's CMIO provider (plug-in object); the extension
//  adds/removes CMIO devices to match.
//
//  Not a file in the App Group container: the system runs camera extensions
//  as _cmiodalassistants, whose App Group container is its own
//  (/var/db/cmiodalassistants/Library/Group Containers/...), not the user's.
//  Darwin notifications are system-wide, so the extension's in-use signals
//  still reach the host that way.
//

import Foundation

enum VirtualCameraShared {
    static let extensionBundleID = "com.mac-rdp.rds.virtualcamera"

    /// Provider property holding the manifest JSON (`CMIOExtensionProperty`
    /// "4cc_cams_glob_0000"; the host addresses it as selector 'cams').
    static let camerasPropertyToken = "cams"

    /// Suggested name for a single always-on camera, if the host chooses to
    /// keep one present rather than mirroring the client set exactly.
    static let defaultCameraName = "MacRDP Camera"

    /// Posted by the extension when the first app starts, or the last one
    /// stops, reading the camera with this id, so the host pulls the client's
    /// webcam (and lights it) only while something here is using it.
    static func inUseNotification(id: String, inUse: Bool) -> String {
        "com.mac-rdp.rds.virtualcamera.\(inUse ? "inUse" : "idle").\(id.uppercased())"
    }

    static func post(_ name: String) {
        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            CFNotificationName(name as CFString), nil, nil, true)
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

    init(cameras: [Camera]) { self.cameras = cameras }

    init?(json: String) {
        guard let m = try? JSONDecoder().decode(Self.self, from: Data(json.utf8)) else { return nil }
        self = m
    }

    var json: String {
        String(decoding: (try? JSONEncoder().encode(self)) ?? Data("{\"cameras\":[]}".utf8), as: UTF8.self)
    }
}
