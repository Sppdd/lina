import AppKit
import SwiftUI

/// The fixes, sitting right on top of the words they correct: a small "really ⌘2" chip above "realy".
/// ⌘1, ⌘2… takes one, ⌘A takes them all, esc leaves the writer's words alone.
@MainActor
final class FixPanel {
    struct Chip: Identifiable, Equatable {
        let number: Int
        let text: String
        let kind: Proofread.Kind?
        /// Position in the panel, SwiftUI coordinates (origin top-left).
        let frame: CGRect
        var id: Int { number }
    }

    var onChoose: ((Int) -> Void)?
    var onAll: (() -> Void)?
    private let panel = floatingPanel(clickThrough: false)

    var isVisible: Bool { panel.isVisible }
    var frame: CGRect { panel.frame }

    static let height: CGFloat = 20
    private static let textFont = NSFont.systemFont(ofSize: 12, weight: .semibold)
    private static let keyFont = NSFont.systemFont(ofSize: 9.5, weight: .bold)

    /// `rects` are the mistakes' places on screen (Cocoa coordinates), one per fix, nil where the app won't say.
    /// Returns false when no fix could be placed, so the caller can show a card instead.
    @discardableResult
    func show(_ fixes: [Fix], rects: [CGRect?]) -> Bool {
        var placed: [(number: Int, text: String, kind: Proofread.Kind?, rect: CGRect)] = []
        for (i, fix) in fixes.enumerated() where i < 9 {
            guard i < rects.count, let word = rects[i] else { continue }
            let w = Self.width(fix.right, key: "⌘\(i + 1)")
            var rect = CGRect(x: word.midX - w / 2, y: word.maxY + 3, width: w, height: Self.height)
            // Keep chips on the same line from overlapping.
            if let prev = placed.last, abs(prev.rect.minY - rect.minY) < 6, rect.minX < prev.rect.maxX + 4 {
                rect.origin.x = prev.rect.maxX + 4
            }
            placed.append((i + 1, fix.right, fix.kind, rect))
        }
        guard let last = placed.last else { hide(); return false }
        if fixes.count > 1 {
            let label = "Fix all"
            let w = Self.width(label, key: "⌘A")
            placed.append((0, label, nil, CGRect(x: last.rect.maxX + 6, y: last.rect.minY, width: w, height: Self.height)))
        }

        let union = placed.map { $0.rect }.reduce(placed[0].rect) { $0.union($1) }.insetBy(dx: -8, dy: -8)
        let bounds = screen(containing: union)
        var frame = union
        frame.origin.x = max(bounds.minX, min(frame.minX, bounds.maxX - frame.width))
        frame.origin.y = max(bounds.minY, min(frame.minY, bounds.maxY - frame.height))
        let dx = frame.minX - union.minX, dy = frame.minY - union.minY
        let chips = placed.map { p in
            Chip(number: p.number, text: p.text, kind: p.kind,
                 frame: CGRect(x: p.rect.minX + dx - frame.minX, y: frame.maxY - (p.rect.maxY + dy),
                               width: p.rect.width, height: p.rect.height))
        }
        panel.contentView = NSHostingView(rootView: FixChips(chips: chips, size: frame.size) { [weak self] n in
            if n == 0 { self?.onAll?() } else { self?.onChoose?(n) }
        })
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        return true
    }

    func hide() { panel.orderOut(nil) }

    private static func width(_ text: String, key: String) -> CGFloat {
        let t = (text as NSString).size(withAttributes: [.font: textFont]).width
        let k = (key as NSString).size(withAttributes: [.font: keyFont]).width
        return ceil(t + k + 4 + 18)
    }
}

/// The chips themselves. Also drawn in the demos.
struct FixChips: View {
    let chips: [FixPanel.Chip]
    let size: CGSize
    var choose: (Int) -> Void = { _ in }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            ForEach(chips) { chip in
                FixChip(text: chip.text, key: chip.number == 0 ? "⌘A" : "⌘\(chip.number)", kind: chip.kind)
                    .frame(width: chip.frame.width, height: chip.frame.height)
                    .offset(x: chip.frame.minX, y: chip.frame.minY)
                    .onTapGesture { choose(chip.number) }
            }
        }
        .frame(width: size.width, height: size.height, alignment: .topLeading)
    }
}

struct FixChip: View {
    let text: String
    let key: String
    /// nil for the "Fix all" chip.
    let kind: Proofread.Kind?

    var body: some View {
        HStack(spacing: 4) {
            Text(text).font(.system(size: 12, weight: .semibold)).lineLimit(1)
            Text(key).font(.system(size: 9.5, weight: .bold)).opacity(0.8)
        }
        .foregroundStyle(kind == nil ? Theme.ink : .white)
        .padding(.horizontal, 9)
        .frame(height: FixPanel.height)
        .background(Capsule().fill(kind.map { CardView.color($0) } ?? Theme.paper))
        .overlay(Capsule().strokeBorder(kind == nil ? Theme.ink.opacity(0.35) : .clear, lineWidth: 1))
        .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
        .contentShape(Capsule())
    }
}
