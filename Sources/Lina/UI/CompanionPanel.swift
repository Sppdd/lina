import AppKit
import SwiftUI

/// A popup that sits just above the writer's cursor, so Lina's words are right where their eyes are.
/// It never takes focus from the document unless they open it to talk back.
@MainActor
final class CompanionPanel {
    static let identifier = NSUserInterfaceItemIdentifier("LinaCompanion")
    static let width: CGFloat = 380
    private let panel: CompanionNSPanel
    private let input = CompanionInput()
    /// The caret the popup points at, in Cocoa screen coordinates.
    private var anchor: CGRect?
    private var height: CGFloat = 120

    init(companion: Companion) {
        panel = CompanionNSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: height),
                                 styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                                 backing: .buffered, defer: true)
        panel.identifier = Self.identifier
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        let host = NSHostingView(rootView: CompanionView(companion: companion, input: input) { [weak self] h in
            self?.resize(to: h)
        })
        host.sizingOptions = []
        panel.contentView = host
    }

    var isVisible: Bool { panel.isVisible }
    var isKey: Bool { panel.isKeyWindow }
    var frame: CGRect { panel.frame }

    /// Shows the popup above the caret. Without one (some apps don't report it), it stays where it was,
    /// or goes to the top right of the screen.
    func show(above caret: CGRect?) {
        if let caret { anchor = caret }
        place()
        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                panel.animator().alphaValue = 1
            }
        }
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.orderOut(nil)
    }

    func focusInput() {
        panel.makeKey()
        input.focus += 1
    }

    private func resize(to h: CGFloat) {
        let h = ceil(h)
        guard h > 0, abs(height - h) > 0.5 else { return }
        height = h
        if panel.isVisible { place() }
    }

    private func place() {
        let size = CGSize(width: Self.width, height: height)
        let frame: CGRect
        if let caret = anchor {
            let screen = NSScreen.screens.first { $0.frame.intersects(caret) } ?? NSScreen.main
            let vf = screen?.visibleFrame ?? .infinite
            let x = max(vf.minX + 8, min(caret.minX - 18, vf.maxX - size.width - 8))
            // Above the line being written; below it when there's no room at the top of the screen.
            var y = caret.maxY + 6
            if y + size.height > vf.maxY - 4 { y = max(vf.minY + 4, caret.minY - size.height - 6) }
            frame = CGRect(origin: CGPoint(x: x, y: y), size: size)
        } else {
            let vf = NSScreen.main?.visibleFrame ?? .zero
            frame = CGRect(x: vf.maxX - size.width - 20, y: vf.maxY - size.height - 20,
                           width: size.width, height: size.height)
        }
        panel.setFrame(frame, display: true)
        panel.invalidateShadow()
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
    var onHeight: (CGFloat) -> Void = { _ in }
    @ObservedObject var settings = AppSettings.shared
    @State private var draft = ""
    @State private var trailHeight: CGFloat = 0
    @FocusState private var typing: Bool

    private static let maxTrailHeight: CGFloat = 300

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            if companion.announcingMode {
                modeNote
            } else if let proposal = companion.proposal {
                ProposalView(proposal: proposal, accept: { companion.acceptProposal() },
                             dismiss: { companion.dismiss() })
            } else if companion.entries.isEmpty {
                emptyState
            } else {
                trail
            }
            if companion.proposal == nil && !companion.announcingMode {
                Divider().opacity(0.5)
                replyBar
            }
        }
        .frame(width: CompanionPanel.width)
        .background(VisualEffect(material: .popover))
        .background(Theme.paper.opacity(0.55))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(.primary.opacity(0.1), lineWidth: 0.5))
        .tint(Theme.ink)
        .fixedSize(horizontal: false, vertical: true)
        .background(GeometryReader { g in Color.clear.preference(key: PopupHeightKey.self, value: g.size.height) })
        .onPreferenceChange(PopupHeightKey.self) { onHeight($0) }
        .frame(maxHeight: .infinity, alignment: .top)
        .onChange(of: input.focus) { _, _ in typing = true }
        .onExitCommand { companion.dismiss() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 8) {
            Wordmark(size: 14)
            modeChip
            if !companion.place.isEmpty {
                Text(companion.place)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            stateDot
            if settings.companionMode == .understand {
                Button { companion.thinkNow() } label: { Image(systemName: "sparkles") }
                    .buttonStyle(.borderless)
                    .help("Read my draft again now")
                    .disabled(companion.state == .thinking)
            }
            Menu {
                Picker("Mode", selection: $settings.companionMode) {
                    ForEach(CompanionMode.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
                }
                Divider()
                Button("Clear the conversation") { companion.clear() }
                Button(settings.companionEnabled ? "Pause reading" : "Resume reading") {
                    settings.companionEnabled.toggle()
                }
            } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .foregroundStyle(Theme.ink)
    }

    /// Which mode Lina is in; click (or ⇧ + the shortcut) to move to the next one.
    private var modeChip: some View {
        Button { settings.companionMode = settings.companionMode.next } label: {
            HStack(spacing: 4) {
                Image(systemName: settings.companionMode.symbol).font(.system(size: 9.5, weight: .semibold))
                Text(settings.companionMode.title).font(.system(size: 10.5, weight: .semibold))
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(Theme.ink.opacity(settings.companionMode == .understand ? 0.08 : 0.16)))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.ink)
        .help("\(settings.companionMode.blurb) \(settings.hotKey.modeTitle) switches mode.")
    }

    @ViewBuilder private var stateDot: some View {
        switch companion.state {
        case .thinking: InkDot().frame(width: 7, height: 7).help("Thinking…")
        case .error: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.system(size: 11))
        case .paused: Image(systemName: "pause.circle").foregroundStyle(.secondary).font(.system(size: 11))
        default: EmptyView()
        }
    }

    // MARK: Body

    private var modeNote: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: settings.companionMode.symbol)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(Theme.ink)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text("\(settings.companionMode.title) mode").font(Theme.serif(15, weight: .semibold))
                Text(settings.companionMode.blurb).font(Theme.serif(13)).foregroundStyle(.secondary)
                HStack(spacing: 4) {
                    KeyCap(settings.hotKey.modeTitle, size: 9.5)
                    Text("next mode").font(.system(size: 10.5)).foregroundStyle(.tertiary)
                }
                .padding(.top, 3)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("When you pause, I'll read along and think with you about what you're saying, and why.")
                .font(Theme.serif(13.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if case let .error(message) = companion.state {
                errorNote(message)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
    }

    private var trail: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(companion.entries) { entry in
                        EntryView(entry: entry).id(entry.id)
                    }
                    if case let .error(message) = companion.state {
                        errorNote(message)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(12)
                .background(GeometryReader { g in Color.clear.preference(key: TrailHeightKey.self, value: g.size.height) })
            }
            .frame(height: min(max(trailHeight, 40), Self.maxTrailHeight))
            .onPreferenceChange(TrailHeightKey.self) { trailHeight = $0 }
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

/// Edit and Auto modes: Lina's rewrite of the sentence just written, under the writer's own.
private struct ProposalView: View {
    let proposal: Companion.Proposal
    let accept: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.system(size: 9.5, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
            Text(proposal.original)
                .font(Theme.serif(13))
                .foregroundStyle(.secondary)
                .strikethrough(!proposal.streaming, color: .secondary.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(proposal.rewritten.isEmpty ? " " : proposal.rewritten)
                    .font(Theme.serif(15, weight: .medium))
                    .foregroundStyle(Theme.ink)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if proposal.streaming { InkDot().frame(width: 6, height: 6) }
            }
            HStack(spacing: 6) {
                if proposal.applied {
                    KeyCap("⌘Z", size: 9.5)
                    Text("undo").font(.system(size: 10.5)).foregroundStyle(.secondary)
                } else if !proposal.streaming {
                    Button(action: accept) {
                        HStack(spacing: 4) {
                            KeyCap("tab", size: 9.5)
                            Text("use it").font(.system(size: 10.5, weight: .medium))
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.ink)
                    Button(action: dismiss) {
                        HStack(spacing: 4) {
                            KeyCap("esc", size: 9.5)
                            Text("keep mine").font(.system(size: 10.5))
                        }
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 6)
                }
                Spacer()
            }
            .padding(.top, 2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var title: String {
        if proposal.applied { return "Rewrote your sentence" }
        if proposal.streaming { return "Rewriting your sentence" }
        return "Another way to say it"
    }
}

private struct PopupHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

private struct TrailHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
