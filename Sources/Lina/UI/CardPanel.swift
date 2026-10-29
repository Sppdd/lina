import AppKit
import SwiftUI

/// What the card at the writer's cursor is showing.
enum CardContent: Equatable {
    /// Lina is working on it.
    case working(String)
    /// `/lina`: one question for the writer.
    case question(String)
    /// Word fixes, listed. Used when the app can't say where the words are on screen;
    /// otherwise the fixes sit right on top of the mistakes (`FixPanel`).
    case corrections([Fix])
    /// A search answer that can replace the question in the sentence.
    case answer(question: String, text: String, sources: [WebSource], grounded: Bool)
    /// Rewrites or an edit to choose from.
    case choices(title: String, original: String, options: [String])
    /// `/lina model`: models on Token Factory (or the local server).
    case models(items: [ModelItem], currentText: String, currentImage: String)
    /// `/lina image`: the picture, ready to drop in.
    case image(prompt: String, image: NSImage)
    case help
    /// A short message that fades on its own.
    case notice(String, Mood)

    var mood: Mood {
        switch self {
        case .working: .thinking
        case let .notice(_, mood): mood
        case .help: .idle
        default: .found
        }
    }

    /// Cards the writer acts on stay until they choose, press esc, or click away.
    var isPersistent: Bool {
        switch self {
        case .working, .notice: false
        default: true
        }
    }

    var isNotice: Bool {
        if case .notice = self { return true }
        return false
    }

    var title: String {
        switch self {
        case .working: "Lina"
        case .question: "Lina asks"
        case let .corrections(fixes):
            fixes.count == 1 ? "1 mistake" : "\(fixes.count) mistakes"
        case let .answer(_, _, _, grounded): grounded ? "From the web" : "From the model"
        case let .choices(title, _, _): title
        case .models: "Models"
        case .image: "Your picture"
        case .help: "Lina's commands"
        case .notice: "Lina"
        }
    }
}

final class CardModel: ObservableObject {
    @Published var content: CardContent?
    @Published var selected = 0
}

// MARK: - Card view

/// The card itself. Also used, with sample content, in Lina's home window and onboarding demos.
struct CardView: View {
    let content: CardContent
    var selected = 0
    var onChoose: ((Int) -> Void)? = nil

    static let width: CGFloat = 400

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                LinaFace(mood: content.mood, head: true)
                    .frame(width: 26, height: 27)
                Text(content.title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                if case .working = content { InkDot().frame(width: 7, height: 7) }
            }
            main
            footer
        }
        .padding(14)
        .frame(width: Self.width, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.paper))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(content.mood.hair.opacity(0.45), lineWidth: 1))
        .shadow(color: .black.opacity(0.14), radius: 14, y: 6)
        .padding(16) // room for the shadow
        .tint(Theme.ink)
    }

    @ViewBuilder private var main: some View {
        switch content {
        case let .working(label):
            Text(label).font(.system(size: 13)).foregroundStyle(.secondary)
        case let .question(q):
            Text(q)
                .font(Theme.serif(17, weight: .medium))
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
        case let .corrections(fixes):
            VStack(alignment: .leading, spacing: 5) {
                ForEach(Array(fixes.enumerated()), id: \.offset) { i, fix in
                    Button { onChoose?(i + 1) } label: {
                        HStack(spacing: 9) {
                            KeyCap(i < 9 ? "⌘\(i + 1)" : "·", size: 10)
                            Text(fix.wrong).strikethrough(true, color: Self.color(fix.kind)).foregroundStyle(.secondary)
                            Image(systemName: "arrow.right").font(.system(size: 9, weight: .bold)).foregroundStyle(.tertiary)
                            Text(fix.right).fontWeight(.semibold).foregroundStyle(Self.color(fix.kind))
                            Spacer(minLength: 0)
                        }
                        .font(Theme.serif(14.5))
                        .padding(.horizontal, 8).padding(.vertical, 5)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.035)))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        case let .answer(question, text, sources, grounded):
            VStack(alignment: .leading, spacing: 8) {
                Text(question)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                Text(text)
                    .font(Theme.serif(16))
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                if !sources.isEmpty {
                    FlowLayout(spacing: 6) {
                        ForEach(sources, id: \.self) { s in
                            Link(destination: URL(string: s.url) ?? URL(string: "https://google.com")!) {
                                Label(s.site, systemImage: "link")
                                    .font(.system(size: 10.5, weight: .medium))
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(Capsule().fill(Theme.ink.opacity(0.08)))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                if !grounded {
                    Text("Not checked against the web. Add a Gemini key in Settings → Search for live answers.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        case let .choices(_, original, options):
            VStack(alignment: .leading, spacing: 8) {
                Text(original)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                optionList(options, labels: [])
            }
        case let .models(items, currentText, currentImage):
            modelList(items, currentText: currentText, currentImage: currentImage)
        case let .image(prompt, image):
            VStack(alignment: .leading, spacing: 8) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 260)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                Text(prompt).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(2)
            }
        case .help:
            VStack(alignment: .leading, spacing: 7) {
                ForEach(CommandParser.words) { w in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(w.usage)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(Theme.ink)
                            .frame(width: 150, alignment: .leading)
                        Text(w.detail).font(.system(size: 11.5)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Text("Anything else you type in the bar is a web search, answered to fit your sentence.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case let .notice(message, _):
            Text(message).font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var hints: [(key: String, label: String)] {
        switch content {
        case .working: return [("esc", "Stop")]
        case .question: return [("esc", "Got it")]
        case let .corrections(fixes):
            return fixes.count > 1 ? [("⌘1–⌘\(min(9, fixes.count))", "Fix one"), ("⌘A", "Fix all"), ("esc", "Keep mine")] : [("⌘1", "Fix"), ("esc", "Keep mine")]
        case let .answer(_, _, sources, _):
            return sources.isEmpty ? [("⌘1", "Insert"), ("esc", "Dismiss")] : [("⌘1", "Insert"), ("⌘2", "With source"), ("esc", "Dismiss")]
        case let .choices(_, _, options): return [("⌘1–⌘\(max(1, options.count))", "Use"), ("esc", "Keep mine")]
        case .models: return [("↑↓", "Move"), ("↩", "Use"), ("⌘1–⌘9", "Pick"), ("esc", "Close")]
        case .image: return [("⌘1", "Insert"), ("⌘2", "Copy"), ("esc", "Dismiss")]
        case .help: return [("esc", "Close")]
        case .notice: return []
        }
    }

    @ViewBuilder private var footer: some View {
        if !hints.isEmpty {
            HStack(spacing: 12) {
                ForEach(Array(hints.enumerated()), id: \.offset) { _, h in
                    HStack(spacing: 4) {
                        KeyCap(h.key, size: 10)
                        Text(h.label).font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.top, 2)
        }
    }

    private func optionList(_ options: [String], labels: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(options.enumerated()), id: \.offset) { i, option in
                Button { onChoose?(i + 1) } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 9) {
                        KeyCap("⌘\(i + 1)", size: 10)
                        VStack(alignment: .leading, spacing: 2) {
                            if i < labels.count {
                                Text(labels[i].uppercased())
                                    .font(.system(size: 9, weight: .semibold)).tracking(0.5)
                                    .foregroundStyle(.secondary)
                            }
                            Text(option)
                                .font(Theme.serif(14.5))
                                .foregroundStyle(.primary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(i == selected ? Theme.ink.opacity(0.10) : Color.primary.opacity(0.035)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func modelList(_ items: [ModelItem], currentText: String, currentImage: String) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                        if i == 0 || items[i - 1].kind != item.kind {
                            Text(item.kind == .text ? "WRITING" : "IMAGES")
                                .font(.system(size: 9.5, weight: .semibold)).tracking(0.6)
                                .foregroundStyle(.secondary)
                                .padding(.top, i == 0 ? 0 : 8).padding(.bottom, 2)
                        }
                        let current = item.id == (item.kind == .text ? currentText : currentImage)
                        Button { onChoose?(i + 1) } label: {
                            HStack(spacing: 9) {
                                if i < 9 { KeyCap("⌘\(i + 1)", size: 10) } else { Color.clear.frame(width: 26, height: 10) }
                                VStack(alignment: .leading, spacing: 0) {
                                    Text(item.shortName).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                                    if !item.maker.isEmpty {
                                        Text(item.maker).font(.system(size: 10.5)).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                }
                                Spacer(minLength: 4)
                                if current { Image(systemName: "checkmark").foregroundStyle(Theme.ink).font(.system(size: 11, weight: .bold)) }
                            }
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(i == selected ? Theme.ink.opacity(0.12) : .clear))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .id(i)
                    }
                }
            }
            .frame(maxHeight: 300)
            .onChange(of: selected) { _, s in withAnimation(Theme.quick) { proxy.scrollTo(s, anchor: .center) } }
        }
    }

    static func color(_ kind: Proofread.Kind) -> Color {
        switch kind {
        case .spelling: Mood.worried.hair
        case .grammar: Mood.found.hair
        case .punctuation: Mood.listening.hair
        }
    }
}

/// A softly pulsing drop of ink: Lina is thinking.
struct InkDot: View {
    @State private var on = false
    var body: some View {
        Circle()
            .fill(Theme.ink)
            .scaleEffect(on ? 1 : 0.55)
            .opacity(on ? 0.9 : 0.35)
            .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: on)
            .onAppear { on = true }
    }
}

/// Wraps chips onto multiple lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 600
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxX: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 { x = 0; y += rowH + spacing; rowH = 0 }
            x += size.width + spacing
            maxX = max(maxX, x - spacing)
            rowH = max(rowH, size.height)
        }
        return CGSize(width: maxX, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowH + spacing; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width + spacing
            rowH = max(rowH, size.height)
        }
    }
}

// MARK: - Panels

/// A borderless panel that floats over every app without taking focus.
func floatingPanel(clickThrough: Bool) -> NSPanel {
    let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = false
    panel.level = .popUpMenu
    panel.ignoresMouseEvents = clickThrough
    panel.hidesOnDeactivate = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
    panel.animationBehavior = .none
    return panel
}

/// The visible frame of the screen showing `rect`.
func screen(containing rect: CGRect) -> NSRect {
    let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: rect.midX, y: rect.midY)) } ?? NSScreen.main
    return screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
}

/// The floating card under the writer's line. It never takes focus from their document.
@MainActor
final class CardPanel {
    let model = CardModel()
    var onChoose: ((Int) -> Void)?
    private let panel = floatingPanel(clickThrough: false)
    private var host: NSHostingView<CardHost>!
    private var anchor: CGRect = .zero

    init() {
        host = NSHostingView(rootView: CardHost(model: model, onChoose: { [weak self] n in self?.onChoose?(n) }))
        panel.contentView = host
    }

    var isVisible: Bool { panel.isVisible && model.content != nil }
    var frame: CGRect { panel.frame }

    /// Shows content under `anchor` (a line of text, in screen coordinates).
    func show(_ content: CardContent, at anchor: CGRect, selected: Int = 0) {
        self.anchor = anchor
        model.selected = selected
        model.content = content
        layout()
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func select(_ index: Int) { model.selected = index }

    func hide() {
        panel.orderOut(nil)
        model.content = nil
    }

    private func layout() {
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        let bounds = screen(containing: anchor)
        // Below the line, nudged so the card's text lines up with the writer's.
        var origin = CGPoint(x: anchor.minX - 30, y: anchor.minY - 2 - size.height)
        if origin.y < bounds.minY + 4 { origin.y = anchor.maxY + 2 }
        origin.x = max(bounds.minX + 4, min(origin.x, bounds.maxX - size.width - 4))
        origin.y = max(bounds.minY + 4, min(origin.y, bounds.maxY - size.height - 4))
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
    }
}

struct CardHost: View {
    @ObservedObject var model: CardModel
    var onChoose: (Int) -> Void

    var body: some View {
        if let content = model.content {
            CardView(content: content, selected: model.selected, onChoose: onChoose)
                .fixedSize()
        }
    }
}

/// Wavy underlines drawn over the writer's own text, under each mistake. Clicks pass through.
@MainActor
final class MarkPanel {
    private let panel = floatingPanel(clickThrough: true)

    struct Underline: Equatable {
        var rect: CGRect
        var color: Color
    }

    func show(_ lines: [Underline]) {
        guard !lines.isEmpty else { hide(); return }
        let union = lines.map(\.rect).reduce(lines[0].rect) { $0.union($1) }.insetBy(dx: -4, dy: -6)
        let local = lines.map { u in
            Underline(rect: CGRect(x: u.rect.minX - union.minX, y: union.maxY - u.rect.maxY,
                                   width: u.rect.width, height: u.rect.height), color: u.color)
        }
        panel.contentView = NSHostingView(rootView: Squiggles(lines: local))
        panel.setFrame(union, display: true)
        panel.orderFrontRegardless()
    }

    func hide() { panel.orderOut(nil) }

    private struct Squiggles: View {
        let lines: [Underline]
        var body: some View {
            Canvas { ctx, _ in
                for u in lines {
                    var p = Path()
                    let y = u.rect.maxY + 1.5
                    var x = u.rect.minX
                    p.move(to: CGPoint(x: x, y: y))
                    var up = true
                    while x < u.rect.maxX {
                        let next = min(x + 3, u.rect.maxX)
                        p.addQuadCurve(to: CGPoint(x: next, y: y), control: CGPoint(x: (x + next) / 2, y: y + (up ? -2.2 : 2.2)))
                        x = next
                        up.toggle()
                    }
                    ctx.stroke(p, with: .color(u.color), lineWidth: 1.6)
                }
            }
        }
    }
}

/// A one-time hint with a ^ pointing up at the writer's own text. Clicks pass through.
@MainActor
final class TipPanel {
    private let panel = floatingPanel(clickThrough: true)
    private var hideWork: DispatchWorkItem?

    var isVisible: Bool { panel.isVisible }

    /// `under` is the character to point at, in screen coordinates.
    func show(_ text: String, under: CGRect) {
        let host = NSHostingView(rootView: TipView(text: text))
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        panel.contentView = host
        let bounds = screen(containing: under)
        var origin = CGPoint(x: under.midX - TipView.caretX, y: under.minY - size.height)
        origin.x = max(bounds.minX + 4, min(origin.x, bounds.maxX - size.width - 4))
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
        panel.orderFrontRegardless()
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.hide() } }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 7, execute: work)
    }

    func hide() {
        hideWork?.cancel()
        panel.orderOut(nil)
    }
}

struct TipView: View {
    let text: String
    static let caretX: CGFloat = 22

    var body: some View {
        VStack(alignment: .leading, spacing: -6) {
            Text("^")
                .font(.system(size: 22, weight: .heavy, design: .rounded))
                .foregroundStyle(Mood.idle.hair)
                .frame(width: 20)
                .padding(.leading, Self.caretX - 10)
            HStack(alignment: .center, spacing: 8) {
                LinaFace(mood: .idle, head: true).frame(width: 18, height: 19)
                Text(text)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: 300, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Mood.idle.hair))
            .shadow(color: .black.opacity(0.15), radius: 6, y: 3)
        }
        .padding(.horizontal, 6)
        .padding(.bottom, 10)
        .fixedSize()
    }
}
