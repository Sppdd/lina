import AppKit
import SwiftUI

/// What Lina's ink drop is doing right now. Every state is the same little shape in a different mood,
/// so the writer can tell what Lina is up to without opening anything.
enum InkState: Equatable { case resting, thinking, listening, pointing }

/// What Lina has to say, written in ink just above the cursor: its reading of the draft,
/// a rewrite to take or leave, or the `/lina` command it's working on.
struct InkCard: Equatable {
    /// A small label on top: "lina hears", "rewrite", "/lina edit this".
    var eyebrow: String
    var text: String
    /// A second, stronger line: Lina's question.
    var detail = ""
    /// The writer's words being replaced, struck through above a rewrite.
    var original = ""
    /// Keys that act on the card: "⇥ use it · esc keep mine".
    var hint = ""
    var streaming = false
}

@MainActor
final class InkModel: ObservableObject {
    @Published var state: InkState = .resting
    /// A short note typed out beside the drop ("edit mode", "stay with this").
    @Published var bubble = ""
    /// Microphone level while listening, 0...1.
    @Published var audioLevel: CGFloat = 0
    /// Grows mid-flight and settles on landing.
    @Published var flightScale: CGFloat = 1
    /// Which way the drop's tip points, in degrees clockwise from straight up.
    @Published var tilt: Double = InkBuddy.restingTilt
    @Published var card: InkCard?
    /// Not enough room above the caret (top of the screen): the card hangs below it instead.
    @Published var cardBelow = false
    /// Moves the card left so it stays on screen when the caret is near the right edge.
    @Published var cardShift: CGFloat = 0
}

/// Lina's presence beside the writer: a drop of ink riding just above the text cursor, in any app.
///
/// It's Lina's take on Clicky's cursor buddy. Clicky follows the mouse; Lina follows the caret,
/// because a writer's eyes are on where the words are going. The drop breathes while it rests,
/// swirls while Lina thinks, turns into a waveform while it listens, and can fly to a phrase in
/// the draft and underline it. What Lina thinks is written in a card just above the drop, so there's
/// no separate window to read.
@MainActor
final class InkBuddy {
    /// Big enough for the card above or below the drop, and to its left near the screen edge. Clear and click-through.
    static let size = CGSize(width: 760, height: 460)
    static let cardWidth: CGFloat = 340
    static let cardRoom: CGFloat = 210
    /// Tip pointing down and left, at the caret it sits beside.
    static let restingTilt = -135.0

    let model = InkModel()
    private let panel: NSPanel
    private let underline = UnderlinePanel()
    /// The drop's resting point beside the caret, in Cocoa screen coordinates.
    private var home: CGPoint?
    private var flight: Timer?
    private var sayToken = UUID()
    private(set) var isPointing = false

    init() {
        panel = ClickThroughPanel(size: Self.size)
        panel.contentView = NSHostingView(rootView: InkBuddyView(model: model))
    }

    var isVisible: Bool { panel.isVisible }
    var hasCard: Bool { model.card != nil }
    /// A note is being typed or still showing beside the drop.
    var isSaying: Bool { !model.bubble.isEmpty }

    func show(_ card: InkCard) {
        if model.card == nil {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { model.card = card }
        } else {
            model.card = card
        }
    }

    func clearCard() {
        guard model.card != nil else { return }
        withAnimation(.easeOut(duration: 0.2)) { model.card = nil }
    }

    /// Moves the drop to ride beside a caret, trailing it a little like a pen behind the words.
    func follow(_ caret: CGRect) {
        let point = CGPoint(x: caret.maxX + 8, y: caret.maxY + 4)
        home = point
        if let screen = (NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main)?.visibleFrame {
            model.cardBelow = screen.maxY - point.y < Self.cardRoom
            model.cardShift = min(0, screen.maxX - 12 - (point.x - 6 + Self.cardWidth))
        }
        guard !isPointing else { return }
        let origin = clamped(origin(for: point))
        if !panel.isVisible {
            panel.setFrameOrigin(origin)
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.25
                panel.animator().alphaValue = 1
            }
        } else if hypot(panel.frame.minX - origin.x, panel.frame.minY - origin.y) > 0.5 {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.18
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrameOrigin(origin)
            }
        }
    }

    func hide() {
        cancelPointing()
        guard panel.isVisible else { return }
        panel.orderOut(nil)
    }

    /// Types a short note beside the drop, keeps it for a moment, then lets it fade.
    func say(_ text: String, hold: TimeInterval = 2.2, then done: (() -> Void)? = nil) {
        let token = UUID()
        sayToken = token
        model.bubble = ""
        let characters = Array(text)
        func type(_ i: Int) {
            guard sayToken == token else { return }
            guard i < characters.count else {
                DispatchQueue.main.asyncAfter(deadline: .now() + hold) { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.sayToken == token else { return }
                        withAnimation(.easeOut(duration: 0.3)) { self.model.bubble = "" }
                        done?()
                    }
                }
                return
            }
            model.bubble.append(characters[i])
            DispatchQueue.main.asyncAfter(deadline: .now() + .random(in: 0.025...0.05)) {
                MainActor.assumeIsolated { type(i + 1) }
            }
        }
        type(0)
    }

    // MARK: Pointing

    /// Flies to a phrase in the draft, underlines it, says why, and flies back to the caret.
    func point(at phrase: CGRect, note: String) {
        guard panel.isVisible, let home else { return }
        cancelPointing()
        isPointing = true
        model.state = .pointing
        // Land just above the phrase's first word, tip pointing down at it.
        let landing = CGPoint(x: phrase.minX + 4, y: phrase.maxY + 10)
        fly(to: landing, finalTilt: 160) { [weak self] in
            guard let self else { return }
            self.underline.show(under: phrase)
            self.say(note, hold: 3.2) { [weak self] in
                guard let self, self.isPointing else { return }
                self.underline.hide()
                let back = self.home ?? home
                self.fly(to: back, finalTilt: Self.restingTilt) { [weak self] in
                    self?.isPointing = false
                    self?.model.state = .resting
                }
            }
        }
    }

    /// The writer started typing again: drop the pointing and get back to the caret right away.
    func cancelPointing() {
        flight?.invalidate()
        flight = nil
        underline.hide()
        guard isPointing else { return }
        isPointing = false
        sayToken = UUID()
        model.bubble = ""
        model.flightScale = 1
        model.tilt = Self.restingTilt
        model.state = .resting
        if let home { panel.setFrameOrigin(clamped(origin(for: home))) }
    }

    /// A quadratic Bézier arc with smoothstep easing: the drop swells mid-flight and faces where it's going.
    private func fly(to end: CGPoint, finalTilt: Double, done: @escaping () -> Void) {
        flight?.invalidate()
        let start = CGPoint(x: panel.frame.minX + InkBuddyView.dropCenter.x,
                            y: panel.frame.maxY - InkBuddyView.dropCenter.y)
        let distance = hypot(end.x - start.x, end.y - start.y)
        let duration = min(max(distance / 800, 0.5), 1.2)
        let control = CGPoint(x: (start.x + end.x) / 2, y: (start.y + end.y) / 2 + min(distance * 0.2, 80))
        let began = Date()
        flight = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                let linear = min(1, Date().timeIntervalSince(began) / duration)
                let t = linear * linear * (3 - 2 * linear)
                let u = 1 - t
                let x = u * u * start.x + 2 * u * t * control.x + t * t * end.x
                let y = u * u * start.y + 2 * u * t * control.y + t * t * end.y
                self.panel.setFrameOrigin(self.origin(for: CGPoint(x: x, y: y)))
                let tx = 2 * u * (control.x - start.x) + 2 * t * (end.x - control.x)
                let ty = 2 * u * (control.y - start.y) + 2 * t * (end.y - control.y)
                self.model.tilt = atan2(tx, ty) * 180 / .pi
                self.model.flightScale = 1 + sin(linear * .pi) * 0.35
                if linear >= 1 {
                    timer.invalidate()
                    self.flight = nil
                    self.model.flightScale = 1
                    withAnimation(.easeInOut(duration: 0.3)) { self.model.tilt = finalTilt }
                    done()
                }
            }
        }
    }

    // MARK: Geometry

    private func origin(for dropCenter: CGPoint) -> CGPoint {
        CGPoint(x: dropCenter.x - InkBuddyView.dropCenter.x,
                y: dropCenter.y - (Self.size.height - InkBuddyView.dropCenter.y))
    }

    /// Keeps the drop itself on screen; the clear panel around it may hang off the edges.
    private func clamped(_ origin: CGPoint) -> CGPoint {
        let c = InkBuddyView.dropCenter
        let drop = CGPoint(x: origin.x + c.x, y: origin.y + Self.size.height - c.y)
        guard let vf = (NSScreen.screens.first { $0.frame.contains(drop) } ?? NSScreen.main)?.frame else { return origin }
        let x = max(vf.minX + 10, min(drop.x, vf.maxX - 12))
        let y = max(vf.minY + 10, min(drop.y, vf.maxY - 10))
        return self.origin(for: CGPoint(x: x, y: y))
    }
}

/// A borderless panel that never takes focus or clicks: the ink lives on top of the writer's app.
private final class ClickThroughPanel: NSPanel {
    init(size: CGSize) {
        super.init(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .popUpMenu
        ignoresMouseEvents = true
        hidesOnDeactivate = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// An ink stroke drawn under the writer's own words.
@MainActor
private final class UnderlinePanel {
    private let panel = ClickThroughPanel(size: CGSize(width: 10, height: 10))
    private let model = UnderlineModel()

    init() {
        panel.contentView = NSHostingView(rootView: UnderlineView(model: model))
    }

    func show(under phrase: CGRect) {
        panel.setFrame(CGRect(x: phrase.minX - 3, y: phrase.minY - 6, width: phrase.width + 6, height: 10), display: true)
        model.drawn = 0
        panel.orderFrontRegardless()
        withAnimation(.easeOut(duration: 0.55)) { model.drawn = 1 }
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        model.drawn = 0
    }
}

private final class UnderlineModel: ObservableObject {
    @Published var drawn: CGFloat = 0
}

private struct UnderlineView: View {
    @ObservedObject var model: UnderlineModel

    var body: some View {
        GeometryReader { g in
            // A slightly uneven, hand-drawn stroke.
            Path { p in
                p.move(to: CGPoint(x: 2, y: 5))
                p.addCurve(to: CGPoint(x: g.size.width - 2, y: 4.5),
                           control1: CGPoint(x: g.size.width * 0.35, y: 7),
                           control2: CGPoint(x: g.size.width * 0.65, y: 3))
            }
            .trim(from: 0, to: model.drawn)
            .stroke(Theme.ink.opacity(0.85), style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
            .shadow(color: Theme.ink.opacity(0.5), radius: 3)
        }
    }
}

// MARK: - The drop

struct InkBuddyView: View {
    /// Where the drop's center sits inside the panel (SwiftUI coordinates, top-left origin).
    static let dropCenter = CGPoint(x: 380, y: 230)
    @ObservedObject var model: InkModel
    @State private var breathing = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            ZStack {
                InkDropShape()
                    .fill(Theme.ink)
                    .frame(width: 10, height: 14)
                    .rotationEffect(.degrees(model.tilt))
                    .scaleEffect(model.flightScale * (breathing ? 1 : 0.84))
                    .shadow(color: Theme.ink.opacity(0.75), radius: 5 + (model.flightScale - 1) * 18)
                    .opacity(model.state == .resting || model.state == .pointing ? 1 : 0)
                InkSwirl()
                    .opacity(model.state == .thinking ? 1 : 0)
                InkWave(level: model.audioLevel)
                    .opacity(model.state == .listening ? 1 : 0)
            }
            .frame(width: 26, height: 26)
            .position(Self.dropCenter)
            .animation(.easeInOut(duration: 0.2), value: model.state)

            if !model.bubble.isEmpty {
                Text(model.bubble)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Theme.paper)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(Theme.ink)
                            .shadow(color: Theme.ink.opacity(0.5), radius: 6)
                    )
                    .fixedSize()
                    .offset(x: Self.dropCenter.x + 14, y: Self.dropCenter.y - 11)
                    .transition(.opacity.combined(with: .scale(scale: 0.6, anchor: .leading)))
            }

            if let card = model.card, model.state != .pointing {
                InkCardView(card: card)
                    .frame(width: InkBuddy.cardWidth, height: InkBuddy.cardRoom - 14,
                           alignment: model.cardBelow ? .topLeading : .bottomLeading)
                    .offset(x: Self.dropCenter.x - 6 + model.cardShift,
                            y: model.cardBelow ? Self.dropCenter.y + 16 : Self.dropCenter.y - InkBuddy.cardRoom)
                    .transition(.opacity.combined(with: .scale(scale: 0.92, anchor: model.cardBelow ? .topLeading : .bottomLeading)))
            }
        }
        .frame(width: InkBuddy.size.width, height: InkBuddy.size.height, alignment: .topLeading)
        .animation(.spring(response: 0.35, dampingFraction: 0.6), value: model.bubble.isEmpty)
        .onAppear {
            withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) { breathing = true }
        }
    }
}

/// Lina's words in ink, just above the cursor.
private struct InkCardView: View {
    let card: InkCard

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Text(card.eyebrow.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .kerning(0.6)
                    .lineLimit(1)
                if card.streaming { ProgressView().controlSize(.mini).tint(Theme.paper) }
            }
            .foregroundStyle(Theme.paper.opacity(0.6))
            if !card.original.isEmpty {
                Text(card.original)
                    .font(Theme.serif(12))
                    .strikethrough(true, color: Theme.paper.opacity(0.5))
                    .foregroundStyle(Theme.paper.opacity(0.5))
                    .lineLimit(3)
            }
            if !card.text.isEmpty {
                Text(card.text)
                    .font(Theme.serif(14))
                    .foregroundStyle(Theme.paper)
                    .lineLimit(6)
            }
            if !card.detail.isEmpty {
                Text(card.detail)
                    .font(Theme.serif(14, weight: .semibold))
                    .foregroundStyle(Theme.paper)
                    .lineLimit(4)
            }
            if !card.hint.isEmpty {
                Text(card.hint)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.paper.opacity(0.6))
                    .padding(.top, 1)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(Theme.ink)
                .shadow(color: Theme.ink.opacity(0.45), radius: 10, y: 2)
        )
        .animation(.easeOut(duration: 0.15), value: card)
    }
}

/// A drop of ink with its tip at the top.
struct InkDropShape: Shape {
    func path(in r: CGRect) -> Path {
        let radius = r.width / 2
        let center = CGPoint(x: r.midX, y: r.maxY - radius)
        var p = Path()
        p.move(to: CGPoint(x: r.midX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: center.y), control: CGPoint(x: r.maxX, y: r.minY + r.height * 0.4))
        p.addArc(center: center, radius: radius, startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
        p.addQuadCurve(to: CGPoint(x: r.midX, y: r.minY), control: CGPoint(x: r.minX, y: r.minY + r.height * 0.4))
        p.closeSubpath()
        return p
    }
}

/// Ink swirling: Lina is thinking.
private struct InkSwirl: View {
    @State private var spinning = false

    var body: some View {
        Circle()
            .trim(from: 0.15, to: 0.85)
            .stroke(AngularGradient(colors: [Theme.ink.opacity(0), Theme.ink], center: .center),
                    style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
            .frame(width: 13, height: 13)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .shadow(color: Theme.ink.opacity(0.6), radius: 5)
            .onAppear {
                withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) { spinning = true }
            }
    }
}

/// Ink bars that move with the writer's voice: Lina is listening.
private struct InkWave: View {
    let level: CGFloat
    private let profile: [CGFloat] = [0.4, 0.7, 1, 0.7, 0.4]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            HStack(spacing: 2) {
                ForEach(0..<profile.count, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(Theme.ink)
                        .frame(width: 2, height: height(i, at: context.date))
                }
            }
            .shadow(color: Theme.ink.opacity(0.6), radius: 5)
        }
    }

    private func height(_ i: Int, at date: Date) -> CGFloat {
        let phase = CGFloat(date.timeIntervalSinceReferenceDate * 3.6) + CGFloat(i) * 0.35
        let loud = pow(min(max(level - 0.008, 0) * 2.85, 1), 0.76)
        return 3 + loud * 11 * profile[i] + (sin(phase) + 1) / 2 * 1.5
    }
}
