import Foundation

/// Downloads, lists and deletes models on the writer's own Ollama server, so "On this Mac" needs no terminal.
/// Ollama's native API lives next to its OpenAI-compatible one: `http://localhost:11434/api/…` beside `/v1`.
@MainActor
final class LocalModels: ObservableObject {
    struct Model: Identifiable, Equatable {
        let name: String
        let bytes: Int64
        var id: String { name }
        var size: String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
    }

    /// Models worth suggesting, smallest first. `minGB` is the Mac memory they're comfortable on.
    struct Suggestion: Identifiable {
        let name: String
        let blurb: String
        let minGB: Int
        var id: String { name }
    }

    static let suggestions: [Suggestion] = [
        .init(name: "llama3.2", blurb: "Meta Llama 3.2 3B · 2 GB · quick on any Apple Silicon Mac", minGB: 8),
        .init(name: "nemotron-mini", blurb: "NVIDIA Nemotron Mini 4B · 2.7 GB · NVIDIA's small open model", minGB: 8),
        .init(name: "qwen2.5:7b", blurb: "Qwen 2.5 7B · 4.7 GB · better writing, needs 16 GB", minGB: 16),
    ]

    /// The best suggestion for this Mac's memory.
    static var recommended: Suggestion {
        let gb = Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)
        return gb >= 16 ? suggestions[1] : suggestions[0]
    }

    enum Status: Equatable { case unknown, offline, ready }

    static let shared = LocalModels()
    @Published private(set) var status: Status = .unknown
    @Published private(set) var installed: [Model] = []
    /// The model being downloaded and how far along it is (0…1, nil while Ollama is still preparing).
    @Published private(set) var pulling: String?
    @Published private(set) var progress: Double?
    @Published private(set) var pullStatus = ""
    @Published private(set) var error: String?
    private var pullTask: Task<Void, Never>?

    private var api: URL? {
        var base = AppSettings.shared.localBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }
        if base.hasSuffix("/v1") { base.removeLast(3) }
        return URL(string: base + "/api")
    }

    func refresh() async {
        guard let url = api?.appendingPathComponent("tags") else { status = .offline; return }
        do {
            let (data, _) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 4))
            struct Tags: Decodable { struct M: Decodable { let name: String; let size: Int64 }; let models: [M] }
            installed = try JSONDecoder().decode(Tags.self, from: data).models
                .map { Model(name: $0.name, bytes: $0.size) }
                .sorted { $0.name < $1.name }
            status = .ready
            error = nil
        } catch {
            status = .offline
            installed = []
        }
    }

    /// True when `name` is installed, treating `llama3.2` and `llama3.2:latest` as the same model.
    func has(_ name: String) -> Bool {
        installed.contains { $0.name == name || $0.name == name + ":latest" }
    }

    /// Downloads a model with progress. Ollama resumes a download that was stopped part-way.
    func pull(_ name: String, thenUse: Bool = true) {
        guard pulling == nil, let url = api?.appendingPathComponent("pull") else { return }
        pulling = name
        progress = nil
        pullStatus = "Starting…"
        error = nil
        pullTask = Task { [weak self] in
            var req = URLRequest(url: url, timeoutInterval: 3600)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: ["model": name, "stream": true])
            do {
                let (bytes, response) = try await URLSession.shared.bytes(for: req)
                if let code = (response as? HTTPURLResponse)?.statusCode, code >= 400 {
                    throw LLMError.http(code, "")
                }
                struct Line: Decodable { let status: String?; let total: Int64?; let completed: Int64?; let error: String? }
                for try await raw in bytes.lines {
                    guard let self, !Task.isCancelled else { return }
                    guard let line = try? JSONDecoder().decode(Line.self, from: Data(raw.utf8)) else { continue }
                    if let e = line.error { throw PullError(message: e) }
                    if let total = line.total, total > 0, let done = line.completed {
                        self.progress = Double(done) / Double(total)
                    }
                    if let s = line.status { self.pullStatus = s.prefix(1).uppercased() + s.dropFirst() }
                }
                guard let self else { return }
                Diagnostics.log("models", "pulled \(name)")
                if thenUse { AppSettings.shared.localModel = name }
                self.finishPull()
                await self.refresh()
            } catch {
                guard let self else { return }
                if !(error is CancellationError) && (error as? URLError)?.code != .cancelled {
                    self.error = (error as? PullError)?.message
                        ?? "Couldn't download \(name). Is Ollama running? (\(error.localizedDescription))"
                    Diagnostics.log("models", "pull \(name) failed: \(error.localizedDescription)")
                }
                self.finishPull()
            }
        }
    }

    func cancelPull() {
        pullTask?.cancel()
        finishPull()
    }

    func delete(_ name: String) async {
        guard let url = api?.appendingPathComponent("delete") else { return }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "DELETE"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["model": name])
        do {
            _ = try await URLSession.shared.data(for: req)
            Diagnostics.log("models", "deleted \(name)")
        } catch {
            self.error = "Couldn't delete \(name): \(error.localizedDescription)"
        }
        await refresh()
    }

    private func finishPull() {
        pulling = nil
        progress = nil
        pullStatus = ""
        pullTask = nil
    }

    private struct PullError: Error { let message: String }
}
