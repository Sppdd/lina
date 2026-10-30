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
    case keepGoing, findWord, fixGrammar, clearer, feeling, tighten, stuck, lookUp, gathered

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
        case .gathered: "Use what I gathered"
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
        case .gathered: "Write with what you copied and screenshotted"
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
        case .gathered: "tray.full"
        }
    }

    /// How the result is applied back to the writing.
    enum Outcome { case replace, insert, choose, note }

    var outcome: Outcome {
        switch self {
        case .keepGoing, .gathered: .insert
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
        case .gathered: 500
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
                       voice: VoicePreset, aboutMe: String,
                       gathered: String = "", sources: [WebLookup.Source] = []) -> [ChatMessage] {
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
            if sources.isEmpty {
                task = """
                Answer this briefly and factually for a writer mid-draft, in 1–3 sentences: \(q)
                If you are not certain, say so plainly. Don't make up sources.
                """
            } else {
                let refs = sources.enumerated().map { "[\($0.offset + 1)] \($0.element.title): \($0.element.extract)" }
                    .joined(separator: "\n")
                task = """
                Answer this briefly and factually for a writer mid-draft, in 1–3 sentences: \(q)
                Use only these Wikipedia summaries. If they don't answer it, say so plainly.
                <sources>\n\(refs)</sources>
                """
            }
        case .gathered:
            task = """
            While researching, the writer copied and screenshotted the clippings below (newest first). \
            Continue their writing with the next few sentences, drawing on whichever clippings fit what they're \
            writing. Quote exactly when you quote, never invent facts the clippings don't give, and ignore \
            clippings that don't belong. Output only the new sentences.
            <clippings>\n\(gathered)</clippings>
            <text>\n\(surrounding)</text>
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

/// What the companion window says back after reading a draft: not words to insert, but thinking.
struct Reflection: Equatable {
    /// What the writer seems to be saying, in a sentence.
    var hearing = ""
    /// Why they seem to be writing it — the reason or feeling underneath.
    var why = ""
    /// One question that would take the thinking further.
    var ask = ""
    /// A thread in the draft worth following next.
    var next = ""
    /// The writer's own words that thread lives in, copied from the draft, so Lina can point at them.
    var quote = ""

    var isEmpty: Bool { hearing.isEmpty && why.isEmpty && ask.isEmpty && next.isEmpty }

    /// Parses the tagged lines the companion prompt asks for. Works on a partial stream too.
    static func parse(_ raw: String) -> Reflection {
        var r = Reflection()
        var current: WritableKeyPath<Reflection, String>?
        for line in raw.components(separatedBy: .newlines) {
            var l = line.trimmingCharacters(in: .whitespaces)
            while let f = l.first, "*#-_• ".contains(f) { l.removeFirst() }
            let upper = l.uppercased()
            let tags: [(String, WritableKeyPath<Reflection, String>)] =
                [("HEARING", \.hearing), ("WHY", \.why), ("ASK", \.ask), ("NEXT", \.next), ("QUOTE", \.quote)]
            if let (tag, path) = tags.first(where: { upper.hasPrefix($0.0) }) {
                var rest = l.dropFirst(tag.count)
                while let f = rest.first, ":*_ ".contains(f) { rest.removeFirst() }
                current = path
                r[keyPath: path] = String(rest)
            } else if let path = current, !l.isEmpty {
                r[keyPath: path] += (r[keyPath: path].isEmpty ? "" : " ") + l
            }
        }
        r.quote = r.quote.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”'‘’ "))
        return r
    }
}

extension Prompts {
    /// The companion reads the whole draft and thinks about it with the writer.
    static func reflection(document: String, focus: String, appName: String, title: String,
                           voice: VoicePreset, aboutMe: String, earlier: [String]) -> [ChatMessage] {
        let sys = persona(voice, aboutMe: aboutMe) + """

        Right now you are not completing their sentences. You sit in a small window beside the draft \
        and think with the writer about what they are writing and why they are writing it. \
        Read the whole draft. Notice the idea under the words, the feeling or purpose driving it, \
        and what they haven't said yet. Talk to the writer as "you", warmly and plainly, like a friend \
        who reads closely. Never rewrite their text and never write the next lines for them.

        Answer in exactly this form, each part one or two short sentences (under 30 words):
        HEARING: what you hear them saying, in your own words
        WHY: why they seem to be writing this — the reason, need or feeling underneath
        ASK: one specific question that would help them go deeper or say it truer
        NEXT: one thread already in the draft that is worth following next
        QUOTE: 2 to 8 words copied exactly from the draft where that thread is
        """
        var user = ""
        if !appName.isEmpty { user += "Writing in: \(appName)\(title.isEmpty ? "" : " — \(title)")\n" }
        if !earlier.isEmpty {
            user += "You already told them (don't repeat yourself):\n" + earlier.suffix(3).map { "- \($0)" }.joined(separator: "\n") + "\n"
        }
        user += "<draft>\n\(document.suffix(6000))</draft>"
        let f = focus.trimmingCharacters(in: .whitespacesAndNewlines)
        if !f.isEmpty { user += "\nThey are working on this part right now:\n<current>\n\(f.suffix(800))</current>" }
        return [.system(sys), .user(user)]
    }

    /// The writer talks back in the companion window.
    static func conversation(document: String, history: [ChatMessage], voice: VoicePreset,
                             aboutMe: String) -> [ChatMessage] {
        let sys = persona(voice, aboutMe: aboutMe) + """

        You sit in a small window beside the writer's draft and think with them about what they are \
        writing and why. They are talking to you now. Answer in two to four short sentences, \
        conversationally, as "you". Help them find their own words: reflect, question, suggest a direction. \
        Only write sample sentences for their draft if they ask for them.
        <draft>
        \(document.suffix(6000))
        </draft>
        """
        return [.system(sys)] + history.suffix(12)
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

extension Prompts {
    /// Edit and Auto modes: rewrite the one sentence the writer just finished.
    static func rewriteSentence(_ sentence: String, before: String, instruction: String? = nil,
                                voice: VoicePreset, aboutMe: String) -> [ChatMessage] {
        let sys = persona(voice, aboutMe: aboutMe) + """

        Task: rewrite one sentence the writer just wrote so it reads better. Fix grammar, spelling and \
        punctuation, make it clearer and smoother, and keep their meaning, voice, person, tense and roughly \
        their length. Don't add new ideas. If the sentence is already good, return it exactly as it is. \
        Output only the rewritten sentence: no quotes, no labels, no explanation.
        """
        var user = ""
        let context = before.suffix(1500).trimmingCharacters(in: .whitespacesAndNewlines)
        if !context.isEmpty { user += "What comes before it:\n<context>\n\(context)</context>\n" }
        user += "<sentence>\(sentence)</sentence>"
        if let instruction, !instruction.isEmpty {
            user += "\nThe writer asked for this change, follow it: \(instruction)"
        }
        return [.system(sys), .user(user)]
    }
}

/// Finds the sentence at the caret that Edit and Auto modes rewrite as a whole.
enum Sentence {
    struct Found: Equatable {
        /// What to replace: the sentence plus any spaces between it and the caret.
        var range: NSRange
        /// The sentence itself, trimmed.
        var text: String
        /// The spaces after the sentence that the replacement has to keep, so the caret lands where it was.
        var trailing: String
    }

    /// The sentence at the caret. With `finishedOnly`, only a sentence that ends in . ! ? (or …) right
    /// before the caret, with nothing else on the line after it: the moment a writer has just finished one.
    static func find(in text: NSString, caret: Int, finishedOnly: Bool) -> Found? {
        let c = max(0, min(caret, text.length))
        var e = c
        while e > 0, [0x20, 0x09].contains(text.character(at: e - 1)) { e -= 1 }
        guard e > 0, !isNewline(text.character(at: e - 1)) else { return nil }

        if finishedOnly {
            guard endsSentence(text, at: e) else { return nil }
            let line = text.lineRange(for: NSRange(location: c, length: 0))
            let rest = text.substring(with: NSRange(location: c, length: NSMaxRange(line) - c))
            guard rest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        }

        // Split on . ! ? … followed by a space ourselves: the system's sentence finder won't split
        // "late. i dont", and unpolished sentences like that are the ones worth rewriting.
        let paragraph = text.paragraphRange(for: NSRange(location: e - 1, length: 0))
        var start = paragraph.location
        var i = paragraph.location
        while i < e - 1 {
            if let after = sentenceEnd(text, at: i), after < e, isSpace(text.character(at: after)), !isAbbreviation(text, endingAt: i) {
                start = after
                i = after
            } else {
                i += 1
            }
        }
        var end = finishedOnly ? e : NSMaxRange(paragraph)
        if !finishedOnly {
            var j = e - 1
            while j < NSMaxRange(paragraph) {
                if let after = sentenceEnd(text, at: j),
                   after >= NSMaxRange(paragraph) || isSpace(text.character(at: after)) {
                    end = after
                    break
                }
                j += 1
            }
        }
        var r = NSRange(location: start, length: max(0, end - start))
        // Trim whitespace at both ends so the range is exactly the sentence.
        while r.length > 0, isSpace(text.character(at: r.location)) { r.location += 1; r.length -= 1 }
        while r.length > 0, isSpace(text.character(at: NSMaxRange(r) - 1)) { r.length -= 1 }
        let sentence = text.substring(with: r)
        guard WordCount.count(sentence) >= 4 else { return nil }

        let replaceEnd = max(NSMaxRange(r), c)
        let trailing = text.substring(with: NSRange(location: NSMaxRange(r), length: replaceEnd - NSMaxRange(r)))
        return Found(range: NSRange(location: r.location, length: replaceEnd - r.location), text: sentence, trailing: trailing)
    }

    /// Cleans the model's rewrite down to one sentence.
    static func clean(_ raw: String, original: String) -> String {
        var s = raw
        for tag in ["<sentence>", "</sentence>"] { s = s.replacingOccurrences(of: tag, with: "") }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        s = s.components(separatedBy: .newlines).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? ""
        s = s.trimmingCharacters(in: .whitespaces)
        for (open, close) in [("\"", "\""), ("“", "”")] where s.count > 2 && s.hasPrefix(open) && s.hasSuffix(close)
            && !original.hasPrefix(open) {
            s = String(s.dropFirst().dropLast())
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    private static func endsSentence(_ text: NSString, at e: Int) -> Bool {
        var i = e - 1
        // Step back over closing quotes and brackets: `He said "go."` ends a sentence too.
        while i > 0, isCloser(text.character(at: i)) { i -= 1 }
        return isTerminal(text.character(at: i))
    }

    /// If a sentence ends at `i` (. ! ? …, then any closing quotes), the index just past it.
    private static func sentenceEnd(_ text: NSString, at i: Int) -> Int? {
        guard isTerminal(text.character(at: i)) else { return nil }
        var j = i + 1
        while j < text.length, isTerminal(text.character(at: j)) || isCloser(text.character(at: j)) { j += 1 }
        return j
    }

    private static let abbreviations: Set<String> = ["mr", "mrs", "ms", "dr", "st", "vs", "e.g", "i.e", "prof", "jr", "sr"]

    /// "Dr." or "e.g." shouldn't end a sentence.
    private static func isAbbreviation(_ text: NSString, endingAt i: Int) -> Bool {
        var k = i
        while k > 0, !isSpace(text.character(at: k - 1)) { k -= 1 }
        let word = text.substring(with: NSRange(location: k, length: i - k)).lowercased()
        return abbreviations.contains(word)
    }

    private static func isTerminal(_ u: unichar) -> Bool { u == 0x2E || u == 0x21 || u == 0x3F || u == 0x2026 }
    private static func isCloser(_ u: unichar) -> Bool {
        u == 0x22 || u == 0x27 || u == 0x201D || u == 0x2019 || u == 0x29 || u == 0x5D
    }

    private static func isNewline(_ u: unichar) -> Bool { u == 0x0A || u == 0x0D || u == 0x2028 || u == 0x2029 }
    private static func isSpace(_ u: unichar) -> Bool { u == 0x20 || u == 0x09 || isNewline(u) }
}
