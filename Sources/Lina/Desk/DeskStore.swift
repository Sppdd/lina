import Foundation
import Combine

/// A page on Lina's Desk. Stored as a plain Markdown file — your words are never locked in.
struct Page: Identifiable, Equatable {
    let id: UUID
    var text: String
    var modified: Date

    var title: String {
        let first = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        let t = first.trimmingCharacters(in: CharacterSet(charactersIn: "# ").union(.whitespaces))
        return t.isEmpty ? "Untitled" : String(t.prefix(60))
    }

    var preview: String {
        let lines = text.split(whereSeparator: \.isNewline).dropFirst()
        return lines.joined(separator: " ").trimmingCharacters(in: .whitespaces).prefix(90).description
    }

    var words: Int { WordCount.count(text) }
}

@MainActor
final class DeskStore: ObservableObject {
    static let shared = DeskStore()

    @Published private(set) var pages: [Page] = []
    @Published var selection: UUID?

    let folder: URL
    private var pendingSaves: [UUID: DispatchWorkItem] = [:]

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        folder = support.appendingPathComponent("Lina/Pages", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        load()
        if pages.isEmpty { create(text: Self.welcome) }
        selection = pages.first?.id
    }

    var current: Page? { pages.first { $0.id == selection } }

    private func url(_ id: UUID) -> URL { folder.appendingPathComponent("\(id.uuidString).md") }

    private func load() {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        pages = files.compactMap { file in
            guard file.pathExtension == "md", let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                  let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
            let date = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            return Page(id: id, text: text, modified: date)
        }
        .sorted { $0.modified > $1.modified }
    }

    @discardableResult
    func create(text: String = "") -> Page {
        let page = Page(id: UUID(), text: text, modified: Date())
        pages.insert(page, at: 0)
        selection = page.id
        write(page)
        return page
    }

    func update(_ id: UUID, text: String) {
        guard let i = pages.firstIndex(where: { $0.id == id }), pages[i].text != text else { return }
        pages[i].text = text
        pages[i].modified = Date()
        let page = pages[i]
        pendingSaves[id]?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.write(page) }
        pendingSaves[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    func delete(_ id: UUID) {
        pendingSaves[id]?.cancel()
        try? FileManager.default.trashItem(at: url(id), resultingItemURL: nil)
        pages.removeAll { $0.id == id }
        if selection == id { selection = pages.first?.id }
        if pages.isEmpty { create() }
    }

    func fileURL(for id: UUID) -> URL { url(id) }

    private func write(_ page: Page) {
        try? page.text.write(to: url(page.id), atomically: true, encoding: .utf8)
    }

    static let welcome = """
    A quiet place to write

    This is your Desk. Start anywhere — Lina reads along and, when you pause, offers what might come next in faint ink. Press Tab to keep it, or simply keep typing.

    Press ⌥Space to ask for more: find the word you're reaching for, fix the grammar, give a paragraph more feeling, or get unstuck.

    Everything here is saved as plain Markdown on your Mac. Try it now — finish this sentence: The thing I keep meaning to write about is
    """
}
