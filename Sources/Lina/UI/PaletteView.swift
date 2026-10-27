import SwiftUI

struct PaletteView: View {
    @ObservedObject var controller: PaletteController
    @ObservedObject var toast: ToastModel
    var onHeight: (CGFloat) -> Void
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            Group {
                switch controller.phase {
                case .choosing: chooser
                default: resultView
                }
            }
            .transition(.opacity)
            Divider().opacity(0.5)
            footer
        }
        .frame(width: PalettePanel.width)
        .background(VisualEffect(material: .popover))
        .background(Theme.paper.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.primary.opacity(0.1), lineWidth: 0.5)
        )
        .overlay(alignment: .top) { toastView }
        .background(GeometryReader { g in
            Color.clear.preference(key: HeightKey.self, value: g.size.height)
        })
        .onPreferenceChange(HeightKey.self) { onHeight($0) }
        .animation(Theme.spring, value: controller.phase)
        .onAppear { fieldFocused = true }
        .onChange(of: controller.phase) { _, p in if p == .choosing { fieldFocused = true } }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            if controller.phase == .choosing {
                Image(systemName: "pencil.and.scribble")
                    .font(.system(size: 18, weight: .regular))
                    .foregroundStyle(Theme.ink)
                TextField("Ask Lina, or choose below…", text: $controller.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 21, weight: .regular))
                    .focused($fieldFocused)
                    .onChange(of: controller.query) { _, _ in controller.selectedIndex = 0 }
            } else {
                Button { controller.back() } label: {
                    Image(systemName: "chevron.backward")
                        .font(.system(size: 13, weight: .semibold))
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(.primary.opacity(0.06)))
                }
                .buttonStyle(.plain)
                .help("Back (esc)")
                Image(systemName: controller.running?.symbol ?? "text.bubble")
                    .foregroundStyle(Theme.ink)
                Text(controller.running?.title ?? controller.runningCustom ?? "")
                    .font(.system(size: 17, weight: .semibold))
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let target = controller.target {
                HStack(spacing: 6) {
                    if let icon = target.icon {
                        Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                    }
                    Text(target.displayName)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 58)
    }

    // MARK: Choosing

    private var chooser: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let target = controller.target {
                excerpt(target)
            }
            VStack(spacing: 2) {
                ForEach(Array(controller.rows.enumerated()), id: \.element.id) { index, row in
                    rowView(row, index: index)
                }
            }
            .padding(8)
        }
    }

    private func excerpt(_ target: WritingTarget) -> some View {
        let text = target.focusText.trimmingCharacters(in: .whitespacesAndNewlines)
        return HStack(alignment: .top, spacing: 10) {
            RoundedRectangle(cornerRadius: 1).fill(Theme.ink.opacity(0.5)).frame(width: 2)
            VStack(alignment: .leading, spacing: 4) {
                Text(target.focusDescription.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.tertiary)
                Text(text.isEmpty ? emptyHint(target) : text)
                    .font(Theme.serif(14))
                    .foregroundStyle(text.isEmpty ? .tertiary : .secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 4)
    }

    private func emptyHint(_ target: WritingTarget) -> String {
        target.canWrite
            ? "Select some text, or place your cursor in a paragraph."
            : "Lina can't read this window. Ask anything — the answer is yours to copy."
    }

    private func rowView(_ row: PaletteController.Row, index: Int) -> some View {
        let selected = index == controller.selectedIndex
        let (symbol, title, hint, enabled, number): (String, String, String, Bool, Int?) = {
            switch row {
            case let .ask(q):
                return ("arrow.up.message", "Ask Lina: “\(q)”", "Applies to your selection or paragraph", true, nil)
            case let .action(a):
                let n = (WritingAction.allCases.firstIndex(of: a) ?? 0) + 1
                return (a.symbol, a.title, a.hint, controller.isAvailable(a), n)
            }
        }()
        return Button { controller.activate(row) } label: {
            HStack(spacing: 12) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(selected ? .white : Theme.ink)
                    .frame(width: 28, height: 28)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(selected ? Theme.ink : Theme.ink.opacity(0.1))
                    )
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 13.5, weight: .medium)).lineLimit(1)
                    Text(hint).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if let number { KeyCap("⌘\(number)", size: 10).opacity(selected ? 1 : 0.6) }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(selected ? Theme.ink.opacity(0.12) : .clear)
            )
            .contentShape(Rectangle())
            .opacity(enabled ? 1 : 0.38)
        }
        .buttonStyle(.plain)
        .onHover { if $0 { controller.selectedIndex = index } }
    }

    // MARK: Result

    private var resultView: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let target = controller.target, controller.running?.outcome == .replace || controller.running == .findWord {
                VStack(alignment: .leading, spacing: 4) {
                    Text("BEFORE").font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundStyle(.tertiary)
                    Text(target.focusText.trimmingCharacters(in: .whitespacesAndNewlines))
                        .font(Theme.serif(13.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
            switch controller.phase {
            case let .failed(message):
                Label {
                    Text(message).font(.system(size: 13))
                } icon: {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                .fixedSize(horizontal: false, vertical: true)
            default:
                if controller.running == .findWord {
                    wordOptions
                } else {
                    resultText
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var resultText: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(controller.primaryOutcome == .note ? "LINA" : "AFTER")
                .font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundStyle(Theme.ink.opacity(0.8))
            ScrollView {
                HStack(alignment: .lastTextBaseline, spacing: 6) {
                    Text(controller.result.isEmpty ? " " : controller.result)
                        .font(Theme.serif(16.5))
                        .lineSpacing(4)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .overlay(alignment: .bottomTrailing) {
                    if controller.phase == .working { InkDot().frame(width: 7, height: 7).padding(4) }
                }
            }
            .frame(maxHeight: 300)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var wordOptions: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CHOOSE A WORD").font(.system(size: 10, weight: .semibold)).tracking(0.6)
                .foregroundStyle(Theme.ink.opacity(0.8))
            if controller.options.isEmpty {
                HStack(spacing: 8) { InkDot().frame(width: 7, height: 7); Text("Thinking of words…").foregroundStyle(.secondary) }
                    .font(.system(size: 13))
            }
            FlowLayout(spacing: 8) {
                ForEach(Array(controller.options.enumerated()), id: \.offset) { i, word in
                    Button {
                        controller.optionIndex = i
                        controller.applyPrimary()
                    } label: {
                        HStack(spacing: 6) {
                            Text("\(i + 1)").font(.system(size: 10, weight: .semibold, design: .rounded))
                                .foregroundStyle(i == controller.optionIndex ? .white.opacity(0.8) : .secondary)
                            Text(word).font(Theme.serif(15))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .foregroundStyle(i == controller.optionIndex ? .white : .primary)
                        .background(Capsule().fill(i == controller.optionIndex ? Theme.ink : .primary.opacity(0.06)))
                    }
                    .buttonStyle(.plain)
                    .onHover { if $0 { controller.optionIndex = i } }
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 14) {
            Wordmark(size: 13).foregroundStyle(.secondary)
            Spacer()
            switch controller.phase {
            case .choosing:
                hint("↑↓", "Choose"); hint("↩", "Run"); hint("esc", "Close")
            case .working:
                hint("esc", "Stop")
            case .failed:
                hint("↩", "Try again"); hint("esc", "Back")
            case .done:
                switch controller.primaryOutcome {
                case .replace, .choose: hint("↩", "Replace"); hint("⌘↩", "Insert after")
                case .insert: hint("↩", "Insert")
                case .note: hint("↩", "Copy"); hint("⌘↩", "Insert")
                }
                hint("⌘R", "Again"); hint("esc", "Back")
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 38)
    }

    private func hint(_ key: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            KeyCap(key, size: 10)
            Text(label).font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var toastView: some View {
        if let m = toast.message {
            Text(m)
                .font(.system(size: 12, weight: .semibold))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(Capsule().fill(Theme.ink))
                .foregroundStyle(.white)
                .padding(.top, 10)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

private struct HeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
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
