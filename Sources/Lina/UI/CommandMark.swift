import AppKit
import SwiftUI

/// Marks a `/lina …` command in the writer's own text: a tinted, underlined band over the words and a small tag
/// after them, so the command reads as Lina's, not the writer's. The text stays in the field; this only draws
/// over it. Clicks pass through.
@MainActor
final class CommandMark {
    enum State { case typing, running, waiting }

    private let panel = floatingPanel(clickThrough: true)
    private static let tagWidth: CGFloat = 104

    /// `band` is the command's place on screen (Cocoa coordinates). With no band, the tag sits after the caret.
    func show(band: CGRect?, caret: CGRect?, state: State) {
        guard let anchor = band ?? caret else { hide(); return }
        let hasBand = band != nil
        let pad: CGFloat = 4
        let frame = CGRect(x: anchor.minX - pad, y: anchor.minY - pad,
                           width: (hasBand ? anchor.width : 1) + pad * 2 + Self.tagWidth, height: anchor.height + pad * 2)
        let local = CGRect(x: pad, y: pad, width: hasBand ? anchor.width : 0, height: anchor.height)
        panel.contentView = NSHostingView(rootView: CommandMarkView(band: local, showBand: hasBand, state: state))
        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
    }

    func hide() { panel.orderOut(nil) }
}

struct CommandMarkView: View {
    let band: CGRect
    let showBand: Bool
    let state: CommandMark.State

    private var color: Color { Self.color(for: state) }
    private var tag: String { Self.tag(for: state) }

    /// Blue while the writer types the command, lavender while Lina works, amber while a card waits: her hair colors.
    static func color(for state: CommandMark.State) -> Color {
        switch state {
        case .typing: Mood.listening.hair
        case .running: Mood.thinking.hair
        case .waiting: Mood.found.hair
        }
    }

    static func tag(for state: CommandMark.State) -> String {
        switch state {
        case .typing: "↩ run · esc"
        case .running: "working…"
        case .waiting: "⌘1 · esc"
        }
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            if showBand {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(color.opacity(0.16))
                    .frame(width: band.width + 4, height: band.height + 2)
                    .offset(x: band.minX - 2, y: band.minY - 1)
                Rectangle()
                    .fill(color)
                    .frame(width: band.width, height: 2)
                    .offset(x: band.minX, y: band.maxY)
            }
            Text(tag)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 7)
                .frame(height: min(18, max(14, band.height - 2)))
                .background(Capsule().fill(color))
                .fixedSize()
                .offset(x: band.maxX + 6, y: band.midY - min(18, max(14, band.height - 2)) / 2)
        }
    }
}

/// A line of the writer's text with a `/lina` command in it, drawn the way Lina marks it on screen.
/// Used by the demos and snapshots.
struct InlineCommandLine: View {
    let text: String
    var command: String?
    var state: CommandMark.State = .typing
    var cursor = true
    var size: CGFloat = 14

    var body: some View {
        line
            .font(.system(size: size))
            .fixedSize(horizontal: false, vertical: true)
    }

    private var line: Text {
        var t = Text(text)
        guard let command else {
            return cursor ? t + Text("|").foregroundStyle(Theme.ink) : t
        }
        let color = CommandMarkView.color(for: state)
        t = t + Text(command).foregroundStyle(color).underline(true, color: color).fontWeight(.medium)
        if cursor && state == .typing { t = t + Text("|").foregroundStyle(Theme.ink) }
        return t + Text("  " + CommandMarkView.tag(for: state))
            .font(.system(size: size - 3, weight: .semibold))
            .foregroundStyle(color)
    }
}
