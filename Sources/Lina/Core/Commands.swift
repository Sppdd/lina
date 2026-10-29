import Foundation

/// `/lina <instruction>` typed anywhere the writer writes, then Return. Lina works on "this" (the text
/// before the command on its line, or the paragraph above it) and writes the result right there.
struct LinaCommand: Equatable {
    enum Kind: Equatable {
        /// Rewrite "this", or write something new at the command.
        case write
        /// Turn "this" (or the instruction itself) into a picture.
        case image
        /// Save "this" (or what follows "remember") to Lina's memory.
        case remember
        /// `/lina bug …`: something went wrong. Lina writes a problem report about this exact moment.
        case report
    }

    /// What the writer asked for, after "/lina".
    var instruction: String
    var kind: Kind
    /// "/lina …" itself, up to the caret (UTF-16, as Accessibility reports it).
    var range: NSRange
    /// What "this" refers to, trimmed. Empty when there's nothing before the command.
    var target: NSRange
    var targetText: String
    /// Whatever sits between the target and the command (a space, or the line breaks above it).
    var gap: String

    /// Replacing "this": everything from the start of the target to the caret.
    var replaceRange: NSRange {
        guard target.length > 0 else { return range }
        return NSRange(location: target.location, length: NSMaxRange(range) - target.location)
    }

    /// Whether the target shares the command's line ("my sentence /lina fix this").
    var targetOnSameLine: Bool { target.length > 0 && !gap.contains(where: \.isNewline) }

    /// The `/lina` command that ends at the caret, if there is one.
    static func find(in text: NSString, caret: Int) -> LinaCommand? {
        let c = max(0, min(caret, text.length))
        let line = text.lineRange(for: NSRange(location: c, length: 0))
        let prefix = text.substring(with: NSRange(location: line.location, length: c - line.location)) as NSString
        // The last "/lina" on the line that starts a word.
        var search = NSRange(location: 0, length: prefix.length)
        var slash = NSNotFound
        while true {
            let r = prefix.range(of: "/lina", options: [.caseInsensitive, .backwards], range: search)
            guard r.location != NSNotFound else { break }
            let startsWord = r.location == 0 || isSpace(prefix.character(at: r.location - 1))
            let after = NSMaxRange(r)
            let endsWord = after < prefix.length && isSpace(prefix.character(at: after))
            if startsWord && endsWord { slash = r.location; break }
            search = NSRange(location: 0, length: r.location)
        }
        guard slash != NSNotFound else { return nil }
        let instruction = prefix.substring(from: slash + 5).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else { return nil }

        let start = line.location + slash
        let range = NSRange(location: start, length: c - start)
        // "this" is the text before the command on its line, or else the paragraph above.
        var target = NSRange(location: start, length: 0)
        let before = text.substring(with: NSRange(location: line.location, length: slash))
        if !before.trimmingCharacters(in: .whitespaces).isEmpty {
            target = trimmed(NSRange(location: line.location, length: slash), in: text)
        } else {
            var e = line.location
            while e > 0, isSpace(text.character(at: e - 1)) { e -= 1 }
            if e > 0 {
                target = trimmed(text.paragraphRange(for: NSRange(location: e - 1, length: 0)), in: text)
            }
        }
        let targetText = target.length > 0 ? text.substring(with: target) : ""
        let gapStart = target.length > 0 ? NSMaxRange(target) : start
        let gap = text.substring(with: NSRange(location: gapStart, length: start - gapStart))
        return LinaCommand(instruction: instruction, kind: classify(instruction), range: range,
                           target: target, targetText: targetText, gap: gap)
    }

    static func classify(_ instruction: String) -> Kind {
        let s = instruction.lowercased()
        if s.range(of: #"^(bug|issue|problem|broken|report)\b(?!\s+(about|on|for|of)\b)"#, options: .regularExpression) != nil {
            return .report
        }
        if s.range(of: #"^(please\s+)?(remember|memori[sz]e|save|keep|note)\b"#, options: .regularExpression) != nil
            || s.range(of: #"\b(to|in|into) (your |my )?memory\b"#, options: .regularExpression) != nil {
            return .remember
        }
        if s.range(of: #"\b(photo|photograph|image|picture|pic|illustration|illustrate|drawing|draw|sketch|painting|artwork|render|visuali[sz]e)\b"#,
                   options: .regularExpression) != nil {
            return .image
        }
        return .write
    }

    /// What to save for `/lina remember …`: the words after "remember", unless they just point at "this".
    var memoryText: String {
        var s = instruction
        if let r = s.range(of: #"^(please\s+)?(remember|memori[sz]e|save|keep|note)(\s+(that|this|it))?\b[:,]?\s*"#,
                           options: [.regularExpression, .caseInsensitive]) {
            s.removeSubrange(r)
        }
        if let r = s.range(of: #"\s*\b(to|in|into) (your |my )?memory\b"#, options: [.regularExpression, .caseInsensitive]) {
            s.removeSubrange(r)
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        let pointsAtThis = s.isEmpty || s.lowercased().range(
            of: #"^(this|that|it|the above|above|this (paragraph|sentence|line|note|part|text))$"#,
            options: .regularExpression) != nil
        return pointsAtThis ? targetText : s
    }

    /// What the writer said went wrong, after "bug".
    var reportNote: String {
        var s = instruction
        if let r = s.range(of: #"^(bug|issue|problem|broken|report)\b[:,]?\s*"#, options: [.regularExpression, .caseInsensitive]) {
            s.removeSubrange(r)
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func trimmed(_ r: NSRange, in text: NSString) -> NSRange {
        var r = r
        while r.length > 0, isSpace(text.character(at: r.location)) { r.location += 1; r.length -= 1 }
        while r.length > 0, isSpace(text.character(at: NSMaxRange(r) - 1)) { r.length -= 1 }
        return r
    }

    private static func isSpace(_ u: unichar) -> Bool {
        u == 0x20 || u == 0x09 || u == 0x0A || u == 0x0D || u == 0x2028 || u == 0x2029 || u == 0xA0
    }
}

/// The model's answer to a `/lina` command: replace "this", or insert new text at the command.
struct CommandReply: Equatable {
    var replace: Bool
    var text: String

    static func parse(_ raw: String, hasTarget: Bool) -> CommandReply {
        var s = raw.replacingOccurrences(of: "\r", with: "").trimmingCharacters(in: .whitespacesAndNewlines)
        // Drop a code fence around the whole answer.
        if s.hasPrefix("```") {
            s = s.components(separatedBy: "\n").dropFirst().joined(separator: "\n")
            if s.hasSuffix("```") { s = String(s.dropLast(3)) }
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var replace = false
        for (tag, isReplace) in [("REPLACE", true), ("INSERT", false)] {
            let head = s.prefix(tag.count + 2).uppercased()
            guard head.hasPrefix(tag) || head.hasPrefix("**" + tag) else { continue }
            s = String(s.dropFirst(head.hasPrefix("**") ? tag.count + 2 : tag.count))
            s = String(s.drop { "*: \t".contains($0) })
            replace = isReplace
            break
        }
        return CommandReply(replace: replace && hasTarget, text: s.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

extension Prompts {
    /// `/lina <instruction>`: edit "this" or write something new where the command was typed.
    static func command(_ instruction: String, target: String, before: String, after: String,
                        voice: VoicePreset, aboutMe: String) -> [ChatMessage] {
        let sys = persona(voice, aboutMe: aboutMe) + """

        The writer typed a command for you into their document: "/lina <instruction>". Do what it asks.
        If it asks you to change the text it refers to (edit, rewrite, fix, shorten, expand, translate, \
        turn it into a list…), answer with the word REPLACE on the first line and then only the new \
        version of that text. If it asks for new writing (write, add, draft, continue, give ideas…), \
        answer with the word INSERT on the first line and then only the text to put where the command is. \
        Match the formatting of the document: plain text, no markdown unless the document uses it. \
        No commentary, no quotes around the text.
        """
        var user = ""
        let context = before.suffix(3000).trimmingCharacters(in: .whitespacesAndNewlines)
        if !context.isEmpty { user += "The document so far:\n<document>\n\(context)\n</document>\n" }
        let rest = after.prefix(800).trimmingCharacters(in: .whitespacesAndNewlines)
        if !rest.isEmpty { user += "What comes after the command:\n<after>\n\(rest)\n</after>\n" }
        if !target.isEmpty { user += "The text the command refers to (\"this\"):\n<this>\n\(target)\n</this>\n" }
        user += "The command: /lina \(instruction)"
        return [.system(sys), .user(user)]
    }

    /// Turns the writer's description into a prompt for a text-to-image model.
    static func imagePrompt(description: String, instruction: String) -> [ChatMessage] {
        let sys = """
        You write prompts for a text-to-image model. Given a writer's description and what they asked \
        for, write one vivid prompt in English, under 70 words: the subject, setting, light, mood and \
        style (a photo unless they asked for another style). Keep every concrete detail from the \
        description. Output only the prompt.
        """
        var user = "What they asked: \(instruction)"
        if !description.isEmpty { user += "\nTheir description:\n\(description.prefix(2000))" }
        return [.system(sys), .user(user)]
    }
}
