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

    private var windowController: CopyProgressWindowController?
    private var pollTimer: Timer?
    private var domainSubdir = ""
    /// Consecutive empty polls before stopping the timer — a brief gap
    /// between transfers shouldn't tear the poller down mid-paste.
    private var emptyPolls = 0
    private static let pollInterval: TimeInterval = 0.25   // smoother bar + snappier UI
    private static let stopAfterEmptyPolls = 12            // ~3s idle → stop polling

    /// Wire up at startup: feed the speed window from config, point at the
    /// clipboard domain, and let the store wake us when work starts (so no
    /// perpetual timer runs while idle).
    func configure(domainSubdir: String, speedWindowSec: TimeInterval) {
        self.domainSubdir = domainSubdir
        CopyEventStore.shared.speedWindowSec = speedWindowSec
        CopyEventStore.shared.setActivityWake {
            DispatchQueue.main.async {
                MainActor.assumeIsolated { CopyProgressTracker.shared.startPolling() }
            }
        }
    }

    /// Row's ✕ button — cancel the current transfer (event stays alive).
    func cancel(sessionID: String) {
        CopyEventStore.shared.cancelSession(sessionID: sessionID)
        poll()   // reflect the cancelled state now, not on the next tick
    }

    // MARK: - Poll loop

    private func startPolling() {
        guard pollTimer == nil else { return }
        emptyPolls = 0
        pollTimer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        poll()   // render immediately, don't wait for the first tick
    }

    private func poll() {
        // Single consistent read of all rows. The store ages each event's
        // speed window by "now" inside this call (the stall-decay tick,
        // folded into the poll — there is no separate timer).
        let snaps = CopyEventStore.shared.progressSnapshots(domainSubdir: domainSubdir)

        if snaps.isEmpty {
            emptyPolls += 1
            windowController?.render([], tracker: self)
            if emptyPolls >= Self.stopAfterEmptyPolls {
                pollTimer?.invalidate(); pollTimer = nil
                windowController?.close(); windowController = nil
            }
            return
        }
        emptyPolls = 0
        ensureWindow()
        windowController?.render(snaps, tracker: self)
    }

    private func ensureWindow() {
        if windowController == nil {
            windowController = CopyProgressWindowController(tracker: self)
        }
        windowController?.showWindow(nil)
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

    /// Reconcile the displayed rows with the polled snapshots: add new,
    /// drop gone, apply each.
    func render(_ snapshots: [ClipProgressSnapshot], tracker: CopyProgressTracker) {
        let desired = snapshots.map { $0.id }
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
            row.onLayoutChange = { [weak self] in self?.relayoutForRowCount() }
            rows[sid] = row
            orderedRowIDs.append(sid)
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor,
                                        constant: -32).isActive = true
        }
        for s in snapshots { rows[s.id]?.apply(s) }
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
    /// Called when the row's height changes (expand/collapse) so the
    /// controller can resize the window IMMEDIATELY instead of waiting for
    /// the next poll tick.
    var onLayoutChange: () -> Void = {}

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

        // Header row: title + percent + cancel button on the right. Percent
        // lives here (not next to the bar) so the bar can span the full
        // width and line up exactly with the chart below.
        let headerRow = NSStackView(views: [header, percent, cancelButton])
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.distribution = .fill
        cancelButton.setContentHuggingPriority(.required, for: .horizontal)
        percent.setContentHuggingPriority(.required, for: .horizontal)
        header.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let outer = NSStackView()
        outer.orientation = .vertical
        outer.alignment = .leading
        outer.spacing = 4
        outer.translatesAutoresizingMaskIntoConstraints = false
        outer.addArrangedSubview(headerRow)
        outer.addArrangedSubview(bar)            // full width, aligns with chart
        outer.addArrangedSubview(detailsBlock)   // expanded content ABOVE the toggle
        outer.addArrangedSubview(detailsToggle)

        addSubview(outer)
        NSLayoutConstraint.activate([
            outer.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            outer.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            outer.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            outer.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
            headerRow.widthAnchor.constraint(equalTo: outer.widthAnchor),
            // bar and chart share the SAME width and leading edge → aligned.
            bar.widthAnchor.constraint(equalTo: outer.widthAnchor),
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
        layoutSubtreeIfNeeded()
        onLayoutChange()   // resize the window NOW, don't wait for a poll
    }

    func apply(_ s: ClipProgressSnapshot) {
        switch s.kind {
        case .resolving:
            if !bar.isIndeterminate { bar.isIndeterminate = true }
            bar.startAnimation(nil)
            header.stringValue = "Resolving file list…  ·  id=\(s.id.prefix(8))"
            percent.stringValue = ""
            chart.setSamples([], currentBps: 0)
            speedLabel.stringValue = "Speed: —"
            nameLabel.stringValue  = "Name: —"
            etaLabel.stringValue   = "Time remaining: calculating…"
            itemsLabel.stringValue = "Items remaining: —"
            cancelButton.isHidden = false

        case .transferring:
            if bar.isIndeterminate { bar.stopAnimation(nil); bar.isIndeterminate = false }
            let pctInt = Int((s.progressFraction * 100).rounded())
            bar.doubleValue = s.progressFraction
            let stateTag = s.cancelled ? " — cancelled" : (s.isComplete ? " — done" : "")
            let fileWord = s.filesTotal == 1 ? "file" : "files"
            header.stringValue =
                "Copying \(formatCount(s.filesTotal)) \(fileWord)\(stateTag)  ·  id=\(s.id.prefix(8))"
            percent.stringValue = "\(pctInt)%"
            cancelButton.isHidden = (s.cancelled || s.isComplete)
            let remainingBytes = max(0, s.totalRealBytes - s.completedRealBytes)
            chart.setSamples(s.chart, currentBps: s.bytesPerSec)
            speedLabel.stringValue = "Speed: \(formatNetworkSpeed(s.bytesPerSec))"
            nameLabel.stringValue  = "Name: \(s.currentName)"
            // Resolved but no bytes yet → "waiting for transfer" instead of
            // a misleading "less than a second".
            let waiting = s.completedRealBytes == 0 && !s.isComplete
            etaLabel.stringValue = waiting
                ? "Time remaining: waiting for transfer"
                : "Time remaining: \(formatDuration(s.etaSeconds, finished: s.isComplete))"
            itemsLabel.stringValue =
                "Items remaining: \(formatCount(s.filesTotal - s.filesCompleted)) "
                + "(\(formatBytes(remainingBytes)))"
        }
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

    private var samples: [ChartPoint] = []
    private var currentBps: Double = 0

    func setSamples(_ s: [ChartPoint], currentBps: Double) {
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
