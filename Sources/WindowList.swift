import AppKit
import CoreGraphics

/// One on-screen window we may tint. Coordinates are Quartz global points (origin at the
/// top-left of the primary display, y down). The list is front to back.
struct WindowRecord {
    let windowNumber: Int
    let pid: pid_t
    let bounds: CGRect
}

enum WindowList {
    /// Normal on-screen windows, excluding this process. Does not read `kCGWindowName`
    /// (that key is what asks for Screen Recording permission).
    /// On-screen windows are the ones on the current Space. Windows on other Spaces are not included.
    static func copyOnScreen() -> [WindowRecord] {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as NSArray? else { return [] }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        var records: [WindowRecord] = []
        records.reserveCapacity(list.count)
        var seen = Set<Int>()

        for case let info as NSDictionary in list {
            guard (info.object(forKey: kCGWindowLayer) as? NSNumber)?.intValue == 0 else { continue }
            guard let pid = (info.object(forKey: kCGWindowOwnerPID) as? NSNumber)?.int32Value,
                  pid > 0, pid != ownPID else { continue }
            if let alpha = (info.object(forKey: kCGWindowAlpha) as? NSNumber)?.doubleValue, alpha <= 0 { continue }
            guard let number = (info.object(forKey: kCGWindowNumber) as? NSNumber).map({ Int($0.uint32Value) }),
                  number > 0, seen.insert(number).inserted else { continue }
            guard let boundsObject = info.object(forKey: kCGWindowBounds) as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsObject as CFDictionary) else { continue }
            guard bounds.width >= 100, bounds.height >= 60 else { continue }
            guard bounds.width.isFinite, bounds.height.isFinite else { continue }
            records.append(WindowRecord(windowNumber: number, pid: pid, bounds: bounds))
        }
        return records
    }
}
