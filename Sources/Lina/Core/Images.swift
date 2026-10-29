import AppKit

enum ImageError: LocalizedError {
    case unavailable(String)
    case http(Int, String)
    case empty

    var errorDescription: String? {
        switch self {
        case let .unavailable(model):
            "Token Factory isn't serving pictures from \(model) right now (404). Try another image model in Settings → Model."
        case let .http(code, body): LLMError.http(code, body).localizedDescription
        case .empty: "The image model sent back no picture."
        }
    }
}

/// Text-to-image through the same Nebius Token Factory key: `POST /v1/images/generations`.
struct ImageClient: Sendable {
    var baseURL: String
    var apiKey: String
    var model: String

    /// Generates one picture and returns it as PNG data.
    func generate(_ prompt: String, width: Int = 1024, height: Int = 768) async throws -> Data {
        guard let url = URL(string: baseURL.trimmedSlash + "/images/generations") else { throw LLMError.badURL }
        var req = URLRequest(url: url, timeoutInterval: 120)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        // Schnell is distilled to a few steps; the larger models want more.
        let steps = model.lowercased().contains("schnell") ? 4 : 28
        let body: [String: Any] = [
            "model": model,
            "prompt": prompt,
            "response_format": "b64_json",
            "response_extension": "png",
            "width": width,
            "height": height,
            "num_inference_steps": steps,
            "seed": -1,
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 200
        if code == 404 { throw ImageError.unavailable(model) }
        guard code < 400 else { throw ImageError.http(code, String(data: data, encoding: .utf8) ?? "") }

        struct Reply: Decodable { struct Item: Decodable { let b64_json: String?; let url: String? }; let data: [Item] }
        guard let item = try JSONDecoder().decode(Reply.self, from: data).data.first else { throw ImageError.empty }
        if let b64 = item.b64_json, let png = Data(base64Encoded: b64) { return png }
        // The link is temporary, so fetch the picture right away.
        if let link = item.url.flatMap(URL.init(string:)) {
            let (png, _) = try await URLSession.shared.data(from: link)
            return png
        }
        throw ImageError.empty
    }

    /// Keeps the picture in ~/Pictures/Lina so it outlives the paste.
    static func save(_ png: Data, named prompt: String) throws -> URL {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/Lina", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let slug = prompt.lowercased().split { !$0.isLetter && !$0.isNumber }.prefix(6).joined(separator: "-")
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "")
        let url = dir.appendingPathComponent("\(stamp)-\(slug.isEmpty ? "lina" : slug).png")
        try png.write(to: url, options: .atomic)
        return url
    }
}
