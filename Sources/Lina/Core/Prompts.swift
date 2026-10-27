import Foundation

/// The kind of writing the user does most — shapes Lina's voice.
enum VoicePreset: String, CaseIterable, Identifiable, Codable {
    case journal, essay, research, story, work

    var id: String { rawValue }

    var title: String {
        switch self {
        case .journal: "Journal"
        case .essay: "Essay & Blog"
        case .research: "Research"
        case .story: "Story & Script"
        case .work: "Work"
        }
    }

    var symbol: String {
        switch self {
        case .journal: "book.closed"
        case .essay: "text.alignleft"
        case .research: "graduationcap"
        case .story: "theatermasks"
        case .work: "briefcase"
        }
    }

    var blurb: String {
        switch self {
        case .journal: "Honest, personal, first-person."
        case .essay: "Clear argument, warm voice."
        case .research: "Precise, careful, cited."
        case .story: "Vivid, scene-driven, emotional."
        case .work: "Direct, friendly, brief."
        }
    }

    var guidance: String {
        switch self {
        case .journal: "This is a private journal. Keep the writer's first-person, reflective, honest voice. Favor concrete feelings and small details over clichés."
        case .essay: "This is an essay or blog post. Keep the argument moving, prefer plain words and a warm, confident voice."
        case .research: "This is academic or research writing. Be precise and measured; avoid overclaiming; never invent citations or numbers."
        case .story: "This is fiction or a script. Favor vivid sensory detail, subtext, and strong verbs. Stay in the established point of view and tense."
        case .work: "This is workplace writing. Be clear, direct, friendly and brief."
        }
    }
}

/// What Lina can do from the palette.
enum WritingAction: String, CaseIterable, Identifiable {
    case keepGoing, findWord, fixGrammar, clearer, feeling, tighten, stuck, lookUp

    var id: String { rawValue }

    var title: String {
        switch self {
        case .keepGoing: "Keep going"
        case .findWord: "Find the word"
        case .fixGrammar: "Fix grammar"
        case .clearer: "Say it clearer"
        case .feeling: "Give it feeling"
        case .tighten: "Tighten"
        case .stuck: "I'm stuck"
        case .lookUp: "Look it up"
        }
    }

    var hint: String {
        switch self {
        case .keepGoing: "Write the next few lines in your voice"
        case .findWord: "Words for what you mean"
        case .fixGrammar: "Spelling, grammar, punctuation — nothing else"
        case .clearer: "Same meaning, easier to read"
        case .feeling: "More emotion and sensory detail"
        case .tighten: "Cut the fat, keep the voice"
        case .stuck: "Questions that get you moving again"
        case .lookUp: "A quick fact, without leaving the page"
        }
    }

    var symbol: String {
        switch self {
        case .keepGoing: "text.append"
        case .findWord: "character.cursor.ibeam"
        case .fixGrammar: "checkmark.seal"
        case .clearer: "sparkles"
        case .feeling: "heart.text.square"
        case .tighten: "arrow.down.right.and.arrow.up.left"
        case .stuck: "lightbulb"
        case .lookUp: "magnifyingglass"
        }
    }

    /// How the result is applied back to the writing.
    enum Outcome { case replace, insert, choose, note }

    var outcome: Outcome {
        switch self {
        case .keepGoing: .insert
        case .findWord: .choose
        case .fixGrammar, .clearer, .feeling, .tighten: .replace
        case .stuck, .lookUp: .note
        }
    }

    var needsTarget: Bool { outcome == .replace || self == .findWord }

    var maxTokens: Int {
        switch self {
        case .findWord: 80
        case .keepGoing: 160
        case .stuck, .lookUp: 260
        default: 700
        }
    }

    var temperature: Double {
        switch self {
        case .fixGrammar: 0.1
        case .tighten, .clearer, .lookUp: 0.3
        case .findWord: 0.6
        default: 0.75
        }
    }
}

/// Everything Lina knows about the moment of writing.
struct WritingContext: Equatable {
    var before: String
    var after: String = ""
    var selection: String = ""
    var appName: String = ""
    var windowTitle: String = ""
}

enum Prompts {
    static func persona(_ voice: VoicePreset, aboutMe: String) -> String {
        var s = """
        You are Lina, a quiet writing companion that sits beside a writer while they write. \
        You help them keep going in their own voice; you never lecture, never explain yourself, \
        and never add commentary, quotes, labels or markdown unless asked. \
        Always answer in the same language the writer is using. \(voice.guidance)
        """
        let me = aboutMe.trimmingCharacters(in: .whitespacesAndNewlines)
        if !me.isEmpty { s += "\nAbout the writer, in their words: \(me)" }
        return s
    }

    /// Inline ghost-text continuation.
    static func continuation(_ ctx: WritingContext, voice: VoicePreset, aboutMe: String,
                             length: SuggestionLength) -> [ChatMessage] {
        let sys = persona(voice, aboutMe: aboutMe) + """

        Task: predict how the writer will continue. Output ONLY the continuation — \(length.instruction) — \
        that begins exactly where their text stops. Do not repeat any of their words. \
        Match their tense, person, tone and vocabulary. No quotes, no preamble, no newline.
        """
        var user = ""
        if !ctx.appName.isEmpty {
            user += "Writing in: \(ctx.appName)\(ctx.windowTitle.isEmpty ? "" : " — \(ctx.windowTitle)")\n"
        }
        user += "<text>\n\(ctx.before.suffix(3000))</text>"
        let after = ctx.after.prefix(400).trimmingCharacters(in: .whitespacesAndNewlines)
        if !after.isEmpty { user += "\n<text_after_cursor>\n\(after)</text_after_cursor>" }
        user += "\nContinue from the very end of <text>."
        return [.system(sys), .user(user)]
    }

    static func action(_ action: WritingAction, ctx: WritingContext, query: String,
                       voice: VoicePreset, aboutMe: String) -> [ChatMessage] {
        let sys = persona(voice, aboutMe: aboutMe)
        let target = ctx.selection
        let surrounding = String(ctx.before.suffix(2500))
        let task: String
        switch action {
        case .keepGoing:
            task = """
            Continue the writing below with the next 2–3 sentences, picking up exactly where it stops. \
            Output only the new sentences.
            <text>\n\(surrounding)</text>
            """
        case .findWord:
            task = """
            The writer is looking for a better word or phrase for: "\(target)"\
            \(query.isEmpty ? "" : " — they mean: \(query)").
            Context: <text>\n\(surrounding)</text>
            Give exactly 6 alternatives that fit this sentence, best first, one per line, \
            no numbering, no explanations.
            """
        case .fixGrammar:
            task = """
            Fix spelling, grammar and punctuation in the passage. Change nothing else — keep every word choice, \
            line break and the writer's style. Output only the corrected passage.
            <passage>\n\(target)</passage>
            """
        case .clearer:
            task = """
            Rewrite the passage so it's clearer and easier to read, keeping the meaning and the writer's voice. \
            Output only the rewritten passage.
            <passage>\n\(target)</passage>
            """
        case .feeling:
            task = """
            Rewrite the passage with more feeling: concrete sensory detail, honest emotion, stronger verbs. \
            Keep it about the same length and in the writer's voice. Output only the rewritten passage.
            <passage>\n\(target)</passage>
            """
        case .tighten:
            task = """
            Tighten the passage: remove filler and repetition, keep the voice and every important idea. \
            Output only the tightened passage.
            <passage>\n\(target)</passage>
            """
        case .stuck:
            task = """
            The writer is stuck. Read what they have so far and offer three short, specific questions \
            or directions that would help them write the next paragraph. Each on its own line, starting with "— ". \
            Do not write the paragraph for them.
            <text>\n\(surrounding.isEmpty ? target : surrounding)</text>
            """
        case .lookUp:
            let q = query.isEmpty ? target : query
            task = """
            Answer this briefly and factually for a writer mid-draft, in 1–3 sentences: \(q)
            If you are not certain, say so plainly. Don't make up sources.
            """
        }
        var user = task
        if !query.isEmpty && action != .findWord && action != .lookUp {
            user += "\nThe writer adds: \(query)"
        }
        return [.system(sys), .user(user)]
    }

    /// A free-form instruction typed into the palette.
    static func custom(_ instruction: String, ctx: WritingContext, voice: VoicePreset, aboutMe: String) -> [ChatMessage] {
        let sys = persona(voice, aboutMe: aboutMe)
        let passage = ctx.selection.isEmpty ? String(ctx.before.suffix(2500)) : ctx.selection
        let user = """
        Instruction from the writer: \(instruction)
        <passage>\n\(passage)</passage>
        Output only the result.
        """
        return [.system(sys), .user(user)]
    }
}

/// Shapes raw model output into something that can sit right after the caret.
enum Suggestion {
    /// Clean a continuation so it joins the writer's text naturally.
    static func clean(_ raw: String, before: String, length: SuggestionLength) -> String {
        var s = raw.replacingOccurrences(of: "\r", with: "")
        // Remove wrapping quotes / labels the model sometimes adds.
        for prefix in ["Continuation:", "continuation:", "…", "..."] where s.hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count))
        }
        if let nl = s.firstIndex(of: "\n") {
            let head = s[..<nl]
            s = head.trimmingCharacters(in: .whitespaces).isEmpty
                ? String(s[nl...]).trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").first ?? ""
                : String(head)
        }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”`"))
        // Drop an echo of the writer's last words.
        let tail = before.suffix(40).trimmingCharacters(in: .whitespaces)
        if tail.count > 8, s.trimmingCharacters(in: .whitespaces).hasPrefix(tail) {
            s = String(s.trimmingCharacters(in: .whitespaces).dropFirst(tail.count))
        }
        // Hard cap length so ghost text never becomes a wall.
        let wordCap: Int = switch length { case .words: 6; case .phrase: 14; case .sentence: 32 }
        let words = s.split(separator: " ", omittingEmptySubsequences: false)
        if words.count > wordCap + 1 {
            s = words.prefix(wordCap + (s.hasPrefix(" ") ? 1 : 0)).joined(separator: " ")
        }
        return joinSpacing(s, before: before)
    }

    /// Ensures exactly one space between the writer's text and the suggestion when needed.
    static func joinSpacing(_ s: String, before: String) -> String {
        guard let last = before.last else { return s.trimmingCharacters(in: .whitespaces) }
        let trimmed = String(s.drop(while: { $0 == " " }))
        guard let first = trimmed.first else { return "" }
        if last.isWhitespace { return trimmed }
        // After punctuation that ends a clause, start with a space unless the suggestion is punctuation.
        if ".,;:!?)”\"".contains(last) {
            return ".,;:!?)".contains(first) ? trimmed : " " + trimmed
        }
        // Mid-word: keep whatever spacing the model chose.
        return s
    }

    /// Parse the "find the word" answer into options.
    static func options(_ raw: String) -> [String] {
        raw.components(separatedBy: .newlines)
            .map { line in
                var l = line.trimmingCharacters(in: .whitespaces)
                while let f = l.first, "-–—•*0123456789.) ".contains(f) { l.removeFirst() }
                return l.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”*` "))
            }
            .filter { !$0.isEmpty && $0.count < 60 }
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            .prefix(6)
            .map { $0 }
    }

    /// Whether the caret is at a good moment to offer a continuation.
    static func isGoodMoment(before: String, after: String) -> Bool {
        let trimmed = before.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 12, let last = before.last else { return false }
        // Only after a finished word: whitespace (but not a fresh blank line) or clause punctuation.
        if last == "\n" { return false }
        guard last == " " || ".,;:!?”\"".contains(last) else { return false }
        // Don't suggest in the middle of a line that already continues.
        if let next = after.first, !next.isNewline { return false }
        return true
    }
}

/// Counts words the way writers expect.
enum WordCount {
    static func count(_ s: String) -> Int {
        var n = 0
        s.enumerateSubstrings(in: s.startIndex..., options: [.byWords, .substringNotRequired]) { _, _, _, _ in n += 1 }
        return n
    }
}
