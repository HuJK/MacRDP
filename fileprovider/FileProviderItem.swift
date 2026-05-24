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

    /// Include `.allowsWriting` even though the domain is conceptually
    /// read-only. Without it, fileproviderd materializes each item as
    /// IMMUTABLE (the `uchg` / Finder "Locked" flag), and a Finder paste
    /// PRESERVES that flag into the destination — so every pasted file
    /// lands locked. Advertising writability drops the immutable flag so
    /// the copied-out file is a normal, editable file. (We don't actually
    /// support writing back INTO the domain — but the clipboard staging
    /// folder is only ever copied OUT of, so no modify path is exercised.)
    var capabilities: NSFileProviderItemCapabilities {
        return entry.isDirectory
            ? [.allowsReading, .allowsContentEnumerating, .allowsWriting,
               .allowsDeleting, .allowsRenaming, .allowsTrashing]
            : [.allowsReading, .allowsWriting,
               .allowsDeleting, .allowsRenaming, .allowsTrashing]
    }

    /// Surface the item to Finder as a normal user-readable AND
    /// user-writable file. Without `.userWritable`, the FP framework
    /// derives mode 0400 (r--------) from capabilities alone, and
    /// Finder's paste *preserves* that into the destination → the
    /// pasted file lands with permission 400 and refuses overwrites
    /// / re-saves. Marking the source as writable makes the destination
    /// inherit umask defaults (typically 0644 / rw-r--r--).
    var fileSystemFlags: NSFileProviderFileSystemFlags {
        if entry.isDirectory {
            return [.userReadable, .userWritable, .userExecutable]
        }
        return [.userReadable, .userWritable]
    }

    /// Version is STABLE for the lifetime of one copy event. The item id
    /// is a per-event UUID and the bytes are an immutable Windows
    /// snapshot, so neither content nor metadata ever changes once the
    /// item is published. Keeping the version stable lets fileproviderd
    /// serve repeat pastes (and concurrent pastes to multiple
    /// destinations) from its local replica instead of re-fetching from
    /// Windows — i.e. "files already pulled aren't re-transferred."
    ///
    /// A NEW copy event mints fresh item ids → fresh versions → a clean
    /// re-fetch, which is exactly what we want. (Previously this was tied
    /// to the manifest's per-publish random sessionID, which forced a
    /// re-fetch of everything on every publish.)
    var itemVersion: NSFileProviderItemVersion {
        let content = "\(entry.id):\(entry.size)".data(using: .utf8) ?? Data([1])
        let meta = "\(entry.id):\(entry.filename):\(entry.size):\(entry.modificationMs ?? 0)"
            .data(using: .utf8) ?? Data([1])
        return NSFileProviderItemVersion(contentVersion: content, metadataVersion: meta)
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
        [.allowsReading, .allowsContentEnumerating  , .allowsWriting]
    }
    var fileSystemFlags: NSFileProviderFileSystemFlags {
        [.userReadable, .userWritable, .userExecutable]
    }
    var itemVersion: NSFileProviderItemVersion {
        NSFileProviderItemVersion(contentVersion: Data([1]),
                                  metadataVersion: Data([1]))
    }
}
