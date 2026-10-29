import AppKit

/// Teaches the commands where they're used: a ^ under the writer's own words, once per lesson.
@MainActor
final class TipCoach {
    enum Tip: String, CaseIterable {
        /// The writer typed "/" for the first time.
        case slash
        /// The writer typed "/lina" for the first time.
        case listening
        /// The writer finished their first sentence.
        case sentence
        /// Lina put something into their text for the first time.
        case inserted

        var text: String {
            switch self {
            case .slash: "Type /lina and a small bar opens here. Ask anything, press Return, and the bar goes away."
            case .listening: "I'm listening. End with . , ? or Return."
            case .sentence: "When you pause after a sentence, I check it. Fixes appear above the words: ⌘1, ⌘2… or ⌘A for all."
            case .inserted: "Done. ⌘Z undoes it, and Lina › Saved keeps a copy."
            }
        }
    }

    private let panel = TipPanel()
    private let settings = AppSettings.shared
    private var lastShown = Date.distantPast
    private var seen: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "tipsSeen") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "tipsSeen") }
    }

    func hasSeen(_ tip: Tip) -> Bool { seen.contains(tip.rawValue) }

    /// Shows a tip pointing up at `rect` (a character on screen), if it's new and the writer wants tips.
    func show(_ tip: Tip, under rect: CGRect?) {
        guard settings.showTips, !hasSeen(tip), let rect, Date().timeIntervalSince(lastShown) > 4 else { return }
        seen.insert(tip.rawValue)
        lastShown = Date()
        panel.show(tip.text, under: rect)
    }

    func hide() { panel.hide() }

    /// "Show tips again" in Lina's window.
    func reset() { seen = [] }
}
