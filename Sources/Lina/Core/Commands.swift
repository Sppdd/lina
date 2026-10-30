import Foundation

/// A `/lina …` command typed straight into any text field.
///
/// Lina never reads on her own. She acts when the writer types a command and "moves on" with
/// `.` `,` `?` `!` or Return, or when they finish a sentence (see `Sentences`).
struct LinaCommand: Equatable {
    enum Kind: Equatable {
        /// `/lina` alone: one short, meaningful question about what you wrote.
        case ask
        /// `/lina fix`: check the paragraph for typos, spelling and grammar.
        case fix
        /// `/lina rewrite [how]`: three rewrites of the paragraph to choose from.
        case rewrite(String)
        /// `/lina edit <instruction>`: the paragraph, changed the way you asked.
        case edit(String)
        /// `/lina model [filter]`: pick the text or image model.
        case model(String)
        /// `/lina image <prompt>`: a picture made by an image model.
        case image(String)
        /// `/lina help`: the list of commands.
        case help
        /// `/lina saved`: open what Lina has saved.
        case saved
        /// `/lina remember [this | note]`: keep a note about the writer, on this Mac.
        case remember(String)
        /// `/lina gathered [how]`: write the next lines from what the writer copied and screenshotted.
        case gathered(String)
        /// `/lina bug [what happened]`: a problem report about this exact moment.
        case bug(String)
        /// Anything else is a question for the web, answered so it fits your sentence.
        case search(String)
    }

    var kind: Kind
    /// The whole command in the field, from the slash to the caret (UTF-16 offsets).
    var range: NSRange
    /// What an answer replaces: the command without the punctuation the writer moved on with,
    /// so "…ended /lina who won last night, and…" keeps its comma.
    var bodyRange: NSRange
    /// The command exactly as typed (the text in `range`).
    var text: String
    /// The punctuation that ended it.
    var terminator: Character
}

enum CommandParser {
    static let trigger = "/lina"
    static let terminators: Set<Character> = [".", ",", "?", "!", "\n"]

    struct Help: Identifiable {
        let word: String
        let usage: String
        let detail: String
        var id: String { usage }
    }

    /// Every command, for help screens.
    static let words: [Help] = [
        Help(word: "", usage: "/lina ↩", detail: "Asks you one question about what you just wrote."),
        Help(word: "fix", usage: "/lina fix", detail: "Checks the paragraph; fixes appear above the mistakes."),
        Help(word: "rewrite", usage: "/lina rewrite [how]", detail: "Three rewrites of the paragraph, e.g. “rewrite warmer”."),
        Help(word: "edit", usage: "/lina edit <change>", detail: "Changes the paragraph the way you say."),
        Help(word: "model", usage: "/lina model", detail: "Lists Token Factory models; switch with ⌘1–⌘9."),
        Help(word: "image", usage: "/lina image <description>", detail: "Makes a picture you can drop into your text."),
        Help(word: "saved", usage: "/lina saved", detail: "Opens everything Lina has saved."),
        Help(word: "remember", usage: "/lina remember [note]", detail: "Remembers a note, or the paragraph above, for next time."),
        Help(word: "gathered", usage: "/lina gathered [how]", detail: "Writes on from the quotes and screenshots you gathered."),
        Help(word: "bug", usage: "/lina bug [what happened]", detail: "Writes a problem report about this moment."),
        Help(word: "help", usage: "/lina help", detail: "Shows this list."),
    ]

    /// Finds a finished command that ends at the caret: `/lina`, then anything, then a terminator.
    /// Trailing spaces after the terminator are allowed (some apps add one).
    static func command(in text: NSString, caret: Int) -> LinaCommand? {
        let caret = min(max(0, caret), text.length)
        guard caret > 0 else { return nil }
        // Look back a bounded distance for the trigger.
        let windowStart = max(0, caret - 600)
        let window = NSRange(location: windowStart, length: caret - windowStart)
        let found = text.range(of: trigger, options: [.backwards, .caseInsensitive], range: window)
        guard found.location != NSNotFound else { return nil }

        // The trigger must stand alone: not part of a URL or a longer word.
        if found.location > 0 {
            let prev = text.character(at: found.location - 1)
            if let s = Unicode.Scalar(prev), !CharacterSet.whitespacesAndNewlines.contains(s),
               !"([\"“'‘".unicodeScalars.contains(s) { return nil }
        }
        let afterTrigger = NSMaxRange(found)
        if afterTrigger < caret, let s = Unicode.Scalar(text.character(at: afterTrigger)) {
            let ok = CharacterSet.whitespaces.contains(s) || terminators.contains(Character(s))
            if !ok { return nil }
        }

        var end = caret
        // Ignore spaces the app put after the terminator.
        while end > afterTrigger, text.character(at: end - 1) == 0x20 { end -= 1 }
        guard end > found.location else { return nil }
        let full = NSRange(location: found.location, length: end - found.location)
        let typed = text.substring(with: full)
        guard let last = typed.last, terminators.contains(last) else { return nil }
        // A command lives on one line; a newline may only be the terminator.
        if typed.dropLast().contains(where: \.isNewline) { return nil }

        let body = String(typed.dropFirst(trigger.count).dropLast()).trimmingCharacters(in: .whitespaces)
        let kind = parse(body, terminator: last)
        // A question mark belongs to the question, so the answer replaces it too.
        let bodyLength = last == "?" ? full.length : full.length - 1
        return LinaCommand(kind: kind, range: NSRange(location: full.location, length: caret - full.location),
                           bodyRange: NSRange(location: full.location, length: bodyLength),
                           text: text.substring(with: NSRange(location: full.location, length: caret - full.location)),
                           terminator: last)
    }

    static func parse(_ body: String, terminator: Character = ".") -> LinaCommand.Kind {
        let trimmed = body.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return .ask }
        let parts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        let word = parts[0].lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ":"))
        let rest = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : ""
        switch word {
        case "ask", "question": return .ask
        case "fix", "proofread", "spell": return rest.isEmpty ? .fix : .edit(trimmed)
        case "check": return rest.isEmpty ? .fix : .search(trimmed + (terminator == "?" ? "?" : ""))
        case "rewrite", "rephrase": return .rewrite(rest)
        case "edit", "change", "make": return rest.isEmpty ? .rewrite("") : .edit(word == "make" ? trimmed : rest)
        case "model", "models": return .model(rest)
        case "image", "imagine", "draw", "picture": return .image(rest)
        case "help", "commands": return rest.isEmpty ? .help : .search(trimmed)
        case "saved", "history": return rest.isEmpty ? .saved : .search(trimmed)
        case "remember", "memorize": return .remember(rest)
        case "gathered", "research", "clippings", "clipboard": return .gathered(rest)
        case "bug", "report": return .bug(rest)
        case "search", "find", "google": return rest.isEmpty ? .help : .search(rest + (terminator == "?" ? "?" : ""))
        default: return .search(trimmed + (terminator == "?" ? "?" : ""))
        }
    }

    /// What the writer typed in the command bar, as a command. Trailing `.` `,` `!` are dropped; `?` is kept.
    static func parseBar(_ typed: String) -> LinaCommand.Kind {
        var body = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.lowercased().hasPrefix(trigger) { body = String(body.dropFirst(trigger.count)) }
        var terminator: Character = "."
        while let last = body.last, ".,!?".contains(last) {
            if last == "?" { terminator = "?" }
            body.removeLast()
        }
        return parse(body.trimmingCharacters(in: .whitespaces), terminator: terminator)
    }

    /// The paragraph a command works on: the text before it on the same line, or, when the
    /// command sits on its own line, the closest paragraph above it.
    static func target(for command: LinaCommand, in text: NSString) -> NSRange? {
        target(before: command.range.location, in: text)
    }

    /// The paragraph text right before `start` on its line, or the closest paragraph above it.
    static func target(before start: Int, in text: NSString) -> NSRange? {
        let start = min(max(0, start), text.length)
        let para = text.paragraphRange(for: NSRange(location: start, length: 0))
        let inline = trimmed(NSRange(location: para.location, length: start - para.location), in: text)
        if inline.length > 0 { return inline }
        var loc = para.location - 1
        while loc >= 0 {
            let prev = text.paragraphRange(for: NSRange(location: loc, length: 0))
            let content = trimmed(prev, in: text)
            if content.length > 0 { return content }
            loc = prev.location - 1
        }
        return nil
    }

    /// The text before the command, without the command itself (what a question is about).
    static func context(before command: LinaCommand, in text: NSString, limit: Int = 4000) -> String {
        let start = max(0, command.range.location - limit)
        return text.substring(with: NSRange(location: start, length: command.range.location - start))
    }

    /// The text after the command, up to the end of its paragraph.
    static func context(after command: LinaCommand, in text: NSString, limit: Int = 400) -> String {
        let end = NSMaxRange(command.range)
        let para = text.paragraphRange(for: NSRange(location: min(end, max(0, text.length - 1)), length: 0))
        let stop = min(text.length, min(NSMaxRange(para), end + limit))
        guard stop > end else { return "" }
        return text.substring(with: NSRange(location: end, length: stop - end))
    }

    /// `range` without leading and trailing whitespace or newlines.
    static func trimmed(_ range: NSRange, in text: NSString) -> NSRange {
        var lo = range.location
        var hi = NSMaxRange(range)
        let ws = CharacterSet.whitespacesAndNewlines
        while lo < hi, let s = Unicode.Scalar(text.character(at: lo)), ws.contains(s) { lo += 1 }
        while hi > lo, let s = Unicode.Scalar(text.character(at: hi - 1)), ws.contains(s) { hi -= 1 }
        return NSRange(location: lo, length: hi - lo)
    }
}

/// Finished sentences, for the check Lina runs when you type a dot.
enum Sentences {
    static let enders: Set<Character> = [".", "?", "!"]
    static let closers: Set<Character> = ["\"", "”", "’", "'", ")", "]"]

    /// The last sentence the writer finished at or before the caret.
    /// The caret may already be a word or two into the next sentence.
    static func lastFinished(in text: NSString, caret: Int, maxLookahead: Int = 80) -> NSRange? {
        let caret = min(max(0, caret), text.length)
        guard caret > 0 else { return nil }
        // Find the last ender followed by whitespace, a closer, or the caret.
        var i = caret - 1
        var endIndex: Int?
        while i >= 0, caret - i <= maxLookahead {
            let c = char(text, i)
            if enders.contains(c) {
                let next = i + 1 < text.length ? char(text, i + 1) : " "
                if i + 1 == caret || next.isWhitespace || closers.contains(next) {
                    // Skip decimals like 3.5 and ellipses mid-thought.
                    let prev = i > 0 ? char(text, i - 1) : " "
                    if !(c == "." && prev.isNumber && next.isNumber) {
                        var e = i + 1
                        while e < caret, closers.contains(char(text, e)) { e += 1 }
                        endIndex = e
                        break
                    }
                }
            }
            i -= 1
        }
        guard let end = endIndex else { return nil }
        // Walk back to the start of the sentence.
        var s = end - 1
        while s > 0 {
            let c = char(text, s - 1)
            if c == "\n" { break }
            if enders.contains(c), s < end - 1, char(text, s).isWhitespace || closers.contains(char(text, s)) { break }
            s -= 1
        }
        let range = CommandParser.trimmed(NSRange(location: s, length: end - s), in: text)
        let sentence = text.substring(with: range)
        guard range.length >= 8, range.length <= 800,
              WordCount.count(sentence) >= 3,
              !sentence.lowercased().contains(CommandParser.trigger)
        else { return nil }
        return range
    }

    /// The last few sentences finished before the caret (most recent last), so a writer who keeps
    /// typing past several full stops still gets each one checked.
    static func recentFinished(in text: NSString, caret: Int, limit: Int = 3) -> [NSRange] {
        var out: [NSRange] = []
        var end = min(max(0, caret), text.length)
        while out.count < limit, let r = lastFinished(in: text, caret: end, maxLookahead: 400) {
            if out.contains(where: { NSIntersectionRange($0, r).length > 0 }) { break }
            out.insert(r, at: 0)
            end = r.location
            if end == 0 { break }
        }
        return out
    }

    private static func char(_ text: NSString, _ i: Int) -> Character {
        guard let s = Unicode.Scalar(text.character(at: i)) else { return " " }
        return Character(s)
    }
}

/// What Lina found in a sentence: the mistakes, and fixed versions to choose from.
struct Proofread: Equatable {
    enum Kind: String, Equatable { case spelling, grammar, punctuation }

    struct Issue: Equatable {
        var wrong: String
        var right: String
        var kind: Kind
    }

    /// A mistake located in the original text, for highlighting.
    struct Mark: Equatable {
        var range: NSRange
        var kind: Kind
        var right: String
    }

    var issues: [Issue]
    /// Whole-passage versions, if the model sent them. Lina shows word fixes, not these.
    var options: [String] = []

    var isEmpty: Bool { issues.isEmpty }

    /// Reads the JSON the proofreading prompt asks for. Tolerates code fences and chatter around it.
    static func parse(_ raw: String, original: String) -> Proofread {
        guard let open = raw.firstIndex(of: "{"), let close = raw.lastIndex(of: "}"), open < close,
              let data = String(raw[open...close]).data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return Proofread(issues: [], options: []) }

        let issues: [Issue] = ((json["issues"] as? [[String: Any]]) ?? []).compactMap { item in
            guard let wrong = (item["wrong"] as? String)?.trimmingCharacters(in: .whitespaces), !wrong.isEmpty else { return nil }
            let right = (item["right"] as? String) ?? ""
            guard wrong != right else { return nil }
            let k = ((item["kind"] as? String) ?? "").lowercased()
            let kind: Kind = k.contains("punct") ? .punctuation : k.contains("gram") || k.contains("word") ? .grammar : .spelling
            return Issue(wrong: wrong, right: right, kind: kind)
        }
        let base = original.trimmingCharacters(in: .whitespacesAndNewlines)
        var options: [String] = []
        for key in ["fixed", "better"] {
            guard let s = (json[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !s.isEmpty, s != base, !options.contains(s) else { continue }
            options.append(s)
        }
        return Proofread(issues: issues, options: options)
    }

    /// Where each mistake sits in `original`, in reading order, without overlaps.
    func marks(in original: String) -> [Mark] {
        let ns = original as NSString
        var out: [Mark] = []
        var from = 0
        for issue in issues {
            var r = ns.range(of: issue.wrong, options: [], range: NSRange(location: from, length: ns.length - from))
            if r.location == NSNotFound { r = ns.range(of: issue.wrong) }
            guard r.location != NSNotFound,
                  !out.contains(where: { NSIntersectionRange($0.range, r).length > 0 }) else { continue }
            out.append(Mark(range: r, kind: issue.kind, right: issue.right))
            from = NSMaxRange(r)
        }
        return out.sorted { $0.range.location < $1.range.location }
    }

    /// The mistakes as fixes in the whole field, given where the checked passage starts.
    func fixes(in passage: String, at offset: Int) -> [Fix] {
        let ns = passage as NSString
        return marks(in: passage).map { m in
            Fix(range: NSRange(location: offset + m.range.location, length: m.range.length),
                wrong: ns.substring(with: m.range), right: m.right, kind: m.kind)
        }
    }
}

/// One mistake Lina can fix by itself: a word or two in the writer's text, and what goes in its place.
struct Fix: Equatable {
    /// Where the mistake is in the field's text (UTF-16 offsets).
    var range: NSRange
    var wrong: String
    var right: String
    var kind: Proofread.Kind
}

enum Fixes {
    /// After `applied` went in, moves the fixes behind it by how much it changed the length.
    static func shift(_ fixes: [Fix], after applied: Fix) -> [Fix] {
        let delta = (applied.right as NSString).length - applied.range.length
        return fixes.map { f in
            var f = f
            if f.range.location >= NSMaxRange(applied.range) { f.range.location += delta }
            return f
        }
    }

    /// One replacement covering every fix: the span from the first mistake to the last, with all of them corrected.
    /// `text` is the field's text the fixes point into.
    static func all(_ fixes: [Fix], in text: NSString) -> (span: NSRange, replacement: String)? {
        let sorted = fixes.sorted { $0.range.location < $1.range.location }
        guard let first = sorted.first, let last = sorted.last, NSMaxRange(last.range) <= text.length else { return nil }
        let span = NSRange(location: first.range.location, length: NSMaxRange(last.range) - first.range.location)
        var out = ""
        var at = span.location
        for f in sorted where f.range.location >= at {
            out += text.substring(with: NSRange(location: at, length: f.range.location - at))
            out += f.right
            at = NSMaxRange(f.range)
        }
        return (span, out)
    }
}

/// Model output shaped for the cards.
enum Answers {
    /// Splits "FIT: … / ANSWER: …" from the search prompt. Falls back to the whole text as the fit.
    static func fitAndAnswer(_ raw: String) -> (fit: String, answer: String) {
        var fit = "", answer = ""
        var inAnswer: Bool?
        for line in raw.components(separatedBy: .newlines) {
            var l = line.trimmingCharacters(in: .whitespaces)
            while let f = l.first, "*#-_• ".contains(f) { l.removeFirst() }
            let upper = l.uppercased()
            if upper.hasPrefix("FIT") {
                inAnswer = false
                fit = clip(l.dropFirst(3))
            } else if upper.hasPrefix("ANSWER") {
                inAnswer = true
                answer = clip(l.dropFirst(6))
            } else if let a = inAnswer, !l.isEmpty {
                if a { answer += (answer.isEmpty ? "" : " ") + l } else { fit += (fit.isEmpty ? "" : " ") + l }
            }
        }
        fit = unquote(fit)
        answer = unquote(answer)
        if fit.isEmpty { fit = unquote(raw.trimmingCharacters(in: .whitespacesAndNewlines)) }
        if answer.isEmpty { answer = fit }
        return (fit, answer)
    }

    /// Splits a list of alternatives separated by `---` lines or numbered "1." lines.
    static func options(_ raw: String, max: Int = 3) -> [String] {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        var parts: [String]
        if text.contains("\n---") || text.hasPrefix("---") {
            parts = text.components(separatedBy: "---")
        } else {
            parts = []
            var current = ""
            for line in text.components(separatedBy: .newlines) {
                let l = line.trimmingCharacters(in: .whitespaces)
                if let first = l.first, first.isNumber, l.dropFirst().first.map({ ".)".contains($0) }) == true {
                    if !current.isEmpty { parts.append(current) }
                    current = String(l.dropFirst(2))
                } else {
                    current += (current.isEmpty ? "" : "\n") + l
                }
            }
            if !current.isEmpty { parts.append(current) }
        }
        var out: [String] = []
        for p in parts {
            let s = unquote(p.trimmingCharacters(in: .whitespacesAndNewlines))
            if !s.isEmpty, !out.contains(s) { out.append(s) }
            if out.count == max { break }
        }
        return out
    }

    /// Joins an inserted answer to the words around it with natural spacing.
    static func fit(_ s: String, before: String, after: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return "" }
        if let last = before.last, !last.isWhitespace, let first = t.first, !".,;:!?)".contains(first) {
            t = " " + t
        }
        if let next = after.first, next.isLetter || next.isNumber, t.last.map({ !$0.isWhitespace }) == true {
            t += " "
        }
        // Don't double the punctuation the writer typed after the question.
        if let next = after.first, ".,;:!?".contains(next), let end = t.last, ".,;:!?".contains(end) {
            t.removeLast()
        }
        return t
    }

    private static func clip(_ s: Substring) -> String {
        var r = s
        while let f = r.first, ":*_ ".contains(f) { r.removeFirst() }
        return String(r)
    }

    private static func unquote(_ s: String) -> String {
        s.trimmingCharacters(in: CharacterSet(charactersIn: "\"“”`").union(.whitespacesAndNewlines))
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
