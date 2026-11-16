import AppKit
import CoreGraphics
// Original artwork: overlapping navy, green, and grey window cards on a dark rounded square.
func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: px,
        pixelsHigh: px,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    let space = CGColorSpaceCreateDeviceRGB()
    func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor {
        CGColor(colorSpace: space, components: [r, g, b, 1])!
    }
    let s = CGFloat(px) / 1024
    ctx.clear(CGRect(x: 0, y: 0, width: CGFloat(px), height: CGFloat(px)))
    func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> CGRect {
        CGRect(x: x * s, y: y * s, width: w * s, height: h * s)
    }
    func fill(_ rect: CGRect, _ radius: CGFloat, _ paint: CGColor) {
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.setFillColor(paint)
        ctx.fillPath()
    }

    let background = box(88, 88, 848, 848)
    let backgroundRadius = 188 * s
    ctx.addPath(CGPath(roundedRect: background, cornerWidth: backgroundRadius, cornerHeight: backgroundRadius, transform: nil))
    ctx.setFillColor(color(0.10, 0.12, 0.15))
    ctx.fillPath()
    ctx.addPath(CGPath(roundedRect: background, cornerWidth: backgroundRadius, cornerHeight: backgroundRadius, transform: nil))
    ctx.clip()

    // Back to front. Coordinates are Core Graphics points, origin at the bottom left.
    let cards: [(CGRect, CGFloat, CGColor)] = [
        (box(156, 174, 520, 390), 64 * s, color(0.58, 0.62, 0.67)),
        (box(246, 316, 520, 390), 64 * s, color(0.24, 0.40, 0.68)),
        (box(336, 458, 520, 390), 64 * s, color(0.18, 0.62, 0.46)),
    ]
    let glass = color(0.15, 0.17, 0.20)
    let frame = 72 * s
    for (rect, radius, paint) in cards {
        fill(rect, radius, paint)
        let inner = rect.insetBy(dx: frame, dy: frame)
        guard inner.width > 4 * s, inner.height > 4 * s else { continue }
        let innerRadius = max(8 * s, radius - frame)
        fill(inner, innerRadius, glass)
    }

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let dir = "AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
for b in [16, 32, 128, 256, 512] {
    try! render(b).write(to: URL(fileURLWithPath: "\(dir)/icon_\(b)x\(b).png"))
    try! render(b * 2).write(to: URL(fileURLWithPath: "\(dir)/icon_\(b)x\(b)@2x.png"))
}
try! render(1024).write(to: URL(fileURLWithPath: "icon-1024.png"))
