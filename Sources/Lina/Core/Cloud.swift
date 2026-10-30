import Foundation

/// Where problem reports go. The publishable key is meant to ship inside the app: the database only lets
/// it file problem reports (insert-only, see supabase/migrations), never read anything back.
enum Cloud {
    static let url = "https://aciwoqsepwuccqkvdwsq.supabase.co"
    static let publishableKey = "sb_publishable_ebqJz46TBYxK8L2On0fhoA_UhLMMv0K"

    /// A random id made on first launch, so reports from one Mac can be told apart. It says nothing about who you are.
    static var installID: UUID {
        let d = UserDefaults.standard
        if let s = d.string(forKey: "installID"), let id = UUID(uuidString: s) { return id }
        let id = UUID()
        d.set(id.uuidString, forKey: "installID")
        return id
    }

    /// Sends a saved report to the Lina team. Returns whether it arrived.
    static func send(reportAt file: URL, kind: String, note: String) async -> Bool {
        guard let text = try? String(contentsOf: file, encoding: .utf8),
              let endpoint = URL(string: url + "/rest/v1/problem_reports") else { return false }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev build"
        let row: [String: String] = [
            "install_id": installID.uuidString, "app_version": String(version.prefix(40)),
            "kind": String(kind.prefix(200)), "note": String(note.prefix(4000)), "report": String(text.prefix(60000)),
        ]
        var req = URLRequest(url: endpoint, timeoutInterval: 20)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(publishableKey, forHTTPHeaderField: "apikey")
        req.setValue("return=minimal", forHTTPHeaderField: "Prefer")
        req.httpBody = try? JSONSerialization.data(withJSONObject: row)
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            await Diagnostics.log("cloud", code < 300 ? "report sent to the Lina team" : "report not sent: HTTP \(code)")
            return code < 300
        } catch {
            await Diagnostics.log("cloud", "report not sent: \(error.localizedDescription)")
            return false
        }
    }
}
