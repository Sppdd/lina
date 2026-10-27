// Renders Lina's app icon: warm paper, a serif "l" in ink, and a ghost of what comes next.
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

func serif(_ s: CGFloat, _ w: NSFont.Weight) -> NSFont {
    let base = NSFont.systemFont(ofSize: s, weight: w)
    return NSFont(descriptor: base.fontDescriptor.withDesign(.serif)!, size: s) ?? base
}

let ink = NSColor(srgbRed: 0.29, green: 0.24, blue: 0.78, alpha: 1)
let letter = NSAttributedString(string: "l", attributes: [.font: serif(560, .semibold), .foregroundColor: NSColor(srgbRed: 0.13, green: 0.11, blue: 0.20, alpha: 1)])
let ghost = NSAttributedString(string: "ina", attributes: [.font: serif(560, .regular), .foregroundColor: ink.withAlphaComponent(0.28)])
let ls = letter.size()
let baseX = rect.minX + 150
let baseY = rect.minY + 95
letter.draw(at: CGPoint(x: baseX, y: baseY))
// Caret, right after the written letter.
let caretX = baseX + ls.width + 26
ink.setFill()
NSBezierPath(roundedRect: CGRect(x: caretX, y: baseY + 120, width: 26, height: 430), xRadius: 13, yRadius: 13).fill()
ghost.draw(at: CGPoint(x: caretX + 50, y: baseY))
ctx.restoreGState()

// Hairline edge.
NSColor.black.withAlphaComponent(0.08).setStroke()
path.lineWidth = 2
path.stroke()
img.unlockFocus()

let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
