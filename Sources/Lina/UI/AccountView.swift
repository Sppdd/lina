import SwiftUI

/// Email-code sign-in, used in onboarding and in Settings → Account.
struct SignInForm: View {
    @ObservedObject var account = Account.shared
    var onSignedIn: (() -> Void)? = nil

    @State private var email = ""
    @State private var code = ""
    @State private var codeSent = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if account.isSignedIn {
                Label("Signed in as \(account.email)", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(Mood.happy.hair)
            } else if !codeSent {
                HStack {
                    TextField("you@example.com", text: $email)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(send)
                    Button(action: send) { label("Email me a code") }
                        .buttonStyle(.borderedProminent)
                        .disabled(busy || !email.contains("@"))
                }
                Text("New here? The same code makes your account. No password.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                HStack {
                    TextField("6-digit code", text: $code)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.oneTimeCode)
                        .font(.system(size: 15, weight: .medium, design: .monospaced))
                        .frame(width: 140)
                        .onSubmit(verify)
                    Button(action: verify) { label("Sign in") }
                        .buttonStyle(.borderedProminent)
                        .disabled(busy || code.filter(\.isNumber).count < 6)
                    Spacer()
                    Button("Use another email") { codeSent = false; code = ""; error = nil }
                        .buttonStyle(.link)
                }
                Text("We sent a code to \(email). It works for a few minutes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Mood.worried.hair)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder private func label(_ title: String) -> some View {
        if busy { ProgressView().controlSize(.small) } else { Text(title) }
    }

    private func send() {
        guard !busy, email.contains("@") else { return }
        busy = true
        error = nil
        Task {
            do {
                try await account.sendCode(to: email)
                codeSent = true
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }

    private func verify() {
        guard !busy else { return }
        busy = true
        error = nil
        Task {
            do {
                try await account.verify(email: email, code: code)
                onSignedIn?()
            } catch {
                self.error = error.localizedDescription
            }
            busy = false
        }
    }
}

/// Settings → Account: who's signed in, today's use, and sign out.
struct AccountSettings: View {
    @ObservedObject var account = Account.shared

    var body: some View {
        Form {
            if !account.isConfigured {
                Section {
                    Text("This build isn't connected to a Lina server, so Lina uses the developer keys in Models and Search (or the .env file).")
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Account")
                } footer: {
                    Text("To connect it, add SUPABASE_URL and SUPABASE_ANON_KEY to .env, or build with scripts/build-app.sh after setting them. See docs/PRODUCTION.md.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else if !account.isSignedIn {
                Section {
                    SignInForm()
                } header: {
                    Text("Sign in")
                } footer: {
                    Text("Signed in, Lina's server does the checking, writing, searching and pictures. Your Mac holds no API keys.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Section("Account") {
                    LabeledContent("Email", value: account.email)
                    LabeledContent("Plan", value: (account.usage?.plan ?? "free").capitalized)
                }
                Section {
                    if let usage = account.usage, !usage.lines.isEmpty {
                        ForEach(usage.lines) { line in
                            UsageRow(line: line)
                        }
                    } else {
                        Text("No use yet today.").foregroundStyle(.secondary)
                    }
                } header: {
                    HStack {
                        Text("Today")
                        Spacer()
                        Button { Task { await account.loadUsage() } } label: { Image(systemName: "arrow.clockwise") }
                            .buttonStyle(.borderless)
                            .help("Refresh")
                    }
                } footer: {
                    Text("Limits reset at midnight UTC.").font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    Button("Sign Out", role: .destructive) { Task { await account.signOut() } }
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 500)
        .task { if account.isSignedIn { await account.loadUsage() } }
    }
}

private struct UsageRow: View {
    let line: Account.Usage.Line

    private var title: String {
        switch line.kind {
        case "check": "Sentence checks"
        case "command": "Commands"
        case "search": "Web searches"
        case "image": "Pictures"
        default: line.kind.capitalized
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(line.limit > 0 ? "\(line.used) of \(line.limit)" : "\(line.used)")
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            if line.limit > 0 {
                ProgressView(value: Double(min(line.used, line.limit)), total: Double(line.limit))
                    .tint(line.used >= line.limit ? Mood.worried.hair : Theme.ink)
            }
        }
        .padding(.vertical, 2)
    }
}
