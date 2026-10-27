import AppKit
import SwiftUI

final class GhostModel: ObservableObject {
    @Published var text = ""
    @Published var fontSize: CGFloat = 14
    @Published var streaming = false
}

/// A floating, click-through panel that draws the suggestion right after the caret in any app.
@MainActor
final class GhostPanel {
    let model = GhostModel()
    private let panel: NSPanel
    private let host: NSHostingView<GhostView>

    init() {
        host = NSHostingView(rootView: GhostView(model: model))
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = host
        panel.animationBehavior = .none
    }

    var isVisible: Bool { panel.isVisible }

    func show(_ text: String, caret: CGRect, streaming: Bool) {
        model.text = text
        model.streaming = streaming
        model.fontSize = max(11, min(30, caret.height * 0.74))
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        let screen = NSScreen.screens.first { $0.frame.contains(caret.origin) } ?? NSScreen.main
        let bounds = screen?.visibleFrame ?? .infinite
        var origin = CGPoint(x: caret.maxX - GhostView.leadingInset - GhostView.outerPadding, y: caret.midY - size.height / 2)
        if origin.x + size.width > bounds.maxX - 8 {
            // Not enough room on this line — float just below it instead.
            origin.x = max(bounds.minX + 8, min(caret.minX, bounds.maxX - size.width - 8))
            origin.y = caret.minY - size.height - 2
        }
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
        model.text = ""
    }
}

struct GhostView: View {
    static let leadingInset: CGFloat = 5
    static let outerPadding: CGFloat = 8
    @ObservedObject var model: GhostModel

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            Text(model.text.trimmingCharacters(in: .newlines))
                .font(.system(size: model.fontSize))
                .foregroundStyle(Color(nsColor: Theme.nsGhost))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 560, alignment: .leading)
            if model.streaming {
                InkDot().frame(width: 6, height: 6)
            } else {
                KeyCap("tab", size: max(9, model.fontSize * 0.62))
                    .transition(.opacity)
            }
        }
        .padding(.leading, Self.leadingInset)
        .padding(.trailing, 6)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color(nsColor: Theme.nsPaper).opacity(0.94))
                .shadow(color: .black.opacity(0.10), radius: 6, y: 2)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Theme.ink.opacity(0.18), lineWidth: 0.5)
        )
        .padding(Self.outerPadding) // room for the shadow
        .fixedSize()
        .animation(Theme.quick, value: model.streaming)
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
