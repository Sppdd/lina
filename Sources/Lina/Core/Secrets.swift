import Foundation
import Security

/// Stores development secrets (API keys) in a file only this user can read, in Lina's Application Support folder.
/// Release builds sign users in instead and never hold provider keys (docs/PRODUCTION.md).
///
/// Lina used to keep them in the login Keychain, but a Keychain item trusts the exact build that wrote it.
/// Lina is ad-hoc signed, so every rebuild looked like a stranger to macOS and it asked
/// "Lina wants to use your confidential information stored in app.lina.mac" again and again.
/// A 0600 file in the user's Library gets the same protection from other users without the prompts.
enum Secrets {
    private static var file: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Lina", isDirectory: true).appendingPathComponent("secrets.json")
    }

    static func get(_ account: String) -> String? {
        if let value = load()[account], !value.isEmpty { return value }
        // One-time move out of the Keychain. This read can prompt once more; after it, never again.
        let flag = "migratedSecretsFromKeychain.\(account)"
        guard !UserDefaults.standard.bool(forKey: flag) else { return nil }
        UserDefaults.standard.set(true, forKey: flag)
        guard let value = LegacyKeychain.get(account) else { return nil }
        set(value, for: account)
        return value
    }

    static func set(_ value: String, for account: String) {
        var all = load()
        all[account] = value.isEmpty ? nil : value
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            let data = try JSONEncoder().encode(all)
            try data.write(to: file, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        } catch {
            NSLog("Lina: couldn't save secrets: \(error)")
        }
    }

    private static func load() -> [String: String] {
        guard let data = try? Data(contentsOf: file),
              let all = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return all
    }
}

/// Reads keys saved by earlier versions of Lina, so nobody has to paste theirs again.
private enum LegacyKeychain {
    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "app.lina.mac",
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data, let s = String(data: data, encoding: .utf8), !s.isEmpty
        else { return nil }
        return s
    }
}
