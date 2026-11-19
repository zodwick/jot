// Draws Jot's app icon and writes Resources/AppIcon.png (1024²) + Resources/AppIcon.icns.
// Usage: swift scripts/make_icon.swift
import AppKit

let size: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

func color(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

// macOS icon grid: 824pt body centred on a 1024 canvas.
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let squircle = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

// Drop shadow under the whole tile.
NSGraphicsContext.saveGraphicsState()
let tileShadow = NSShadow()
tileShadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
tileShadow.shadowBlurRadius = 28
tileShadow.shadowOffset = NSSize(width: 0, height: -12)
tileShadow.set()
color(0x4F5BEF).setFill()
squircle.fill()
NSGraphicsContext.restoreGraphicsState()

// Background: sky blue → indigo, plus soft coloured glows for the glass to refract.
NSGraphicsContext.saveGraphicsState()
squircle.addClip()
NSGradient(colors: [color(0x7CD3FF), color(0x5B7CFA), color(0x5A3FE0)],
           atLocations: [0, 0.55, 1], colorSpace: .sRGB)!.draw(in: body, angle: -60)
func glow(_ c: NSColor, at p: NSPoint, radius r: CGFloat) {
    NSGradient(colors: [c, c.withAlphaComponent(0)])!
        .draw(fromCenter: p, radius: 0, toCenter: p, radius: r, options: [])
}
glow(color(0xFF8FB1, 0.85), at: NSPoint(x: 250, y: 260), radius: 380)
glow(color(0xD7A8FF, 0.5), at: NSPoint(x: 820, y: 330), radius: 300)
glow(color(0x9BF1FF, 0.55), at: NSPoint(x: 760, y: 860), radius: 340)

// Glass card, tilted slightly.
let card = NSRect(x: 262, y: 236, width: 500, height: 560)
var transform = AffineTransform(translationByX: 512, byY: 516)
transform.rotate(byDegrees: -7)
transform.translate(x: -512, y: -516)
let cardPath = NSBezierPath(roundedRect: card, xRadius: 70, yRadius: 70)
cardPath.transform(using: transform)

NSGraphicsContext.saveGraphicsState()
let cardShadow = NSShadow()
cardShadow.shadowColor = color(0x1B1260, 0.35)
cardShadow.shadowBlurRadius = 48
cardShadow.shadowOffset = NSSize(width: 0, height: -26)
cardShadow.set()
color(0xFFFFFF, 0.26).setFill()
cardPath.fill()
NSGraphicsContext.restoreGraphicsState()

NSGraphicsContext.saveGraphicsState()
cardPath.addClip()
// Frost: bright at the top edge, fading down (light catching the glass).
NSGradient(colors: [color(0xFFFFFF, 0.55), color(0xFFFFFF, 0.12), color(0xFFFFFF, 0.22)],
           atLocations: [0, 0.6, 1], colorSpace: .sRGB)!.draw(in: cardPath, angle: -97)
NSGraphicsContext.restoreGraphicsState()

color(0xFFFFFF, 0.75).setStroke()
cardPath.lineWidth = 4
cardPath.stroke()

// Card content: a bullet, a ticked checkbox and a few lines of "writing".
NSGraphicsContext.saveGraphicsState()
ctx.concatenate(CGAffineTransform(a: transform.m11, b: transform.m12, c: transform.m21,
                                  d: transform.m22, tx: transform.tX, ty: transform.tY))
let ink = color(0xFFFFFF, 0.96)
func line(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, alpha: CGFloat = 0.96) {
    let p = NSBezierPath()
    p.move(to: NSPoint(x: x, y: y)); p.line(to: NSPoint(x: x + w, y: y))
    p.lineWidth = 34; p.lineCapStyle = .round
    color(0xFFFFFF, alpha).setStroke(); p.stroke()
}
// Row 1: heading line
line(330, 700, 250)
// Row 2: bullet
ink.setFill()
NSBezierPath(ovalIn: NSRect(x: 318, y: 573, width: 34, height: 34)).fill()
line(400, 590, 270, alpha: 0.85)
// Row 3: ticked checkbox
let box = NSRect(x: 307, y: 453, width: 58, height: 58)
color(0xFFFFFF, 0.96).setFill()
NSBezierPath(ovalIn: box).fill()
let tick = NSBezierPath()
tick.move(to: NSPoint(x: box.minX + 15, y: box.midY + 1))
tick.line(to: NSPoint(x: box.minX + 26, y: box.midY - 11))
tick.line(to: NSPoint(x: box.maxX - 13, y: box.midY + 13))
tick.lineWidth = 9; tick.lineCapStyle = .round; tick.lineJoinStyle = .round
color(0x5B6CF5).setStroke(); tick.stroke()
line(400, 482, 210, alpha: 0.85)
// Row 4: bullet
NSBezierPath(ovalIn: NSRect(x: 318, y: 357, width: 34, height: 34)).fill()
line(400, 374, 150, alpha: 0.85)
NSGraphicsContext.restoreGraphicsState()

// Top sheen + hairline rim, like system glass icons.
NSGradient(colors: [color(0xFFFFFF, 0.28), color(0xFFFFFF, 0)])!
    .draw(in: NSRect(x: body.minX, y: body.midY + 120, width: body.width, height: body.height / 2 - 120), angle: -90)
NSGraphicsContext.restoreGraphicsState()

color(0xFFFFFF, 0.35).setStroke()
let rim = NSBezierPath(roundedRect: body.insetBy(dx: 1.5, dy: 1.5), xRadius: 184, yRadius: 184)
rim.lineWidth = 3
rim.stroke()

NSGraphicsContext.restoreGraphicsState()

// Write PNG + build .icns via iconutil.
let root = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let resources = root.appendingPathComponent("Resources")
let png = resources.appendingPathComponent("AppIcon.png")
try! rep.representation(using: .png, properties: [:])!.write(to: png)

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for base in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let px = base * scale
        let name = scale == 1 ? "icon_\(base)x\(base).png" : "icon_\(base)x\(base)@2x.png"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sips")
        p.arguments = ["-z", "\(px)", "\(px)", png.path, "--out", iconset.appendingPathComponent(name).path]
        p.standardOutput = FileHandle.nullDevice
        try! p.run(); p.waitUntilExit()
    }
}
let util = Process()
util.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
util.arguments = ["-c", "icns", iconset.path, "-o", resources.appendingPathComponent("AppIcon.icns").path]
try! util.run(); util.waitUntilExit()
print(util.terminationStatus == 0 ? "Wrote Resources/AppIcon.png and AppIcon.icns" : "iconutil failed")
