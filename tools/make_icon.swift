// Renders Resources/AppIcon.icns in the same style as IR Generator / Mixdeck:
// gold line-art (a tapered fretboard) on an obsidian rounded tile. Usage: swift tools/make_icon.swift
import AppKit

let gold = NSColor(srgbRed: 0xC5 / 255, green: 0xA0 / 255, blue: 0x59 / 255, alpha: 1)
let haze = NSColor(srgbRed: 0x86 / 255, green: 0xA2 / 255, blue: 0xBD / 255, alpha: 1)

func render(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px), inset = s * 0.09
    let body = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let path = NSBezierPath(roundedRect: body, xRadius: s * 0.18, yRadius: s * 0.18)
    NSGradient(starting: NSColor(white: 0.17, alpha: 1), ending: NSColor(white: 0.06, alpha: 1))!.draw(in: path, angle: -90)
    gold.withAlphaComponent(0.45).setStroke()
    path.lineWidth = max(1, s * 0.008)
    path.stroke()

    NSGraphicsContext.saveGraphicsState()
    path.addClip()
    let w = body.width, h = body.height, cx = body.midX + w * 0.05
    let yTop = body.minY + h * 0.80, yBot = body.minY + h * 0.06
    let hwTop = w * 0.12, hwBot = w * 0.30
    func hw(_ y: CGFloat) -> CGFloat { hwTop + (yTop - y) / (yTop - yBot) * (hwBot - hwTop) }
    func fretY(_ n: Int) -> CGFloat { yTop - (yTop - yBot) * (1 - CGFloat(pow(2.0, -Double(n) / 12))) / 0.5 }

    let glow = NSShadow()
    glow.shadowColor = gold.withAlphaComponent(0.8)
    glow.shadowBlurRadius = s * 0.04
    glow.set()

    let outline = NSBezierPath()
    outline.move(to: NSPoint(x: cx - hwTop, y: yTop))
    outline.line(to: NSPoint(x: cx + hwTop, y: yTop))
    outline.line(to: NSPoint(x: cx + hwBot, y: yBot))
    outline.line(to: NSPoint(x: cx - hwBot, y: yBot))
    outline.close()
    outline.lineWidth = s * 0.018
    outline.lineJoinStyle = .round
    gold.setStroke()
    outline.stroke()

    // Nut
    let nut = NSBezierPath()
    nut.move(to: NSPoint(x: cx - hwTop - s * 0.012, y: yTop)); nut.line(to: NSPoint(x: cx + hwTop + s * 0.012, y: yTop))
    nut.lineWidth = s * 0.036; nut.lineCapStyle = .round; nut.stroke()

    // Frets
    let frets = NSBezierPath()
    for n in 1...11 {
        let y = fretY(n)
        frets.move(to: NSPoint(x: cx - hw(y), y: y)); frets.line(to: NSPoint(x: cx + hw(y), y: y))
    }
    frets.lineWidth = s * 0.009
    gold.withAlphaComponent(0.85).setStroke()
    frets.stroke()

    // Inlays
    gold.setFill()
    func dot(_ x: CGFloat, _ y: CGFloat) {
        let r = s * 0.016
        NSBezierPath(ovalIn: NSRect(x: x - r, y: y - r, width: 2 * r, height: 2 * r)).fill()
    }
    for n in [3, 5, 7, 9] { dot(cx, (fretY(n - 1) + fretY(n)) / 2) }
    let y12 = (fretY(10) + fretY(11)) / 2
    dot(cx - hw(y12) * 0.4, y12); dot(cx + hw(y12) * 0.4, y12)

    // Dimension line (measurement) in haze, left of the board
    let dx = body.minX + w * 0.13
    let dim = NSBezierPath()
    dim.move(to: NSPoint(x: dx, y: yTop)); dim.line(to: NSPoint(x: dx, y: body.minY + h * 0.14))
    for y in [yTop, body.minY + h * 0.14] {
        dim.move(to: NSPoint(x: dx - s * 0.03, y: y)); dim.line(to: NSPoint(x: dx + s * 0.03, y: y))
    }
    dim.lineWidth = s * 0.011; dim.lineCapStyle = .round
    let g2 = NSShadow(); g2.shadowColor = haze.withAlphaComponent(0.8); g2.shadowBlurRadius = s * 0.03; g2.set()
    haze.setStroke(); dim.stroke()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let set = "Resources/AppIcon.iconset"
try? FileManager.default.removeItem(atPath: set)
try FileManager.default.createDirectory(atPath: set, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: URL(fileURLWithPath: "\(set)/icon_\(base)x\(base).png"))
    try render(base * 2).write(to: URL(fileURLWithPath: "\(set)/icon_\(base)x\(base)@2x.png"))
}
print("iconset written")
