import AppKit

/// One click-through border (and optional tint) per target window, keyed by window number.
final class OverlayController {
    /// Fired about 150 ms after a window's frame stops changing, so a hidden border can come back.
    var onNeedsRefresh: (() -> Void)?

    private var overlays: [Int: Overlay] = [:]
    private let colors = AppColor()
    private let identity = AppIdentity()
    private var previousBounds: [Int: CGRect] = [:]
    private var lastMovedAt: [Int: Date] = [:]
    private var stableWork: DispatchWorkItem?
    private var missionActive = false
    private var missionQuietSince: Date?
    private static let stableDelay: TimeInterval = 0.15
    private static let missionExitDelay: TimeInterval = 0.30

    /// Places borders for on-screen windows and orders the others out without destroying them.
    /// An overlay is created only when its target is on screen and its frame has settled, so the
    /// first `order(.above, relativeTo:)` joins the target's Space. The same window is ordered
    /// back in when that target returns.
    func refresh(windows: [WindowRecord], settings: Settings, trigger: String) -> [pid_t: Int] {
        guard settings.isEnabled else {
            orderOutAll()
            logIfChanged(trigger: trigger, onScreen: windows.count, rows: [], zOrder: [])
            return [:]
        }
        guard let primaryHeight = Self.primaryScreenHeight() else { return [:] }

        let excluded = settings.excludedBundleIDs
        if freezeForMissionControl(windows, excluded: excluded, trigger: trigger) {
            var countsDuringFreeze: [pid_t: Int] = [:]
            for item in trackable(windows, excluded: excluded) {
                countsDuringFreeze[item.pid, default: 0] += 1
            }
            return countsDuringFreeze
        }

        var counts: [pid_t: Int] = [:]
        let borderWidth = settings.borderWidth
        let showsTint = settings.tintEnabled
        let now = Date()
        var shown: [Desired] = []
        var rows: [DebugLog.Row] = []
        var waitingForStable = false

        for window in windows where window.layer == 0 && window.bounds.width >= 100 && window.bounds.height >= 60 {
            guard let bundleID = identity.trackableBundleID(for: window.pid, excluded: excluded) else { continue }
            counts[window.pid, default: 0] += 1
            let known = previousBounds[window.windowNumber]
            // No stored frame means this window just appeared. Wait until the frame holds still
            // so a Space animation cannot flash a border in the wrong place.
            let moving = known.map { Self.framesDiffer($0, window.bounds) } ?? true
            previousBounds[window.windowNumber] = window.bounds
            if moving { lastMovedAt[window.windowNumber] = now }
            let unsettled = lastMovedAt[window.windowNumber].map { now.timeIntervalSince($0) < Self.stableDelay } ?? false
            let app = NSRunningApplication(processIdentifier: window.pid)
            let color = colors.color(
                bundleID: bundleID,
                windowNumber: window.windowNumber,
                icon: app?.icon,
                overrideHex: settings.overrideHex(for: bundleID)
            )
            let visible = !moving && !unsettled
            if moving || unsettled { waitingForStable = true }
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
        logIfChanged(trigger: trigger, onScreen: rows.count, rows: rows, zOrder: zOrder.map(\.windowID))
        return counts
    }

    /// Mission Control reports scaled, moving preview frames. Touching overlays in response
    /// makes those previews re-layout forever. While it is active, leave every overlay as it is.
    private func freezeForMissionControl(_ windows: [WindowRecord], excluded: Set<String>, trigger: String) -> Bool {
        let detected = missionDetected(windows, excluded: excluded)
        let framesChanging = trackedFramesChanging(windows, excluded: excluded)
        let wasActive = missionActive
        if detected.reasons.isEmpty {
            guard missionActive else { return false }
            if framesChanging {
                missionQuietSince = Date()
                return true
            }
            if missionQuietSince == nil { missionQuietSince = Date() }
            if Date().timeIntervalSince(missionQuietSince!) < Self.missionExitDelay {
                return true
            }
            missionActive = false
            missionQuietSince = nil
            logMissionControl(entering: false, reason: "frames-stable", windows: windows, trigger: trigger)
            return false
        }
        missionActive = true
        missionQuietSince = nil
        if !wasActive {
            logMissionControl(entering: true, reason: detected.reasons.joined(separator: "+"), windows: windows, trigger: trigger)
        }
        return true
    }

    private struct MissionHit {
        var reasons: [String]
    }

    private func missionDetected(_ windows: [WindowRecord], excluded: Set<String>) -> MissionHit {
        var reasons: [String] = []
        if dockCoversScreen(windows) { reasons.append("dock-cover") }
        if windowManagerLayerZero(windows) { reasons.append("window-manager") }
        if uniformScale(windows, excluded: excluded) { reasons.append("uniform-scale") }
        return MissionHit(reasons: reasons)
    }

    private func dockCoversScreen(_ windows: [WindowRecord]) -> Bool {
        windows.contains { window in
            window.layer > 0
                && identity.bundleID(for: window.pid) == AppIdentity.dockBundleID
                && coversWholeScreen(window.bounds)
        }
    }

    private func windowManagerLayerZero(_ windows: [WindowRecord]) -> Bool {
        windows.contains { window in
            window.layer == 0
                && window.bounds.width >= 100
                && window.bounds.height >= 60
                && identity.bundleID(for: window.pid) == AppIdentity.windowManagerBundleID
        }
    }

    /// Several already-tracked windows resized by the same factor in this tick.
    private func uniformScale(_ windows: [WindowRecord], excluded: Set<String>) -> Bool {
        var scales: [CGFloat] = []
        for window in windows where window.layer == 0 {
            guard identity.trackableBundleID(for: window.pid, excluded: excluded) != nil else { continue }
            guard let old = previousBounds[window.windowNumber], old.width > 20, old.height > 20 else { continue }
            let widthChanged = abs(window.bounds.width - old.width) > 1
            let heightChanged = abs(window.bounds.height - old.height) > 1
            guard widthChanged || heightChanged else { continue }
            let scaleX = window.bounds.width / old.width
            let scaleY = window.bounds.height / old.height
            guard abs(scaleX - scaleY) < 0.08 else { continue }
            scales.append(scaleX)
        }
        guard scales.count >= 2 else { return false }
        let mean = scales.reduce(0, +) / CGFloat(scales.count)
        return scales.allSatisfy { abs($0 - mean) < 0.06 }
    }

    private func trackedFramesChanging(_ windows: [WindowRecord], excluded: Set<String>) -> Bool {
        for window in windows where window.layer == 0 {
            guard identity.trackableBundleID(for: window.pid, excluded: excluded) != nil else { continue }
            guard let old = previousBounds[window.windowNumber] else { continue }
            if Self.framesDiffer(old, window.bounds) { return true }
        }
        return false
    }

    private func coversWholeScreen(_ bounds: CGRect) -> Bool {
        NSScreen.screens.contains { screen in
            let size = screen.frame.size
            return bounds.width >= size.width * 0.85 && bounds.height >= size.height * 0.85
        }
    }

    private func trackable(_ windows: [WindowRecord], excluded: Set<String>) -> [WindowRecord] {
        windows.filter { window in
            window.layer == 0
                && window.bounds.width >= 100
                && window.bounds.height >= 60
                && identity.trackableBundleID(for: window.pid, excluded: excluded) != nil
        }
    }

    private func logMissionControl(entering: Bool, reason: String, windows: [WindowRecord], trigger: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        var lines = ["\(stamp) mission-control \(entering ? "enter" : "exit") reason=\(reason) trigger=\(trigger)"]
        for window in windows where window.layer != 0 {
            let bundle = identity.bundleID(for: window.pid) ?? "?"
            let frame = window.bounds
            lines.append(
                "  layer=\(window.layer) pid=\(window.pid) bundle=\(bundle) " +
                "bounds=\(Int(frame.origin.x)),\(Int(frame.origin.y)),\(Int(frame.width))x\(Int(frame.height))"
            )
        }
        let layerZeroManager = windows.filter {
            $0.layer == 0 && identity.bundleID(for: $0.pid) == AppIdentity.windowManagerBundleID
        }
        if !layerZeroManager.isEmpty {
            lines.append("  window-manager-layer0=\(layerZeroManager.count)")
        }
        DebugLog.writeRaw(lines.joined(separator: "\n"))
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
