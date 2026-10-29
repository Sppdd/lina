import AppKit
import SwiftUI

/// A small bar that opens at the caret when the writer types `/lina` (or presses ⌥ Space).
/// The command lives here, not in the writer's text, so there's nothing to delete afterwards.
/// Return runs it; so does moving on with ", " or ". ". Esc, or Delete on an empty bar, closes it.
@MainActor
final class CommandBar {
    let model = CommandBarModel()
    var onSubmit: ((String) -> Void)?
    var onCancel: (() -> Void)?

    private let panel: BarPanel
    private var host: NSHostingView<CommandBarView>!
    private var closing = false

    init() {
        panel = BarPanel(contentRect: CGRect(x: 0, y: 0, width: CommandBarView.width, height: 90),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.animationBehavior = .none
        host = NSHostingView(rootView: CommandBarView(model: model,
                                                     submit: { [weak self] text in self?.submit(text) },
                                                     cancel: { [weak self] in self?.cancel() }))
        panel.contentView = host
        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                // Clicking somewhere else puts the command away.
                guard let self, !self.closing, self.panel.isVisible else { return }
                self.cancel()
            }
        }
    }

    var isVisible: Bool { panel.isVisible }
    var frame: CGRect { panel.frame }

    /// Opens under `anchor`, the writer's line in screen coordinates.
    func show(at anchor: CGRect) {
        model.text = ""
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        let bounds = screen(containing: anchor)
        var origin = CGPoint(x: anchor.minX - 20, y: anchor.minY - 2 - size.height)
        if origin.y < bounds.minY + 4 { origin.y = anchor.maxY + 2 }
        origin.x = max(bounds.minX + 4, min(origin.x, bounds.maxX - size.width - 4))
        panel.setFrame(CGRect(origin: origin, size: size), display: true)
        closing = false
        panel.makeKeyAndOrderFront(nil)
        model.focus += 1
    }

    func hide() {
        closing = true
        panel.orderOut(nil)
    }

    private func submit(_ text: String) {
        hide()
        onSubmit?(text)
    }

    private func cancel() {
        hide()
        onCancel?()
    }
}

final class CommandBarModel: ObservableObject {
    @Published var text = ""
    @Published var focus = 0
}

/// Takes keyboard focus without bringing Lina to the front, so the writer's app stays active.
private final class BarPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

struct CommandBarView: View {
    static let width: CGFloat = 500

    @ObservedObject var model: CommandBarModel
    var submit: (String) -> Void
    var cancel: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        CommandBarLook(text: model.text) {
            TextField("Ask anything, or: fix · rewrite · edit · model · image", text: $model.text)
                .textFieldStyle(.plain)
                .font(.system(size: 14))
                .focused($focused)
                .onSubmit { submit(model.text) }
                .onExitCommand { cancel() }
                .onKeyPress(.delete) {
                    guard model.text.isEmpty else { return .ignored }
                    cancel()
                    return .handled
                }
                .onChange(of: model.text) { _, t in
                    // Moving on with a comma or a full stop runs it, as it would in the text.
                    if t.count > 2, [", ", ". ", "? "].contains(where: { t.hasSuffix($0) }) { submit(t) }
                }
        }
        .onAppear { focused = true }
        .onChange(of: model.focus) { _, _ in focused = true }
    }
}

/// How the bar looks. The field is passed in, so the demos can show the same bar with typed text.
struct CommandBarLook<Field: View>: View {
    let text: String
    @ViewBuilder var field: Field

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 9) {
                LinaFace(mood: .listening, head: true).frame(width: 24, height: 25)
                Text("/lina")
                    .font(.system(size: 13.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Mood.listening.hair)
                field
                KeyCap("↩", size: 10)
            }
            Text(Self.hint(for: text))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.leading, 33)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: CommandBarView.width, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous).fill(Theme.paper))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous).strokeBorder(Mood.listening.hair.opacity(0.55), lineWidth: 1))
        .shadow(color: .black.opacity(0.16), radius: 14, y: 6)
        .padding(16)
    }

    /// What Return will do with what's typed so far.
    static func hint(for text: String) -> String {
        let t = text.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return "↩ asks you a question about what you wrote · esc closes" }
        let word = t.split(separator: " ").first.map { $0.lowercased() } ?? ""
        if let help = CommandParser.words.first(where: { !$0.word.isEmpty && $0.word.hasPrefix(word) }) {
            return "\(help.usage)  \(help.detail)"
        }
        return "↩ searches the web and answers in words that fit your sentence"
    }
}

extension CommandBarLook where Field == Text {
    /// A still bar showing `text`, for demos and snapshots.
    init(showing text: String) {
        self.text = text
        self.field = Text(text.isEmpty ? "Ask anything, or: fix · rewrite · edit · model · image" : text)
            .font(.system(size: 14))
            .foregroundColor(text.isEmpty ? .secondary : .primary)
    }
}
