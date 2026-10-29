import AppKit
import SwiftUI

/// `Lina --snapshots DIR` renders every screen and card to PNG offscreen, for design review and the README.
@MainActor
enum Snapshots {
    static func runIfRequested(engine: LinaEngine) {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshots"), args.count > i + 1 else { return }
        let dir = URL(fileURLWithPath: args[i + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let typo = UseCase.typoSentence
        let fix = Proofread(issues: [
            .init(wrong: "you're", right: "your", kind: .grammar),
            .init(wrong: "realy", right: "really", kind: .spelling),
            .init(wrong: "apreciate", right: "appreciate", kind: .spelling),
        ], options: ["Thank you for your help, I really appreciate it.", "Thank you for your help. I really appreciate it."])
        let cards: [(String, CardContent)] = [
            ("card-corrections", .corrections(original: typo, marks: fix.marks(in: typo), options: fix.options)),
            ("card-answer", .answer(question: "who won and how", text: "with Argentina beating France on penalties after a 3–3 draw",
                                    sources: [WebSource(title: "fifa.com", url: "https://www.fifa.com"),
                                              WebSource(title: "bbc.com", url: "https://www.bbc.com")], grounded: true)),
            ("card-question", .question("What would you miss most about the job you have now?")),
            ("card-rewrite", .choices(title: "Rewrites · polite", original: "hey can u send the report asap", options: [
                "Hi, could you send me the report as soon as you can?",
                "Hi Sam, could you send the report when you get a chance today?",
                "Would you mind sending over the report today? Thanks!",
            ])),
            ("card-models", .models(items: [
                ModelItem(id: "nvidia/nemotron-3-super-120b-a12b", kind: .text),
                ModelItem(id: "nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B", kind: .text),
                ModelItem(id: "black-forest-labs/flux-schnell", kind: .image),
            ], currentText: "nvidia/nemotron-3-super-120b-a12b", currentImage: "black-forest-labs/flux-schnell")),
            ("card-image", .image(prompt: "a cozy reading nook at dusk, watercolor", image: DemoArt.readingNook())),
            ("card-help", .help),
            ("card-working", .working("Searching the web…")),
        ]

        for dark in [false, true] {
            let suffix = dark ? "-dark" : ""
            for step in 0..<5 {
                render(OnboardingView(engine: engine, step: step), size: CGSize(width: 760, height: 640), dark: dark,
                       to: dir.appendingPathComponent("onboarding-\(step)\(suffix).png"))
            }
            render(MenuBarView(engine: engine).background(VisualEffect(material: .menu)),
                   size: nil, dark: dark, to: dir.appendingPathComponent("menubar\(suffix).png"))
            for section in HomeSection.allCases {
                HomeNavigation.shared.section = section
                render(HomeView(engine: engine), size: CGSize(width: 1100, height: 760), dark: dark,
                       to: dir.appendingPathComponent("home-\(section.rawValue)\(suffix).png"), window: true)
            }
            for (name, content) in cards {
                render(CardView(content: content), size: nil, dark: dark, to: dir.appendingPathComponent("\(name)\(suffix).png"))
            }
            render(TipView(text: TipCoach.Tip.slash.text), size: nil, dark: dark, to: dir.appendingPathComponent("tip\(suffix).png"))
            render(HStack(spacing: 18) {
                ForEach(Mood.allCases) { mood in
                    VStack(spacing: 6) {
                        LinaFace(mood: mood).frame(width: 110, height: 110)
                        Text(mood.title).font(.system(size: 11, weight: .semibold)).foregroundStyle(mood.hair)
                    }
                }
            }.padding(20).background(Theme.paper), size: nil, dark: dark, to: dir.appendingPathComponent("moods\(suffix).png"))
        }
        HomeNavigation.shared.section = .meet
        print("Snapshots written to \(dir.path)")
        exit(0)
    }

    private static func render<V: View>(_ view: V, size: CGSize?, dark: Bool, to url: URL, window titled: Bool = false) {
        let host = NSHostingView(rootView: view)
        let s = size ?? host.fittingSize
        let style: NSWindow.StyleMask = titled ? [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView] : [.borderless]
        let w = NSWindow(contentRect: CGRect(origin: CGPoint(x: -20000, y: -20000), size: s), styleMask: style, backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        w.contentView = host
        w.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        let target = titled ? (w.contentView?.superview ?? host) : host
        guard let rep = target.bitmapImageRepForCachingDisplay(in: target.bounds) else { return }
        target.cacheDisplay(in: target.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        w.orderOut(nil)
    }
}
