import Foundation
import NaturalLanguage

/// "Look it up" with the web on: searches Wikipedia in the writer's language and hands the model the
/// summaries, so the answer comes with a source instead of from memory. Off until the writer turns it on.
/// Only the question is sent to Wikipedia, never the draft.
enum WebLookup {
    struct Source: Equatable, Identifiable {
        let title: String
        let extract: String
        let url: URL
        var id: URL { url }
    }

    static func search(_ query: String, limit: Int = 3) async throws -> [Source] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        let lang = language(of: q)
        var comps = URLComponents(string: "https://\(lang).wikipedia.org/w/rest.php/v1/search/page")!
        comps.queryItems = [.init(name: "q", value: String(q.prefix(200))), .init(name: "limit", value: String(limit))]
        guard let url = comps.url else { return [] }

        struct Pages: Decodable { struct P: Decodable { let key: String; let title: String }; let pages: [P] }
        let pages = try JSONDecoder().decode(Pages.self, from: try await get(url)).pages

        return await withTaskGroup(of: (Int, Source?).self) { group in
            for (i, page) in pages.enumerated() {
                group.addTask { (i, try? await summary(page.key, title: page.title, lang: lang)) }
            }
            var found: [(Int, Source)] = []
            for await (i, s) in group { if let s { found.append((i, s)) } }
            return found.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    private static func summary(_ key: String, title: String, lang: String) async throws -> Source? {
        let path = key.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? key
        guard let url = URL(string: "https://\(lang).wikipedia.org/api/rest_v1/page/summary/\(path)") else { return nil }
        struct Summary: Decodable {
            struct Urls: Decodable { struct Desktop: Decodable { let page: String }; let desktop: Desktop }
            let extract: String?
            let content_urls: Urls?
        }
        let s = try JSONDecoder().decode(Summary.self, from: try await get(url))
        guard let extract = s.extract, !extract.isEmpty,
              let page = s.content_urls.flatMap({ URL(string: $0.desktop.page) })
        else { return nil }
        return Source(title: title, extract: String(extract.prefix(1200)), url: page)
    }

    private static func get(_ url: URL) async throws -> Data {
        var req = URLRequest(url: url, timeoutInterval: 8)
        req.setValue("Lina/1.3 (https://github.com/Sppdd/lina)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 200
        guard code < 400 else { throw LLMError.http(code, "") }
        return data
    }

    /// Wikipedia's subdomains are mostly ISO 639-1 codes, which is what NaturalLanguage returns.
    static func language(of text: String) -> String {
        guard text.count >= 12, let lang = NLLanguageRecognizer.dominantLanguage(for: text)?.rawValue else { return "en" }
        switch lang {
        case "zh-Hans", "zh-Hant": return "zh"
        case "nb": return "no"
        default: return lang.count == 2 ? lang : "en"
        }
    }
}
