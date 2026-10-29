import Foundation

/// `Lina --selftest [--local MODEL] [--models] [--search "question"] [--image "prompt" out.png]`
/// runs Lina's real prompts against the configured models and prints the results:
/// a quick way to check keys or a new model from the terminal.
enum SelfTest {
    static func runIfRequested() {
        let args = CommandLine.arguments
        guard args.contains("--selftest") else { return }
        let settings = MainActor.assumeIsolated { AppSettings.shared }
        let local: LLMEndpoint? = args.firstIndex(of: "--local").flatMap { i in
            args.count > i + 1 ? LLMEndpoint(baseURL: Provider.local.defaultBaseURL, apiKey: "local", model: args[i + 1]) : nil
        }
        let check = local ?? MainActor.assumeIsolated { settings.checkEndpoint }
        let command = local ?? MainActor.assumeIsolated { settings.commandEndpoint }
        let nebius = MainActor.assumeIsolated { settings.nebiusEndpoint }
        let imageModel = MainActor.assumeIsolated { settings.imageModel }
        let gemini = MainActor.assumeIsolated { settings.gemini }

        func run(_ work: @escaping @Sendable () async -> Void) -> Never {
            let done = DispatchSemaphore(value: 0)
            Task.detached {
                await work()
                done.signal()
            }
            while done.wait(timeout: .now() + 0.05) == .timedOut {
                RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            }
            exit(0)
        }

        if args.contains("--models") {
            run {
                do {
                    let items = ModelCatalog.items(try await LLMClient(endpoint: nebius).listModels())
                    for item in items { print("\(item.kind == .image ? "image" : "text ")  \(item.id)") }
                } catch { print("✗ \(error.localizedDescription)") }
            }
        }

        if let i = args.firstIndex(of: "--search"), args.count > i + 1 {
            let question = args[i + 1]
            run {
                do {
                    let t0 = Date()
                    let answer = try await gemini.ask(
                        system: Prompts.searchSystem(voice: .essay, aboutMe: "", grounded: true),
                        prompt: Prompts.searchUser(question: question, before: "I read that ", after: ", which surprised me."))
                    let (fit, plain) = Answers.fitAndAnswer(answer.text)
                    print("(\(Int(Date().timeIntervalSince(t0) * 1000)) ms)")
                    print("Fits as: I read that ⟨\(fit)⟩, which surprised me.")
                    print("Answer:  \(plain)")
                    print("Sources: \(answer.sources.map(\.site).joined(separator: ", "))")
                } catch { print("✗ \(error.localizedDescription)") }
            }
        }

        if let i = args.firstIndex(of: "--image"), args.count > i + 2 {
            let prompt = args[i + 1], out = args[i + 2]
            run {
                do {
                    let png = try await LLMClient(endpoint: nebius).generateImage(prompt: prompt, model: imageModel)
                    try png.write(to: URL(fileURLWithPath: out))
                    print("✓ \(imageModel) → \(out) (\(png.count / 1024) KB)")
                } catch { print("✗ \(error.localizedDescription)") }
            }
        }

        print("Lina self-test\n· checks   → \(check.baseURL) · \(check.model)\n· commands → \(command.model)\n")
        run {
            do {
                let sentence = "Thank you for you're help, I realy apreciate it."
                var t0 = Date()
                let raw = try await LLMClient(endpoint: check).complete(Prompts.proofread(sentence, before: ""),
                                                                         maxTokens: 700, temperature: 0.1)
                let result = Proofread.parse(raw, original: sentence)
                let found = result.issues.map { $0.wrong + " → " + $0.right }.joined(separator: ", ")
                print("Check (\(Int(Date().timeIntervalSince(t0) * 1000)) ms): \(found)")
                for (n, option) in result.options.enumerated() { print("  ⌘\(n + 1) \(option)") }
                if result.isEmpty { print("✗ Could not read the check:\n\(raw)") }

                t0 = Date()
                let q = try await LLMClient(endpoint: command).complete(
                    Prompts.question(text: "I think I want to quit my job and open a bakery, but everyone says it's risky.",
                                     appName: "Notes", voice: .journal, aboutMe: ""),
                    maxTokens: 120, temperature: 0.7)
                print("\n/lina (\(Int(Date().timeIntervalSince(t0) * 1000)) ms): \(q.trimmingCharacters(in: .whitespacesAndNewlines))")

                t0 = Date()
                let rewrites = try await LLMClient(endpoint: command).complete(
                    Prompts.rewrite("hey can u send the report asap", how: "polite", voice: .work, aboutMe: ""),
                    maxTokens: 600, temperature: 0.8)
                print("\n/lina rewrite polite (\(Int(Date().timeIntervalSince(t0) * 1000)) ms):")
                for (n, option) in Answers.options(rewrites).enumerated() { print("  ⌘\(n + 1) \(option)") }
                print("\n✓ Done")
            } catch {
                print("✗ \(error.localizedDescription)")
            }
        }
    }
}
