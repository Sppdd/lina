import Foundation

/// Things the writer asked Lina to remember: highlight text and press ⌃⌥M, or type `/lina remember …`.
/// Kept on this Mac in ~/Library/Application Support/Lina/memory.json and given to the model with every request.
@MainActor
final class MemoryStore: ObservableObject {
    struct Item: Codable, Identifiable, Equatable {
        var id = UUID()
        var text: String
        /// Where it came from, e.g. "Notes · Letter to Dad".
        var source: String
        var date = Date()
    }

    static let shared = MemoryStore()
    @Published private(set) var items: [Item] = []
    private let url: URL

    private init(url: URL? = nil) {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Lina", isDirectory: true)
        self.url = url ?? dir.appendingPathComponent("memory.json")
        if let data = try? Data(contentsOf: self.url), let saved = try? JSONDecoder().decode([Item].self, from: data) {
            items = saved
        }
    }

    func add(_ text: String, source: String) {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !items.contains(where: { $0.text == clean }) else { return }
        items.insert(Item(text: String(clean.prefix(4000)), source: source), at: 0)
        save()
    }

    func remove(_ id: Item.ID) {
        items.removeAll { $0.id == id }
        save()
    }

    func removeAll() {
        items.removeAll()
        save()
    }

    /// The newest memories, as many as fit in a prompt.
    var promptText: String {
        var out: [String] = []
        var budget = 2500
        for item in items {
            let line = "- " + item.text.replacingOccurrences(of: "\n", with: " ")
            guard line.count <= budget else { break }
            out.append(line)
            budget -= line.count
        }
        return out.joined(separator: "\n")
    }

    private func save() {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
