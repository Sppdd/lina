import SwiftUI
import AppKit

/// What Lina is doing right now. Her hair color and face show it everywhere she appears:
/// the menu bar, the cards at your cursor, and her home window.
enum Mood: String, CaseIterable, Identifiable {
    case idle, listening, thinking, found, happy, worried, sleeping

    var id: String { rawValue }

    var title: String {
        switch self {
        case .idle: "Ready"
        case .listening: "Listening"
        case .thinking: "Thinking"
        case .found: "Found something"
        case .happy: "Done"
        case .worried: "Needs you"
        case .sleeping: "Paused"
        }
    }

    /// What the mood means, in the writer's terms.
    var meaning: String {
        switch self {
        case .idle: "Lina is on and quiet. She only speaks when you ask or finish a sentence."
        case .listening: "You typed /lina. Finish with . , ? or Return and she answers."
        case .thinking: "She's checking a sentence, searching, or writing options."
        case .found: "A card is waiting at your cursor. Press ⌘1, ⌘2… to choose, esc to dismiss."
        case .happy: "Your choice went into your text."
        case .worried: "Something needs your attention: access, a key, or a failed request."
        case .sleeping: "Lina is off, or paused in this app."
        }
    }

    var hair: Color { Color(nsColor: nsHair) }

    var nsHair: NSColor {
        switch self {
        case .idle: NSColor(srgbRed: 0.29, green: 0.24, blue: 0.78, alpha: 1)
        case .listening: NSColor(srgbRed: 0.12, green: 0.53, blue: 0.78, alpha: 1)
        case .thinking: NSColor(srgbRed: 0.545, green: 0.36, blue: 0.965, alpha: 1)
        case .found: NSColor(srgbRed: 0.88, green: 0.63, blue: 0.0, alpha: 1)
        case .happy: NSColor(srgbRed: 0.13, green: 0.64, blue: 0.35, alpha: 1)
        case .worried: NSColor(srgbRed: 0.90, green: 0.33, blue: 0.24, alpha: 1)
        case .sleeping: NSColor(srgbRed: 0.60, green: 0.59, blue: 0.66, alpha: 1)
        }
    }
}

/// Lina herself, in 3D (`LinaModel`): moving where `animated`, a still picture elsewhere.
/// `head` crops to her face for small places like cards and the menu bar.
/// Macs without Metal get her earlier line drawing instead.
struct LinaFace: View {
    var mood: Mood = .idle
    var head = false
    var animated = false

    /// Off while rendering snapshots to PNG: live 3D views don't draw into an offscreen window.
    static var live = true

    var body: some View {
        GeometryReader { geo in
            Group {
                if !LinaRender.isAvailable {
                    flat
                } else if animated && Self.live {
                    Lina3DView(mood: mood, head: head)
                } else if let still = LinaRender.image(mood, points: Self.renderHeight(geo.size.height), head: head) {
                    Image(nsImage: still).resizable().interpolation(.high)
                } else {
                    flat
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .aspectRatio(head ? LinaModel.headAspect : 1, contentMode: .fit)
        .allowsHitTesting(false)
        .accessibilityElement()
        .accessibilityLabel("Lina, \(mood.title.lowercased())")
    }

    private var flat: some View {
        Group {
            if animated {
                TimelineView(.periodic(from: .now, by: 0.1)) { timeline in
                    FaceCanvas(mood: mood, head: head,
                               blink: Self.isBlinking(timeline.date.timeIntervalSinceReferenceDate))
                }
            } else {
                FaceCanvas(mood: mood, head: head, blink: false)
            }
        }
    }

    /// Stills are rendered at a few fixed heights and scaled, so a handful of pictures cover every size.
    static func renderHeight(_ height: CGFloat) -> CGFloat {
        [32, 64, 128, 256].first { $0 >= height } ?? 256
    }

    static func isBlinking(_ t: TimeInterval) -> Bool { t.truncatingRemainder(dividingBy: 4.3) < 0.14 }
}

struct FaceCanvas: View {
    let mood: Mood
    let head: Bool
    let blink: Bool

    var body: some View {
        Canvas { ctx, size in
            LinaDrawing.draw(ctx, size: size, mood: mood, head: head, blink: blink)
        }
        .aspectRatio(head ? LinaDrawing.headBox.width / LinaDrawing.headBox.height : 1, contentMode: .fit)
        .accessibilityElement()
        .accessibilityLabel("Lina, \(mood.title.lowercased())")
    }
}

/// The drawing, in a 100 × 100 design space (y down), so it scales from the menu bar to a hero.
enum LinaDrawing {
    static let fullBox = CGRect(x: 0, y: 0, width: 100, height: 100)
    static let headBox = CGRect(x: 20, y: 14, width: 60, height: 62)

    static let line = Color(red: 0.11, green: 0.10, blue: 0.14)
    static let skin = Color(red: 1.0, green: 0.965, blue: 0.937)
    static let blush = Color(red: 0.97, green: 0.655, blue: 0.627).opacity(0.45)

    private enum Eyes { case open, wide, up, smiling, closed }
    private enum Brows { case calm, raised, tilted, worried }
    private enum Mouth { case smile, grin, soft, flat, oh, wavy, small }

    static func draw(_ base: GraphicsContext, size: CGSize, mood: Mood, head: Bool, blink: Bool) {
        var ctx = base
        let box = head ? headBox : fullBox
        let scale = min(size.width / box.width, size.height / box.height)
        ctx.translateBy(x: (size.width - box.width * scale) / 2, y: (size.height - box.height * scale) / 2)
        ctx.scaleBy(x: scale, y: scale)
        ctx.translateBy(x: -box.minX, y: -box.minY)
        // Thicker lines when tiny, so she still reads at 18 pt.
        let w: CGFloat = box.width * scale < 40 ? 3.2 : 2.2
        let hair = mood.hair

        // Hair, behind the face.
        shape(ctx, w, fill: hair, path { p in
            p.move(to: pt(27, 50))
            p.addCurve(to: pt(51, 18), control1: pt(24, 30), control2: pt(36, 18))
            p.addCurve(to: pt(75, 52), control1: pt(67, 18), control2: pt(78, 30))
            p.addCurve(to: pt(80, 78), control1: pt(74, 64), control2: pt(78, 72))
            p.addCurve(to: pt(58, 74), control1: pt(70, 82), control2: pt(62, 80))
            p.addLine(to: pt(42, 74))
            p.addCurve(to: pt(20, 78), control1: pt(38, 80), control2: pt(30, 82))
            p.addCurve(to: pt(27, 50), control1: pt(22, 72), control2: pt(26, 64))
            p.closeSubpath()
        })
        // Neck.
        shape(ctx, w, fill: skin, path { p in
            p.move(to: pt(44, 64))
            p.addLine(to: pt(44, 81))
            p.addQuadCurve(to: pt(56, 81), control: pt(50, 85))
            p.addLine(to: pt(56, 64))
            p.closeSubpath()
        })
        // Shirt.
        if !head {
            shape(ctx, w, fill: .white, path { p in
                p.move(to: pt(22, 100))
                p.addCurve(to: pt(43, 81), control1: pt(24, 88), control2: pt(34, 83))
                p.addQuadCurve(to: pt(57, 81), control: pt(50, 89))
                p.addCurve(to: pt(78, 100), control1: pt(66, 83), control2: pt(76, 88))
            })
        }
        // Face.
        shape(ctx, w, fill: skin, path { p in
            p.move(to: pt(31, 46))
            p.addCurve(to: pt(69, 46), control1: pt(31, 30), control2: pt(69, 30))
            p.addCurve(to: pt(50, 73), control1: pt(69, 60), control2: pt(62, 71))
            p.addCurve(to: pt(31, 46), control1: pt(38, 71), control2: pt(31, 60))
            p.closeSubpath()
        })
        // Side-swept bangs.
        shape(ctx, w, fill: hair, path { p in
            p.move(to: pt(29.5, 43))
            p.addCurve(to: pt(53, 22), control1: pt(28, 27), control2: pt(42, 21))
            p.addCurve(to: pt(71, 47), control1: pt(67, 23), control2: pt(74, 33))
            p.addCurve(to: pt(53, 30.5), control1: pt(66, 37), control2: pt(58, 33))
            p.addCurve(to: pt(29.5, 43), control1: pt(48, 36), control2: pt(39, 40))
            p.closeSubpath()
        })
        // Cheeks.
        ctx.fill(Path(ellipseIn: CGRect(x: 35, y: 54, width: 6, height: 6)), with: .color(blush))
        ctx.fill(Path(ellipseIn: CGRect(x: 59, y: 54, width: 6, height: 6)), with: .color(blush))
        // Nose.
        stroke(ctx, min(w, 1.8), path { p in
            p.move(to: pt(49.5, 50))
            p.addQuadCurve(to: pt(51, 57), control: pt(48, 56.5))
        })

        let (eyes, brows, mouth) = features(mood)
        drawBrows(ctx, w, brows)
        drawEyes(ctx, w, blink && eyes != .smiling ? .closed : eyes)
        drawMouth(ctx, w, mouth)
    }

    private static func features(_ mood: Mood) -> (Eyes, Brows, Mouth) {
        switch mood {
        case .idle: (.open, .calm, .smile)
        case .listening: (.wide, .raised, .soft)
        case .thinking: (.up, .tilted, .flat)
        case .found: (.wide, .raised, .oh)
        case .happy: (.smiling, .calm, .grin)
        case .worried: (.open, .worried, .wavy)
        case .sleeping: (.closed, .calm, .small)
        }
    }

    private static func drawEyes(_ ctx: GraphicsContext, _ w: CGFloat, _ eyes: Eyes) {
        switch eyes {
        case .open:
            for x in [42.0, 58.0] { ctx.fill(Path(ellipseIn: CGRect(x: x - 2.1, y: 46.4, width: 4.2, height: 5.2)), with: .color(line)) }
        case .wide:
            for x in [42.0, 58.0] {
                ctx.fill(Path(ellipseIn: CGRect(x: x - 2.6, y: 45.8, width: 5.2, height: 6.4)), with: .color(line))
                ctx.fill(Path(ellipseIn: CGRect(x: x + 0.0, y: 47.2, width: 1.6, height: 1.6)), with: .color(.white))
            }
        case .up:
            for x in [43.0, 59.0] { ctx.fill(Path(ellipseIn: CGRect(x: x - 2.1, y: 45.0, width: 4.2, height: 5.2)), with: .color(line)) }
        case .smiling:
            for x in [42.0, 58.0] {
                stroke(ctx, w, path { p in
                    p.move(to: pt(x - 3, 50))
                    p.addQuadCurve(to: pt(x + 3, 50), control: pt(x, 46.5))
                })
            }
        case .closed:
            for x in [42.0, 58.0] {
                stroke(ctx, w, path { p in
                    p.move(to: pt(x - 3, 49.5))
                    p.addQuadCurve(to: pt(x + 3, 49.5), control: pt(x, 52))
                })
            }
        }
    }

    private static func drawBrows(_ ctx: GraphicsContext, _ w: CGFloat, _ brows: Brows) {
        let (left, right): ((CGPoint, CGPoint, CGPoint), (CGPoint, CGPoint, CGPoint)) = switch brows {
        case .calm: ((pt(38.5, 43), pt(42, 41), pt(45.5, 42.5)), (pt(54.5, 42.5), pt(58, 41), pt(61.5, 43)))
        case .raised: ((pt(38.5, 41), pt(42, 38.5), pt(45.5, 40.5)), (pt(54.5, 40.5), pt(58, 38.5), pt(61.5, 41)))
        case .tilted: ((pt(38.5, 43), pt(42, 42), pt(45.5, 42.5)), (pt(54.5, 41), pt(58, 39), pt(61.5, 40.5)))
        case .worried: ((pt(38.5, 42), pt(42, 42), pt(45.5, 40.5)), (pt(54.5, 40.5), pt(58, 42), pt(61.5, 42)))
        }
        for b in [left, right] {
            stroke(ctx, w, path { p in
                p.move(to: b.0)
                p.addQuadCurve(to: b.2, control: b.1)
            })
        }
    }

    private static func drawMouth(_ ctx: GraphicsContext, _ w: CGFloat, _ mouth: Mouth) {
        switch mouth {
        case .smile:
            stroke(ctx, w, path { p in p.move(to: pt(45.5, 62.5)); p.addQuadCurve(to: pt(54.5, 62.5), control: pt(50, 66)) })
        case .soft:
            stroke(ctx, w, path { p in p.move(to: pt(47, 63)); p.addQuadCurve(to: pt(53, 63), control: pt(50, 65.5)) })
        case .flat:
            stroke(ctx, w, path { p in p.move(to: pt(47, 64)); p.addLine(to: pt(53, 63.4)) })
        case .small:
            stroke(ctx, w, path { p in p.move(to: pt(48, 63.5)); p.addQuadCurve(to: pt(52, 63.5), control: pt(50, 64.8)) })
        case .wavy:
            stroke(ctx, w, path { p in
                p.move(to: pt(45.5, 64.5))
                p.addQuadCurve(to: pt(50, 64.5), control: pt(47.75, 62.5))
                p.addQuadCurve(to: pt(54.5, 64.5), control: pt(52.25, 66.5))
            })
        case .oh:
            shape(ctx, w, fill: .white, Path(ellipseIn: CGRect(x: 47.8, y: 61.4, width: 4.4, height: 5.2)))
        case .grin:
            shape(ctx, w, fill: .white, path { p in
                p.move(to: pt(44.5, 61.5))
                p.addLine(to: pt(55.5, 61.5))
                p.addQuadCurve(to: pt(50, 67.5), control: pt(55, 67.5))
                p.addQuadCurve(to: pt(44.5, 61.5), control: pt(45, 67.5))
                p.closeSubpath()
            })
        }
    }

    // MARK: Helpers

    private static func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }

    private static func path(_ build: (inout Path) -> Void) -> Path {
        var p = Path()
        build(&p)
        return p
    }

    private static func shape(_ ctx: GraphicsContext, _ w: CGFloat, fill: Color, _ p: Path) {
        ctx.fill(p, with: .color(fill))
        ctx.stroke(p, with: .color(line), style: StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round))
    }

    private static func stroke(_ ctx: GraphicsContext, _ w: CGFloat, _ p: Path) {
        ctx.stroke(p, with: .color(line), style: StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round))
    }
}

/// Rendered faces for AppKit places (the menu bar), cached per mood.
@MainActor
enum LinaFaceImage {
    private static var cache: [String: NSImage] = [:]

    static func image(_ mood: Mood, size: CGFloat = 18, head: Bool = true) -> NSImage {
        if let still = LinaRender.image(mood, points: size, head: head) { return still }
        let key = "\(mood.rawValue)-\(size)-\(head)"
        if let hit = cache[key] { return hit }
        let renderer = ImageRenderer(content: FaceCanvas(mood: mood, head: head, blink: false)
            .frame(width: size, height: size))
        renderer.scale = 2
        let image = renderer.nsImage ?? NSImage(size: NSSize(width: size, height: size))
        image.isTemplate = false
        cache[key] = image
        return image
    }
}
