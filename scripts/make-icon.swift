// Renders Lina's app icon: Lina herself on warm, ruled paper.
import AppKit

let size: CGFloat = 1024
let img = NSImage(size: NSSize(width: size, height: size))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// macOS icon grid: 824pt squircle centered on a 1024 canvas.
let inset: CGFloat = 100
let rect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let path = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)

ctx.saveGState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
shadow.shadowBlurRadius = 28
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.set()
NSColor(srgbRed: 0.98, green: 0.96, blue: 0.92, alpha: 1).setFill()
path.fill()
ctx.restoreGState()

ctx.saveGState()
path.addClip()
let paper = NSGradient(colors: [
    NSColor(srgbRed: 1.00, green: 0.99, blue: 0.97, alpha: 1),
    NSColor(srgbRed: 0.95, green: 0.92, blue: 0.86, alpha: 1),
])!
paper.draw(in: rect, angle: -90)

// Faint ruled lines, like a notebook.
NSColor(srgbRed: 0.29, green: 0.24, blue: 0.78, alpha: 0.07).setStroke()
for i in 0..<6 {
    let y = rect.minY + 150 + CGFloat(i) * 105
    let line = NSBezierPath()
    line.move(to: CGPoint(x: rect.minX, y: y))
    line.line(to: CGPoint(x: rect.maxX, y: y))
    line.lineWidth = 4
    line.stroke()
}

// Lina herself, the same drawing as Design/LinaFace.swift, in a 100 × 100 space with y pointing down.
let scale = rect.width / 76
ctx.saveGState()
ctx.translateBy(x: rect.minX - 12 * scale, y: rect.maxY + 14 * scale - 40)
ctx.scaleBy(x: scale, y: -scale)
let lineColor = CGColor(srgbRed: 0.11, green: 0.10, blue: 0.14, alpha: 1)
let skin = CGColor(srgbRed: 1.0, green: 0.965, blue: 0.937, alpha: 1)
let hair = CGColor(srgbRed: 0.29, green: 0.24, blue: 0.78, alpha: 1)
ctx.setLineWidth(2.2)
ctx.setLineCap(.round)
ctx.setLineJoin(.round)
ctx.setStrokeColor(lineColor)

func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
func shape(_ fill: CGColor?, _ build: (CGMutablePath) -> Void) {
    let path = CGMutablePath()
    build(path)
    if let fill {
        ctx.addPath(path)
        ctx.setFillColor(fill)
        ctx.fillPath()
    }
    ctx.addPath(path)
    ctx.strokePath()
}

shape(hair) { h in
    h.move(to: p(27, 50))
    h.addCurve(to: p(51, 18), control1: p(24, 30), control2: p(36, 18))
    h.addCurve(to: p(75, 52), control1: p(67, 18), control2: p(78, 30))
    h.addCurve(to: p(80, 78), control1: p(74, 64), control2: p(78, 72))
    h.addCurve(to: p(58, 74), control1: p(70, 82), control2: p(62, 80))
    h.addLine(to: p(42, 74))
    h.addCurve(to: p(20, 78), control1: p(38, 80), control2: p(30, 82))
    h.addCurve(to: p(27, 50), control1: p(22, 72), control2: p(26, 64))
    h.closeSubpath()
}
shape(skin) { n in
    n.move(to: p(44, 64)); n.addLine(to: p(44, 81))
    n.addQuadCurve(to: p(56, 81), control: p(50, 85))
    n.addLine(to: p(56, 64)); n.closeSubpath()
}
shape(CGColor(gray: 1, alpha: 1)) { s in
    s.move(to: p(22, 100))
    s.addCurve(to: p(43, 81), control1: p(24, 88), control2: p(34, 83))
    s.addQuadCurve(to: p(57, 81), control: p(50, 89))
    s.addCurve(to: p(78, 100), control1: p(66, 83), control2: p(76, 88))
}
shape(skin) { f in
    f.move(to: p(31, 46))
    f.addCurve(to: p(69, 46), control1: p(31, 30), control2: p(69, 30))
    f.addCurve(to: p(50, 73), control1: p(69, 60), control2: p(62, 71))
    f.addCurve(to: p(31, 46), control1: p(38, 71), control2: p(31, 60))
    f.closeSubpath()
}
shape(hair) { b in
    b.move(to: p(29.5, 43))
    b.addCurve(to: p(53, 22), control1: p(28, 27), control2: p(42, 21))
    b.addCurve(to: p(71, 47), control1: p(67, 23), control2: p(74, 33))
    b.addCurve(to: p(53, 30.5), control1: p(66, 37), control2: p(58, 33))
    b.addCurve(to: p(29.5, 43), control1: p(48, 36), control2: p(39, 40))
    b.closeSubpath()
}
ctx.setFillColor(CGColor(srgbRed: 0.97, green: 0.655, blue: 0.627, alpha: 0.45))
ctx.fillEllipse(in: CGRect(x: 35, y: 54, width: 6, height: 6))
ctx.fillEllipse(in: CGRect(x: 59, y: 54, width: 6, height: 6))
ctx.setFillColor(lineColor)
ctx.fillEllipse(in: CGRect(x: 39.9, y: 46.4, width: 4.2, height: 5.2))
ctx.fillEllipse(in: CGRect(x: 55.9, y: 46.4, width: 4.2, height: 5.2))
shape(nil) { l in
    l.move(to: p(38.5, 43)); l.addQuadCurve(to: p(45.5, 42.5), control: p(42, 41))
    l.move(to: p(54.5, 42.5)); l.addQuadCurve(to: p(61.5, 43), control: p(58, 41))
    l.move(to: p(45.5, 62.5)); l.addQuadCurve(to: p(54.5, 62.5), control: p(50, 66))
}
ctx.setLineWidth(1.8)
shape(nil) { n in n.move(to: p(49.5, 50)); n.addQuadCurve(to: p(51, 57), control: p(48, 56.5)) }
ctx.restoreGState()
ctx.restoreGState()

// Hairline edge.
NSColor.black.withAlphaComponent(0.08).setStroke()
path.lineWidth = 2
path.stroke()
img.unlockFocus()

let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
