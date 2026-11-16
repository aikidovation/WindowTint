import AppKit

/// Icon color for a bundle, plus a stable per-window shade.
final class AppColor {
    private var baseByBundle: [String: NSColor] = [:]
    /// Keyed by bundle id and window number, so the shade is a function of those two and does not follow a recycled id onto another app.
    private var indexByBundleWindow: [String: Int] = [:]
    private var nextIndexByBundle: [String: Int] = [:]

    func color(bundleID: String, windowNumber: Int, icon: NSImage?, overrideHex: String?) -> NSColor {
        let base = resolvedBase(bundleID: bundleID, icon: icon, overrideHex: overrideHex)
        return Self.shade(base, index: shadeIndex(bundleID: bundleID, windowNumber: windowNumber))
    }

    /// First window seen for a bundle is index 0. Later windows of that same bundle get the next index, and keep it.
    private func shadeIndex(bundleID: String, windowNumber: Int) -> Int {
        let key = "\(bundleID)\t\(windowNumber)"
        if let existing = indexByBundleWindow[key] { return existing }
        let next = nextIndexByBundle[bundleID] ?? 0
        indexByBundleWindow[key] = next
        nextIndexByBundle[bundleID] = next + 1
        return next
    }

    private func resolvedBase(bundleID: String, icon: NSImage?, overrideHex: String?) -> NSColor {
        if let overrideHex, let parsed = NSColor(hex: overrideHex) {
            return parsed
        }
        if let cached = baseByBundle[bundleID] { return cached }
        // Don't cache a missing icon; the running app may not have one yet.
        guard let icon else { return Self.hashedColor(bundleID) }
        let resolved = Self.averageIconColor(icon) ?? Self.hashedColor(bundleID)
        baseByBundle[bundleID] = resolved
        return resolved
    }

    /// Average of the 16×16 icon's pixels that are chromatic and mostly opaque, weighted by saturation.
    private static func averageIconColor(_ image: NSImage) -> NSColor? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 16,
            pixelsHigh: 16,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.clear.setFill()
        NSRect(x: 0, y: 0, width: 16, height: 16).fill()
        image.draw(
            in: NSRect(x: 0, y: 0, width: 16, height: 16),
            from: .zero,
            operation: .sourceOver,
            fraction: 1
        )
        NSGraphicsContext.restoreGraphicsState()

        var sumR: CGFloat = 0
        var sumG: CGFloat = 0
        var sumB: CGFloat = 0
        var sumW: CGFloat = 0
        var count = 0
        for y in 0..<16 {
            for x in 0..<16 {
                // getHue writes its out-parameters and returns Void. The failable step is the sRGB conversion.
                guard let sample = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                var hue: CGFloat = 0
                var saturation: CGFloat = 0
                var brightness: CGFloat = 0
                var alpha: CGFloat = 0
                sample.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
                guard saturation > 0.25, alpha > 0.5 else { continue }
                sumR += sample.redComponent * saturation
                sumG += sample.greenComponent * saturation
                sumB += sample.blueComponent * saturation
                sumW += saturation
                count += 1
            }
        }
        guard count >= 6, sumW > 0 else { return nil }
        let averaged = NSColor(deviceRed: sumR / sumW, green: sumG / sumW, blue: sumB / sumW, alpha: 1)
        return normalize(averaged)
    }

    /// Pull an arbitrary icon average into a border that stays vivid on a dark desktop.
    private static func normalize(_ color: NSColor) -> NSColor {
        guard let rgb = color.usingColorSpace(.sRGB) else { return color }
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        rgb.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        let clampedSaturation = min(0.8, max(0.6, saturation))
        return NSColor(hue: hue, saturation: clampedSaturation, brightness: 0.75, alpha: 1)
    }

    /// Hue stays the app's hue. Index 0 is the base brightness; later windows move only about 8–12%.
    private static func shade(_ base: NSColor, index: Int) -> NSColor {
        guard let rgb = base.usingColorSpace(.sRGB) else { return base }
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        var alpha: CGFloat = 0
        rgb.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        let steps: [CGFloat] = [0, 0.10, -0.10, 0.08, -0.12]
        let adjusted = min(0.90, max(0.50, brightness + steps[index % steps.count]))
        return NSColor(hue: hue, saturation: saturation, brightness: adjusted, alpha: 1)
    }

    private static func hashedColor(_ bundleID: String) -> NSColor {
        var hash: UInt32 = 2_166_136_261
        for byte in bundleID.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        let hue = CGFloat(hash % 360) / 360
        return NSColor(hue: hue, saturation: 0.7, brightness: 0.75, alpha: 1)
    }
}

extension NSColor {
    /// `#RRGGBB` or `RRGGBB`.
    convenience init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }
        let red = CGFloat((value >> 16) & 0xFF) / 255
        let green = CGFloat((value >> 8) & 0xFF) / 255
        let blue = CGFloat(value & 0xFF) / 255
        self.init(srgbRed: red, green: green, blue: blue, alpha: 1)
    }

    var hexRGB: String {
        guard let rgb = usingColorSpace(.sRGB) else { return "#000000" }
        let red = Int((rgb.redComponent * 255).rounded())
        let green = Int((rgb.greenComponent * 255).rounded())
        let blue = Int((rgb.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", red, green, blue)
    }
}
