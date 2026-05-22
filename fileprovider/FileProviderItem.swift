//
//  FileProviderItem.swift
//  fileprovider
//
//  An `NSFileProviderItem` backed by an entry in our App-Group
//  manifest. The extension itself is read-only — Finder can paste OUT
//  of our domain, but can't paste IN. capabilities reflect that.
//

import FileProvider
import UniformTypeIdentifiers
import Foundation

final class FileProviderItem: NSObject, NSFileProviderItem {
    private let entry: ManifestItem
    private let manifestSessionID: String

    init(_ entry: ManifestItem, manifestSessionID: String) {
        self.entry = entry
        self.manifestSessionID = manifestSessionID
    }

    var itemIdentifier: NSFileProviderItemIdentifier {
        NSFileProviderItemIdentifier(entry.id)
    }

    var parentItemIdentifier: NSFileProviderItemIdentifier {
        if let pid = entry.parentID {
            return NSFileProviderItemIdentifier(pid)
        }
        return .rootContainer
    }

    var filename: String { entry.filename }

    var contentType: UTType {
        if entry.isDirectory { return .folder }
        let ext = (entry.filename as NSString).pathExtension
        if !ext.isEmpty, let t = UTType(filenameExtension: ext) { return t }
        return .data
    }

    var documentSize: NSNumber? {
        entry.isDirectory ? nil : NSNumber(value: entry.size)
    }

    var contentModificationDate: Date? {
        guard let ms = entry.modificationMs else { return nil }
        return Date(timeIntervalSince1970: Double(ms) / 1000.0)
    }

    /// Read-only domain: users can copy out (allowsReading) but not
    /// modify, rename, or delete from Finder.
    var capabilities: NSFileProviderItemCapabilities {
        return entry.isDirectory
            ? [.allowsReading, .allowsContentEnumerating]
            : [.allowsReading]
    }

    /// Tying both contentVersion and metadataVersion to the manifest's
    /// sessionID means: any time we publish a new manifest, Finder sees
    /// the items as "changed" and re-fetches.
    var itemVersion: NSFileProviderItemVersion {
        let v = manifestSessionID.data(using: .utf8) ?? Data([1])
        return NSFileProviderItemVersion(contentVersion: v, metadataVersion: v)
    }
}

/// The synthetic root container — returned when Finder asks for
/// `.rootContainer`. Has no manifest entry; capabilities allow
/// enumeration into the manifest items.
final class RootFileProviderItem: NSObject, NSFileProviderItem {
    let displayName: String
    init(displayName: String) { self.displayName = displayName }
    var itemIdentifier: NSFileProviderItemIdentifier { .rootContainer }
    var parentItemIdentifier: NSFileProviderItemIdentifier { .rootContainer }
    var filename: String { displayName }
    var contentType: UTType { .folder }
    var capabilities: NSFileProviderItemCapabilities {
        [.allowsReading, .allowsContentEnumerating]
    }
    var itemVersion: NSFileProviderItemVersion {
        NSFileProviderItemVersion(contentVersion: Data([1]),
                                  metadataVersion: Data([1]))
    }
}
