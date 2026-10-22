import AppKit

// Dessine l'icône de l'app (1024 × 1024) : ./tools/make-icon.sh la convertit en .icns.
let size: CGFloat = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.png"

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: a)
}

// Gabarit des icônes macOS : corps de 824 px centré, coins ~185 px.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let shape = NSBezierPath(roundedRect: body, xRadius: 186, yRadius: 186)

// Ombre portée douce
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
rgb(30, 30, 40).setFill()
shape.fill()
ctx.restoreGState()

// Fond : graphite vers indigo
ctx.saveGState()
shape.addClip()
NSGradient(colors: [rgb(58, 60, 92), rgb(24, 25, 36)])!.draw(in: body, angle: -90)
// Halo léger en haut
NSGradient(colors: [rgb(255, 255, 255, 0.16), rgb(255, 255, 255, 0)])!
    .draw(in: CGRect(x: body.minX, y: body.midY, width: body.width, height: body.height / 2), angle: -90)
ctx.restoreGState()

// Liseré intérieur
rgb(255, 255, 255, 0.12).setStroke()
let rim = NSBezierPath(roundedRect: body.insetBy(dx: 2, dy: 2), xRadius: 184, yRadius: 184)
rim.lineWidth = 4
rim.stroke()

// Deux baies de serveur
func bay(y: CGFloat, lit: Bool) {
    let r = CGRect(x: 236, y: y, width: 552, height: 196)
    let p = NSBezierPath(roundedRect: r, xRadius: 52, yRadius: 52)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 18, color: NSColor.black.withAlphaComponent(0.3).cgColor)
    NSGradient(colors: [rgb(250, 250, 255), rgb(214, 216, 230)])!.draw(in: p, angle: -90)
    ctx.restoreGState()

    // Voyant
    let dot = CGRect(x: r.minX + 62, y: r.midY - 36, width: 72, height: 72)
    if lit {
        ctx.saveGState()
        ctx.setShadow(offset: .zero, blur: 34, color: rgb(52, 220, 140, 0.9).cgColor)
        rgb(46, 204, 128).setFill()
        NSBezierPath(ovalIn: dot).fill()
        ctx.restoreGState()
        rgb(255, 255, 255, 0.45).setFill()
        NSBezierPath(ovalIn: CGRect(x: dot.minX + 16, y: dot.midY + 4, width: 26, height: 18)).fill()
    } else {
        rgb(150, 154, 175).setFill()
        NSBezierPath(ovalIn: dot).fill()
    }

    // Fentes
    rgb(120, 124, 150).setFill()
    for (i, w) in [CGFloat(250), 170].enumerated() {
        let slot = CGRect(x: r.minX + 182, y: r.midY + (i == 0 ? 12 : -46), width: w, height: 34)
        NSBezierPath(roundedRect: slot, xRadius: 17, yRadius: 17).fill()
    }
}
bay(y: 540, lit: true)
bay(y: 288, lit: true)

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
