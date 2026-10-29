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
        case .noKey: "Sign in to search, or add GEMINI_API_KEY to .env for development."
        case let .http(code, body):
            switch code {
            case 400: "Gemini didn't accept the request (400). \(body.prefix(140))"
            case 401: "Sign in again to search (401)."
            case 403: LLMError.isServerMessage(body) ? LLMError.serverMessage(body) : "Gemini rejected the key (403). Check it in Settings → Search."
            case 429: body.contains("today") ? LLMError.serverMessage(body) : "Search is busy. Try again in a minute."
            default: LLMError.isServerMessage(body) ? LLMError.serverMessage(body) : "Gemini error \(code). \(body.prefix(140))"
            }
        case .empty: "Gemini sent an empty answer."
        }
    }
}

/// Google Gemini with Google Search grounding: answers come from the live web, with their sources.
struct GeminiClient: Sendable {
    /// A Gemini key in development, or the user's session token when going through Lina's server.
    var apiKey: String
    var model: String
    /// Lina's server (`…/functions/v1/lina-ai`). When set, the server holds the Gemini key and picks the model.
    var gateway: String? = nil

    static let defaultModel = "gemini-3.5-flash-lite"

    struct Answer: Equatable {
        var text: String
        var sources: [WebSource]
        var queries: [String]
        /// Google's Search Suggestions, as HTML. Google's terms require showing them with the answer.
        var suggestionsHTML: String = ""
    }

    /// The request body Google expects, with Google Search grounding on and thinking kept short.
    static func body(model: String, system: String, prompt: String) -> [String: Any] {
        var config: [String: Any] = ["temperature": 0.3, "maxOutputTokens": 600]
        // A mid-sentence answer has to be quick: keep thinking short.
        if model.contains("2.5") {
            config["thinkingConfig"] = ["thinkingBudget": 0]
        } else if model.contains("gemini-3") {
            config["thinkingConfig"] = ["thinkingLevel": "low"]
        }
        return [
            "system_instruction": ["parts": [["text": system]]],
            "contents": [["role": "user", "parts": [["text": prompt]]]],
            "tools": [["google_search": [String: Any]()]],
            "generationConfig": config,
        ]
    }

    func ask(system: String, prompt: String) async throws -> Answer {
        guard !apiKey.trimmingCharacters(in: .whitespaces).isEmpty else { throw GeminiError.noKey }
        let name = model.isEmpty ? Self.defaultModel : model
        var req: URLRequest
        if let gateway {
            guard let url = URL(string: gateway.trimmedSlash + "/search") else { throw LLMError.badURL }
            req = URLRequest(url: url, timeoutInterval: 40)
            req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
            req.httpBody = try JSONSerialization.data(withJSONObject: ["system": system, "prompt": prompt])
        } else {
            guard let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(name):generateContent")
            else { throw LLMError.badURL }
            req = URLRequest(url: url, timeoutInterval: 40)
            req.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
            req.httpBody = try JSONSerialization.data(withJSONObject: Self.body(model: name, system: system, prompt: prompt))
        }
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
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
        let suggestions = ((meta["searchEntryPoint"] as? [String: Any])?["renderedContent"] as? String) ?? ""
        return Answer(text: text, sources: Array(sources.prefix(4)), queries: queries, suggestionsHTML: suggestions)
    }
}
