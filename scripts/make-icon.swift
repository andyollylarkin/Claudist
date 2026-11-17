// Renders Resources/AppIcon-1024.png: indigo squircle (mindsw.io palette), lavender-white task card with a check, agent spark.
// Usage: swift scripts/make-icon.swift <out.png>
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon-1024.png"

func color(_ hex: UInt32, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// macOS icon grid: 824pt squircle centered in 1024 with a soft drop shadow.
let inset: CGFloat = 100
let tile = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: color(0x000000, 0.28).cgColor)
ctx.addPath(tilePath)
ctx.setFillColor(color(0x5856C1).cgColor)
ctx.fillPath()
ctx.restoreGState()

// Warm terracotta gradient.
ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [color(0x8A88D3).cgColor, color(0x6E6BD0).cgColor, color(0x4A48A8).cgColor] as CFArray,
                          locations: [0, 0.45, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: tile.minX, y: tile.maxY), end: CGPoint(x: tile.maxX, y: tile.minY), options: [])
// Soft top light, no hard edge.
let sheen = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                       colors: [color(0xFFFFFF, 0.12).cgColor, color(0xFFFFFF, 0).cgColor] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(sheen, startCenter: CGPoint(x: tile.midX - 120, y: tile.maxY), startRadius: 0,
                       endCenter: CGPoint(x: tile.midX - 120, y: tile.maxY), endRadius: 620, options: [])
ctx.restoreGState()

// Cream task card, slightly tilted.
ctx.saveGState()
ctx.translateBy(x: 488, y: 470)
ctx.rotate(by: -0.07)
let card = CGRect(x: -235, y: -225, width: 470, height: 450)
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x1D1B27, 0.35).cgColor)
ctx.addPath(CGPath(roundedRect: card, cornerWidth: 72, cornerHeight: 72, transform: nil))
ctx.setFillColor(color(0xF4F4FF).cgColor)
ctx.fillPath()
ctx.setShadow(offset: .zero, blur: 0, color: nil)

// Faint text lines on the card.
ctx.setFillColor(color(0xE3E3FF).cgColor)
for (y, w) in [(130.0, 300.0), (80.0, 210.0)] {
    ctx.addPath(CGPath(roundedRect: CGRect(x: -165, y: y, width: w, height: 26), cornerWidth: 13, cornerHeight: 13, transform: nil))
    ctx.fillPath()
}

// Check mark.
let check = CGMutablePath()
check.move(to: CGPoint(x: -140, y: -40))
check.addLine(to: CGPoint(x: -45, y: -130))
check.addLine(to: CGPoint(x: 140, y: 40))
ctx.addPath(check)
ctx.setStrokeColor(color(0x5856C1).cgColor)
ctx.setLineWidth(62)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
ctx.strokePath()
ctx.restoreGState()

// Agent spark: cream rays with rounded ends, uneven lengths for a hand-drawn feel.
ctx.saveGState()
let center = CGPoint(x: 748, y: 752)
ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 14, color: color(0x1D1B27, 0.3).cgColor)
ctx.setStrokeColor(color(0xFBFBFF).cgColor)
ctx.setLineCap(.round)
// Tapered petals at uneven angles and lengths.
let rays: [(angle: CGFloat, length: CGFloat, width: CGFloat)] = [
    (84, 104, 34), (127, 78, 28), (166, 94, 31), (208, 70, 26), (247, 90, 30),
    (290, 100, 32), (331, 76, 27), (12, 96, 32), (49, 74, 26),
]
ctx.setFillColor(color(0xFBFBFF).cgColor)
for ray in rays {
    let a = ray.angle * .pi / 180
    let tip = CGPoint(x: center.x + cos(a) * ray.length, y: center.y + sin(a) * ray.length)
    let n = CGPoint(x: -sin(a), y: cos(a))
    let half = ray.width / 2
    let petal = CGMutablePath()
    // Narrow at the core, full and rounded at the tip.
    petal.move(to: CGPoint(x: center.x + n.x * half * 0.35, y: center.y + n.y * half * 0.35))
    petal.addLine(to: CGPoint(x: tip.x + n.x * half, y: tip.y + n.y * half))
    petal.addArc(center: tip, radius: half, startAngle: a + .pi / 2, endAngle: a - .pi / 2, clockwise: true)
    petal.addLine(to: CGPoint(x: center.x - n.x * half * 0.35, y: center.y - n.y * half * 0.35))
    petal.closeSubpath()
    ctx.addPath(petal)
    ctx.fillPath()
}
ctx.fillEllipse(in: CGRect(x: center.x - 26, y: center.y - 26, width: 52, height: 52))
ctx.restoreGState()

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
