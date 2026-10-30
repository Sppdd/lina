import Foundation

struct LLMEndpoint: Equatable, Sendable {
    var baseURL: String
    /// A provider key in development, or the user's session token when going through Lina's server.
    var apiKey: String
    var model: String
    /// Extra headers, e.g. which job a request is for when it goes through Lina's server.
    var headers: [String: String] = [:]
}

struct ChatMessage: Codable, Sendable {
    let role: String
    let content: String

    static func system(_ s: String) -> ChatMessage { .init(role: "system", content: s) }
    static func user(_ s: String) -> ChatMessage { .init(role: "user", content: s) }
    static func assistant(_ s: String) -> ChatMessage { .init(role: "assistant", content: s) }
}

enum LLMError: LocalizedError {
    case badURL
    case http(Int, String)
    case notConfigured
    case message(String)

    var errorDescription: String? {
        switch self {
        case .badURL: "The server address isn't a valid URL."
        case .notConfigured: "Add your Nebius API key in Settings → Models."
        case let .message(m): m
        case let .http(code, body):
            switch code {
            case 401: "Lina couldn't sign you in (401). Sign in again, or check the key in Settings."
            case 402, 403: Self.isServerMessage(body) ? Self.serverMessage(body) : "Not allowed (\(code)). Check your account or key in Settings."
            case 404: "Model not found (404). Type /lina model to pick another."
            case 429: body.contains("today") ? Self.serverMessage(body) : "Lina is busy right now. Try again in a moment."
            default: Self.isServerMessage(body) ? Self.serverMessage(body) : "Server error \(code). \(body.prefix(160))"
            }
        }
    }
}

extension LLMError {
    /// Whether the body is Lina's server explaining itself: `{"error": "…"}`.
    static func isServerMessage(_ body: String) -> Bool {
        guard let data = body.data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        return json["error"] is String
    }

    /// The `error` text Lina's server sends with a refusal, e.g. "You've used today's 20 searches."
    static func serverMessage(_ body: String) -> String {
        if let data = body.data(using: .utf8),
           let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
           let message = json["error"] as? String { return message }
        return String(body.prefix(200))
    }
}

/// Streaming client for any OpenAI-compatible chat-completions endpoint
/// (Nebius Token Factory, Ollama, LM Studio, llama.cpp server).
struct LLMClient: Sendable {
    var endpoint: LLMEndpoint

    private var isNemotron: Bool { endpoint.model.lowercased().contains("nemotron") }
    private var isLocal: Bool { endpoint.baseURL.contains("localhost") || endpoint.baseURL.contains("127.0.0.1") }

    func stream(
        _ messages: [ChatMessage],
        maxTokens: Int,
        temperature: Double = 0.5,
        stop: [String] = []
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var filter = ThinkFilter()
                    // Reasoning models think by default; real-time writing help must not think out loud.
                    var disableThinking = true
                    var attempt = 0
                    while true {
                        attempt += 1
                        let request = try makeRequest(messages, maxTokens: maxTokens, temperature: temperature,
                                                      stop: stop, disableThinking: disableThinking)
                        let (bytes, response) = try await URLSession.shared.bytes(for: request)
                        let code = (response as? HTTPURLResponse)?.statusCode ?? 200
                        if code >= 400 {
                            var body = ""
                            for try await line in bytes.lines { body += line; if body.count > 600 { break } }
                            // Some servers reject unknown fields; retry once without the thinking switch.
                            if code == 400 && disableThinking && attempt == 1 {
                                disableThinking = false
                                continue
                            }
                            throw LLMError.http(code, body)
                        }
                        for try await line in bytes.lines {
                            try Task.checkCancellation()
                            guard line.hasPrefix("data:") else { continue }
                            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                            if payload == "[DONE]" { break }
                            guard let data = payload.data(using: .utf8),
                                  let chunk = try? JSONDecoder().decode(StreamChunk.self, from: data),
                                  let piece = chunk.choices.first?.delta?.content, !piece.isEmpty
                            else { continue }
                            let visible = filter.feed(piece)
                            if !visible.isEmpty { continuation.yield(visible) }
                        }
                        break
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Convenience: collect the whole streamed answer.
    func complete(_ messages: [ChatMessage], maxTokens: Int, temperature: Double = 0.5,
                  stop: [String] = []) async throws -> String {
        var out = ""
        for try await piece in stream(messages, maxTokens: maxTokens, temperature: temperature, stop: stop) {
            out += piece
        }
        return out
    }

    func listModels() async throws -> [String] {
        guard let url = URL(string: endpoint.baseURL.trimmedSlash + "/models") else { throw LLMError.badURL }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("Bearer \(endpoint.apiKey)", forHTTPHeaderField: "Authorization")
        for (k, v) in endpoint.headers { req.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 200
        guard code < 400 else { throw LLMError.http(code, String(data: data, encoding: .utf8) ?? "") }
        struct ModelList: Decodable { struct M: Decodable { let id: String }; let data: [M] }
        return try JSONDecoder().decode(ModelList.self, from: data).data.map(\.id).sorted()
    }

    /// Makes a picture with an OpenAI-compatible images endpoint (Token Factory's FLUX models).
    func generateImage(prompt: String, model: String, size: Int = 1024) async throws -> Data {
        guard let url = URL(string: endpoint.baseURL.trimmedSlash + "/images/generations") else { throw LLMError.badURL }
        var req = URLRequest(url: url, timeoutInterval: 120)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(endpoint.apiKey)", forHTTPHeaderField: "Authorization")
        for (k, v) in endpoint.headers { req.setValue(v, forHTTPHeaderField: k) }
        let body: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "response_format": "b64_json",
            "response_extension": "png",
            "width": size,
            "height": size,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 200
        guard code < 400 else { throw LLMError.http(code, String(data: data, encoding: .utf8) ?? "") }
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let first = (json["data"] as? [[String: Any]])?.first
        else { throw LLMError.message("The image model sent nothing back.") }
        if let b64 = first["b64_json"] as? String, let png = Data(base64Encoded: b64) { return png }
        if let link = first["url"] as? String, let u = URL(string: link) {
            let (png, _) = try await URLSession.shared.data(from: u)
            return png
        }
        throw LLMError.message("The image model sent nothing back.")
    }

    private func makeRequest(_ messages: [ChatMessage], maxTokens: Int, temperature: Double,
                             stop: [String], disableThinking: Bool) throws -> URLRequest {
        guard let url = URL(string: endpoint.baseURL.trimmedSlash + "/chat/completions") else { throw LLMError.badURL }
        var req = URLRequest(url: url, timeoutInterval: 45)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(endpoint.apiKey)", forHTTPHeaderField: "Authorization")
        for (k, v) in endpoint.headers { req.setValue(v, forHTTPHeaderField: k) }

        var msgs = messages
        if disableThinking && isNemotron, let first = msgs.first, first.role == "system" {
            msgs[0] = .system("/no_think\n" + first.content)
        }
        var body: [String: Any] = [
            "model": endpoint.model,
            "messages": msgs.map { ["role": $0.role, "content": $0.content] },
            "max_tokens": maxTokens,
            "temperature": temperature,
            "stream": true,
        ]
        if !stop.isEmpty { body["stop"] = stop }
        if disableThinking {
            if isNemotron { body["chat_template_kwargs"] = ["enable_thinking": false] }
            if isLocal { body["reasoning_effort"] = "none" }
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    private struct StreamChunk: Decodable {
        struct Choice: Decodable { struct Delta: Decodable { let content: String? }; let delta: Delta? }
        let choices: [Choice]
    }
}

/// Removes `<think>…</think>` spans from a token stream, even when tags are split across chunks.
struct ThinkFilter {
    private var buffer = ""
    private var inThink = false

    mutating func feed(_ piece: String) -> String {
        buffer += piece
        var out = ""
        while true {
            if inThink {
                if let r = buffer.range(of: "</think>") {
                    buffer = String(buffer[r.upperBound...])
                    inThink = false
                } else {
                    // Keep only what could be the start of a closing tag.
                    buffer = String(buffer.suffix(7))
                    return out
                }
            } else {
                if let r = buffer.range(of: "<think>") {
                    out += buffer[..<r.lowerBound]
                    buffer = String(buffer[r.upperBound...])
                    inThink = true
                } else {
                    // Hold back a possible partial "<think" at the end.
                    if let lt = buffer.lastIndex(of: "<"), "<think>".hasPrefix(buffer[lt...]) {
                        out += buffer[..<lt]
                        buffer = String(buffer[lt...])
                    } else {
                        out += buffer
                        buffer = ""
                    }
                    return out
                }
            }
        }
    }
}

extension String {
    var trimmedSlash: String { hasSuffix("/") ? String(dropLast()) : self }
}

/// One model on the provider, sorted by what it makes.
struct ModelItem: Identifiable, Hashable {
    enum Kind: String { case text, image }

    let id: String
    let kind: Kind

    var shortName: String { id.split(separator: "/").last.map(String.init) ?? id }
    var maker: String { id.contains("/") ? id.split(separator: "/").first.map(String.init) ?? "" : "" }
}

enum ModelCatalog {
    static let defaultImageModel = "black-forest-labs/flux-schnell"

    /// Text or image, or nil for models Lina can't use (embeddings, guards, speech).
    static func kind(of id: String) -> ModelItem.Kind? {
        let l = id.lowercased()
        let skip = ["embed", "bge-", "e5-", "rerank", "guard", "whisper", "tts", "clip"]
        if skip.contains(where: { l.contains($0) }) { return nil }
        let image = ["flux", "stable-diffusion", "sdxl", "sd3", "dall-e", "imagen", "kandinsky", "playground", "-image", "image-"]
        if image.contains(where: { l.contains($0) }) { return .image }
        return .text
    }

    /// Usable models, NVIDIA first, then alphabetical.
    static func items(_ ids: [String]) -> [ModelItem] {
        ids.compactMap { id in kind(of: id).map { ModelItem(id: id, kind: $0) } }
            .sorted { a, b in
                let an = a.id.lowercased().contains("nvidia"), bn = b.id.lowercased().contains("nvidia")
                if an != bn { return an }
                return a.id.localizedCaseInsensitiveCompare(b.id) == .orderedAscending
            }
    }
}
