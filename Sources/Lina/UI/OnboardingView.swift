import SwiftUI

struct OnboardingView: View {
    @ObservedObject var engine: GhostEngine
    @ObservedObject var settings = AppSettings.shared
    @State var step = 0
    @State private var trusted = AX.isTrusted
    @Environment(\.dismissWindow) private var dismissWindow
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private let steps = 5

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                switch step {
                case 0: welcome
                case 1: access
                case 2: model
                case 3: voice
                default: ready
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal: .move(edge: .leading).combined(with: .opacity)))
            .id(step)

            footer
        }
        .frame(width: 680, height: 560)
        .background(Theme.paper)
        .tint(Theme.ink)
        .onReceive(poll) { _ in
            trusted = AX.isTrusted
            if trusted { engine.start() }
        }
    }

    private var footer: some View {
        HStack {
            if step > 0 {
                Button("Back") { withAnimation(Theme.spring) { step -= 1 } }
                    .buttonStyle(InkButtonStyle(prominent: false))
            }
            Spacer()
            HStack(spacing: 7) {
                ForEach(0..<steps, id: \.self) { i in
                    Capsule()
                        .fill(i == step ? Theme.ink : Theme.ink.opacity(0.18))
                        .frame(width: i == step ? 18 : 7, height: 7)
                }
            }
            .animation(Theme.spring, value: step)
            Spacer()
            Button(step == steps - 1 ? "Start Writing" : (step == 0 ? "Get Started" : "Continue")) {
                if step == steps - 1 { finish(openDesk: false) } else { withAnimation(Theme.spring) { step += 1 } }
            }
            .buttonStyle(InkButtonStyle())
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 20)
    }

    private func finish(openDesk: Bool) {
        settings.hasOnboarded = true
        engine.start()
        dismissWindow(id: "welcome")
        if openDesk { WindowOpener.shared.open("desk") }
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(spacing: 22) {
            Spacer()
            Wordmark(size: 58)
            VStack(spacing: 10) {
                Text("Write with someone beside you.")
                    .font(Theme.serif(30, weight: .semibold))
                Text("Lina reads along in any app and, when you pause, offers what might come next — in faint ink, right at your cursor.")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
            }
            GhostDemo()
                .padding(.top, 8)
            Spacer()
        }
        .padding(.horizontal, 40)
    }

    private var access: some View {
        StepLayout(symbol: "hand.raised", title: "Let Lina read along",
                   message: "macOS asks you to approve apps that read what's on screen. Lina uses this only to see the text field you're writing in and where your cursor is — never password fields.") {
            VStack(spacing: 14) {
                if trusted {
                    Label("Access granted", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.green)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    Button("Open System Settings") { AX.requestTrust(); AX.openAccessibilitySettings() }
                        .buttonStyle(InkButtonStyle())
                    Text("Turn on **Lina** under Privacy & Security → Accessibility. This page updates on its own.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Text("You can skip this and use Lina's Desk in the meantime.")
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                }
            }
            .animation(Theme.spring, value: trusted)
        }
    }

    private var model: some View {
        StepLayout(symbol: "cpu", title: "Choose Lina's mind",
                   message: "Lina runs on open models. Use NVIDIA Nemotron on Nebius for speed, or a model on this Mac for complete privacy.") {
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    ForEach(Provider.allCases) { p in
                        let on = settings.provider == p
                        Button { withAnimation(Theme.spring) { settings.provider = p } } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Image(systemName: p == .nebius ? "bolt.horizontal.circle" : "desktopcomputer")
                                    .font(.system(size: 20))
                                    .foregroundStyle(on ? .white : Theme.ink)
                                Text(p.title).font(.system(size: 14, weight: .semibold))
                                Text(p.subtitle).font(.system(size: 11.5))
                                    .foregroundStyle(on ? .white.opacity(0.85) : .secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .foregroundStyle(on ? .white : .primary)
                            .padding(14)
                            .frame(width: 230, height: 118, alignment: .topLeading)
                            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(on ? Theme.ink : Color.primary.opacity(0.04)))
                        }
                        .buttonStyle(.plain)
                    }
                }
                if settings.provider == .nebius {
                    OnboardingKeyField()
                } else {
                    Text("Start Ollama and run `ollama pull llama3.2`. You can change the server in Settings.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var voice: some View {
        StepLayout(symbol: "text.quote", title: "What do you write?",
                   message: "Lina adapts its suggestions to your kind of writing. You can change this any time.") {
            VStack(spacing: 14) {
                VoicePicker(selection: $settings.voice, columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3))
                    .frame(width: 560)
                Stepper(value: $settings.dailyGoal, in: 100...5000, step: 50) {
                    Text("Daily goal: **\(settings.dailyGoal) words**").font(.system(size: 13))
                }
                .frame(width: 260)
            }
        }
    }

    private var ready: some View {
        StepLayout(symbol: "checkmark.seal", title: "You're ready.",
                   message: "Open any app — Notes, Mail, Journal, a browser — and start writing. Lina will be there when you pause.") {
            VStack(spacing: 16) {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 10) {
                    ShortcutRow(keys: ["tab"], text: "Keep the suggestion")
                    ShortcutRow(keys: ["⌥", "tab"], text: "Keep just the next word")
                    ShortcutRow(keys: ["esc"], text: "Dismiss — or simply keep typing")
                    ShortcutRow(keys: settings.hotKey.title.components(separatedBy: " "), text: "Ask Lina: find the word, fix, feel, get unstuck")
                }
                .padding(18)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.04)))
                Button("Or try it on the Desk first →") { finish(openDesk: true) }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.ink)
                    .font(.system(size: 13, weight: .medium))
            }
        }
    }
}

private struct StepLayout<Content: View>: View {
    let symbol: String
    let title: String
    let message: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 18) {
            Spacer(minLength: 20)
            Image(systemName: symbol)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Theme.ink)
                .frame(width: 72, height: 72)
                .background(Circle().fill(Theme.ink.opacity(0.1)))
            Text(title).font(Theme.serif(28, weight: .semibold))
            Text(message)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 470)
            content.padding(.top, 6)
            Spacer(minLength: 10)
        }
        .padding(.horizontal, 40)
    }
}

private struct ShortcutRow: View {
    let keys: [String]
    let text: String
    var body: some View {
        GridRow {
            HStack(spacing: 4) { ForEach(keys, id: \.self) { KeyCap($0, size: 12) } }
                .gridColumnAlignment(.trailing)
            Text(text).font(.system(size: 13))
        }
    }
}

private struct OnboardingKeyField: View {
    @ObservedObject var settings = AppSettings.shared
    @State private var key = ""
    @State private var state: ModelSettings.TestState = .idle

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                SecureField("Paste your Nebius API key", text: $key)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 330)
                    .onSubmit(test)
                Button(action: test) {
                    if state == .testing { ProgressView().controlSize(.small) } else { Text("Connect") }
                }
                .disabled(key.isEmpty || state == .testing)
            }
            Group {
                switch state {
                case .idle:
                    Link("Get a free key at tokenfactory.nebius.com", destination: URL(string: "https://tokenfactory.nebius.com/")!)
                case .testing: Text("Saying hello to Nemotron…").foregroundStyle(.secondary)
                case let .ok(ms): Label("Connected in \(ms) ms", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case let .failed(m): Label(m, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                }
            }
            .font(.system(size: 12))
        }
        .onAppear { key = settings.apiKey }
    }

    private func test() {
        settings.apiKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
        state = .testing
        let client = LLMClient(endpoint: settings.endpoint)
        Task {
            let start = Date()
            do {
                _ = try await client.complete([.system("Reply with one word."), .user("Say: ready")], maxTokens: 8, temperature: 0)
                state = .ok(Int(Date().timeIntervalSince(start) * 1000))
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }
}

/// A looping vignette of Lina at work: the writer types, pauses, and a thought appears in ink.
struct GhostDemo: View {
    private let typed = "The morning light came through the kitchen window,"
    private let ghost = " and for the first time in weeks I wanted to write."
    @State private var shown = 0
    @State private var showGhost = false
    @State private var accepted = false
    @State private var caretOn = true

    var body: some View {
        HStack(spacing: 0) {
            (Text(String(typed.prefix(shown)))
                + Text(showGhost || accepted ? ghost : "")
                    .foregroundColor(accepted ? .primary : Color(nsColor: Theme.nsGhost)))
                .font(Theme.serif(17))
                .lineSpacing(5)
                .frame(width: 520, alignment: .leading)
                .overlay(alignment: .bottomTrailing) {
                    if showGhost && !accepted {
                        KeyCap("tab", size: 11).offset(y: 22).transition(.opacity)
                    }
                }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .frame(width: 580, height: 96, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.background))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Theme.paperEdge, lineWidth: 1))
        .shadow(color: .black.opacity(0.06), radius: 12, y: 6)
        .task { await loop() }
        .accessibilityLabel("Example: Lina suggests the end of a sentence as you write.")
    }

    @MainActor
    private func loop() async {
        while !Task.isCancelled {
            shown = 0; showGhost = false; accepted = false
            for i in 1...typed.count {
                shown = i
                try? await Task.sleep(for: .milliseconds(Int.random(in: 35...85)))
            }
            try? await Task.sleep(for: .milliseconds(700))
            withAnimation(.easeIn(duration: 0.35)) { showGhost = true }
            try? await Task.sleep(for: .milliseconds(1700))
            withAnimation(Theme.quick) { accepted = true }
            try? await Task.sleep(for: .milliseconds(2400))
        }
    }
}
