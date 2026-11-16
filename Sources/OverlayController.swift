import AppKit

/// One click-through border (and optional tint) per target window, keyed by window number.
final class OverlayController {
    private var overlays: [Int: Overlay] = [:]
    private let colors = AppColor()

    /// Places borders for `windows` (front to back). Returns how many listed windows each pid owns,
    /// including ones skipped for exclusion, so accessibility subscriptions can track opens and closes.
    func refresh(windows: [WindowRecord], settings: Settings) -> [pid_t: Int] {
        var counts: [pid_t: Int] = [:]
        for window in windows {
            counts[window.pid, default: 0] += 1
        }
        guard settings.isEnabled else {
            removeAll()
            return counts
        }
        guard let primaryHeight = Self.primaryScreenHeight() else { return counts }

        let excluded = settings.excludedBundleIDs
        let borderWidth = settings.borderWidth
        let showsTint = settings.tintEnabled
        var live = Set<Int>()
        var placed: [(number: Int, frame: NSRect, color: NSColor)] = []

        for window in windows {
            let app = NSRunningApplication(processIdentifier: window.pid)
            if let bundleID = app?.bundleIdentifier, bundleID == Bundle.main.bundleIdentifier { continue }
            if let bundleID = app?.bundleIdentifier, excluded.contains(bundleID) { continue }
            let frame = Self.cocoaFrame(fromQuartz: window.bounds, primaryHeight: primaryHeight)
            let bundleID = app?.bundleIdentifier ?? "pid:\(window.pid)"
            let color = colors.color(
                bundleID: bundleID,
                windowNumber: window.windowNumber,
                icon: app?.icon,
                overrideHex: app?.bundleIdentifier.flatMap { settings.overrideHex(for: $0) }
            )
            live.insert(window.windowNumber)
            placed.append((window.windowNumber, frame, color))
        }

        for number in Array(overlays.keys) where !live.contains(number) {
            overlays[number]?.hide()
            overlays.removeValue(forKey: number)
        }

        // Back to front, so each border is ordered just above its own window and stays
        // under windows that are already in front of it.
        for item in placed.reversed() {
            let overlay = overlays[item.number] ?? makeOverlay(number: item.number)
            overlay.update(frame: item.frame, color: item.color, borderWidth: borderWidth, showsTint: showsTint)
            overlay.orderAboveOwner()
        }
        return counts
    }

    private func makeOverlay(number: Int) -> Overlay {
        let overlay = Overlay(ownerWindowNumber: number)
        overlays[number] = overlay
        return overlay
    }

    private func removeAll() {
        for overlay in overlays.values { overlay.hide() }
        overlays.removeAll()
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
        // `.canJoinAllSpaces` would paint the border on spaces that do not contain the window.
        // `.moveToActiveSpace` would drag it onto the active space every time we re-order.
        // `.stationary` keeps Mission Control from treating the border as a document window.
        // `.ignoresCycle` leaves it out of Cmd-`. `.fullScreenAuxiliary` shares a full-screen space.
        window.collectionBehavior = [.stationary, .ignoresCycle, .fullScreenAuxiliary]
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
