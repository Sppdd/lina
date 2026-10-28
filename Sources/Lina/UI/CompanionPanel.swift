import AppKit
import SwiftUI

/// A floating window that stays beside whatever you're writing in. It never takes focus from your
/// document unless you click into it to talk back.
@MainActor
final class CompanionPanel {
    private let panel: CompanionNSPanel
    private let input = CompanionInput()

    init(companion: Companion) {
        panel = CompanionNSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 540),
                             styleMask: [.titled, .closable, .resizable, .fullSizeContentView, .nonactivatingPanel],
                             backing: .buffered, defer: true)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 280, height: 320)
        panel.backgroundColor = Theme.nsPaper
        for button in [NSWindow.ButtonType.miniaturizeButton, .zoomButton] {
            panel.standardWindowButton(button)?.isHidden = true
        }
        panel.contentView = NSHostingView(rootView: CompanionView(companion: companion, input: input))
        panel.setFrameAutosaveName("LinaCompanion")
        if !panel.setFrameUsingName("LinaCompanion"), let screen = NSScreen.main?.visibleFrame {
            panel.setFrameOrigin(NSPoint(x: screen.maxX - 340 - 20, y: screen.maxY - 540 - 20))
        }
    }

    var isVisible: Bool { panel.isVisible }
    var isKey: Bool { panel.isKeyWindow }

    func show() { panel.orderFrontRegardless() }
    func hide() { panel.orderOut(nil) }

    func focusInput() {
        panel.makeKey()
        input.focus += 1
    }
}

/// A non-activating panel that can still take keyboard focus for the reply field.
private final class CompanionNSPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Lets AppKit ask the SwiftUI reply field to take focus.
final class CompanionInput: ObservableObject {
    @Published var focus = 0
}

struct CompanionView: View {
    @ObservedObject var companion: Companion
    @ObservedObject var input: CompanionInput
    @ObservedObject var settings = AppSettings.shared
    @State private var draft = ""
    @FocusState private var typing: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            if companion.entries.isEmpty {
                emptyState
            } else {
                trail
            }
            Divider().opacity(0.5)
            replyBar
        }
        .background(Theme.paper)
        .tint(Theme.ink)
        .onChange(of: input.focus) { _, _ in typing = true }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Wordmark(size: 17)
            VStack(alignment: .leading, spacing: 1) {
                Text("thinking with you")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                if !companion.place.isEmpty {
                    Text(companion.place)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
            stateDot
            Button { companion.thinkNow() } label: { Image(systemName: "sparkles") }
                .buttonStyle(.borderless)
                .help("Read my draft again now")
                .disabled(companion.state == .thinking)
            Menu {
                Button("Clear the conversation") { companion.clear() }
                Button(settings.companionEnabled ? "Pause reading" : "Resume reading") {
                    settings.companionEnabled.toggle()
                }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
        }
        .padding(.leading, 44) // clear the close button in the title bar
        .padding(.trailing, 12)
        .padding(.vertical, 9)
        .foregroundStyle(Theme.ink)
    }

    @ViewBuilder private var stateDot: some View {
        switch companion.state {
        case .thinking: InkDot().frame(width: 7, height: 7).help("Thinking…")
        case .error: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.system(size: 11))
        case .paused: Image(systemName: "pause.circle").foregroundStyle(.secondary).font(.system(size: 11))
        default: EmptyView()
        }
    }

    // MARK: Trail

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "text.bubble")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Theme.ink.opacity(0.6))
            Text("Write anywhere.")
                .font(Theme.serif(17, weight: .semibold))
            Text("When you pause, I'll read along and think with you about what you're saying, and why.")
                .font(Theme.serif(13.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 240)
            if case let .error(message) = companion.state {
                errorNote(message)
            }
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(20)
    }

    private var trail: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 14) {
                    ForEach(companion.entries) { entry in
                        EntryView(entry: entry).id(entry.id)
                    }
                    if case let .error(message) = companion.state {
                        errorNote(message)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(14)
            }
            .onChange(of: companion.entries) { _, _ in
                withAnimation(Theme.quick) { proxy.scrollTo("end", anchor: .bottom) }
            }
            .onAppear { proxy.scrollTo("end", anchor: .bottom) }
        }
    }

    private func errorNote(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).font(.system(size: 11.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(Color.orange.opacity(0.08)))
    }

    // MARK: Reply

    private var replyBar: some View {
        HStack(spacing: 8) {
            TextField("Answer Lina, or think out loud…", text: $draft, axis: .vertical)
                .textFieldStyle(.plain)
                .font(Theme.serif(13.5))
                .lineLimit(1...4)
                .focused($typing)
                .onSubmit(send)
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill").font(.system(size: 19))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(draft.trimmingCharacters(in: .whitespaces).isEmpty ? Color.secondary : Theme.ink)
            .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private func send() {
        companion.send(draft)
        draft = ""
    }
}

private struct EntryView: View {
    let entry: Companion.Entry

    var body: some View {
        switch entry.kind {
        case let .reflection(r):
            reflection(r)
        case let .writer(text):
            HStack {
                Spacer(minLength: 40)
                Text(text)
                    .font(Theme.serif(13.5))
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Theme.ink.opacity(0.10)))
                    .textSelection(.enabled)
            }
        case let .reply(text):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(text.isEmpty ? " " : text)
                    .font(Theme.serif(14))
                    .lineSpacing(2)
                    .textSelection(.enabled)
                if entry.streaming { InkDot().frame(width: 6, height: 6) }
            }
        case let .place(name):
            HStack(spacing: 8) {
                Rectangle().fill(Theme.paperEdge).frame(height: 1)
                Text(name).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.tertiary).lineLimit(1)
                Rectangle().fill(Theme.paperEdge).frame(height: 1)
            }
        }
    }

    private func reflection(_ r: Reflection) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            part("What I hear", r.hearing)
            part("Why you're writing it", r.why)
            if !r.ask.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    label("A question for you")
                    Text(r.ask)
                        .font(Theme.serif(15, weight: .medium))
                        .foregroundStyle(Theme.ink)
                        .lineSpacing(2)
                        .textSelection(.enabled)
                }
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 1).fill(Theme.ink.opacity(0.5)).frame(width: 2)
                }
            }
            part("A thread to follow", r.next)
            if entry.streaming && r.next.isEmpty { InkDot().frame(width: 6, height: 6) }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.background.secondary.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.paperEdge, lineWidth: 0.5))
    }

    @ViewBuilder private func part(_ title: String, _ text: String) -> some View {
        if !text.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                label(title)
                Text(text)
                    .font(Theme.serif(14))
                    .lineSpacing(2)
                    .textSelection(.enabled)
            }
        }
    }

    private func label(_ s: String) -> some View {
        Text(s.uppercased())
            .font(.system(size: 9.5, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
    }
}
