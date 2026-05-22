//
//  CopyProgressWindow.swift
//  MacRDP
//
//  Windows-style file-copy dialog with NATIVE macOS panel chrome.
//  Supports MULTIPLE concurrent copy sessions, one row per session
//  (just like Windows Explorer's transfer window). Each row has its
//  own progress bar, percent, speed, and cancel (✕) button; expanding
//  a row shows its speed-vs-progress chart plus name / ETA / items.
//
//  Two notions of "progress" per session:
//    * progress-bar percentage uses a WEIGHTED total where every file
//      contributes `size + 4 KiB` (directories flat 4 KiB). Lots of
//      tiny files still move the bar at a sane pace.
//    * displayed byte counts and speed use REAL on-disk byte totals
//      so "X of Y" / "Speed: N Mbps" match what's actually moving.
//

import AppKit
import os

@MainActor
final class CopyProgressTracker {

    static let shared = CopyProgressTracker()
    private init() {}

    // MARK: - Session model

    fileprivate struct TrackedItem {
        let id: String
        let name: String
        let size: Int64
        let isDirectory: Bool
        var bytesSeen: Int64 = 0
        var weight: Int64 { isDirectory ? 4096 : (size + 4096) }
        var contributedWeight: Int64 {
            if isDirectory { return weight }
            let seen = max(bytesSeen, 0)
            if seen >= size { return weight }
            return seen
        }
        var contributedReal: Int64 {
            isDirectory ? 0 : min(size, max(bytesSeen, 0))
        }
    }

    /// One per Windows-clipboard event the user copied.
    fileprivate final class Session {
        let id: String
        let title: String
        var items: [String: TrackedItem] = [:]
        var totalWeight: Int64 = 0
        var totalRealBytes: Int64 = 0
        var startedAt: Date? = nil
        var lastChunkAt: Date = Date()
        var lastSampleAt: Date? = nil
        var lastSampleBytes: Int64 = 0
        var cancelled: Bool = false
        var completedNotifiedAt: Date? = nil
        /// Per-session sample buffer for the expandable line chart.
        var speedSamples: [(pct: Double, bps: Double)] = []
        init(id: String, title: String) {
            self.id = id
            self.title = title
        }
    }

    /// Live sessions, oldest-first (UUID lex order is good enough).
    private var sessions: [Session] = []
    /// itemID → sessionID; populated by `registerItems`.
    private var itemToSession: [String: String] = [:]

    private var windowController: CopyProgressWindowController?
    /// Independent ~500ms timer for speed sampling across all sessions.
    private var sampleTimer: Timer?
    /// Auto-close after this much idle time once every session is
    /// either done or cancelled.
    private static let idleHideAfter: TimeInterval = 1.5
    private var hideTimer: Timer?
    /// Per-session deferred "show window" timer. Window only appears
    /// 500 ms after first chunk for a session — instant transfers
    /// don't flash a UI element.
    private var showTimers: [String: Timer] = [:]

    // MARK: - Registration

    /// Called from ClipboardBridge right before its host XPC fetcher
    /// closure can fire. Adds a new session; existing sessions are
    /// preserved (this is multi-copy aware).
    func registerItems(sessionID: String,
                       title: String,
                       entries: [(id: String,
                                   name: String,
                                   size: Int64,
                                   isDirectory: Bool)]) {
        let s = Session(id: sessionID, title: title)
        for e in entries {
            let it = TrackedItem(id: e.id, name: e.name,
                                 size: e.size, isDirectory: e.isDirectory)
            s.items[it.id] = it
            s.totalWeight += it.weight
            if !it.isDirectory { s.totalRealBytes += it.size }
            itemToSession[it.id] = sessionID
        }
        sessions.append(s)
        // NO `ensureWindow()` here — we only register the session.
        // The window appears 500 ms after the first chunk lands for
        // this session (see `_chunkDelivered`). Pure copy events
        // shouldn't produce any visible UI.
    }

    // MARK: - Chunk firehose

    nonisolated func chunkDelivered(itemID: String,
                                    offset: Int64,
                                    length: Int64) {
        Task { @MainActor in self._chunkDelivered(itemID: itemID, offset: offset, length: length) }
    }

    private func _chunkDelivered(itemID: String, offset: Int64, length: Int64) {
        guard let sid = itemToSession[itemID] else { return }
        guard let session = sessions.first(where: { $0.id == sid }) else { return }
        guard var item = session.items[itemID] else { return }
        item.bytesSeen = max(item.bytesSeen, offset + length)
        session.items[itemID] = item
        let isFirstChunk = (session.startedAt == nil)
        if isFirstChunk {
            session.startedAt = Date()
            session.lastSampleAt = session.startedAt
            session.lastSampleBytes = 0
            startSamplerIfNeeded()
            // Defer the window by 500 ms — small / instant transfers
            // (e.g. the synthetic test file or tiny pastes) complete
            // before the timer fires and never produce visible UI.
            let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
                Task { @MainActor in self?.showRowIfStillTransferring(sid: sid) }
            }
            showTimers[sid] = timer
        }
        session.lastChunkAt = Date()
        windowController?.refreshRow(sessionID: sid, snapshot: snapshot(session))
        rescheduleHideIfAllDone()
    }

    private func showRowIfStillTransferring(sid: String) {
        showTimers.removeValue(forKey: sid)
        guard let session = sessions.first(where: { $0.id == sid }) else { return }
        // If the transfer already finished, skip showing the window.
        let weighted = session.items.values.reduce(0) { $0 + $1.contributedWeight }
        if !session.cancelled,
           weighted >= session.totalWeight, session.totalWeight > 0 { return }
        ensureWindow()
        // Show only rows for sessions that have actually started.
        let active = sessions.filter { $0.startedAt != nil }
        windowController?.reloadRows(sessions: active, tracker: self)
        windowController?.refreshRow(sessionID: sid, snapshot: snapshot(session))
    }

    // MARK: - User cancel

    /// Called from the row's ✕ button.
    func cancel(sessionID: String) {
        guard let session = sessions.first(where: { $0.id == sessionID }) else { return }
        session.cancelled = true
        FileProviderXPCService.shared.cancelSession(sessionID: sessionID)
        windowController?.refreshRow(sessionID: sessionID, snapshot: snapshot(session))
        rescheduleHideIfAllDone()
    }

    // MARK: - Sampling

    private func startSamplerIfNeeded() {
        guard sampleTimer == nil else { return }
        sampleTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickSamples() }
        }
    }

    private func tickSamples() {
        let now = Date()
        for session in sessions {
            guard session.startedAt != nil else { continue }
            let nowReal = session.items.values.reduce(0) { $0 + $1.contributedReal }
            let deltaT = session.lastSampleAt.map { now.timeIntervalSince($0) } ?? 0
            let bps = deltaT > 0
                ? Double(nowReal - session.lastSampleBytes) / deltaT
                : 0
            session.lastSampleAt = now
            session.lastSampleBytes = nowReal
            let weighted = session.items.values.reduce(0) { $0 + $1.contributedWeight }
            let frac = session.totalWeight > 0
                ? Double(weighted) / Double(session.totalWeight) : 0
            // De-dup near-identical X to avoid vertical stripes.
            if let last = session.speedSamples.last,
               abs(last.pct - frac) < 0.001 {
                session.speedSamples[session.speedSamples.count - 1] =
                    (frac, (last.bps + max(0, bps)) / 2)
            } else {
                session.speedSamples.append((frac, max(0, bps)))
            }
            windowController?.refreshRow(sessionID: session.id, snapshot: snapshot(session))
        }
    }

    // MARK: - Snapshots / window plumbing

    struct Snapshot {
        let id: String
        let title: String
        let fileCount: Int
        let progressFraction: Double
        let completedRealBytes: Int64
        let totalRealBytes: Int64
        let bytesPerSec: Double
        let etaSeconds: TimeInterval
        let filesCompleted: Int
        let filesTotal: Int
        let currentName: String
        let cancelled: Bool
        let isComplete: Bool
        let speedSamples: [(pct: Double, bps: Double)]
    }

    fileprivate func snapshot(_ session: Session) -> Snapshot {
        let weighted = session.items.values.reduce(0) { $0 + $1.contributedWeight }
        let real = session.items.values.reduce(0) { $0 + $1.contributedReal }
        let frac = session.totalWeight > 0
            ? Double(weighted) / Double(session.totalWeight) : 0
        let elapsed = session.startedAt.map { max(Date().timeIntervalSince($0), 0.001) } ?? 0.001
        let bps = Double(real) / elapsed
        let eta = frac > 0 && frac < 1 ? elapsed * (1.0 / frac - 1.0) : 0
        let files = session.items.values.filter { !$0.isDirectory }
        let done = files.filter { $0.bytesSeen >= $0.size && $0.size > 0 }.count
        let current = session.items.values.first { $0.bytesSeen > 0 && $0.bytesSeen < $0.size }
            ?? session.items.values.first { !$0.isDirectory }
        return Snapshot(
            id: session.id,
            title: session.title,
            fileCount: files.count,
            progressFraction: frac,
            completedRealBytes: real,
            totalRealBytes: session.totalRealBytes,
            bytesPerSec: bps,
            etaSeconds: eta,
            filesCompleted: done,
            filesTotal: files.count,
            currentName: current?.name ?? "—",
            cancelled: session.cancelled,
            isComplete: !session.cancelled && weighted >= session.totalWeight && session.totalWeight > 0,
            speedSamples: session.speedSamples)
    }

    private func ensureWindow() {
        if windowController == nil {
            windowController = CopyProgressWindowController(tracker: self)
        }
        windowController?.showWindow(nil)
    }

    private func rescheduleHideIfAllDone() {
        // Hide only when EVERY active (= ever-transferred) session is
        // done or cancelled. Idle copy events that never received a
        // chunk don't count.
        let activeSessions = sessions.filter { $0.startedAt != nil }
        guard !activeSessions.isEmpty else { return }
        let allDone = activeSessions.allSatisfy { session in
            let w = session.items.values.reduce(0) { $0 + $1.contributedWeight }
            return session.cancelled || (w >= session.totalWeight && session.totalWeight > 0)
        }
        hideTimer?.invalidate()
        guard allDone else { return }
        hideTimer = Timer.scheduledTimer(withTimeInterval: Self.idleHideAfter, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.closeWindowIfStillIdle() }
        }
    }

    private func closeWindowIfStillIdle() {
        let activeSessions = sessions.filter { $0.startedAt != nil }
        let allDone = activeSessions.allSatisfy { session in
            let w = session.items.values.reduce(0) { $0 + $1.contributedWeight }
            return session.cancelled || (w >= session.totalWeight && session.totalWeight > 0)
        }
        guard allDone else { return }
        // Keep registered-but-never-started sessions around — they
        // may be triggered by a paste later. But drop the active ones.
        sessions.removeAll { $0.startedAt != nil }
        // Best-effort: also drop their item mappings.
        let liveItemIDs = Set(sessions.flatMap { $0.items.keys })
        itemToSession = itemToSession.filter { liveItemIDs.contains($0.key) }
        sampleTimer?.invalidate(); sampleTimer = nil
        windowController?.close()
        windowController = nil
    }
}

// MARK: - Window

@MainActor
private final class CopyProgressWindowController: NSWindowController {

    static let fixedContentWidth: CGFloat = 560

    private weak var tracker: CopyProgressTracker?
    private let stack = NSStackView()
    private let scrollView = NSScrollView()
    /// Active rows by sessionID so updates are O(1).
    private var rows: [String: SessionRowView] = [:]
    private var orderedRowIDs: [String] = []

    init(tracker: CopyProgressTracker) {
        self.tracker = tracker
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0,
                                width: Self.fixedContentWidth,
                                height: 200),
            styleMask: [.titled, .closable, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false)
        panel.title = "Copying"
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces]
        panel.center()
        // Reasonable size limits.
        panel.minSize = NSSize(width: Self.fixedContentWidth, height: 140)
        panel.maxSize = NSSize(width: Self.fixedContentWidth, height: 1600)
        super.init(window: panel)
        buildLayout()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func buildLayout() {
        guard let content = window?.contentView else { return }

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.documentView = stack
        scrollView.verticalScrollElasticity = .allowed

        content.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: content.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            // Stack inherits the scroll view's width.
            stack.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
        ])
    }

    func reloadRows(sessions: [CopyProgressTracker.Session],
                    tracker: CopyProgressTracker) {
        // Snapshot the desired ordered ids; add any missing, remove any
        // stale, keep existing rows intact.
        let desired = sessions.map { $0.id }
        let desiredSet = Set(desired)

        for sid in orderedRowIDs where !desiredSet.contains(sid) {
            rows[sid]?.removeFromSuperview()
            rows.removeValue(forKey: sid)
        }
        orderedRowIDs.removeAll { !desiredSet.contains($0) }

        for sid in desired where rows[sid] == nil {
            let row = SessionRowView(sessionID: sid) { [weak tracker] in
                tracker?.cancel(sessionID: sid)
            }
            rows[sid] = row
            orderedRowIDs.append(sid)
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor,
                                        constant: -32).isActive = true
        }
        relayoutForRowCount()
    }

    func refreshRow(sessionID: String, snapshot: CopyProgressTracker.Snapshot) {
        rows[sessionID]?.apply(snapshot)
        relayoutForRowCount()
    }

    private func relayoutForRowCount() {
        guard let win = window else { return }
        // Re-derive content height from sum of row fitting sizes.
        let totalRowHeight = orderedRowIDs.reduce(CGFloat(0)) {
            $0 + (rows[$1]?.fittingHeight ?? 80) + 6
        }
        let target = min(max(140, totalRowHeight + 24), 1200)
        let frame = win.frame
        let contentH = win.contentRect(forFrameRect: frame).size.height
        if abs(contentH - target) > 1 {
            win.setContentSize(NSSize(width: Self.fixedContentWidth,
                                      height: target))
        }
    }
}

// MARK: - Per-session row

@MainActor
private final class SessionRowView: NSView {

    private let sessionID: String
    private let onCancel: () -> Void

    private let header = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()
    private let percent = NSTextField(labelWithString: "0%")
    private let cancelButton = NSButton()
    private let detailsToggle = NSButton(title: "More details ⌄",
                                          target: nil, action: nil)
    private let detailsBlock = NSStackView()
    private let chart = SpeedChartView()
    private let speedLabel = NSTextField(labelWithString: "Speed: —")
    private let nameLabel = NSTextField(labelWithString: "Name: —")
    private let etaLabel = NSTextField(labelWithString: "Time remaining: —")
    private let itemsLabel = NSTextField(labelWithString: "Items remaining: —")
    private var detailsExpanded = false

    init(sessionID: String, onCancel: @escaping () -> Void) {
        self.sessionID = sessionID
        self.onCancel = onCancel
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.6).cgColor
        layer?.cornerRadius = 8
        buildLayout()
    }
    required init?(coder: NSCoder) { fatalError() }

    var fittingHeight: CGFloat {
        layoutSubtreeIfNeeded()
        return fittingSize.height
    }

    private func buildLayout() {
        header.font = .systemFont(ofSize: 12, weight: .medium)
        header.lineBreakMode = .byTruncatingMiddle
        percent.font = .systemFont(ofSize: 11)
        percent.textColor = .secondaryLabelColor

        bar.style = .bar
        bar.isIndeterminate = false
        bar.minValue = 0
        bar.maxValue = 1
        bar.doubleValue = 0

        // Per-row Cancel button. Bordered + labelled so it's
        // unmistakably a button (the earlier borderless glyph was
        // easy to miss).
        cancelButton.title = "Cancel"
        cancelButton.bezelStyle = .rounded
        cancelButton.controlSize = .small
        cancelButton.font = .systemFont(ofSize: 11)
        cancelButton.target = self
        cancelButton.action = #selector(handleCancel)
        cancelButton.toolTip = "Cancel this copy"

        detailsToggle.bezelStyle = .recessed
        detailsToggle.font = .systemFont(ofSize: 10)
        detailsToggle.target = self
        detailsToggle.action = #selector(toggleDetails)

        for l in [speedLabel, nameLabel, etaLabel, itemsLabel] {
            l.font = .systemFont(ofSize: 10)
            l.textColor = .secondaryLabelColor
            l.lineBreakMode = .byTruncatingMiddle
        }

        detailsBlock.orientation = .vertical
        detailsBlock.alignment = .leading
        detailsBlock.spacing = 2
        detailsBlock.addArrangedSubview(chart)
        detailsBlock.addArrangedSubview(speedLabel)
        detailsBlock.addArrangedSubview(nameLabel)
        detailsBlock.addArrangedSubview(etaLabel)
        detailsBlock.addArrangedSubview(itemsLabel)
        detailsBlock.isHidden = true
        chart.translatesAutoresizingMaskIntoConstraints = false
        chart.heightAnchor.constraint(equalToConstant: 70).isActive = true

        // Header row: title + cancel button on the right.
        let headerRow = NSStackView(views: [header, cancelButton])
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.distribution = .fill
        cancelButton.setContentHuggingPriority(.required, for: .horizontal)
        header.setContentHuggingPriority(.defaultLow, for: .horizontal)

        // Bar row: bar + percent on the right.
        let barRow = NSStackView(views: [bar, percent])
        barRow.orientation = .horizontal
        barRow.alignment = .centerY
        percent.setContentHuggingPriority(.required, for: .horizontal)

        let outer = NSStackView()
        outer.orientation = .vertical
        outer.alignment = .leading
        outer.spacing = 4
        outer.translatesAutoresizingMaskIntoConstraints = false
        outer.addArrangedSubview(headerRow)
        outer.addArrangedSubview(barRow)
        outer.addArrangedSubview(detailsToggle)
        outer.addArrangedSubview(detailsBlock)

        addSubview(outer)
        NSLayoutConstraint.activate([
            outer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            outer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            outer.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            outer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            headerRow.widthAnchor.constraint(equalTo: outer.widthAnchor),
            barRow.widthAnchor.constraint(equalTo: outer.widthAnchor),
            bar.widthAnchor.constraint(greaterThanOrEqualToConstant: 200),
            detailsBlock.widthAnchor.constraint(equalTo: outer.widthAnchor),
            chart.widthAnchor.constraint(equalTo: detailsBlock.widthAnchor),
        ])
    }

    @objc private func handleCancel() {
        onCancel()
    }
    @objc private func toggleDetails() {
        detailsExpanded.toggle()
        detailsBlock.isHidden = !detailsExpanded
        detailsToggle.title = detailsExpanded ? "Fewer details ⌃" : "More details ⌄"
        needsLayout = true
    }

    func apply(_ s: CopyProgressTracker.Snapshot) {
        let pctInt = Int((s.progressFraction * 100).rounded())
        bar.doubleValue = s.progressFraction
        let stateTag: String
        if s.cancelled { stateTag = " — cancelled" }
        else if s.isComplete { stateTag = " — done" }
        else { stateTag = "" }
        let fileWord = s.fileCount == 1 ? "file" : "files"
        header.stringValue =
            "Copying \(formatCount(s.fileCount)) \(fileWord)\(stateTag)  ·  id=\(s.id.prefix(8))"
        percent.stringValue = "\(pctInt)%"

        if s.cancelled || s.isComplete {
            cancelButton.isHidden = true
        }

        let remainingBytes = max(0, s.totalRealBytes - s.completedRealBytes)
        chart.setSamples(s.speedSamples, currentBps: s.bytesPerSec)
        speedLabel.stringValue = "Speed: \(formatNetworkSpeed(s.bytesPerSec))"
        nameLabel.stringValue  = "Name: \(s.currentName)"
        etaLabel.stringValue   = "Time remaining: \(formatDuration(s.etaSeconds, finished: s.isComplete))"
        itemsLabel.stringValue =
            "Items remaining: \(formatCount(s.filesTotal - s.filesCompleted)) "
            + "(\(formatBytes(remainingBytes)))"
    }

    // Formatters (kept here to make the row self-contained).
    private static let countFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        return f
    }()
    private func formatCount(_ n: Int) -> String {
        Self.countFormatter.string(from: NSNumber(value: n)) ?? "\(n)"
    }
    private func formatBytes(_ bytes: Int64) -> String {
        let bcf = ByteCountFormatter()
        bcf.allowedUnits = [.useKB, .useMB, .useGB]
        bcf.countStyle = .binary
        return bcf.string(fromByteCount: bytes)
    }
    private func formatNetworkSpeed(_ bytesPerSec: Double) -> String {
        let bps = max(0, bytesPerSec) * 8
        if bps >= 1_000_000_000 { return String(format: "%.2f Gbps", bps / 1_000_000_000) }
        if bps >= 1_000_000     { return String(format: "%.2f Mbps", bps / 1_000_000) }
        if bps >= 1_000         { return String(format: "%.1f Kbps", bps / 1_000) }
        return "\(Int(bps)) bps"
    }
    private func formatDuration(_ s: TimeInterval, finished: Bool) -> String {
        if finished { return "done" }
        guard s.isFinite, s >= 0 else { return "calculating…" }
        if s < 1 { return "less than a second" }
        if s < 60 { return "about \(Int(s)) seconds" }
        let m = Int(s / 60); let sec = Int(s.truncatingRemainder(dividingBy: 60))
        if m < 60 { return "about \(m) min \(sec) sec" }
        let h = m / 60, mm = m % 60
        return "about \(h) hr \(mm) min"
    }
}

// MARK: - Speed chart (single-session)

@MainActor
private final class SpeedChartView: NSView {

    private var samples: [(pct: Double, bps: Double)] = []
    private var currentBps: Double = 0

    func setSamples(_ s: [(pct: Double, bps: Double)], currentBps: Double) {
        self.samples = s
        self.currentBps = currentBps
        needsDisplay = true
    }

    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        bounds.fill()

        let bottomGap: CGFloat = 14
        let topInset: CGFloat = 12
        let chartRect = NSRect(x: bounds.minX,
                                y: bounds.minY + bottomGap,
                                width: bounds.width,
                                height: max(0, bounds.height - bottomGap - topInset))
        if chartRect.width <= 0 || chartRect.height <= 0 { return }

        NSColor.separatorColor.setStroke()
        let axes = NSBezierPath()
        axes.move(to: NSPoint(x: chartRect.minX, y: chartRect.minY))
        axes.line(to: NSPoint(x: chartRect.maxX, y: chartRect.minY))
        axes.move(to: NSPoint(x: chartRect.minX, y: chartRect.minY))
        axes.line(to: NSPoint(x: chartRect.minX, y: chartRect.maxY))
        axes.lineWidth = 1
        axes.stroke()

        guard !samples.isEmpty else { return }
        let peak = max(samples.map { $0.bps }.max() ?? 1, 1)
        let xy: (Double, Double) -> NSPoint = { pct, bps in
            NSPoint(x: chartRect.minX + chartRect.width * CGFloat(pct),
                    y: chartRect.minY + chartRect.height * CGFloat(bps / peak))
        }
        var pts: [NSPoint] = [xy(0, 0)]
        for s in samples { pts.append(xy(s.pct, s.bps)) }

        let fill = NSBezierPath()
        fill.move(to: NSPoint(x: pts.first!.x, y: chartRect.minY))
        for p in pts { fill.line(to: p) }
        fill.line(to: NSPoint(x: pts.last!.x, y: chartRect.minY))
        fill.close()
        NSColor.controlAccentColor.withAlphaComponent(0.18).setFill()
        fill.fill()

        NSColor.controlAccentColor.setStroke()
        let line = NSBezierPath()
        for (i, p) in pts.enumerated() {
            if i == 0 { line.move(to: p) } else { line.line(to: p) }
        }
        line.lineWidth = 1.5
        line.stroke()

        let speedY = chartRect.minY + chartRect.height * CGFloat(currentBps / peak)
        NSColor.systemRed.withAlphaComponent(0.75).setStroke()
        let dash = NSBezierPath()
        dash.lineWidth = 1
        dash.setLineDash([4, 3], count: 2, phase: 0)
        dash.move(to: NSPoint(x: chartRect.minX, y: speedY))
        dash.line(to: NSPoint(x: chartRect.maxX, y: speedY))
        dash.stroke()

        let bcf = ByteCountFormatter()
        bcf.allowedUnits = [.useKB, .useMB, .useGB]
        bcf.countStyle = .binary
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9),
            .foregroundColor: NSColor.tertiaryLabelColor]
        let peakStr = "\(bcf.string(fromByteCount: Int64(peak)))/s"
        (peakStr as NSString).draw(at: NSPoint(x: chartRect.minX + 4, y: chartRect.maxY - 12),
                                    withAttributes: attrs)
        ("0%" as NSString).draw(at: NSPoint(x: chartRect.minX, y: chartRect.minY - 12),
                                 withAttributes: attrs)
        let hundredSize = ("100%" as NSString).size(withAttributes: attrs)
        ("100%" as NSString).draw(
            at: NSPoint(x: chartRect.maxX - hundredSize.width,
                        y: chartRect.minY - 12),
            withAttributes: attrs)
    }
}
