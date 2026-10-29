import AppKit
import Combine

/// One thing Lina did for the writer, kept on this Mac.
struct HistoryItem: Codable, Identifiable, Equatable {
    enum Kind: String, Codable, CaseIterable {
        case search, question, fix, rewrite, edit, image

        var title: String {
            switch self {
            case .search: "Search"
            case .question: "Question"
            case .fix: "Fix"
            case .rewrite: "Rewrite"
            case .edit: "Edit"
            case .image: "Image"
            }
        }

        var symbol: String {
            switch self {
            case .search: "globe"
            case .question: "questionmark.bubble"
            case .fix: "checkmark.seal"
            case .rewrite: "arrow.triangle.2.circlepath"
            case .edit: "pencil"
            case .image: "photo"
            }
        }
    }

    var id = UUID()
    var kind: Kind
    var date = Date()
    /// The app it happened in.
    var app: String
    /// What the writer asked or wrote.
    var prompt: String
    /// What Lina answered (the first option, for choices).
    var result: String
    var sources: [WebSource] = []
    /// A file name in the Images folder.
    var imageFile: String?
    /// Whether the writer put it into their text.
    var inserted = false
}

/// Everything Lina has saved, as one JSON file in Application Support. Never leaves the Mac.
@MainActor
final class History: ObservableObject {
    static let shared = History()

    @Published private(set) var items: [HistoryItem] = []

    let folder: URL
    let imagesFolder: URL
    private var file: URL { folder.appendingPathComponent("history.json") }
    private var pendingSave: DispatchWorkItem?

    private init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        folder = support.appendingPathComponent("Lina", isDirectory: true)
        imagesFolder = folder.appendingPathComponent("Images", isDirectory: true)
        try? FileManager.default.createDirectory(at: imagesFolder, withIntermediateDirectories: true)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: file), let saved = try? decoder.decode([HistoryItem].self, from: data) {
            items = saved
        }
    }

    @discardableResult
    func add(_ item: HistoryItem) -> UUID {
        items.insert(item, at: 0)
        if items.count > 500 { items.removeLast(items.count - 500) }
        save()
        return item.id
    }

    func markInserted(_ id: UUID?) {
        guard let id, let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].inserted = true
        save()
    }

    func update(_ id: UUID?, result: String) {
        guard let id, let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].result = result
        save()
    }

    func delete(_ id: UUID) {
        if let item = items.first(where: { $0.id == id }), let name = item.imageFile {
            try? FileManager.default.removeItem(at: imagesFolder.appendingPathComponent(name))
        }
        items.removeAll { $0.id == id }
        save()
    }

    func clear() {
        for name in items.compactMap(\.imageFile) {
            try? FileManager.default.removeItem(at: imagesFolder.appendingPathComponent(name))
        }
        items.removeAll()
        save()
    }

    /// Stores a generated picture and returns its file name.
    func storeImage(_ png: Data) -> String? {
        let name = "\(UUID().uuidString).png"
        do {
            try png.write(to: imagesFolder.appendingPathComponent(name), options: .atomic)
            return name
        } catch {
            return nil
        }
    }

    func image(for item: HistoryItem) -> NSImage? {
        guard let name = item.imageFile else { return nil }
        return NSImage(contentsOf: imagesFolder.appendingPathComponent(name))
    }

    /// Writes soon, but also on quit, so nothing is lost.
    private func save() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.flush() } }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func flush() {
        pendingSave?.cancel()
        pendingSave = nil
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        if let data = try? encoder.encode(items) {
            try? data.write(to: file, options: .atomic)
        }
    }
}
