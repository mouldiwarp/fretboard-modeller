// Renders Resources/AppIcon.icns. Usage: swift tools/make_icon.swift
import AppKit

func rgb(_ r: Int, _ g: Int, _ b: Int, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: a)
}
func gradient(_ cs: [CGColor]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: cs as CFArray, locations: nil)!
}

func draw(_ c: CGContext) {
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

    // Tile with drop shadow
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: rgb(0, 0, 0, 0.45))
    c.addPath(tilePath); c.setFillColor(rgb(24, 32, 48)); c.fillPath()
    c.restoreGState()

    c.saveGState()
    c.addPath(tilePath); c.clip()
    c.drawLinearGradient(gradient([rgb(52, 68, 96), rgb(18, 24, 38)]),
                         start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])

    // Board geometry: nut at top (narrow), widening toward the heel at the bottom.
    let cx: CGFloat = 512, yTop: CGFloat = 800, yBot: CGFloat = 60
    func hw(_ y: CGFloat) -> CGFloat { 150 + (yTop - y) * (150.0 / 700.0) }
    let board = CGMutablePath()
    board.move(to: CGPoint(x: cx - hw(yTop), y: yTop))
    board.addLine(to: CGPoint(x: cx + hw(yTop), y: yTop))
    board.addLine(to: CGPoint(x: cx + hw(yBot), y: yBot))
    board.addLine(to: CGPoint(x: cx - hw(yBot), y: yBot))
    board.closeSubpath()

    c.saveGState()
    c.addPath(board); c.clip()
    c.drawLinearGradient(gradient([rgb(92, 48, 30), rgb(62, 31, 20), rgb(92, 48, 30)]),
                         start: CGPoint(x: 200, y: 0), end: CGPoint(x: 824, y: 0), options: [])
    // grain
    c.setStrokeColor(rgb(35, 16, 10, 0.35)); c.setLineWidth(3)
    for i in -9...9 {
        let f = CGFloat(i) / 10
        c.move(to: CGPoint(x: cx + f * hw(yTop) * 1.0, y: yTop))
        c.addLine(to: CGPoint(x: cx + f * hw(yBot), y: yBot))
    }
    c.strokePath()

    // Frets (equal-temperament spacing, 14 frets span the visible board)
    func fy(_ n: Int) -> CGFloat {
        yTop - 700 * (1 - CGFloat(pow(2.0, -Double(n) / 12))) / (1 - CGFloat(pow(2.0, -14.0 / 12)))
    }
    // Inlays
    c.setFillColor(rgb(236, 230, 214))
    func dot(_ x: CGFloat, _ y: CGFloat) {
        c.setShadow(offset: CGSize(width: 0, height: -3), blur: 5, color: rgb(0, 0, 0, 0.5))
        c.fillEllipse(in: CGRect(x: x - 17, y: y - 17, width: 34, height: 34))
    }
    for n in [3, 5, 7, 9] { dot(cx, (fy(n - 1) + fy(n)) / 2) }
    let y12 = (fy(11) + fy(12)) / 2
    dot(cx - hw(y12) * 0.42, y12); dot(cx + hw(y12) * 0.42, y12)
    c.setShadow(offset: .zero, blur: 0, color: nil)

    // Strings
    c.setStrokeColor(rgb(214, 218, 226, 0.85)); c.setLineWidth(5)
    for i in 0..<6 {
        let f = (CGFloat(i) - 2.5) / 2.5 * 0.82
        c.move(to: CGPoint(x: cx + f * hw(yTop), y: yTop))
        c.addLine(to: CGPoint(x: cx + f * hw(yBot), y: yBot))
    }
    c.strokePath()

    for n in 1...13 {
        let y = fy(n), w = hw(y)
        c.setStrokeColor(rgb(120, 126, 138)); c.setLineWidth(13)
        c.move(to: CGPoint(x: cx - w, y: y - 2)); c.addLine(to: CGPoint(x: cx + w, y: y - 2)); c.strokePath()
        c.setStrokeColor(rgb(226, 230, 238)); c.setLineWidth(9)
        c.move(to: CGPoint(x: cx - w, y: y)); c.addLine(to: CGPoint(x: cx + w, y: y)); c.strokePath()
    }
    c.restoreGState()

    // Nut
    let nut = CGRect(x: cx - hw(yTop) - 6, y: yTop, width: 2 * hw(yTop) + 12, height: 34)
    c.setFillColor(rgb(238, 232, 214))
    c.addPath(CGPath(roundedRect: nut, cornerWidth: 8, cornerHeight: 8, transform: nil)); c.fillPath()

    // Board edge highlight
    c.addPath(board); c.setStrokeColor(rgb(20, 10, 6, 0.8)); c.setLineWidth(6); c.strokePath()

    // Measurement dimension line on the left
    let cyan = rgb(53, 208, 255)
    c.setStrokeColor(cyan); c.setFillColor(cyan); c.setLineWidth(9); c.setLineCap(.round)
    let dx: CGFloat = 158, y0: CGFloat = 834, y1: CGFloat = 175
    c.move(to: CGPoint(x: dx, y: y0)); c.addLine(to: CGPoint(x: dx, y: y1)); c.strokePath()
    for y in [y0, y1] { c.move(to: CGPoint(x: dx - 24, y: y)); c.addLine(to: CGPoint(x: dx + 24, y: y)); c.strokePath() }
    for (y, s) in [(y0, CGFloat(-1)), (y1, CGFloat(1))] {
        c.move(to: CGPoint(x: dx, y: y)); c.addLine(to: CGPoint(x: dx - 18, y: y + s * 36))
        c.addLine(to: CGPoint(x: dx + 18, y: y + s * 36)); c.closePath(); c.fillPath()
    }

    // Glossy top highlight
    c.drawLinearGradient(gradient([rgb(255, 255, 255, 0.14), rgb(255, 255, 255, 0)]),
                         start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 620), options: [])
    c.restoreGState()

    // Rim
    c.addPath(tilePath); c.setStrokeColor(rgb(255, 255, 255, 0.18)); c.setLineWidth(3); c.strokePath()
}

func png(_ px: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let g = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = g
    g.cgContext.scaleBy(x: CGFloat(px) / 1024, y: CGFloat(px) / 1024)
    draw(g.cgContext)
    return rep.representation(using: .png, properties: [:])!
}

let fm = FileManager.default
let set = "Resources/AppIcon.iconset"
try? fm.removeItem(atPath: set)
try fm.createDirectory(atPath: set, withIntermediateDirectories: true)
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512), ("512x512@2x", 1024)] {
    try png(px).write(to: URL(fileURLWithPath: "\(set)/icon_\(name).png"))
}
print("iconset written")
