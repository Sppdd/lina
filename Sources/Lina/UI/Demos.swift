import AppKit
import SwiftUI

/// One thing Lina is great at, shown as a short animated scene.
struct UseCase: Identifiable {
    let id: String
    let title: String
    /// Who it's for.
    let who: String
    let pitch: String
    /// What to type to try it yourself.
    let tryIt: String
    let steps: [DemoStep]
}

enum DemoStep {
    /// Types text into the scene, character by character.
    case type(String)
    case pause(Double)
    case card(CardContent, selected: Int)
    case select(Int)
    /// Swaps part of the scene's text, as choosing an option does.
    case replace(String, with: String)
    case hideCard
    /// Drops a picture into the scene's text.
    case picture
}

extension UseCase {
    static let typoSentence = "Thank you for you're help, I realy apreciate it."

    @MainActor
    static var all: [UseCase] {
        let typo = typoSentence
        let typoFix = Proofread(issues: [
            .init(wrong: "you're", right: "your", kind: .grammar),
            .init(wrong: "realy", right: "really", kind: .spelling),
            .init(wrong: "apreciate", right: "appreciate", kind: .spelling),
        ], options: ["Thank you for your help, I really appreciate it.",
                     "Thank you for your help. I really appreciate it."])
        let models = [
            ModelItem(id: "nvidia/nemotron-3-super-120b-a12b", kind: .text),
            ModelItem(id: "nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B", kind: .text),
            ModelItem(id: "meta-llama/Llama-3.3-70B-Instruct", kind: .text),
            ModelItem(id: "black-forest-labs/flux-schnell", kind: .image),
            ModelItem(id: "black-forest-labs/flux-dev", kind: .image),
        ]
        return [
            UseCase(id: "typos", title: "Catch typos as you go", who: "Everyone",
                    pitch: "Finish a sentence with a dot. If something's wrong, Lina underlines it and offers a fix. If not, she stays quiet.",
                    tryIt: typo,
                    steps: [.type(typo), .pause(0.9),
                            .card(.corrections(original: typo, marks: typoFix.marks(in: typo), options: typoFix.options), selected: 0),
                            .pause(2.6), .select(0), .pause(0.6),
                            .replace(typo, with: typoFix.options[0]), .hideCard, .pause(2.2)]),
            UseCase(id: "search", title: "Ask the web mid-sentence", who: "Students, writers, anyone fact-checking",
                    pitch: "Put a question right where the fact belongs. The answer comes back worded to fit your sentence.",
                    tryIt: "The 2022 World Cup final ended /lina who won and how,",
                    steps: [.type("The 2022 World Cup final ended /lina who won and how,"), .pause(0.9),
                            .card(.answer(question: "who won and how",
                                          text: "with Argentina beating France on penalties after a 3–3 draw",
                                          sources: [WebSource(title: "fifa.com", url: "https://www.fifa.com"),
                                                    WebSource(title: "bbc.com", url: "https://www.bbc.com")],
                                          grounded: true), selected: 0),
                            .pause(2.6), .select(0), .pause(0.5),
                            .replace("/lina who won and how", with: "with Argentina beating France on penalties after a 3–3 draw"),
                            .hideCard, .pause(2.4)]),
            UseCase(id: "question", title: "A question that makes you think", who: "Journaling, essays, hard decisions",
                    pitch: "Type /lina after a thought. She asks one sharp question about it, and leaves the answering to you.",
                    tryIt: "I think I want to quit my job and open a bakery. /lina.",
                    steps: [.type("I think I want to quit my job and open a bakery. /lina."), .pause(0.6),
                            .replace(" /lina.", with: ""),
                            .card(.question("What would you miss most about the job you have now?"), selected: 0),
                            .pause(3.2), .hideCard, .type(" Honestly, the people."), .pause(2.0)]),
            UseCase(id: "rewrite", title: "Say it better, in the tone you need", who: "Email, Slack, cover letters",
                    pitch: "Add /lina rewrite and a tone after a rough draft. Pick one of three versions with ⌘1, ⌘2 or ⌘3.",
                    tryIt: "hey can u send the report asap /lina rewrite polite.",
                    steps: [.type("hey can u send the report asap /lina rewrite polite."), .pause(0.9),
                            .card(.choices(title: "Rewrites · polite", original: "hey can u send the report asap", options: [
                                "Hi, could you send me the report as soon as you can?",
                                "Hi Sam, could you send the report when you get a chance today?",
                                "Would you mind sending over the report today? Thanks!",
                            ]), selected: 0),
                            .pause(1.6), .select(1), .pause(1.2),
                            .replace("hey can u send the report asap /lina rewrite polite.",
                                     with: "Hi Sam, could you send the report when you get a chance today?"),
                            .hideCard, .pause(2.2)]),
            UseCase(id: "models", title: "Switch models without leaving the page", who: "Power users",
                    pitch: "Type /lina model to see what Token Factory offers, writing and image models alike, and switch with one key.",
                    tryIt: "/lina model",
                    steps: [.type("/lina model"), .pause(0.5), .replace("/lina model", with: ""),
                            .card(.models(items: models, currentText: models[1].id, currentImage: models[3].id), selected: 1),
                            .pause(1.0), .select(0), .pause(1.2),
                            .card(.notice("Now writing with nemotron-3-super-120b-a12b.", .happy), selected: 0),
                            .pause(1.8), .hideCard, .pause(1.0)]),
            UseCase(id: "image", title: "A picture for your post", who: "Newsletters, social posts, slides",
                    pitch: "Describe it after /lina image. FLUX on Token Factory draws it, and ⌘1 drops it into your text.",
                    tryIt: "/lina image a cozy reading nook at dusk, watercolor.",
                    steps: [.type("/lina image a cozy reading nook at dusk, watercolor."), .pause(0.9),
                            .card(.image(prompt: "a cozy reading nook at dusk, watercolor", image: DemoArt.readingNook()), selected: 0),
                            .pause(2.4), .select(0), .pause(0.4),
                            .replace("/lina image a cozy reading nook at dusk, watercolor.", with: ""),
                            .picture, .hideCard, .pause(2.4)]),
        ]
    }
}

/// Plays a use case on a loop: a little text field, Lina's card under it.
struct DemoPlayer: View {
    let useCase: UseCase
    var appName = "Notes"
    var compact = false

    @State private var text = ""
    @State private var card: CardContent?
    @State private var selected = 0
    @State private var picture: NSImage?
    @State private var caretOn = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                ForEach(0..<3, id: \.self) { i in
                    Circle().fill([Color.red, .yellow, .green][i].opacity(0.7)).frame(width: 8, height: 8)
                }
                Text(appName).font(.system(size: 10.5, weight: .medium)).foregroundStyle(.secondary).padding(.leading, 6)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.primary.opacity(0.04))

            VStack(alignment: .leading, spacing: 8) {
                (Text(text) + Text(caretOn ? "|" : " ").foregroundStyle(Theme.ink))
                    .font(.system(size: compact ? 13 : 14))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                if let picture {
                    Image(nsImage: picture).resizable().scaledToFit().frame(height: 90)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(14)

            ZStack(alignment: .topLeading) {
                Color.clear
                if let card {
                    CardView(content: card, selected: selected)
                        .scaleEffect(compact ? 0.82 : 0.9, anchor: .topLeading)
                        .padding(.leading, -6)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .frame(height: compact ? 250 : 300, alignment: .topLeading)
            .clipped()
        }
        .frame(width: compact ? 400 : 440)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.paperEdge, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .task(id: useCase.id) { await loop() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Example: \(useCase.title). \(useCase.pitch)")
    }

    @MainActor
    private func loop() async {
        while !Task.isCancelled {
            text = ""; card = nil; selected = 0; picture = nil
            for step in useCase.steps {
                if Task.isCancelled { return }
                switch step {
                case let .type(s):
                    for ch in s {
                        text.append(ch)
                        try? await Task.sleep(for: .milliseconds(Int.random(in: 28...62)))
                        if Task.isCancelled { return }
                    }
                case let .pause(seconds):
                    caretOn = true
                    try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
                case let .card(content, sel):
                    selected = sel
                    withAnimation(Theme.spring) { card = content }
                case let .select(i):
                    withAnimation(Theme.quick) { selected = i }
                case let .replace(old, new):
                    withAnimation(Theme.quick) { text = text.replacingOccurrences(of: old, with: new) }
                case .hideCard:
                    withAnimation(Theme.quick) { card = nil }
                case .picture:
                    if case let .image(_, image)? = card { withAnimation(Theme.spring) { picture = image } }
                }
            }
        }
    }
}

/// A small painted scene for the image demo, so it works offline.
@MainActor
enum DemoArt {
    private static var cached: NSImage?

    static func readingNook() -> NSImage {
        if let cached { return cached }
        let scene = ZStack {
            LinearGradient(colors: [Color(red: 0.98, green: 0.78, blue: 0.55), Color(red: 0.55, green: 0.45, blue: 0.75)],
                           startPoint: .top, endPoint: .bottom)
            RoundedRectangle(cornerRadius: 6).fill(Color(red: 0.98, green: 0.9, blue: 0.7).opacity(0.85))
                .frame(width: 120, height: 90).offset(x: 60, y: -40)
            Rectangle().fill(Color(red: 0.4, green: 0.28, blue: 0.3)).frame(width: 4, height: 90).offset(x: 60, y: -40)
            Capsule().fill(Color(red: 0.35, green: 0.45, blue: 0.4)).frame(width: 170, height: 70).offset(x: -50, y: 70)
            Circle().fill(Color(red: 1, green: 0.9, blue: 0.6).opacity(0.9)).frame(width: 30, height: 30).offset(x: -120, y: -10)
            Rectangle().fill(Color(red: 0.3, green: 0.22, blue: 0.2)).frame(width: 3, height: 80).offset(x: -120, y: 30)
        }
        .frame(width: 360, height: 240)
        let renderer = ImageRenderer(content: scene)
        renderer.scale = 2
        let image = renderer.nsImage ?? NSImage(size: NSSize(width: 360, height: 240))
        cached = image
        return image
    }
}
