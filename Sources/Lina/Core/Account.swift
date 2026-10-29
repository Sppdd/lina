import AppKit
import Foundation

/// The writer's Lina account, on Supabase. Signed in, every model call goes through Lina's server (`lina-ai`),
/// which holds the Nebius and Gemini keys and counts each person's daily use. The app never sees those keys.
///
/// Sign-in is an emailed six-digit code (Supabase Auth's email OTP), done over plain REST so Lina needs no SDK.
/// The session is kept in `Secrets` and refreshed before it expires.
@MainActor
final class Account: ObservableObject {
    static let shared = Account()

    /// Where Lina's Supabase project is. The publishable (anon) key is meant to ship inside apps.
    struct Config: Equatable {
        let url: String
        let anonKey: String

        /// Info.plist (release builds), then the environment, then `.env` (development).
        static func load() -> Config? {
            let info = Bundle.main.infoDictionary ?? [:]
            let env = ProcessInfo.processInfo.environment
            func value(_ plist: String, _ names: [String]) -> String? {
                if let v = info[plist] as? String, !v.isEmpty, !v.hasPrefix("$(") { return v }
                return names.lazy.compactMap { env[$0] }.first { !$0.isEmpty } ?? DotEnv.first(of: names)
            }
            guard let url = value("LinaSupabaseURL", ["SUPABASE_URL", "LINA_SUPABASE_URL"]),
                  let key = value("LinaSupabaseAnonKey", ["SUPABASE_ANON_KEY", "SUPABASE_PUBLISHABLE_KEY", "LINA_SUPABASE_ANON_KEY"]),
                  URL(string: url) != nil
            else { return nil }
            return Config(url: url.trimmedSlash, anonKey: key)
        }
    }

    struct Session: Codable, Equatable {
        var accessToken: String
        var refreshToken: String
        /// Seconds since 1970.
        var expiresAt: Double
        var email: String
    }

    /// Today's use against the plan's limits, as the server reports it.
    struct Usage: Equatable {
        struct Line: Equatable, Identifiable {
            let kind: String
            let used: Int
            let limit: Int
            var id: String { kind }
        }
        var plan: String
        var lines: [Line]
    }

    enum AccountError: LocalizedError {
        case notConfigured
        case server(String)

        var errorDescription: String? {
            switch self {
            case .notConfigured: "This build of Lina isn't connected to a Lina server yet."
            case let .server(m): m
            }
        }
    }

    let config = Config.load()
    @Published private(set) var session: Session?
    @Published private(set) var usage: Usage?

    var isConfigured: Bool { config != nil }
    var isSignedIn: Bool { config != nil && session != nil }
    var email: String { session?.email ?? "" }

    /// Lina's server function, e.g. `https://<ref>.supabase.co/functions/v1/lina-ai`.
    var gateway: String? { config.map { $0.url + "/functions/v1/lina-ai" } }
    var accessToken: String { session?.accessToken ?? "" }

    private var refreshTimer: Timer?
    private var refreshing: Task<Void, Never>?
    private static let secret = "supabase-session"

    private init() {
        if let raw = Secrets.get(Self.secret), let data = raw.data(using: .utf8) {
            session = try? JSONDecoder().decode(Session.self, from: data)
        }
        guard config != nil else { return }
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated { Account.shared.refreshSoon() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { Account.shared.refreshSoon(force: true) }
        }
        refreshSoon()
    }

    /// The model endpoint for a job ("check", "command", "image", "models") through Lina's server.
    func endpoint(model: String, task: String) -> LLMEndpoint? {
        guard let gateway, let config, let session else { return nil }
        return LLMEndpoint(baseURL: gateway + "/v1", apiKey: session.accessToken, model: model,
                           headers: ["apikey": config.anonKey, "x-lina-task": task])
    }

    // MARK: Signing in

    /// Emails a six-digit code. New addresses get an account.
    func sendCode(to email: String) async throws {
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        _ = try await auth("otp", body: ["email": address, "create_user": true])
    }

    /// Checks the code and keeps the session.
    func verify(email: String, code: String) async throws {
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let token = code.filter(\.isNumber)
        let json = try await auth("verify", body: ["type": "email", "email": address, "token": token])
        try keep(json, email: address)
        await loadUsage()
    }

    func signOut() async {
        if let config, let session {
            var req = URLRequest(url: URL(string: config.url + "/auth/v1/logout")!, timeoutInterval: 10)
            req.httpMethod = "POST"
            req.setValue(config.anonKey, forHTTPHeaderField: "apikey")
            req.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
            _ = try? await URLSession.shared.data(for: req)
        }
        session = nil
        usage = nil
        Secrets.set("", for: Self.secret)
    }

    // MARK: Staying signed in

    /// Refreshes the session when it has less than five minutes left (or now, after the Mac wakes).
    func refreshSoon(force: Bool = false) {
        guard let session, refreshing == nil else { return }
        let left = session.expiresAt - Date().timeIntervalSince1970
        guard force || left < 300 else { return }
        refreshing = Task { [weak self] in
            await self?.refresh()
            self?.refreshing = nil
        }
    }

    /// Call before a request when the session may be stale; returns quickly when it's fresh.
    func ensureFresh() async {
        guard let session, session.expiresAt - Date().timeIntervalSince1970 < 60 else { return }
        if let refreshing { await refreshing.value; return }
        await refresh()
    }

    private func refresh() async {
        guard let session else { return }
        do {
            let json = try await auth("token?grant_type=refresh_token", body: ["refresh_token": session.refreshToken])
            try keep(json, email: session.email)
        } catch AccountError.server(let message) where message.lowercased().contains("refresh token") {
            // The refresh token was revoked or already used: the writer has to sign in again.
            self.session = nil
            Secrets.set("", for: Self.secret)
        } catch {
            NSLog("Lina: session refresh failed: \(error.localizedDescription)")
        }
    }

    private func keep(_ json: [String: Any], email: String) throws {
        guard let access = json["access_token"] as? String, let refresh = json["refresh_token"] as? String else {
            throw AccountError.server("The server didn't send a session. Try again.")
        }
        let expiresIn = (json["expires_in"] as? Double) ?? 3600
        let expiresAt = (json["expires_at"] as? Double) ?? Date().timeIntervalSince1970 + expiresIn
        let mail = ((json["user"] as? [String: Any])?["email"] as? String) ?? email
        let s = Session(accessToken: access, refreshToken: refresh, expiresAt: expiresAt, email: mail)
        session = s
        if let data = try? JSONEncoder().encode(s), let raw = String(data: data, encoding: .utf8) {
            Secrets.set(raw, for: Self.secret)
        }
    }

    // MARK: Usage

    /// Today's use, from `lina-ai/usage`.
    func loadUsage() async {
        await ensureFresh()
        guard let gateway, let config, let session, let url = URL(string: gateway + "/usage") else { return }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(session.accessToken)", forHTTPHeaderField: "Authorization")
        guard let reply = try? await URLSession.shared.data(for: req),
              ((reply.1 as? HTTPURLResponse)?.statusCode ?? 500) < 400,
              let json = (try? JSONSerialization.jsonObject(with: reply.0)) as? [String: Any]
        else { return }
        usage = Self.usage(from: json)
    }

    /// Reads `{"plan": "free", "usage": [{"kind": "search", "used": 3, "limit": 20}, …]}`.
    nonisolated static func usage(from json: [String: Any]) -> Usage {
        let lines = ((json["usage"] as? [[String: Any]]) ?? []).compactMap { row -> Usage.Line? in
            guard let kind = row["kind"] as? String else { return nil }
            return Usage.Line(kind: kind, used: (row["used"] as? Int) ?? 0, limit: (row["limit"] as? Int) ?? 0)
        }
        return Usage(plan: (json["plan"] as? String) ?? "free", lines: lines)
    }

    // MARK: Supabase Auth REST

    private func auth(_ path: String, body: [String: Any]) async throws -> [String: Any] {
        guard let config, let url = URL(string: config.url + "/auth/v1/" + path) else { throw AccountError.notConfigured }
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(config.anonKey, forHTTPHeaderField: "apikey")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 200
        let json = ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
        guard code < 400 else { throw AccountError.server(Self.message(json, code: code)) }
        return json
    }

    /// Supabase Auth errors come as `msg`, `error_description` or `message`; turn the common ones into plain words.
    nonisolated static func message(_ json: [String: Any], code: Int) -> String {
        let raw = (json["msg"] as? String) ?? (json["error_description"] as? String)
            ?? (json["message"] as? String) ?? (json["error"] as? String) ?? ""
        let lower = raw.lowercased()
        if code == 429 || lower.contains("rate limit") || lower.contains("security purposes") {
            return "Too many codes asked for. Wait a minute, then try again."
        }
        if lower.contains("expired") || (lower.contains("invalid") && (lower.contains("otp") || lower.contains("token"))) {
            return "That code didn't work or has expired. Ask for a new one."
        }
        if lower.contains("signups not allowed") { return "New sign-ups are closed right now." }
        if lower.contains("email") && lower.contains("invalid") { return "That doesn't look like an email address." }
        return raw.isEmpty ? "The Lina server said no (\(code))." : raw
    }
}
