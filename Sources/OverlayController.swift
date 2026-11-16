import AppKit

/// One click-through border (and optional tint) per target window, keyed by window number.
final class OverlayController {
    /// Fired about 150 ms after a window's frame stops changing, so a hidden border can come back.
    var onNeedsRefresh: (() -> Void)?

    private var overlays: [Int: Overlay] = [:]
    private let colors = AppColor()
    private var previousBounds: [Int: CGRect] = [:]
    private var lastMovedAt: [Int: Date] = [:]
    private var stableWork: DispatchWorkItem?
    private static let stableDelay: TimeInterval = 0.15

    /// Places borders for on-screen windows and orders the others out without destroying them.
    /// An overlay is created only when its target is on screen and its frame has settled, so the
    /// first `order(.above, relativeTo:)` joins the target's Space. The same window is ordered
    /// back in when that target returns.
    func refresh(windows: [WindowRecord], settings: Settings, trigger: String) -> [pid_t: Int] {
        var counts: [pid_t: Int] = [:]
        for window in windows {
            counts[window.pid, default: 0] += 1
        }
        guard settings.isEnabled else {
            orderOutAll()
            log(trigger: trigger, windows: windows, rows: [])
            return counts
        }
        guard let primaryHeight = Self.primaryScreenHeight() else { return counts }

        let excluded = settings.excludedBundleIDs
        let borderWidth = settings.borderWidth
        let showsTint = settings.tintEnabled
        let now = Date()
        let onScreen = Set(windows.map(\.windowNumber))
        for (number, overlay) in overlays where !onScreen.contains(number) {
            overlay.hide()
        }

        var placed: [(number: Int, frame: NSRect, color: NSColor)] = []
        var rows: [DebugLog.Row] = []
        var waitingForStable = false

        for window in windows {
            let app = NSRunningApplication(processIdentifier: window.pid)
            let bundleID = app?.bundleIdentifier ?? "pid:\(window.pid)"
            let skip = app?.bundleIdentifier == Bundle.main.bundleIdentifier
                || (app?.bundleIdentifier).map { excluded.contains($0) } == true
            let known = previousBounds[window.windowNumber]
            // No stored frame means this window just appeared. Wait until the frame holds still
            // so a Space animation cannot flash a border in the wrong place.
            let moving = known.map { Self.framesDiffer($0, window.bounds) } ?? true
            previousBounds[window.windowNumber] = window.bounds
            if moving { lastMovedAt[window.windowNumber] = now }
            let unsettled = lastMovedAt[window.windowNumber].map { now.timeIntervalSince($0) < Self.stableDelay } ?? false
            let color = colors.color(
                bundleID: bundleID,
                windowNumber: window.windowNumber,
                icon: app?.icon,
                overrideHex: app?.bundleIdentifier.flatMap { settings.overrideHex(for: $0) }
            )
            if skip || moving || unsettled {
                overlays[window.windowNumber]?.hide()
                if !skip && (moving || unsettled) { waitingForStable = true }
                rows.append(DebugLog.Row(
                    windowID: window.windowNumber, pid: window.pid, bundleID: bundleID,
                    frame: window.bounds, state: "hidden", color: color.hexRGB
                ))
                continue
            }
            lastMovedAt.removeValue(forKey: window.windowNumber)
            let created = overlays[window.windowNumber] == nil
            let frame = Self.cocoaFrame(fromQuartz: window.bounds, primaryHeight: primaryHeight)
            placed.append((window.windowNumber, frame, color))
            rows.append(DebugLog.Row(
                windowID: window.windowNumber, pid: window.pid, bundleID: bundleID,
                frame: window.bounds, state: created ? "created" : "shown", color: color.hexRGB
            ))
        }

        // Back to front, so each border is ordered just above its own window.
        // That is the relationship Mission Control sometimes captures; every on-screen window gets it.
        for item in placed.reversed() {
            let overlay = overlays[item.number] ?? makeOverlay(number: item.number)
            overlay.update(frame: item.frame, color: item.color, borderWidth: borderWidth, showsTint: showsTint)
            overlay.orderAboveOwner()
        }
        if waitingForStable { armStabilityCheck() }
        log(trigger: trigger, windows: windows, rows: rows)
        return counts
    }

    private func log(trigger: String, windows: [WindowRecord], rows: [DebugLog.Row]) {
        DebugLog.write(trigger: trigger, onScreen: windows.count, rows: rows)
    }

    private func armStabilityCheck() {
        stableWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.onNeedsRefresh?()
        }
        stableWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.stableDelay, execute: work)
    }

    private func makeOverlay(number: Int) -> Overlay {
        let overlay = Overlay(ownerWindowNumber: number)
        overlays[number] = overlay
        return overlay
    }

    private func orderOutAll() {
        for overlay in overlays.values { overlay.hide() }
    }

    private static func framesDiffer(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.origin.x - b.origin.x) > 1
            || abs(a.origin.y - b.origin.y) > 1
            || abs(a.size.width - b.size.width) > 1
            || abs(a.size.height - b.size.height) > 1
    }

    /// Primary display height. Quartz y is measured from the top of that display; Cocoa y from its bottom.
    private static func primaryScreenHeight() -> CGFloat? {
        NSScreen.screens.first {
            abs($0.frame.origin.x) < 1 && abs($0.frame.origin.y) < 1
        }?.frame.height
    }

    private static func cocoaFrame(fromQuartz rect: CGRect, primaryHeight: CGFloat) -> NSRect {
        NSRect(
            x: rect.origin.x,
            y: primaryHeight - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }
}

private final class Overlay {
    let ownerWindowNumber: Int
    private let window: NSWindow
    private let border: BorderView

    init(ownerWindowNumber: Int) {
        self.ownerWindowNumber = ownerWindowNumber
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 60),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = .normal
        // `.managed` stays on the Space where this window was first ordered in.
        // `.transient` would follow the active Space and show up torn off from its window.
        // `.ignoresCycle` leaves it out of Cmd-`. `.fullScreenAuxiliary` shares a full-screen space.
        window.collectionBehavior = [.managed, .ignoresCycle, .fullScreenAuxiliary]
        window.hidesOnDeactivate = false
        window.isExcludedFromWindowsMenu = true
        window.animationBehavior = .none

        let border = BorderView(frame: .zero)
        border.autoresizingMask = [.width, .height]
        window.contentView = border
        self.window = window
        self.border = border
    }

    func update(frame: NSRect, color: NSColor, borderWidth: CGFloat, showsTint: Bool) {
        if !Self.nearlyEqual(window.frame, frame) {
            window.setFrame(frame, display: false, animate: false)
        }
        border.apply(color: color, width: borderWidth, tint: showsTint)
    }

    func orderAboveOwner() {
        window.order(.above, relativeTo: ownerWindowNumber)
    }

    func hide() {
        window.orderOut(nil)
    }

    private static func nearlyEqual(_ a: NSRect, _ b: NSRect) -> Bool {
        abs(a.origin.x - b.origin.x) < 0.5
            && abs(a.origin.y - b.origin.y) < 0.5
            && abs(a.size.width - b.size.width) < 0.5
            && abs(a.size.height - b.size.height) < 0.5
    }
}

private final class BorderView: NSView {
    private var borderColor: NSColor = .systemBlue
    private var borderWidth: CGFloat = 4
    private var showsTint: Bool = false

    override var isOpaque: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        layer?.isOpaque = false
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true
    }

    func apply(color: NSColor, width: CGFloat, tint: Bool) {
        let changed = !borderColor.isEqual(color) || borderWidth != width || showsTint != tint
        borderColor = color
        borderWidth = width
        showsTint = tint
        if changed { needsDisplay = true }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width > 1, bounds.height > 1 else { return }
        NSColor.clear.setFill()
        dirtyRect.fill()

        let outerRadius = min(Settings.cornerRadius, min(bounds.width, bounds.height) / 2)
        if showsTint {
            let outer = NSBezierPath(roundedRect: bounds, xRadius: outerRadius, yRadius: outerRadius)
            borderColor.withAlphaComponent(Settings.tintOpacity).setFill()
            outer.fill()
        }

        let inset = borderWidth / 2
        let innerRect = bounds.insetBy(dx: inset, dy: inset)
        guard innerRect.width > 1, innerRect.height > 1 else { return }
        let innerRadius = max(0, outerRadius - inset)
        let inner = NSBezierPath(roundedRect: innerRect, xRadius: innerRadius, yRadius: innerRadius)
        borderColor.setStroke()
        inner.lineWidth = borderWidth
        inner.lineJoinStyle = .round
        inner.stroke()
    }
}
