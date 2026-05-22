//
//  ClipboardBridge.swift
//  MacRDP
//
//  Bidirectional bridge between NSPasteboard and RDP CLIPRDR.
//
//  Mac → client: poll NSPasteboard.changeCount, ship a FormatList PDU
//                advertising every format we can serve (plain text, HTML,
//                RTF, image). When the client asks for one, read the Mac
//                pasteboard, encode (CF_UNICODETEXT, CF_HTML w/ magic
//                header, RTF, CF_DIB), respond.
//
//  Client → Mac: on a client FormatList, claim NSPasteboard with the
//                full set of Mac types we can hydrate from the client's
//                offered formats. When a Mac app pastes, the provider
//                maps the requested NS type back to the CF format id we
//                stored at claim time, sends a FormatDataRequest, blocks
//                on a semaphore for the bytes, decodes, returns.
//
//  Format negotiation:
//    - Stock Windows formats (id < 0xC000) — no name, fixed semantics.
//    - Custom formats (id >= 0xC000) — name on the wire, both sides
//      assign their own ids and match by name.
//

import Foundation
import AppKit
import FileProvider
import UniformTypeIdentifiers
import os

/// Windows clipboard format identifiers (subset).
enum CFFormat: UInt32 {
    case text          = 1        // CF_TEXT
    case bitmap        = 2        // CF_BITMAP
    case dib           = 8        // CF_DIB
    case unicodeText   = 13       // CF_UNICODETEXT
    case hdrop         = 15       // CF_HDROP
    case dibV5         = 17       // CF_DIBV5
}

/// Custom (named) clipboard formats we know how to encode/decode.
enum CFFormatName: String {
    case htmlFormat            = "HTML Format"
    case richTextFormat        = "Rich Text Format"
    case fileGroupDescriptorW  = "FileGroupDescriptorW"
    case fileContents          = "FileContents"
}

final class ClipboardBridge: NSObject, @unchecked Sendable {

    private let config: Config

    // MARK: - Outbound callbacks (set by RDPSession after construction)

    var sendFormatList: (@Sendable ([(id: UInt32, name: String?)]) -> Void)?
    var sendFormatDataResponse: (@Sendable (UInt32, Data) -> Void)?
    var sendFormatDataRequest:  (@Sendable (UInt32) -> Void)?

    // MARK: - State

    private var pollTimer: DispatchSourceTimer?
    /// MainActor-only.
    private var lastChangeCount: Int = -1
    /// MainActor-only — set after CLIPRDR handshake completes.
    private var channelReady: Bool = false
    /// MainActor-only — pasteboard changeCount we set ourselves (to
    /// suppress the echo on the next poll tick).
    private var selfWroteChangeCount: Int = -1

    /// Outgoing custom-format ids we've assigned during this session.
    /// Stable across re-advertisements so the client can cache name→id
    /// after the first FormatList. MainActor-only.
    private var outboundNameToID: [String: UInt32] = [:]
    private var nextOutboundCustomID: UInt32 = 0xC100  // arbitrary base

    /// Last format list we sent — kept so we can re-ship it if mstsc
    /// rejects the first attempt (transient Windows-clipboard contention
    /// from Office et al.). MainActor-only.
    private var lastSentFormats: [(id: UInt32, name: String?)] = []
    private var formatListRetriesRemaining: Int = 0

    /// Thread-safe pending fetch slot for client→Mac data plumbing.
    private final class PendingFetch {
        let formatID: UInt32
        let semaphore = DispatchSemaphore(value: 0)
        var data: Data?
        init(formatID: UInt32) { self.formatID = formatID }
    }
    private let pendingLock = NSLock()
    private var pending: PendingFetch?

    /// Map of registered NS type → client-side CF id, populated when we
    /// claim the pasteboard from a client format list. The data
    /// provider reads this (off-MainActor) to figure out which CF id to
    /// request when a Mac app pastes. Guarded by `pendingLock`.
    private var claimedTypeMap: [NSPasteboard.PasteboardType: UInt32] = [:]

    // MARK: - File state

    /// One entry per file/folder advertised in the current FileGroupDescriptorW.
    /// `relativePath` uses Windows-style separators (`\`) and includes the
    /// top-level item's name (so the first entry of a single-file copy is
    /// just "myfile.txt"; a folder copy starts with the folder name).
    /// Guarded by `pendingLock`.
    fileprivate struct OutFileEntry {
        let url: URL              // absolute Mac path
        let relativePath: String  // "MyFolder\\sub\\file.txt"
        let isDirectory: Bool
        let size: UInt64
        let modTime: Date?
    }
    private var outFiles: [OutFileEntry] = []
    /// Cached open file handles for in-progress chunked reads, keyed by
    /// the listIndex into outFiles. Closed when the session ends.
    private var outOpenHandles: [Int: FileHandle] = [:]
    /// Custom CF id we assigned for FileGroupDescriptorW this session.
    /// Same lifetime as `outboundNameToID`.
    private var outFileGroupDescID: UInt32 = 0

    /// Inbound (client→Mac) file entries from the most recent
    /// FileGroupDescriptorW. Paths are POSIX (`/`) here for ease of use
    /// with macOS APIs. Indexed positionally — listIndex on the wire is
    /// the array index. Guarded by `pendingLock`.
    fileprivate struct InFileEntry {
        let relativePath: String   // "MyFolder/sub/file.txt"
        let isDirectory: Bool
        let size: UInt64
    }
    private var inFiles: [InFileEntry] = []
    /// Client→Mac: in-flight file-contents fetches, keyed by streamId.
    private final class PendingFileFetch {
        let semaphore = DispatchSemaphore(value: 0)
        var data: Data = Data()
    }
    private var inPendingFiles: [UInt32: PendingFileFetch] = [:]
    private var nextInStreamID: UInt32 = 1
    /// Custom CF id the client assigned for FileContents (for sending
    /// FILECONTENTS_REQUEST). 0 if absent.
    private var inFileContentsID: UInt32 = 0
    private var inFileGroupDescID: UInt32 = 0

    // MARK: - File outbound callbacks (set by RDPSession after construction)

    var sendFileContentsResponse: (@Sendable (_ streamID: UInt32, _ success: Bool, _ data: Data) -> Void)?
    var sendFileContentsRequest:  (@Sendable (_ streamID: UInt32, _ listIndex: UInt32,
                                              _ wantSize: Bool, _ offset: UInt64, _ length: UInt32) -> Void)?

    init(config: Config) {
        self.config = config
        super.init()
    }

    // MARK: - Lifecycle (MainActor)

    @MainActor
    func start() throws {
        let queue = DispatchQueue(label: "com.macrdp.clipboard", qos: .userInitiated)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        let interval = DispatchTimeInterval.milliseconds(config.clipboard.pollIntervalMs)
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.poll()
            }
        }
        timer.resume()
        self.pollTimer = timer
        Log.clip.info("Clipboard polling started @\(self.config.clipboard.pollIntervalMs, privacy: .public)ms")
    }

    @MainActor
    func stop() {
        pollTimer?.cancel()
        pollTimer = nil
        pendingLock.lock()
        if let p = pending {
            p.data = Data()
            p.semaphore.signal()
            pending = nil
        }
        // Wake any in-flight file fetches with empty data so the
        // materialize loops bail rather than blocking forever.
        for (_, f) in inPendingFiles {
            f.data = Data()
            f.semaphore.signal()
        }
        inPendingFiles.removeAll()
        for (_, h) in outOpenHandles { try? h.close() }
        outOpenHandles.removeAll()
        outFiles.removeAll()
        pendingLock.unlock()
    }

    /// Called by RDPSession once the CLIPRDR channel handshake completes.
    @MainActor
    func markReady() {
        channelReady = true
        lastChangeCount = -1
        poll()
    }

    // MARK: - Mac → Client

    @MainActor
    private func poll() {
        guard channelReady else { return }
        let pb = NSPasteboard.general
        let cc = pb.changeCount
        guard cc != lastChangeCount else { return }
        lastChangeCount = cc

        if cc == selfWroteChangeCount { return }

        var formats: [(id: UInt32, name: String?)] = []
        let types = pb.types ?? []
        let typesDump = types.map { $0.rawValue }.joined(separator: ", ")
        Log.clip.info("Mac pasteboard changed (cc=\(cc, privacy: .public)) types=[\(typesDump, privacy: .public)]")

        // Plain text — always include as a fallback if any text is on the
        // pasteboard, even if richer formats are also there.
        if config.clipboard.text, hasText(pb) {
            formats.append((CFFormat.unicodeText.rawValue, nil))
            formats.append((CFFormat.text.rawValue, nil))
        }

        // HTML. Different source apps publish HTML under different UTIs
        // (modern public.html, legacy "Apple HTML pasteboard type",
        // Office-flavored "com.microsoft.html-format"). Pick the first
        // type whose raw name conforms to public.html or whose data
        // looks like an HTML document.
        if config.clipboard.text, Self.findHTMLData(pb) != nil {
            let id = assignOutboundCustomID(for: CFFormatName.htmlFormat.rawValue)
            formats.append((id, CFFormatName.htmlFormat.rawValue))
        }

        // RTF.
        if config.clipboard.text, pb.data(forType: .rtf) != nil {
            let id = assignOutboundCustomID(for: CFFormatName.richTextFormat.rawValue)
            formats.append((id, CFFormatName.richTextFormat.rawValue))
        }

        // Image.
        if config.clipboard.image, hasImage(pb) {
            formats.append((CFFormat.dib.rawValue, nil))
        }

        // Files / folders — recurse folders into a flat descriptor list
        // and advertise FileGroupDescriptorW + FileContents. We don't
        // also publish CF_HDROP: modern Windows clients prefer the
        // descriptor-based path, and CF_HDROP can't carry folder trees.
        if config.clipboard.files {
            let urls = Self.fileURLs(on: pb)
            if !urls.isEmpty,
               let entries = expandFileURLs(urls, limitMiB: config.clipboard.maxFileSizeMiB) {
                pendingLock.lock()
                outFiles = entries
                // Close any leftover handles from a previous copy.
                for (_, h) in outOpenHandles { try? h.close() }
                outOpenHandles.removeAll()
                pendingLock.unlock()

                let descID = assignOutboundCustomID(for: CFFormatName.fileGroupDescriptorW.rawValue)
                let contID = assignOutboundCustomID(for: CFFormatName.fileContents.rawValue)
                outFileGroupDescID = descID
                formats.append((descID, CFFormatName.fileGroupDescriptorW.rawValue))
                formats.append((contID, CFFormatName.fileContents.rawValue))
                Log.clip.info("Advertising \(entries.count, privacy: .public) file/folder entry(ies)")
            }
        }

        let summary = formats.map { f in
            if let n = f.name { return "\(f.id)='\(n)'" } else { return "\(f.id)" }
        }.joined(separator: ", ")
        Log.clip.info("Advertising \(formats.count, privacy: .public) format(s): [\(summary, privacy: .public)]")
        lastSentFormats = formats
        // Allow a couple of retries on CB_RESPONSE_FAIL (Office on
        // Windows briefly holding the clipboard is the usual cause).
        formatListRetriesRemaining = 3
        sendFormatList?(formats)
    }

    /// Called when the client ACKs (or NAKs) a FormatList we sent. On
    /// FAIL we schedule a re-send — mstsc returns FAIL when its
    /// OpenClipboard() loses to another app polling the clipboard
    /// (Word/Outlook/Excel), which is usually transient.
    @MainActor
    func handleFormatListResponse(success: Bool) {
        if success {
            formatListRetriesRemaining = 0
            return
        }
        guard formatListRetriesRemaining > 0, !lastSentFormats.isEmpty else {
            Log.clip.error("FormatList rejected; out of retries. Close Office apps on the client to avoid Windows clipboard contention.")
            return
        }
        formatListRetriesRemaining -= 1
        // Stagger the retry so the contender has time to release the
        // Windows clipboard. Backoff doubles each attempt: 250ms, 500ms, 1s.
        let attempt = 3 - formatListRetriesRemaining
        let delayMs = 250 * (1 << (attempt - 1))
        Log.clip.notice("FormatList rejected — retrying in \(delayMs, privacy: .public)ms (attempt \(attempt, privacy: .public)/3)")
        let formats = lastSentFormats
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
            self?.sendFormatList?(formats)
        }
    }

    @MainActor
    private func assignOutboundCustomID(for name: String) -> UInt32 {
        if let existing = outboundNameToID[name] { return existing }
        let id = nextOutboundCustomID
        nextOutboundCustomID += 1
        outboundNameToID[name] = id
        return id
    }

    @MainActor
    private func hasText(_ pb: NSPasteboard) -> Bool {
        pb.canReadObject(forClasses: [NSString.self], options: nil)
    }
    @MainActor
    private func hasImage(_ pb: NSPasteboard) -> Bool {
        pb.canReadObject(forClasses: [NSImage.self], options: nil)
    }

    nonisolated func handleClientFormatDataRequest(formatID: UInt32) {
        Task { @MainActor [weak self] in
            self?.serveFormatDataRequest(formatID: formatID)
        }
    }

    @MainActor
    private func serveFormatDataRequest(formatID: UInt32) {
        let pb = NSPasteboard.general
        var payload = Data()

        switch formatID {
        case CFFormat.unicodeText.rawValue, CFFormat.text.rawValue:
            if let s = pb.string(forType: .string) {
                payload = Self.encodeUnicodeText(s)
            }
        case CFFormat.dib.rawValue, CFFormat.dibV5.rawValue:
            if let img = NSImage(pasteboard: pb),
               let dib = Self.encodeDIB(img) {
                payload = dib
            }
        default:
            // Custom format: look up which name we assigned this id.
            if let name = outboundNameToID.first(where: { $0.value == formatID })?.key {
                switch name {
                case CFFormatName.htmlFormat.rawValue:
                    let raw = Self.findHTMLData(pb)
                    if let raw, let s = Self.decodeHTMLBytes(raw) {
                        payload = Self.encodeCFHTML(htmlFragment: s)
                        Log.clip.info("Encoded CF_HTML: src=\(raw.count, privacy: .public)B → \(payload.count, privacy: .public)B")
                    } else {
                        Log.clip.error("CF_HTML encode failed — raw=\(raw?.count ?? -1, privacy: .public)B")
                    }
                case CFFormatName.richTextFormat.rawValue:
                    if let rtf = pb.data(forType: .rtf) {
                        // RTF is plain ASCII; CLIPRDR ships it as-is with
                        // a NUL terminator (most decoders are tolerant
                        // either way, but Windows convention adds one).
                        var bytes = rtf
                        bytes.append(0)
                        payload = bytes
                    }
                case CFFormatName.fileGroupDescriptorW.rawValue:
                    pendingLock.lock()
                    let entries = outFiles
                    pendingLock.unlock()
                    payload = Self.encodeFileGroupDescriptorW(entries)
                    Log.clip.info("Encoded FILEGROUPDESCRIPTORW: \(entries.count, privacy: .public) entries → \(payload.count, privacy: .public) bytes")
                case CFFormatName.fileContents.rawValue:
                    // File bytes never travel through FormatDataResponse;
                    // they come via CB_FILECONTENTS_REQUEST. Respond with
                    // empty data (the client should not be asking).
                    Log.clip.error("Client asked for FileContents via FormatDataRequest — ignored")
                default:
                    break
                }
            }
        }
        Log.clip.info("Client→server FormatDataRequest fid=\(formatID, privacy: .public) → \(payload.count, privacy: .public) bytes")
        sendFormatDataResponse?(formatID, payload)
    }

    // MARK: - Client → Mac

    nonisolated func handleClientFormatList(_ formats: [(id: UInt32, name: String?)]) {
        Task { @MainActor [weak self] in
            self?.claimPasteboardForClientFormats(formats)
        }
    }

    @MainActor
    private func claimPasteboardForClientFormats(_ formats: [(id: UInt32, name: String?)]) {
        // Build a map: client's CF id → (Mac NS type we'd serve from it).
        // We register every NS type we *can* hydrate; AppKit asks the
        // pasting app's preferred type at paste time.
        var typeMap: [NSPasteboard.PasteboardType: UInt32] = [:]

        // Log what the client actually offered so we can verify
        // case/spelling of named formats.
        let dump = formats.map { f -> String in
            if let n = f.name, !n.isEmpty { return "\(f.id)='\(n)'" }
            return "\(f.id)"
        }.joined(separator: ", ")
        Log.clip.info("Client offered \(formats.count, privacy: .public) format(s): [\(dump, privacy: .public)]")

        let ids = Dictionary(uniqueKeysWithValues:
            formats.compactMap { f -> (UInt32, String?)? in (f.id, f.name) })

        // Custom (named) ids the client offered. Match case-insensitively
        // against known canonical names so we don't miss "html format"
        // vs "HTML Format" etc.
        var nameToID: [String: UInt32] = [:]
        for f in formats {
            guard let n = f.name, !n.isEmpty else { continue }
            nameToID[n.lowercased()] = f.id
        }

        if let id = nameToID[CFFormatName.htmlFormat.rawValue.lowercased()] {
            typeMap[.html] = id
        }
        if let id = nameToID[CFFormatName.richTextFormat.rawValue.lowercased()] {
            typeMap[.rtf] = id
        }
        if ids[CFFormat.unicodeText.rawValue] != nil {
            typeMap[.string] = CFFormat.unicodeText.rawValue
        } else if ids[CFFormat.text.rawValue] != nil {
            typeMap[.string] = CFFormat.text.rawValue
        }
        if ids[CFFormat.dib.rawValue] != nil {
            typeMap[.tiff] = CFFormat.dib.rawValue
        } else if ids[CFFormat.dibV5.rawValue] != nil {
            typeMap[.tiff] = CFFormat.dibV5.rawValue
        }

        // Files. If both FileGroupDescriptorW and FileContents are
        // present, we'll fetch the descriptor and claim the pasteboard
        // with NSFilePromiseProvider items instead of an ordinary data
        // provider. File copies are mutually exclusive with text/image
        // copies in CLIPRDR (the source claims only one or the other).
        let descID = nameToID[CFFormatName.fileGroupDescriptorW.rawValue.lowercased()]
        let contID = nameToID[CFFormatName.fileContents.rawValue.lowercased()]
        if config.clipboard.files, let descID, let contID {
            inFileGroupDescID = descID
            inFileContentsID  = contID
            claimPasteboardWithFilePromisesAsync(descriptorFormatID: descID)
            return
        }

        guard !typeMap.isEmpty else {
            Log.clip.info("Client format list (\(formats.count, privacy: .public)) has no formats we support")
            return
        }

        pendingLock.lock()
        claimedTypeMap = typeMap
        pendingLock.unlock()

        let pb = NSPasteboard.general
        pb.clearContents()
        let item = NSPasteboardItem()
        // Register every type. AppKit consults this list when an app
        // queries `availableType(from:)`.
        item.setDataProvider(self, forTypes: Array(typeMap.keys))
        pb.writeObjects([item])
        selfWroteChangeCount = pb.changeCount
        lastChangeCount      = pb.changeCount

        let summary = typeMap.map { "\($0.key.rawValue)→fid=\($0.value)" }.joined(separator: ", ")
        Log.clip.info("Client copied → claimed pasteboard with \(typeMap.count, privacy: .public) type(s): \(summary, privacy: .public)")
    }

    /// When the client copies files, Finder needs real `file://` URLs
    /// on the pasteboard to enable Paste. We eagerly fetch every file's
    /// bytes, publish a manifest into our FileProvider domain, then
    /// put the domain's user-visible URLs on the pasteboard. Finder
    /// (and any other app) copies through the extension — works
    /// system-wide.
    @MainActor
    private func claimPasteboardWithFilePromisesAsync(descriptorFormatID: UInt32) {
        let inbox = AppDelegate.sharedClipboardInbox
        Log.clip.info("Lazy file list incoming for FileProvider domain '\(inbox.domainIdentifier.rawValue, privacy: .public)'")

        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let raw = self.awaitClientFormatData(formatID: descriptorFormatID, timeoutMs: 5_000)
            let entries = ClipboardBridge.parseFileGroupDescriptorW(raw)
            guard !entries.isEmpty else {
                Log.clip.error("Client file list empty — nothing to paste")
                return
            }
            self.pendingLock.lock()
            self.inFiles = entries
            self.claimedTypeMap = [:]
            self.pendingLock.unlock()

            // Stable UUIDs + parent links — same as before.
            var ids = [String](repeating: "", count: entries.count)
            for i in 0..<entries.count { ids[i] = UUID().uuidString }
            func parentID(of i: Int) -> String? {
                let path = entries[i].relativePath
                guard let lastSlash = path.lastIndex(of: "/") else { return nil }
                let parentPath = String(path[..<lastSlash])
                for j in 0..<entries.count where j != i {
                    if entries[j].relativePath == parentPath { return ids[j] }
                }
                return nil
            }
            // Map id → listIndex so the XPC fetcher can route to the
            // right CLIPRDR slot when the extension asks for bytes.
            var idToListIndex: [String: Int] = [:]
            var items: [FileProviderInbox.PublishItem] = []
            items.reserveCapacity(entries.count)
            for (idx, e) in entries.enumerated() {
                let filename = (e.relativePath as NSString).lastPathComponent
                items.append(.init(id: ids[idx],
                                   filename: filename,
                                   parentID: parentID(of: idx),
                                   isDirectory: e.isDirectory,
                                   size: Int64(e.size),
                                   modificationMs: nil))
                idToListIndex[ids[idx]] = idx
            }
            Log.clip.info("Publishing metadata for \(items.count, privacy: .public) item(s) — bytes lazy via XPC")

            // Hop to MainActor: publish manifest, register XPC fetcher,
            // resolve URLs for the pasteboard.
            await MainActor.run {
                // Register a per-domain fetcher that handles "give me
                // bytes for item X, offset Y, length L" by routing
                // through the existing awaitFileContents / CLIPRDR path.
                FileProviderXPCService.shared.registerFetcher(
                    domainSubdir: inbox.subdir
                ) { [weak self] itemID, offset, length in
                    guard let self else {
                        return (nil, NSError(domain: "MacRDP.clip", code: 99,
                            userInfo: [NSLocalizedDescriptionKey: "session gone"]))
                    }
                    guard let listIndex = idToListIndex[itemID] else {
                        return (nil, NSError(domain: "MacRDP.clip", code: 404,
                            userInfo: [NSLocalizedDescriptionKey: "unknown item id"]))
                    }
                    let data = self.awaitFileContents(
                        listIndex: UInt32(listIndex),
                        offset: UInt64(offset),
                        length: UInt32(length),
                        timeoutMs: 30_000)
                    if data.isEmpty {
                        return (nil, NSError(domain: "MacRDP.clip", code: 504,
                            userInfo: [NSLocalizedDescriptionKey: "RDP fetch timed out"]))
                    }
                    return (data, nil)
                }

                Task { @MainActor in
                    do {
                        try await inbox.publish(items)
                    } catch {
                        Log.clip.error("FileProvider publish failed: \(String(describing: error), privacy: .public)")
                        return
                    }
                    await self.resolveAndWriteFileURLs(inbox: inbox, items: items)
                }
            }
        }
    }

    @MainActor
    private func resolveAndWriteFileURLs(inbox: FileProviderInbox,
                                          items: [FileProviderInbox.PublishItem]) async {
        // Only top-level items (parentID == nil) go on the pasteboard.
        // The FP framework gives us URLs inside the domain mount;
        // Finder/Mail/etc. read through the extension when pasting.
        var urls: [URL] = []
        for it in items where it.parentID == nil {
            if let url = await inbox.userVisibleURL(itemID: it.id, filename: it.filename) {
                urls.append(url)
            } else {
                Log.clip.error("No URL resolved for \(it.filename, privacy: .public)")
            }
        }
        guard !urls.isEmpty else { return }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(urls as [NSURL])
        selfWroteChangeCount = pb.changeCount
        lastChangeCount      = pb.changeCount
        Log.clip.info("Pasteboard claimed with \(urls.count, privacy: .public) FileProvider URL(s)")
    }

    /// MUST NOT MainActor-hop: the data-provider waiting on the
    /// semaphore may itself be running on the main thread.
    nonisolated func handleClientFormatDataResponse(formatID: UInt32, data: Data) {
        pendingLock.lock()
        let p = pending
        if p?.formatID == formatID {
            p?.data = data
            pending = nil
        }
        pendingLock.unlock()
        p?.semaphore.signal()
    }

    nonisolated private func awaitClientFormatData(formatID: UInt32, timeoutMs: Int) -> Data {
        let fetch = PendingFetch(formatID: formatID)
        pendingLock.lock()
        pending = fetch
        pendingLock.unlock()

        sendFormatDataRequest?(formatID)

        let deadline = DispatchTime.now() + .milliseconds(timeoutMs)
        _ = fetch.semaphore.wait(timeout: deadline)

        pendingLock.lock()
        if pending === fetch { pending = nil }
        let result = fetch.data ?? Data()
        pendingLock.unlock()
        return result
    }

    // MARK: - Files: Mac → Client

    /// Extract file URLs from the pasteboard. Returns absolute,
    /// resolved file paths (deduplicated, in original order).
    static func fileURLs(on pb: NSPasteboard) -> [URL] {
        let items = pb.readObjects(forClasses: [NSURL.self],
                                   options: [.urlReadingFileURLsOnly: true]) ?? []
        var seen = Set<String>()
        var out: [URL] = []
        for item in items {
            guard let url = (item as? URL)?.standardizedFileURL.resolvingSymlinksInPath() else { continue }
            let key = url.path
            if !seen.contains(key) {
                seen.insert(key)
                out.append(url)
            }
        }
        return out
    }

    /// Recursively expand the given roots into a flat list of entries
    /// with Windows-style relative paths. Folders are listed before
    /// their children. Returns nil if any single file exceeds the
    /// max-file-size cap from config.
    @MainActor
    private func expandFileURLs(_ roots: [URL], limitMiB: Int) -> [OutFileEntry]? {
        let fm = FileManager.default
        var out: [OutFileEntry] = []
        let limit = UInt64(limitMiB) * 1024 * 1024
        for root in roots {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: root.path, isDirectory: &isDir) else { continue }
            let rootName = root.lastPathComponent
            if isDir.boolValue {
                // Folder entry first
                let attrs = try? fm.attributesOfItem(atPath: root.path)
                out.append(.init(url: root,
                                 relativePath: rootName,
                                 isDirectory: true,
                                 size: 0,
                                 modTime: attrs?[.modificationDate] as? Date))
                // Walk descendants — directoryEnumerator visits in DFS order.
                if let enumerator = fm.enumerator(
                    at: root,
                    includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
                    options: [.skipsHiddenFiles],
                    errorHandler: { _, _ in true }) {
                    for case let url as URL in enumerator {
                        let resolved = url.standardizedFileURL
                        let values = try? resolved.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
                        let isChildDir = values?.isDirectory ?? false
                        let size = UInt64(values?.fileSize ?? 0)
                        if !isChildDir, size > limit {
                            Log.clip.error("File exceeds maxFileSizeMiB=\(limitMiB, privacy: .public) — refusing: \(resolved.lastPathComponent, privacy: .public)")
                            return nil
                        }
                        // Build the relative path: <rootName>\<relativeFromRoot, joined by \>
                        let relFromRoot = url.path.dropFirst(root.path.count)
                            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                        let winPath = rootName + "\\" + relFromRoot.replacingOccurrences(of: "/", with: "\\")
                        out.append(.init(url: resolved,
                                         relativePath: winPath,
                                         isDirectory: isChildDir,
                                         size: size,
                                         modTime: values?.contentModificationDate))
                    }
                }
            } else {
                let values = try? root.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                let size = UInt64(values?.fileSize ?? 0)
                if size > limit {
                    Log.clip.error("File exceeds maxFileSizeMiB=\(limitMiB, privacy: .public) — refusing: \(rootName, privacy: .public)")
                    return nil
                }
                out.append(.init(url: root,
                                 relativePath: rootName,
                                 isDirectory: false,
                                 size: size,
                                 modTime: values?.contentModificationDate))
            }
        }
        return out
    }

    /// Serialize the current outFiles into a FILEGROUPDESCRIPTORW blob:
    /// 4-byte count + N × 592-byte FILEDESCRIPTORW.
    private static func encodeFileGroupDescriptorW(_ entries: [OutFileEntry]) -> Data {
        let FD_ATTRIBUTES: UInt32 = 0x00000004
        let FD_FILESIZE:   UInt32 = 0x00000040
        let FD_WRITESTIME: UInt32 = 0x00000020
        let FILE_ATTRIBUTE_DIRECTORY: UInt32 = 0x00000010
        let FILE_ATTRIBUTE_NORMAL:    UInt32 = 0x00000080

        var out = Data()
        out.reserveCapacity(4 + entries.count * 592)
        var count = UInt32(entries.count).littleEndian
        withUnsafeBytes(of: &count) { out.append(contentsOf: $0) }

        for e in entries {
            var fd = Data(repeating: 0, count: 592)
            func put32(_ value: UInt32, at offset: Int) {
                var v = value.littleEndian
                withUnsafeBytes(of: &v) { src in
                    for i in 0..<4 { fd[offset + i] = src[i] }
                }
            }
            func put64(_ value: UInt64, at offset: Int) {
                var v = value.littleEndian
                withUnsafeBytes(of: &v) { src in
                    for i in 0..<8 { fd[offset + i] = src[i] }
                }
            }
            var flags = FD_ATTRIBUTES
            if !e.isDirectory { flags |= FD_FILESIZE }
            if e.modTime != nil { flags |= FD_WRITESTIME }
            put32(flags, at: 0)
            // CLSID (16) at 4 — zero
            // sizel (8) at 20 — zero
            // pointl (8) at 28 — zero
            let attr = e.isDirectory ? FILE_ATTRIBUTE_DIRECTORY : FILE_ATTRIBUTE_NORMAL
            put32(attr, at: 36)
            // ftCreationTime (8) at 40, ftLastAccessTime (8) at 48 — zero
            if let mod = e.modTime {
                // FILETIME = 100-ns intervals since 1601-01-01 UTC.
                let unixSeconds = mod.timeIntervalSince1970
                let ft = UInt64((unixSeconds + 11644473600.0) * 10_000_000.0)
                put64(ft, at: 56)
            }
            put32(UInt32((e.size >> 32) & 0xFFFFFFFF), at: 64)   // nFileSizeHigh
            put32(UInt32(e.size & 0xFFFFFFFF), at: 68)           // nFileSizeLow
            // cFileName (520) at 72 — UTF-16LE, NUL-terminated, MAX_PATH=260.
            let utf16 = Array(e.relativePath.utf16).prefix(259)  // leave room for NUL
            for (i, unit) in utf16.enumerated() {
                let off = 72 + i * 2
                fd[off]     = UInt8(unit & 0xFF)
                fd[off + 1] = UInt8((unit >> 8) & 0xFF)
            }
            out.append(fd)
        }
        return out
    }

    /// Handle CB_FILECONTENTS_REQUEST from the client. Runs on the
    /// bridge thread. Replies with bytes (FILECONTENTS_RANGE) or an
    /// 8-byte size (FILECONTENTS_SIZE).
    nonisolated func handleClientFileContentsRequest(streamID: UInt32,
                                                     listIndex: UInt32,
                                                     wantSize: Bool,
                                                     offset: UInt64,
                                                     length: UInt32) {
        pendingLock.lock()
        let entry: OutFileEntry?
        if Int(listIndex) < outFiles.count {
            entry = outFiles[Int(listIndex)]
        } else {
            entry = nil
        }
        pendingLock.unlock()

        guard let entry, !entry.isDirectory else {
            Log.clip.error("FileContentsRequest streamId=\(streamID, privacy: .public) listIndex=\(listIndex, privacy: .public): no such file")
            sendFileContentsResponse?(streamID, false, Data())
            return
        }

        if wantSize {
            var size = entry.size.littleEndian
            let data = withUnsafeBytes(of: &size) { Data($0) }
            sendFileContentsResponse?(streamID, true, data)
            return
        }

        // Range read. Open (or reuse) a file handle.
        do {
            pendingLock.lock()
            var handle = outOpenHandles[Int(listIndex)]
            if handle == nil {
                handle = try FileHandle(forReadingFrom: entry.url)
                outOpenHandles[Int(listIndex)] = handle
            }
            pendingLock.unlock()

            try handle?.seek(toOffset: offset)
            let bytes = handle?.readData(ofLength: Int(length)) ?? Data()
            sendFileContentsResponse?(streamID, true, bytes)
        } catch {
            Log.clip.error("FileContentsRequest read failed: \(String(describing: error), privacy: .public)")
            sendFileContentsResponse?(streamID, false, Data())
        }
    }

    // MARK: - Files: Client → Mac

    /// Parse a FILEGROUPDESCRIPTORW blob into a flat list of entries
    /// with POSIX-style relative paths.
    fileprivate static func parseFileGroupDescriptorW(_ data: Data) -> [InFileEntry] {
        guard data.count >= 4 else { return [] }
        let FILE_ATTRIBUTE_DIRECTORY: UInt32 = 0x10
        let count = data.withUnsafeBytes { ptr -> UInt32 in
            ptr.load(fromByteOffset: 0, as: UInt32.self).littleEndian
        }
        guard data.count >= 4 + Int(count) * 592 else { return [] }
        var out: [InFileEntry] = []
        out.reserveCapacity(Int(count))
        for i in 0..<Int(count) {
            let base = 4 + i * 592
            let attr = data.withUnsafeBytes { ptr -> UInt32 in
                ptr.load(fromByteOffset: base + 36, as: UInt32.self).littleEndian
            }
            let sizeHi = data.withUnsafeBytes { ptr -> UInt32 in
                ptr.load(fromByteOffset: base + 64, as: UInt32.self).littleEndian
            }
            let sizeLo = data.withUnsafeBytes { ptr -> UInt32 in
                ptr.load(fromByteOffset: base + 68, as: UInt32.self).littleEndian
            }
            let size = (UInt64(sizeHi) << 32) | UInt64(sizeLo)
            // Decode cFileName: UTF-16LE up to first NUL, max 260 chars.
            var nameUnits: [UInt16] = []
            nameUnits.reserveCapacity(260)
            for j in 0..<260 {
                let off = base + 72 + j * 2
                let unit = data.withUnsafeBytes { ptr -> UInt16 in
                    ptr.load(fromByteOffset: off, as: UInt16.self).littleEndian
                }
                if unit == 0 { break }
                nameUnits.append(unit)
            }
            let winName = String(decoding: nameUnits, as: UTF16.self)
            // Strip leading separators, convert \ to /, deny path traversal.
            let normalized = winName
                .replacingOccurrences(of: "\\", with: "/")
                .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if normalized.contains("..") {
                Log.clip.error("Rejecting suspicious file entry (path traversal): \(winName, privacy: .public)")
                continue
            }
            let isDir = (attr & FILE_ATTRIBUTE_DIRECTORY) != 0
            out.append(InFileEntry(relativePath: normalized,
                                   isDirectory: isDir,
                                   size: size))
        }
        return out
    }

    /// Block (with timeout) waiting for the client's bytes for a
    /// FILECONTENTS_REQUEST we sent. Runs on the file-promise queue.
    nonisolated private func awaitFileContents(listIndex: UInt32,
                                                offset: UInt64,
                                                length: UInt32,
                                                timeoutMs: Int) -> Data {
        pendingLock.lock()
        let sid = nextInStreamID
        nextInStreamID = nextInStreamID &+ 1
        if nextInStreamID == 0 { nextInStreamID = 1 }
        let fetch = PendingFileFetch()
        inPendingFiles[sid] = fetch
        pendingLock.unlock()

        sendFileContentsRequest?(sid, listIndex, false, offset, length)

        let deadline = DispatchTime.now() + .milliseconds(timeoutMs)
        _ = fetch.semaphore.wait(timeout: deadline)

        pendingLock.lock()
        inPendingFiles.removeValue(forKey: sid)
        let bytes = fetch.data
        pendingLock.unlock()
        return bytes
    }

    /// Bridge thread delivers FILECONTENTS_RESPONSE bytes. Routes to
    /// the pending fetch by streamId. No MainActor hop.
    nonisolated func handleClientFileContentsResponse(streamID: UInt32, data: Data) {
        pendingLock.lock()
        let fetch = inPendingFiles[streamID]
        fetch?.data = data
        pendingLock.unlock()
        fetch?.semaphore.signal()
    }

    /// Materialize a single inbound file at `destURL` by streaming from
    /// the client in chunks. Throws on I/O or transfer failure.
    nonisolated private func materializeFile(listIndex: Int,
                                              size: UInt64,
                                              destURL: URL) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: destURL)
        fm.createFile(atPath: destURL.path, contents: nil, attributes: nil)
        guard let handle = try? FileHandle(forWritingTo: destURL) else {
            throw NSError(domain: "MacRDP.clip", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "open dest failed"])
        }
        defer { try? handle.close() }

        let chunk: UInt32 = 256 * 1024
        var offset: UInt64 = 0
        while offset < size {
            let want = UInt32(min(UInt64(chunk), size - offset))
            let bytes = awaitFileContents(listIndex: UInt32(listIndex),
                                          offset: offset,
                                          length: want,
                                          timeoutMs: 30_000)
            if bytes.isEmpty {
                throw NSError(domain: "MacRDP.clip", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "fetch timed out / FAIL at offset \(offset)"])
            }
            try handle.write(contentsOf: bytes)
            offset += UInt64(bytes.count)
            // If the client returns fewer bytes than asked, that's fine —
            // we advance by what we got.
        }
    }

    /// Materialize a folder root at `destURL` by walking the inbound
    /// entry list, creating directories and streaming each file. The
    /// `rootIndex` is the listIndex of the folder entry itself.
    nonisolated private func materializeFolder(rootIndex: Int,
                                                destURL: URL) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: destURL)
        try fm.createDirectory(at: destURL, withIntermediateDirectories: true)

        pendingLock.lock()
        let entries = inFiles
        pendingLock.unlock()
        guard rootIndex < entries.count else { return }
        let root = entries[rootIndex]
        let rootName = root.relativePath  // e.g. "MyFolder"

        // Iterate every child whose relativePath starts with "<root>/".
        let prefix = rootName + "/"
        for (i, e) in entries.enumerated() where i != rootIndex {
            guard e.relativePath.hasPrefix(prefix) else { continue }
            let relInside = String(e.relativePath.dropFirst(prefix.count))
            let childURL = destURL.appendingPathComponent(relInside)
            // Path-traversal safety: childURL must be inside destURL.
            let standardized = childURL.standardizedFileURL.path
            if !standardized.hasPrefix(destURL.standardizedFileURL.path) {
                throw NSError(domain: "MacRDP.clip", code: 3,
                              userInfo: [NSLocalizedDescriptionKey: "rejected path traversal: \(e.relativePath)"])
            }
            if e.isDirectory {
                try fm.createDirectory(at: childURL, withIntermediateDirectories: true)
            } else {
                try fm.createDirectory(at: childURL.deletingLastPathComponent(),
                                       withIntermediateDirectories: true)
                try materializeFile(listIndex: i, size: e.size, destURL: childURL)
            }
        }
    }

    // MARK: - Encoders / decoders (text)

    static func encodeUnicodeText(_ s: String) -> Data {
        var out = Data()
        let utf16 = Array(s.utf16) + [UInt16(0)]
        out.reserveCapacity(utf16.count * 2)
        for unit in utf16 {
            out.append(UInt8(unit & 0xFF))
            out.append(UInt8((unit >> 8) & 0xFF))
        }
        return out
    }

    static func decodeUnicodeText(_ data: Data) -> String? {
        guard data.count >= 2 else { return nil }
        var bytes = data
        if bytes.count >= 2,
           bytes[bytes.count - 1] == 0,
           bytes[bytes.count - 2] == 0 {
            bytes.removeLast(2)
        }
        return bytes.withUnsafeBytes { raw -> String? in
            let units = raw.bindMemory(to: UInt16.self)
            guard let base = units.baseAddress else { return nil }
            return String(utf16CodeUnits: base, count: units.count)
        }
    }

    static func decodeAnsiText(_ data: Data) -> String? {
        var bytes = data
        while bytes.last == 0 { bytes.removeLast() }
        return String(data: bytes, encoding: .windowsCP1252)
            ?? String(data: bytes, encoding: .utf8)
    }

    // MARK: - Encoders / decoders (CF_HTML)
    //
    // The "HTML Format" clipboard format isn't raw HTML — it's prefixed
    // with a tiny ASCII description that names byte offsets back into
    // the same buffer:
    //
    //   Version:0.9
    //   StartHTML:00000097
    //   EndHTML:0000023A
    //   StartFragment:00000131
    //   EndFragment:000001FE
    //   <html>…<!--StartFragment-->…actual fragment…<!--EndFragment-->…</html>
    //
    // The numbers are decimal-ASCII, 10 digits, zero-padded, measured
    // from the START of the same buffer (including the header itself).

    /// Find HTML data on the pasteboard, accepting common alternative
    /// UTIs used by Word, Office, and legacy NS types. Returns the
    /// first non-empty match. Runs on MainActor (we don't enforce — the
    /// callers already are).
    static func findHTMLData(_ pb: NSPasteboard) -> Data? {
        let candidates: [NSPasteboard.PasteboardType] = [
            .html,
            NSPasteboard.PasteboardType("public.html"),
            NSPasteboard.PasteboardType("Apple HTML pasteboard type"),
            NSPasteboard.PasteboardType("NSHTMLPboardType"),
            NSPasteboard.PasteboardType("com.microsoft.html-format"),
        ]
        for t in candidates {
            if let d = pb.data(forType: t), !d.isEmpty { return d }
        }
        // Last resort: scan all types and pick one whose contents start
        // with an HTML signature.
        if let types = pb.types {
            for t in types {
                guard let d = pb.data(forType: t), d.count > 4 else { continue }
                let prefix = d.prefix(64)
                if let s = String(data: prefix, encoding: .utf8),
                   s.contains("<html") || s.contains("<HTML") || s.contains("<!DOCTYPE") {
                    return d
                }
            }
        }
        return nil
    }

    /// Decode HTML bytes from NSPasteboard. Usually UTF-8, but Word /
    /// Office occasionally hand back UTF-16 with a BOM.
    static func decodeHTMLBytes(_ data: Data) -> String? {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16)
        }
        return String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .windowsCP1252)
    }

    static func encodeCFHTML(htmlFragment: String) -> Data {
        // If the source already looks like a full document, leave it
        // alone and inject only the fragment markers. Otherwise wrap it
        // in a minimal scaffold so the result still parses as HTML.
        var doc = htmlFragment
        let startMark = "<!--StartFragment-->"
        let endMark   = "<!--EndFragment-->"

        let alreadyHasStart = doc.range(of: startMark) != nil
        let alreadyHasEnd   = doc.range(of: endMark)   != nil

        if !alreadyHasStart || !alreadyHasEnd {
            // Inject markers around the body's content; fall back to
            // wrapping the entire string if there's no <body>.
            if let bodyOpen = doc.range(of: "<body", options: .caseInsensitive),
               let bodyTagEnd = doc.range(of: ">", range: bodyOpen.upperBound..<doc.endIndex),
               let bodyClose = doc.range(of: "</body>", options: [.caseInsensitive, .backwards]) {
                if !alreadyHasEnd {
                    doc.insert(contentsOf: endMark, at: bodyClose.lowerBound)
                }
                if !alreadyHasStart {
                    doc.insert(contentsOf: startMark, at: bodyTagEnd.upperBound)
                }
            } else {
                let prefix = "<!DOCTYPE html><html><body>" + startMark
                let suffix = endMark + "</body></html>"
                doc = prefix + doc + suffix
            }
        }

        // Compute byte offsets in the final UTF-8 buffer.
        let header =
            "Version:0.9\r\n" +
            "StartHTML:%010ld\r\n" +
            "EndHTML:%010ld\r\n" +
            "StartFragment:%010ld\r\n" +
            "EndFragment:%010ld\r\n"
        // Fixed-width digits make the header length constant; render
        // with zeros first just to size it.
        let placeholderHeader = String(format: header, 0, 0, 0, 0)
        let headerLen = placeholderHeader.utf8.count
        let bodyBytes = Array(doc.utf8)

        // Locate the markers' byte ranges. We need EndFragment to point
        // BEFORE the `<!--EndFragment-->` comment and StartFragment AFTER
        // the `<!--StartFragment-->` comment.
        let startMarkBytes = Array(startMark.utf8)
        let endMarkBytes   = Array(endMark.utf8)
        let startIdxInBody = bodyBytes.firstRange(of: startMarkBytes)?.upperBound ?? 0
        let endIdxInBody   = bodyBytes.firstRange(of: endMarkBytes)?.lowerBound ?? bodyBytes.count

        let startHTML     = headerLen
        let endHTML       = headerLen + bodyBytes.count
        let startFragment = headerLen + startIdxInBody
        let endFragment   = headerLen + endIdxInBody

        // Use %ld with Swift `Int` (64-bit on macOS) — %d would only
        // consume 4 bytes per arg and corrupt the subsequent ones.
        let realHeader = String(format: header,
                                startHTML, endHTML,
                                startFragment, endFragment)
        var out = Data()
        out.append(contentsOf: realHeader.utf8)
        out.append(contentsOf: bodyBytes)
        return out
    }

    /// Strip the CF_HTML magic header, return the inner HTML fragment
    /// (or the full <html>…</html> body if no fragment markers).
    static func decodeCFHTML(_ data: Data) -> String? {
        guard let full = String(data: data, encoding: .utf8) else { return nil }
        // Parse header k:v lines until we hit a non-key character or HTML.
        // Just locate StartFragment / EndFragment markers via the header.
        var startFragment: Int? = nil
        var endFragment: Int? = nil
        var startHTML: Int? = nil
        var endHTML: Int? = nil
        full.enumerateLines { line, stop in
            // Header lines look like "Key:NNNNNNNNNN". Bail at the first
            // non-header line (which begins the HTML body).
            if let colon = line.firstIndex(of: ":") {
                let key = String(line[..<colon])
                let val = String(line[line.index(after: colon)...])
                switch key {
                case "Version": break
                case "StartHTML":     startHTML     = Int(val.trimmingCharacters(in: .whitespaces))
                case "EndHTML":       endHTML       = Int(val.trimmingCharacters(in: .whitespaces))
                case "StartFragment": startFragment = Int(val.trimmingCharacters(in: .whitespaces))
                case "EndFragment":   endFragment   = Int(val.trimmingCharacters(in: .whitespaces))
                case "SourceURL":     break
                default:
                    // First non-header line — stop scanning.
                    stop = true
                }
            } else {
                stop = true
            }
        }

        let utf8 = Array(full.utf8)
        if let sf = startFragment, let ef = endFragment,
           sf >= 0, ef <= utf8.count, sf < ef {
            return String(decoding: utf8[sf..<ef], as: UTF8.self)
        }
        if let sh = startHTML, let eh = endHTML,
           sh >= 0, eh <= utf8.count, sh < eh {
            return String(decoding: utf8[sh..<eh], as: UTF8.self)
        }
        // Header parse failed — fall back to returning the whole thing
        // (better than nothing for apps tolerant of header prefix).
        return full
    }

    // MARK: - Encoders / decoders (image)

    static func encodeDIB(_ image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return nil }
        let w = Int(rep.pixelsWide)
        let h = Int(rep.pixelsHigh)
        let bytesPerRow = w * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * h)
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(
                data: &pixels, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                space: cs,
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
              ),
              let cg = rep.cgImage else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))

        var flipped = [UInt8](repeating: 0, count: bytesPerRow * h)
        for y in 0..<h {
            let srcOff = y * bytesPerRow
            let dstOff = (h - 1 - y) * bytesPerRow
            flipped.replaceSubrange(dstOff..<dstOff+bytesPerRow,
                with: pixels[srcOff..<srcOff+bytesPerRow])
        }

        var header = Data()
        func u32(_ v: UInt32) {
            header.append(UInt8(v & 0xFF))
            header.append(UInt8((v >> 8)  & 0xFF))
            header.append(UInt8((v >> 16) & 0xFF))
            header.append(UInt8((v >> 24) & 0xFF))
        }
        func i32(_ v: Int32) { u32(UInt32(bitPattern: v)) }
        func u16(_ v: UInt16) {
            header.append(UInt8(v & 0xFF))
            header.append(UInt8((v >> 8) & 0xFF))
        }
        u32(40)
        i32(Int32(w))
        i32(Int32(h))
        u16(1)
        u16(32)
        u32(0)
        u32(UInt32(bytesPerRow * h))
        i32(2835)
        i32(2835)
        u32(0)
        u32(0)

        var out = header
        out.append(Data(flipped))
        return out
    }

    static func decodeDIBToTIFF(_ dib: Data) -> Data? {
        guard dib.count >= 40 else { return nil }
        let headerSize = dib.withUnsafeBytes { $0.load(as: UInt32.self) }
        var bmp = Data()
        bmp.reserveCapacity(14 + dib.count)
        bmp.append(contentsOf: [0x42, 0x4D])
        var fileSize = UInt32(14 + dib.count).littleEndian
        withUnsafeBytes(of: &fileSize) { bmp.append(contentsOf: $0) }
        bmp.append(contentsOf: [0, 0, 0, 0])
        var offBits = UInt32(14 + headerSize).littleEndian
        withUnsafeBytes(of: &offBits) { bmp.append(contentsOf: $0) }
        bmp.append(dib)
        guard let rep = NSBitmapImageRep(data: bmp) else { return nil }
        return rep.tiffRepresentation
    }
}

// MARK: - NSPasteboardItemDataProvider

extension ClipboardBridge: NSPasteboardItemDataProvider {

    nonisolated func pasteboard(_ pasteboard: NSPasteboard?,
                                item: NSPasteboardItem,
                                provideDataForType type: NSPasteboard.PasteboardType) {
        pendingLock.lock()
        let formatID = claimedTypeMap[type]
        pendingLock.unlock()
        guard let formatID else {
            Log.clip.error("provideDataForType \(type.rawValue, privacy: .public): no mapping")
            item.setData(Data(), forType: type)
            return
        }
        let raw = awaitClientFormatData(formatID: formatID, timeoutMs: 3_000)
        Log.clip.info("provideDataForType \(type.rawValue, privacy: .public) fid=\(formatID, privacy: .public): \(raw.count, privacy: .public) bytes")

        switch type {
        case .string:
            let s: String?
            if formatID == CFFormat.unicodeText.rawValue {
                s = ClipboardBridge.decodeUnicodeText(raw)
            } else {
                s = ClipboardBridge.decodeAnsiText(raw)
            }
            if let s {
                item.setString(s, forType: type)
            } else {
                item.setData(Data(), forType: type)
            }
        case .html:
            if let html = ClipboardBridge.decodeCFHTML(raw),
               let d = html.data(using: .utf8) {
                item.setData(d, forType: type)
            } else {
                item.setData(Data(), forType: type)
            }
        case .rtf:
            // RTF is pass-through ASCII; strip a trailing NUL if present.
            var bytes = raw
            if bytes.last == 0 { bytes.removeLast() }
            item.setData(bytes, forType: type)
        case .tiff:
            if let tiff = ClipboardBridge.decodeDIBToTIFF(raw) {
                item.setData(tiff, forType: type)
            } else {
                item.setData(Data(), forType: type)
            }
        default:
            item.setData(Data(), forType: type)
        }
    }
}
