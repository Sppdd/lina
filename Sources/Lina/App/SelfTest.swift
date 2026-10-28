import Foundation

/// `Lina --selftest [--local MODEL] [--models] [--companion]` exercises the real prompts against the configured model
/// and prints the results — a quick way to check a key or a new model from the terminal.
enum SelfTest {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard args.contains("--selftest") else { return }
        let settings = MainActor.assumeIsolated { AppSettings.shared }
        var endpoint = MainActor.assumeIsolated { settings.endpoint }
        if let i = args.firstIndex(of: "--local"), args.count > i + 1 {
            endpoint = LLMEndpoint(baseURL: Provider.local.defaultBaseURL, apiKey: "local", model: args[i + 1])
        }
        let client = LLMClient(endpoint: endpoint)
        if args.contains("--companion") {
            let companion = LLMClient(endpoint: MainActor.assumeIsolated { settings.companionEndpoint })
            print("Companion → \(companion.endpoint.model)\n")
            let draft = """
            I keep starting this letter to my father and deleting it. He's been gone two years and \
            I still set the table for four sometimes. I want to tell him the shop is doing fine, \
            that Mom laughs again, but every sentence sounds like a report. Maybe what I actually want \
            to say is that I'm angry he never let me help.
            """
            let done = DispatchSemaphore(value: 0)
            Task.detached {
                do {
                    let t0 = Date()
                    let raw = try await companion.complete(
                        Prompts.reflection(document: draft, focus: "", appName: "Notes", title: "Letter",
                                           voice: .journal, aboutMe: "", earlier: []),
                        maxTokens: 400, temperature: 0.6)
                    let r = Reflection.parse(raw)
                    print("(\(Int(Date().timeIntervalSince(t0) * 1000)) ms)")
                    print("Hearing: \(r.hearing)\nWhy: \(r.why)\nAsk: \(r.ask)\nNext: \(r.next)")
                    if r.isEmpty { print("✗ Could not parse:\n\(raw)") }
                } catch { print("✗ \(error.localizedDescription)") }
                done.signal()
            }
            done.wait()
            exit(0)
        }
        if args.contains("--models") {
            let done = DispatchSemaphore(value: 0)
            Task.detached {
                do { print(try await client.listModels().joined(separator: "\n")) } catch { print("✗ \(error.localizedDescription)") }
                done.signal()
            }
            done.wait()
            exit(0)
        }
        print("Lina self-test → \(endpoint.baseURL) · \(endpoint.model) · key \(endpoint.apiKey.isEmpty ? "missing" : "\(endpoint.apiKey.count) chars")\n")

        let done = DispatchSemaphore(value: 0)
        Task.detached {
            let before = "I didn't expect the city to feel so quiet after the rain. The streets were empty, and "
            let ctx = WritingContext(before: before, appName: "Notes")
            do {
                let t0 = Date()
                let raw = try await client.complete(
                    Prompts.continuation(ctx, voice: .journal, aboutMe: "", length: .phrase),
                    maxTokens: 28, temperature: 0.45, stop: ["\n\n"])
                let ms = Int(Date().timeIntervalSince(t0) * 1000)
                print("Ghost (\(ms) ms): \(before)⟨\(Suggestion.clean(raw, before: before, length: .phrase))⟩\n")

                var actx = ctx
                actx.selection = "quiet"
                let words = try await client.complete(
                    Prompts.action(.findWord, ctx: actx, query: "", voice: .journal, aboutMe: ""),
                    maxTokens: 80, temperature: 0.6)
                print("Find the word for “quiet”: \(Suggestion.options(words).joined(separator: " · "))\n")

                actx.selection = "me and him goes to the market yesterday and buyed apple's."
                let fixed = try await client.complete(
                    Prompts.action(.fixGrammar, ctx: actx, query: "", voice: .journal, aboutMe: ""),
                    maxTokens: 120, temperature: 0.1)
                print("Fix grammar: \(fixed.trimmingCharacters(in: .whitespacesAndNewlines))\n")
                print("✓ All good")
            } catch {
                print("✗ \(error.localizedDescription)")
            }
            done.signal()
        }
        while done.wait(timeout: .now() + 0.05) == .timedOut {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        exit(0)
    }
}
