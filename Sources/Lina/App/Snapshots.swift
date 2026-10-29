import AppKit
import SwiftUI

/// `Lina --snapshots DIR` renders every major screen to PNG offscreen, for design review and the README.
@MainActor
enum Snapshots {
    static func runIfRequested(engine: GhostEngine) {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshots"), args.count > i + 1 else { return }
        let dir = URL(fileURLWithPath: args[i + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        for dark in [false, true] {
            let suffix = dark ? "-dark" : ""
            for step in 0..<5 {
                let v = OnboardingView(engine: engine, step: step)
                render(v, size: CGSize(width: 680, height: 560), dark: dark, to: dir.appendingPathComponent("onboarding-\(step)\(suffix).png"))
            }
            render(MenuBarView(engine: engine, palette: PaletteController(), companion: Companion()).background(VisualEffect(material: .menu)),
                   size: nil, dark: dark, to: dir.appendingPathComponent("menubar\(suffix).png"))

            let sample = SampleTarget()
            let p1 = PaletteController(); p1.preview(target: sample, action: nil, phase: .choosing)
            render(palette(p1), size: nil, dark: dark, to: dir.appendingPathComponent("palette-choose\(suffix).png"))
            let p2 = PaletteController()
            p2.preview(target: sample, action: .feeling, phase: .done,
                       result: "The rain had stopped, and the city held its breath — wet stone, a far-off siren, my own footsteps louder than they had any right to be.")
            render(palette(p2), size: nil, dark: dark, to: dir.appendingPathComponent("palette-result\(suffix).png"))
            let p3 = PaletteController()
            p3.preview(target: sample, action: .findWord, phase: .done, options: ["hushed", "still", "muted", "serene", "subdued", "tranquil"])
            render(palette(p3), size: nil, dark: dark, to: dir.appendingPathComponent("palette-words\(suffix).png"))

            let companion = Companion()
            companion.preview(place: "Notes · Letter to Dad", entries: [
                .reflection(Reflection(
                    hearing: "You're trying to reach your father, but the letter keeps turning into a report — the shop, Mom — instead of what you feel.",
                    why: "Underneath the updates there's anger you haven't said out loud: he never let you help.",
                    ask: "What did you want to carry for him that he wouldn't let you?",
                    next: "Setting the table for four — stay with that small ritual and see what it holds.")),
                .writer("I think I want to forgive him, but I'm not ready."),
                .reply("Then maybe the letter doesn't need to forgive him yet. It can just tell him what it cost you — the forgiving can come later, in another letter."),
            ])
            render(CompanionView(companion: companion, input: CompanionInput()), size: nil,
                   dark: dark, to: dir.appendingPathComponent("companion\(suffix).png"))
            let editing = Companion()
            editing.preview(proposal: .init(original: "i dont know why i keep putting off calling him, its not like hes going anywhere.",
                                            rewritten: "I don't know why I keep putting off calling him; it's not as if he's going anywhere.",
                                            streaming: false))
            render(CompanionView(companion: editing, input: CompanionInput()), size: nil,
                   dark: dark, to: dir.appendingPathComponent("companion-edit\(suffix).png"))

            for (name, state, bubble) in [("ink", InkState.resting, "hi, i'm lina"), ("ink-thinking", .thinking, ""),
                                          ("ink-listening", .listening, "")] {
                let ink = InkModel(); ink.state = state; ink.bubble = bubble; ink.audioLevel = 0.12
                render(InkBuddyView(model: ink).background(Theme.paper), size: InkBuddy.size, dark: dark,
                       to: dir.appendingPathComponent("\(name)\(suffix).png"))
            }

            let cards: [(String, InkCard)] = [
                ("ink-card", InkCard(eyebrow: "lina hears",
                                     text: "You're trying to reach your father, but the letter keeps turning into a report.",
                                     detail: "What did you want to carry for him that he wouldn't let you?",
                                     hint: "⌥ Space to reply · hold ⌃⌥ to talk · esc")),
                ("ink-rewrite", InkCard(eyebrow: "rewrite",
                                        text: "I don't know why I keep putting off calling him; it's not as if he's going anywhere.",
                                        original: "i dont know why i keep putting off calling him, its not like hes going anywhere.",
                                        hint: "⇥ use it · esc keep mine")),
                ("ink-command", InkCard(eyebrow: "/lina turn this description to a photo", text: "drawing it…",
                                        hint: "A narrow kitchen at dawn, steam rising from a kettle, soft window light", streaming: true)),
            ]
            for (name, card) in cards {
                let ink = InkModel(); ink.state = card.streaming ? .thinking : .resting; ink.card = card
                render(InkBuddyView(model: ink).background(Theme.paper), size: InkBuddy.size, dark: dark,
                       to: dir.appendingPathComponent("\(name)\(suffix).png"))
            }
            render(ReportView().background(Theme.paper), size: nil, dark: dark, to: dir.appendingPathComponent("report\(suffix).png"))
            render(MemorySettings(), size: CGSize(width: 560, height: 520), dark: dark, to: dir.appendingPathComponent("settings-memory\(suffix).png"))

            let ghost = GhostModel(); ghost.text = " and only the drip from the awning echoed softly."; ghost.fontSize = 14
            render(GhostView(model: ghost), size: nil, dark: dark, to: dir.appendingPathComponent("ghost\(suffix).png"))

            render(DeskView(openPalette: {}), size: CGSize(width: 1100, height: 720), dark: dark,
                   to: dir.appendingPathComponent("desk\(suffix).png"), window: true)
            render(ModelSettings(), size: CGSize(width: 560, height: 520), dark: dark, to: dir.appendingPathComponent("settings-model\(suffix).png"))
            render(VoiceSettings(), size: CGSize(width: 560, height: 520), dark: dark, to: dir.appendingPathComponent("settings-voice\(suffix).png"))
        }
        print("Snapshots written to \(dir.path)")
        exit(0)
    }

    private static func palette(_ c: PaletteController) -> some View {
        PaletteView(controller: c, toast: ToastModel(), onHeight: { _ in })
            .fixedSize(horizontal: false, vertical: true)
    }

    private static func render<V: View>(_ view: V, size: CGSize?, dark: Bool, to url: URL, window titled: Bool = false) {
        let host = NSHostingView(rootView: view)
        let s = size ?? host.fittingSize
        let style: NSWindow.StyleMask = titled ? [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView] : [.borderless]
        let w = NSWindow(contentRect: CGRect(origin: CGPoint(x: -20000, y: -20000), size: s), styleMask: style, backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        w.contentView = host
        w.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.6))
        let target = titled ? (w.contentView?.superview ?? host) : host
        guard let rep = target.bitmapImageRepForCachingDisplay(in: target.bounds) else { return }
        target.cacheDisplay(in: target.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        w.orderOut(nil)
    }
}

@MainActor
private final class SampleTarget: WritingTarget {
    var displayName: String { "Notes" }
    var icon: NSImage? { NSWorkspace.shared.icon(forFile: "/System/Applications/Notes.app") }
    var focusText: String { "The rain stopped and the city was quiet. I walked home and it was very quiet and I could hear my steps." }
    var hasSelection: Bool { false }
    var canWrite: Bool { true }
    var context: WritingContext { WritingContext(before: focusText, selection: focusText, appName: "Notes") }
    func replaceFocus(with text: String) {}
    func insertAfterFocus(_ text: String) {}
    func restore() {}
}
