import Foundation
import Supabase

/// Lina's Supabase project. The publishable key is meant to ship inside the app: the database only lets
/// it file problem reports (insert-only, see cloud/supabase/migrations), never read anything back.
enum Cloud {
    static let client = SupabaseClient(
        supabaseURL: URL(string: "https://aciwoqsepwuccqkvdwsq.supabase.co")!,
        supabaseKey: "sb_publishable_ebqJz46TBYxK8L2On0fhoA_UhLMMv0K"
    )

    /// A random id made on first launch, so reports from one Mac can be told apart. It says nothing about who you are.
    static var installID: UUID {
        let d = UserDefaults.standard
        if let s = d.string(forKey: "installID"), let id = UUID(uuidString: s) { return id }
        let id = UUID()
        d.set(id.uuidString, forKey: "installID")
        return id
    }

    struct ProblemReport: Encodable {
        let installId: UUID
        let appVersion: String
        let kind: String
        let note: String
        let report: String

        enum CodingKeys: String, CodingKey {
            case installId = "install_id", appVersion = "app_version", kind, note, report
        }
    }

    /// Sends a saved report to the Lina team. Returns whether it arrived.
    static func send(reportAt url: URL, kind: String, note: String) async -> Bool {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev build"
        let row = ProblemReport(installId: installID, appVersion: String(version.prefix(40)),
                                kind: String(kind.prefix(200)), note: String(note.prefix(4000)),
                                report: String(text.prefix(60000)))
        do {
            try await client.from("problem_reports").insert(row).execute()
            await Diagnostics.log("cloud", "report sent to the Lina team")
            return true
        } catch {
            await Diagnostics.log("cloud", "report not sent: \(error.localizedDescription)")
            return false
        }
    }
}
