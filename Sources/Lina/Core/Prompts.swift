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
        case .journal: "This is a private journal. Keep the writer's first-person, reflective, honest voice."
        case .essay: "This is an essay or blog post. Prefer plain words and a warm, confident voice."
        case .research: "This is academic or research writing. Be precise and measured; never invent citations or numbers."
        case .story: "This is fiction or a script. Stay in the established point of view and tense."
        case .work: "This is workplace writing. Be clear, direct, friendly and brief."
        }
    }
}

enum Prompts {
    static func persona(_ voice: VoicePreset, aboutMe: String) -> String {
        var s = """
        You are Lina, a writing helper who appears at the writer's cursor only when they ask. \
        You are brief and direct: no greetings, no explanations, no labels, no markdown. \
        Always answer in the same language the writer is using. \(voice.guidance)
        """
        let me = aboutMe.trimmingCharacters(in: .whitespacesAndNewlines)
        if !me.isEmpty { s += "\nAbout the writer, in their words: \(me)" }
        return s
    }

    /// `/lina` alone: one question that makes the writer think harder.
    static func question(text: String, appName: String, voice: VoicePreset, aboutMe: String) -> [ChatMessage] {
        let sys = persona(voice, aboutMe: aboutMe) + """

        The writer typed /lina to ask you to read what they wrote and push their thinking. \
        Ask exactly ONE short question (under 20 words) that matters for this text: a gap, an unstated \
        reason, an assumption, a reader's likely objection, or the feeling underneath. \
        Use their specifics. Do not praise, summarize, advise or rewrite. Output only the question.
        """
        var user = appName.isEmpty ? "" : "Writing in: \(appName)\n"
        user += "<text>\n\(text.suffix(4000))</text>"
        return [.system(sys), .user(user)]
    }

    /// The check that runs when a sentence ends, and `/lina fix`.
    static func proofread(_ passage: String, before: String) -> [ChatMessage] {
        let sys = """
        You are a careful proofreader. Find only real mistakes in the passage: spelling, typos, grammar, \
        wrong words, and punctuation. Ignore style, names, slang and anything clearly intentional. \
        Never change meaning or voice.
        Reply with JSON only, no code fences:
        {"issues":[{"wrong":"exact text copied from the passage","right":"the correction","kind":"spelling|grammar|punctuation"}],\
        "fixed":"the passage with only those mistakes fixed",\
        "better":"the passage fixed and slightly clearer, same meaning and voice"}
        If there are no mistakes, reply {"issues":[]}.
        """
        var user = ""
        let ctx = before.suffix(600).trimmingCharacters(in: .whitespacesAndNewlines)
        if !ctx.isEmpty { user += "Earlier text, for context only:\n<context>\n\(ctx)\n</context>\n" }
        user += "<passage>\n\(passage)\n</passage>"
        return [.system(sys), .user(user)]
    }

    /// `/lina rewrite [how]`: three versions to choose from.
    static func rewrite(_ passage: String, how: String, voice: VoicePreset, aboutMe: String) -> [ChatMessage] {
        let sys = persona(voice, aboutMe: aboutMe) + """

        Rewrite the passage three different ways\(how.isEmpty ? "" : ", each one \(how)"). \
        Keep the meaning, the language and roughly the length. Output the three versions only, \
        separated by a line containing only ---.
        """
        return [.system(sys), .user("<passage>\n\(passage)\n</passage>")]
    }

    /// `/lina edit <instruction>`: one changed version.
    static func edit(_ passage: String, instruction: String, voice: VoicePreset, aboutMe: String) -> [ChatMessage] {
        let sys = persona(voice, aboutMe: aboutMe) + """

        Apply the writer's instruction to the passage. Change only what the instruction asks for. \
        Output only the resulting passage.
        """
        return [.system(sys), .user("Instruction: \(instruction)\n<passage>\n\(passage)\n</passage>")]
    }

    /// Search: answer the question so the answer can stand in its place in the sentence.
    static func searchSystem(voice: VoicePreset, aboutMe: String, grounded: Bool) -> String {
        persona(voice, aboutMe: aboutMe) + """

        The writer asked a question in the middle of their text. \
        \(grounded ? "Search the web for the answer." : "Answer from what you know; if you are not sure, say so briefly.") \
        Then write the answer so it can REPLACE the question in their text: it must read naturally with \
        the words before and after it (grammar, capitalization, tense, language) and be under 30 words. \
        Reply in exactly two lines:
        FIT: the replacement text
        ANSWER: the answer as one plain standalone sentence
        """
    }

    static func searchUser(question: String, before: String, after: String) -> String {
        """
        Text before the question: "\(before.suffix(500))"
        Question: \(question)
        Text after the question: "\(after.prefix(200))"
        """
    }

    static func search(question: String, before: String, after: String, voice: VoicePreset, aboutMe: String) -> [ChatMessage] {
        [.system(searchSystem(voice: voice, aboutMe: aboutMe, grounded: false)),
         .user(searchUser(question: question, before: before, after: after))]
    }
}
