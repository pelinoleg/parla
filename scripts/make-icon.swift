// Renders Resources/AppIcon.icns: run `swift scripts/make-icon.swift` from the repo root.
import AppKit
import CoreText

func render(_ px: Int) -> Data {
    let s = CGFloat(px) / 1024
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpace(name: CGColorSpace.sRGB)!,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: s, y: s)
    let rgb = CGColorSpace(name: CGColorSpace.sRGB)!
    func c(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
        CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: a)
    }

    // Background squircle (Apple icon grid: 824pt body inset 100pt)
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let bg = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 30, color: c(0x000000, 0.35))
    ctx.addPath(bg); ctx.setFillColor(c(0x1B1B22)); ctx.fillPath()
    ctx.restoreGState()
    ctx.saveGState()
    ctx.addPath(bg); ctx.clip()
    ctx.drawLinearGradient(CGGradient(colorsSpace: rgb, colors: [c(0x2C2B3A), c(0x15151B)] as CFArray, locations: [0, 1])!,
                           start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    ctx.restoreGState()

    // Two overlapping speech bubbles: back one (warm), front one (cool) with "A→" feel
    func bubble(_ rect: CGRect, tailLeft: Bool) -> CGPath {
        let p = CGMutablePath()
        p.addRoundedRect(in: rect, cornerWidth: 70, cornerHeight: 70)
        let tx = tailLeft ? rect.minX + 70 : rect.maxX - 70
        let dir: CGFloat = tailLeft ? -1 : 1
        p.move(to: CGPoint(x: tx - 34, y: rect.minY + 4))
        p.addLine(to: CGPoint(x: tx + dir * 46, y: rect.minY - 70))
        p.addLine(to: CGPoint(x: tx + 34, y: rect.minY + 4))
        p.closeSubpath()
        return p
    }
    func fill(_ path: CGPath, _ colors: [CGColor], _ start: CGPoint, _ end: CGPoint, glow: CGColor) {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 36, color: glow)
        ctx.addPath(path); ctx.setFillColor(colors[0]); ctx.fillPath()
        ctx.restoreGState()
        ctx.saveGState()
        ctx.addPath(path); ctx.clip()
        ctx.drawLinearGradient(CGGradient(colorsSpace: rgb, colors: colors as CFArray, locations: nil)!, start: start, end: end, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        ctx.restoreGState()
    }
    let back = bubble(CGRect(x: 220, y: 470, width: 400, height: 300), tailLeft: true)
    fill(back, [c(0xFFB25E), c(0xFF5E7A)], CGPoint(x: 220, y: 770), CGPoint(x: 620, y: 470), glow: c(0xFF5E7A, 0.45))
    let front = bubble(CGRect(x: 404, y: 270, width: 400, height: 300), tailLeft: false)
    fill(front, [c(0x5EA8FF), c(0x7C4DFF)], CGPoint(x: 404, y: 570), CGPoint(x: 804, y: 270), glow: c(0x7C4DFF, 0.5))

    // Glyphs: "A" on the back bubble, "文" on the front one
    func glyph(_ s: String, _ center: CGPoint, size: CGFloat) {
        let attr = NSAttributedString(string: s, attributes: [
            .font: NSFont.systemFont(ofSize: size, weight: .bold),
            .foregroundColor: NSColor.white,
        ])
        let line = CTLineCreateWithAttributedString(attr)
        let b = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
        ctx.textPosition = CGPoint(x: center.x - b.width / 2 - b.minX, y: center.y - b.height / 2 - b.minY)
        CTLineDraw(line, ctx)
    }
    glyph("A", CGPoint(x: 360, y: 640), size: 170)
    glyph("文", CGPoint(x: 604, y: 420), size: 170)

    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    return rep.representation(using: .png, properties: [:])!
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    try! render(base).write(to: iconset.appendingPathComponent("icon_\(base)x\(base).png"))
    try! render(base * 2).write(to: iconset.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try! p.run(); p.waitUntilExit()
try! render(512).write(to: URL(fileURLWithPath: "Resources/icon.png"))
print("Resources/AppIcon.icns written")
