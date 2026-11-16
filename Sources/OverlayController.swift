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
            logIfChanged(trigger: trigger, onScreen: windows.count, rows: [], zOrder: [])
            return counts
        }
        guard let primaryHeight = Self.primaryScreenHeight() else { return counts }

        let excluded = settings.excludedBundleIDs
        let borderWidth = settings.borderWidth
        let showsTint = settings.tintEnabled
        let now = Date()
        var shown: [Desired] = []
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
            let visible = !skip && !moving && !unsettled
            if !skip && (moving || unsettled) { waitingForStable = true }
            if !visible {
                rows.append(DebugLog.Row(
                    windowID: window.windowNumber, pid: window.pid, bundleID: bundleID,
                    frame: window.bounds, state: "hidden", color: color.hexRGB
                ))
                continue
            }
            lastMovedAt.removeValue(forKey: window.windowNumber)
            let frame = Self.cocoaFrame(fromQuartz: window.bounds, primaryHeight: primaryHeight)
            shown.append(Desired(windowID: window.windowNumber, frame: frame, color: color, colorHex: color.hexRGB))
            rows.append(DebugLog.Row(
                windowID: window.windowNumber, pid: window.pid, bundleID: bundleID,
                frame: window.bounds,
                state: placement[window.windowNumber]?.shown == true ? "shown" : "created",
                color: color.hexRGB
            ))
        }

        // Window list is front to back. Ordering back to front puts each border just above its window.
        let zOrder = Array(shown.reversed())
        apply(zOrder: zOrder, borderWidth: borderWidth, showsTint: showsTint)
        if waitingForStable { armStabilityCheck() }
        logIfChanged(trigger: trigger, onScreen: windows.count, rows: rows, zOrder: zOrder.map(\.windowID))
        return counts
    }

    /// Last AppKit state. Refresh does nothing when the desired frame, visibility, and z-order match this.
    private struct Placement {
        var shown: Bool
        var frame: NSRect
        var colorHex: String
        var borderWidth: CGFloat
        var showsTint: Bool
    }

    private struct Desired {
        var windowID: Int
        var frame: NSRect
        var color: NSColor
        var colorHex: String
    }

    private var placement: [Int: Placement] = [:]
    private var appliedOrder: [Int] = []
    private var lastLogKey: String?

    private func apply(zOrder: [Desired], borderWidth: CGFloat, showsTint: Bool) {
        let shownIDs = Set(zOrder.map(\.windowID))
        for id in Array(placement.keys) where !shownIDs.contains(id) {
            guard var place = placement[id], place.shown else { continue }
            overlays[id]?.hide()
            place.shown = false
            placement[id] = place
        }
        for (index, item) in zOrder.enumerated() {
            let overlay = overlays[item.windowID] ?? makeOverlay(number: item.windowID)
            let previous = placement[item.windowID]
            if previous == nil || !Self.sameFrame(previous!.frame, item.frame) {
                overlay.setFrame(item.frame)
            }
            if previous == nil
                || previous!.colorHex != item.colorHex
                || previous!.borderWidth != borderWidth
                || previous!.showsTint != showsTint {
                overlay.applyStyle(color: item.color, borderWidth: borderWidth, showsTint: showsTint)
            }
            let zChanged = appliedOrder.firstIndex(of: item.windowID) != index || previous?.shown != true
            if zChanged {
                overlay.orderAboveOwner()
            }
            placement[item.windowID] = Placement(
                shown: true,
                frame: previous != nil && Self.sameFrame(previous!.frame, item.frame) ? previous!.frame : item.frame,
                colorHex: item.colorHex,
                borderWidth: borderWidth,
                showsTint: showsTint
            )
        }
        appliedOrder = zOrder.map(\.windowID)
    }

    private func logIfChanged(trigger: String, onScreen: Int, rows: [DebugLog.Row], zOrder: [Int]) {
        let key = zOrder.map(String.init).joined(separator: ",") + "|" + rows.map { row in
            let frame = row.frame
            return "\(row.windowID):\(row.state):\(row.color):\(Int(frame.origin.x)),\(Int(frame.origin.y)),\(Int(frame.width))x\(Int(frame.height))"
        }.joined(separator: ";")
        guard key != lastLogKey else { return }
        lastLogKey = key
        DebugLog.write(trigger: trigger, onScreen: onScreen, zOrder: zOrder, rows: rows)
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
        for (id, overlay) in overlays {
            guard var place = placement[id], place.shown else { continue }
            overlay.hide()
            place.shown = false
            placement[id] = place
        }
        appliedOrder = []
    }

    private static func sameFrame(_ a: NSRect, _ b: NSRect) -> Bool {
        abs(a.origin.x - b.origin.x) < 0.5
            && abs(a.origin.y - b.origin.y) < 0.5
            && abs(a.size.width - b.size.width) < 0.5
            && abs(a.size.height - b.size.height) < 0.5
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

    func setFrame(_ frame: NSRect) {
        window.setFrame(frame, display: false, animate: false)
    }

    func applyStyle(color: NSColor, borderWidth: CGFloat, showsTint: Bool) {
        border.apply(color: color, width: borderWidth, tint: showsTint)
    }

    func orderAboveOwner() {
        window.order(.above, relativeTo: ownerWindowNumber)
    }

    func hide() {
        window.orderOut(nil)
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
