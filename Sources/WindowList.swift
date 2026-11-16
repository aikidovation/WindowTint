import AppKit
import CoreGraphics

/// One on-screen window from `CGWindowListCopyWindowInfo`. Coordinates are Quartz global
/// points (origin at the top-left of the primary display, y down). The list is front to back.
struct WindowRecord {
    let windowNumber: Int
    let pid: pid_t
    let layer: Int
    let bounds: CGRect
}

enum WindowList {
    /// Every on-screen window, including higher layers. Mission Control is detected from those.
    /// On-screen windows are the ones on the current Space.
    static func copyOnScreen() -> [WindowRecord] {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as NSArray? else { return [] }

        var records: [WindowRecord] = []
        records.reserveCapacity(list.count)
        var seen = Set<Int>()

        for case let info as NSDictionary in list {
            let layer = (info.object(forKey: kCGWindowLayer) as? NSNumber)?.intValue ?? 0
            guard let pid = (info.object(forKey: kCGWindowOwnerPID) as? NSNumber)?.int32Value,
                  pid > 0 else { continue }
            if let alpha = (info.object(forKey: kCGWindowAlpha) as? NSNumber)?.doubleValue, alpha <= 0 { continue }
            guard let number = (info.object(forKey: kCGWindowNumber) as? NSNumber).map({ Int($0.uint32Value) }),
                  number > 0, seen.insert(number).inserted else { continue }
            guard let boundsObject = info.object(forKey: kCGWindowBounds) as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsObject as CFDictionary) else { continue }
            guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else { continue }
            records.append(WindowRecord(windowNumber: number, pid: pid, layer: layer, bounds: bounds))
        }
        return records
    }
}

/// Remembers a process's bundle id so a failed lookup cannot invent a new color.
final class AppIdentity {
    private struct Cached {
        var bundleID: String
        var regular: Bool
    }

    static let windowManagerBundleID = "com.apple.WindowManager"
    static let dockBundleID = "com.apple.dock"

    private var cache: [pid_t: Cached] = [:]

    /// Bundle id if this process has ever been seen, even when this tick's lookup fails.
    func bundleID(for pid: pid_t) -> String? {
        if let cached = cache[pid] { return cached.bundleID }
        guard let id = liveBundleID(for: pid) else { return nil }
        return id
    }

    /// Bundle id of a normal app window we should tint, or nil to skip it this tick.
    func trackableBundleID(for pid: pid_t, excluded: Set<String>) -> String? {
        _ = liveBundleID(for: pid)
        guard let cached = cache[pid], cached.regular else { return nil }
        if cached.bundleID == Self.windowManagerBundleID || cached.bundleID == Self.dockBundleID { return nil }
        if cached.bundleID == Bundle.main.bundleIdentifier { return nil }
        if excluded.contains(cached.bundleID) { return nil }
        return cached.bundleID
    }

    /// Updates the cache when the process can be read. Does not replace a known id with a failed read.
    private func liveBundleID(for pid: pid_t) -> String? {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return cache[pid]?.bundleID }
        guard let id = app.bundleIdentifier, !id.isEmpty else { return cache[pid]?.bundleID }
        cache[pid] = Cached(bundleID: id, regular: app.activationPolicy == .regular)
        return id
    }
}
