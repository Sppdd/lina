import Foundation

/// A web page an answer came from.
struct WebSource: Codable, Hashable {
    var title: String
    var url: String

    /// The site, for small chips ("bbc.com").
    var site: String {
        if !title.isEmpty, !title.contains(" ") { return title }
        return URL(string: url)?.host?.replacingOccurrences(of: "www.", with: "") ?? title
    }
}

enum GeminiError: LocalizedError {
    case noKey
    case http(Int, String)
    case empty

    var errorDescription: String? {
        switch self {
        case .noKey: "Add GEMINI_API_KEY to .env, or a Gemini key in Settings → Search."
        case let .http(code, body):
            switch code {
            case 400: "Gemini didn't accept the request (400). \(body.prefix(140))"
            case 401, 403: "Gemini rejected the key (\(code)). Check it in Settings → Search."
            case 429: "Gemini is rate limiting. Try again in a minute."
            default: "Gemini error \(code). \(body.prefix(140))"
            }
        case .empty: "Gemini sent an empty answer."
        }
    }
}

/// Google Gemini with Google Search grounding: answers come from the live web, with their sources.
struct GeminiClient: Sendable {
    var apiKey: String
    var model: String

    static let defaultModel = "gemini-2.5-flash"

    struct Answer: Equatable {
        var text: String
        var sources: [WebSource]
        var queries: [String]
    }

    func ask(system: String, prompt: String) async throws -> Answer {
        guard !apiKey.trimmingCharacters(in: .whitespaces).isEmpty else { throw GeminiError.noKey }
        let name = model.isEmpty ? Self.defaultModel : model
        guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(name):generateContent")
        else { throw LLMError.badURL }
        var req = URLRequest(url: url, timeoutInterval: 40)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        var config: [String: Any] = ["temperature": 0.3, "maxOutputTokens": 400]
        // 2.5 models think by default; a mid-sentence answer has to be quick.
        if name.contains("2.5-flash") { config["thinkingConfig"] = ["thinkingBudget": 0] }
        let body: [String: Any] = [
            "system_instruction": ["parts": [["text": system]]],
            "contents": [["role": "user", "parts": [["text": prompt]]]],
            "tools": [["google_search": [String: Any]()]],
            "generationConfig": config,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 200
        guard code < 400 else { throw GeminiError.http(code, String(data: data, encoding: .utf8) ?? "") }
        let answer = Self.parse(data)
        guard !answer.text.isEmpty else { throw GeminiError.empty }
        return answer
    }

    /// Reads a generateContent response: the text parts, the grounding sources and the queries used.
    static func parse(_ data: Data) -> Answer {
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let candidate = (json["candidates"] as? [[String: Any]])?.first
        else { return Answer(text: "", sources: [], queries: []) }
        let parts = ((candidate["content"] as? [String: Any])?["parts"] as? [[String: Any]]) ?? []
        let text = parts.compactMap { $0["text"] as? String }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        let meta = candidate["groundingMetadata"] as? [String: Any] ?? [:]
        var sources: [WebSource] = []
        for chunk in (meta["groundingChunks"] as? [[String: Any]]) ?? [] {
            guard let web = chunk["web"] as? [String: Any], let uri = web["uri"] as? String else { continue }
            let s = WebSource(title: (web["title"] as? String) ?? "", url: uri)
            if !sources.contains(where: { $0.site == s.site }) { sources.append(s) }
        }
        let queries = (meta["webSearchQueries"] as? [String]) ?? []
        return Answer(text: text, sources: Array(sources.prefix(4)), queries: queries)
    }
}
