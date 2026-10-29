import SwiftUI
import Combine

struct OnboardingView: View {
    @ObservedObject var engine: LinaEngine
    @ObservedObject var settings = AppSettings.shared
    @State var step = 0
    @State private var trusted = AX.isTrusted
    @State private var demo = 0
    @Environment(\.dismissWindow) private var dismissWindow
    private let poll = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private let steps = 5

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                switch step {
                case 0: meet
                case 1: access
                case 2: keys
                case 3: see
                default: ready
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal: .move(edge: .leading).combined(with: .opacity)))
            .id(step)

            footer
        }
        .frame(width: 760, height: 640)
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
            Button(step == steps - 1 ? "Start Writing" : (step == 0 ? "Say Hi" : "Continue")) {
                if step == steps - 1 { finish() } else { withAnimation(Theme.spring) { step += 1 } }
            }
            .buttonStyle(InkButtonStyle())
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 20)
    }

    private func finish() {
        settings.hasOnboarded = true
        engine.start()
        dismissWindow(id: "welcome")
    }

    // MARK: Steps

    private var meet: some View {
        VStack(spacing: 18) {
            Spacer()
            TimelineView(.periodic(from: .now, by: 1.8)) { tl in
                let moods: [Mood] = [.idle, .listening, .thinking, .found, .happy]
                let i = Int(tl.date.timeIntervalSinceReferenceDate / 1.8) % moods.count
                LinaFace(mood: moods[i], animated: true).frame(width: 190, height: 190)
            }
            VStack(spacing: 10) {
                Text("Hi, I'm Lina.")
                    .font(Theme.serif(34, weight: .semibold))
                Text("I sit at your cursor in every app, and I only speak when you ask. Type /lina and a small bar opens right there: ask for a fact, a question, a rewrite or a picture. When you pause after a sentence, I put fixes above any mistakes.")
                    .font(.system(size: 14.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 500)
                Text("Watch my hair: it changes color with what I'm doing.")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.ink)
            }
            Spacer()
        }
        .padding(.horizontal, 40)
    }

    private var access: some View {
        StepLayout(mood: trusted ? .happy : .listening, title: "Let me see what you're typing",
                   message: "macOS asks you to approve apps that read the screen. I read the field you're in only when you type /lina or pause after a sentence, never password fields.") {
            VStack(spacing: 14) {
                if trusted {
                    Label("Access granted", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Mood.happy.hair)
                        .transition(.scale.combined(with: .opacity))
                } else {
                    Button("Open System Settings") { AX.grantAccess() }
                        .buttonStyle(InkButtonStyle())
                    Text("Turn on **Lina** under Privacy & Security → Accessibility. This page updates on its own.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .animation(Theme.spring, value: trusted)
        }
    }

    private var keys: some View {
        StepLayout(mood: settings.isModelConfigured ? .happy : .idle, title: "Give me a mind, and the web",
                   message: "Nemotron on Nebius Token Factory checks your sentences and answers commands. Gemini lets me search the live web when you ask a question.") {
            VStack(spacing: 14) {
                HStack(spacing: 12) {
                    ForEach(Provider.allCases) { p in
                        let on = settings.provider == p
                        Button { withAnimation(Theme.spring) { settings.provider = p } } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(p.title).font(.system(size: 13.5, weight: .semibold))
                                Text(p.subtitle).font(.system(size: 11))
                                    .foregroundStyle(on ? .white.opacity(0.85) : .secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .foregroundStyle(on ? .white : .primary)
                            .padding(12)
                            .frame(width: 250, height: 70, alignment: .topLeading)
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(on ? Theme.ink : Color.primary.opacity(0.04)))
                        }
                        .buttonStyle(.plain)
                    }
                }
                if settings.provider == .nebius {
                    KeyField(title: "Nebius API key", link: ("Get a key at tokenfactory.nebius.com", "https://tokenfactory.nebius.com/"),
                             key: $settings.apiKey) { key in
                        let client = LLMClient(endpoint: LLMEndpoint(baseURL: Provider.nebius.defaultBaseURL, apiKey: key,
                                                                     model: settings.checkModel))
                        _ = try await client.complete([.system("Reply with one word."), .user("Say: ready")], maxTokens: 8, temperature: 0)
                    }
                } else {
                    Text("Start Ollama and run `ollama pull llama3.2`. You can change the server in Settings.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                KeyField(title: "Gemini API key (optional, for web search)",
                         link: ("Get a key at aistudio.google.com", "https://aistudio.google.com/apikey"),
                         key: $settings.geminiKey) { key in
                    _ = try await GeminiClient(apiKey: key, model: settings.geminiModel)
                        .ask(system: "Answer in one word.", prompt: "What is the capital of France?")
                }
            }
        }
    }

    private var see: some View {
        let cases = Array(UseCase.all.prefix(3))
        let shown = cases[demo % cases.count]
        return VStack(spacing: 14) {
            VStack(spacing: 6) {
                Text(shown.title).font(Theme.serif(26, weight: .semibold))
                Text(shown.pitch)
                    .font(.system(size: 13.5)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 22)
            DemoPlayer(useCase: shown, compact: true)
                .id(shown.id)
            HStack(spacing: 14) {
                Button { withAnimation(Theme.spring) { demo = (demo + cases.count - 1) % cases.count } } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)
                ForEach(0..<cases.count, id: \.self) { i in
                    Circle().fill(i == demo % cases.count ? Theme.ink : Theme.ink.opacity(0.2)).frame(width: 6, height: 6)
                }
                Button { withAnimation(Theme.spring) { demo = (demo + 1) % cases.count } } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.borderless)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 40)
    }

    private var ready: some View {
        StepLayout(mood: .happy, title: "Try me now.",
                   message: "Open any app where you write: Notes, Mail, a browser. Or start with a practice page.") {
            VStack(spacing: 16) {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 9) {
                    ForEach(CommandParser.words.prefix(5)) { w in
                        GridRow {
                            Text(w.usage)
                                .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                                .foregroundStyle(Theme.ink)
                                .gridColumnAlignment(.trailing)
                            Text(w.detail).font(.system(size: 12.5))
                        }
                    }
                    GridRow {
                        Text("/lina <question> ↩")
                            .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                            .foregroundStyle(Theme.ink)
                        Text("Answers from the web, worded to fit your sentence.").font(.system(size: 12.5))
                    }
                }
                .padding(18)
                .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.04)))
                Button("Open a practice page in TextEdit →") { TryIt.openTextEdit() }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.ink)
                    .font(.system(size: 13, weight: .medium))
            }
        }
    }
}

private struct StepLayout<Content: View>: View {
    let mood: Mood
    let title: String
    let message: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 16)
            LinaFace(mood: mood, head: true, animated: true)
                .frame(width: 84, height: 87)
            Text(title).font(Theme.serif(28, weight: .semibold))
            Text(message)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
                .fixedSize(horizontal: false, vertical: true)
            content.padding(.top, 4)
            Spacer(minLength: 10)
        }
        .padding(.horizontal, 40)
    }
}

/// A key field with a Connect button that checks the key works.
private struct KeyField: View {
    let title: String
    let link: (String, String)
    @Binding var key: String
    let check: (String) async throws -> Void
    @State private var draft = ""
    @State private var state: TestState = .idle

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11.5, weight: .medium)).foregroundStyle(.secondary)
            HStack {
                SecureField("Paste your key", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 360)
                    .onSubmit(test)
                Button(action: test) {
                    if state == .testing { ProgressView().controlSize(.small) } else { Text("Connect") }
                }
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty || state == .testing)
            }
            Group {
                switch state {
                case .idle:
                    if let url = URL(string: link.1) { Link(link.0, destination: url) }
                case .testing: Text("Checking…").foregroundStyle(.secondary)
                case let .ok(ms): Label("Connected in \(ms) ms", systemImage: "checkmark.circle.fill").foregroundStyle(Mood.happy.hair)
                case let .failed(m): Label(m, systemImage: "xmark.octagon.fill").foregroundStyle(Mood.worried.hair).lineLimit(2)
                }
            }
            .font(.system(size: 11.5))
        }
        .frame(width: 460, alignment: .leading)
        .onAppear { draft = key }
    }

    private func test() {
        let k = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return }
        key = k
        state = .testing
        Task {
            let start = Date()
            do {
                try await check(k)
                state = .ok(Int(Date().timeIntervalSince(start) * 1000))
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }
}

enum TestState: Equatable { case idle, testing, ok(Int), failed(String) }
