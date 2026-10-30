import XCTest
@testable import Lina

final class AnswerTests: XCTestCase {
    func testProofreadParsesFencedJSON() {
        let raw = """
        ```json
        {"issues":[{"wrong":"realy","right":"really","kind":"spelling"},{"wrong":"you're","right":"your","kind":"grammar"}],
         "fixed":"Thanks for your help, I really like it.","better":"Thanks for your help. I really like it."}
        ```
        """
        let original = "Thanks for you're help, I realy like it."
        let p = Proofread.parse(raw, original: original)
        XCTAssertEqual(p.issues.count, 2)
        XCTAssertEqual(p.options, ["Thanks for your help, I really like it.", "Thanks for your help. I really like it."])
        let marks = p.marks(in: original)
        XCTAssertEqual(marks.map { (original as NSString).substring(with: $0.range) }, ["you're", "realy"])
        XCTAssertEqual(marks.first?.kind, .grammar)
    }

    func testProofreadWithNoMistakesIsEmpty() {
        XCTAssertTrue(Proofread.parse(#"{"issues":[]}"#, original: "All good here.").isEmpty)
        XCTAssertTrue(Proofread.parse("Looks fine to me!", original: "All good here.").isEmpty)
        // A "mistake" that isn't in the sentence gives no fix to show.
        let phantom = Proofread.parse(#"{"issues":[{"wrong":"x","right":"y"}]}"#, original: "All good here.")
        XCTAssertTrue(phantom.fixes(in: "All good here.", at: 0).isEmpty)
    }

    func testFixesPointIntoTheField() {
        let sentence = "I realy like it."
        let p = Proofread.parse(#"{"issues":[{"wrong":"realy","right":"really","kind":"spelling"}]}"#, original: sentence)
        let fixes = p.fixes(in: sentence, at: 10)
        XCTAssertEqual(fixes, [Fix(range: NSRange(location: 12, length: 5), wrong: "realy", right: "really", kind: .spelling)])
    }

    func testShiftAfterOneFixGoesIn() {
        let a = Fix(range: NSRange(location: 2, length: 5), wrong: "realy", right: "really", kind: .spelling)
        let b = Fix(range: NSRange(location: 13, length: 3), wrong: "teh", right: "the", kind: .spelling)
        let shifted = Fixes.shift([b], after: a)
        XCTAssertEqual(shifted.first?.range, NSRange(location: 14, length: 3))
    }

    func testFixAllIsOneReplacement() throws {
        let text = "Thank you for you're help, I realy apreciate it." as NSString
        let fixes = [("you're", "your"), ("realy", "really"), ("apreciate", "appreciate")].map { w, r in
            Fix(range: text.range(of: w), wrong: w, right: r, kind: .spelling)
        }
        let all = try XCTUnwrap(Fixes.all(fixes, in: text))
        XCTAssertEqual(text.substring(with: all.span), "you're help, I realy apreciate")
        XCTAssertEqual(all.replacement, "your help, I really appreciate")
    }

    func testFitAndAnswer() {
        let (fit, answer) = Answers.fitAndAnswer("**FIT:** with Argentina winning on penalties\nANSWER: Argentina won the 2022 final.")
        XCTAssertEqual(fit, "with Argentina winning on penalties")
        XCTAssertEqual(answer, "Argentina won the 2022 final.")
        XCTAssertEqual(Answers.fitAndAnswer("\"Lima\"").fit, "Lima")
    }

    func testOptions() {
        XCTAssertEqual(Answers.options("One.\n---\nTwo.\n---\nThree.\n---\nFour."), ["One.", "Two.", "Three."])
        XCTAssertEqual(Answers.options("1. First way\n2) Second way"), ["First way", "Second way"])
    }

    func testFitSpacing() {
        XCTAssertEqual(Answers.fit("with Argentina winning", before: "The final ended", after: ", and"), " with Argentina winning")
        XCTAssertEqual(Answers.fit("Lima.", before: "The capital is ", after: "."), "Lima")
        XCTAssertEqual(Answers.fit("Lima", before: "", after: "is lovely"), "Lima ")
    }

    func testModelCatalog() {
        XCTAssertEqual(ModelCatalog.kind(of: "black-forest-labs/flux-schnell"), .image)
        XCTAssertEqual(ModelCatalog.kind(of: "nvidia/nemotron-3-super-120b-a12b"), .text)
        XCTAssertNil(ModelCatalog.kind(of: "BAAI/bge-en-icl"))
        let items = ModelCatalog.items(["meta-llama/Llama-3.3-70B-Instruct", "nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B", "BAAI/bge-m3"])
        XCTAssertEqual(items.map(\.id), ["nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B", "meta-llama/Llama-3.3-70B-Instruct"])
        XCTAssertEqual(items.first?.shortName, "NVIDIA-Nemotron-3-Nano-30B-A3B")
    }

    func testGeminiResponse() {
        let json = """
        {"candidates":[{"content":{"parts":[{"text":"FIT: Lima\\n"},{"text":"ANSWER: Lima is the capital of Peru."}]},
          "groundingMetadata":{"webSearchQueries":["capital of peru"],
            "groundingChunks":[{"web":{"uri":"https://vertexaisearch.cloud.google.com/a","title":"britannica.com"}},
                               {"web":{"uri":"https://vertexaisearch.cloud.google.com/b","title":"britannica.com"}},
                               {"web":{"uri":"https://vertexaisearch.cloud.google.com/c","title":"wikipedia.org"}}]}}]}
        """
        let a = GeminiClient.parse(Data(json.utf8))
        XCTAssertEqual(a.text, "FIT: Lima\nANSWER: Lima is the capital of Peru.")
        XCTAssertEqual(a.sources.map(\.site), ["britannica.com", "wikipedia.org"])
        XCTAssertEqual(a.queries, ["capital of peru"])
        XCTAssertEqual(a.suggestionsHTML, "")
    }

    func testGeminiSearchSuggestionsAreKept() {
        let json = """
        {"candidates":[{"content":{"parts":[{"text":"FIT: Lima"}]},
          "groundingMetadata":{"searchEntryPoint":{"renderedContent":"<div class=\\"chip\\">capital of peru</div>"}}}]}
        """
        let a = GeminiClient.parse(Data(json.utf8))
        XCTAssertEqual(a.suggestionsHTML, "<div class=\"chip\">capital of peru</div>")
    }

    func testGeminiRequestKeepsThinkingShort() {
        let three = GeminiClient.body(model: "gemini-3.5-flash-lite", system: "s", prompt: "p")
        let config3 = three["generationConfig"] as? [String: Any]
        XCTAssertEqual((config3?["thinkingConfig"] as? [String: String])?["thinkingLevel"], "low")
        XCTAssertNotNil(three["tools"])
        let old = GeminiClient.body(model: "gemini-2.5-flash", system: "s", prompt: "p")
        let config25 = old["generationConfig"] as? [String: Any]
        XCTAssertEqual((config25?["thinkingConfig"] as? [String: Int])?["thinkingBudget"], 0)
    }

    func testServerRefusalsReadAsPlainWords() {
        let body = #"{"error":"You've used today's 20 searches. They come back at midnight UTC."}"#
        XCTAssertEqual(LLMError.http(429, body).errorDescription, "You've used today's 20 searches. They come back at midnight UTC.")
        XCTAssertEqual(LLMError.http(403, #"{"error":"flux-dev isn't available for pictures."}"#).errorDescription,
                       "flux-dev isn't available for pictures.")
        XCTAssertEqual(LLMError.http(429, "slow down").errorDescription, "Lina is busy right now. Try again in a moment.")
    }

    func testAccountUsageAndAuthErrors() {
        let usage = Account.usage(from: ["plan": "free", "usage": [
            ["kind": "search", "used": 3, "limit": 20],
            ["kind": "image", "used": 0, "limit": 5],
        ]])
        XCTAssertEqual(usage.plan, "free")
        XCTAssertEqual(usage.lines.map(\.kind), ["search", "image"])
        XCTAssertEqual(usage.lines.first?.used, 3)
        XCTAssertEqual(Account.message(["msg": "Token has expired or is invalid"], code: 403),
                       "That code didn't work or has expired. Ask for a new one.")
        XCTAssertEqual(Account.message(["msg": "For security purposes, you can only request this after 30 seconds."], code: 429),
                       "Too many codes asked for. Wait a minute, then try again.")
    }

    func testThinkFilterAcrossChunks() {
        var f = ThinkFilter()
        var out = ""
        for piece in ["Hel", "lo <thi", "nk>secret plan</th", "ink> world", "<", "b>"] { out += f.feed(piece) }
        XCTAssertEqual(out, "Hello  world<b>")
    }

    func testWordCount() {
        XCTAssertEqual(WordCount.count("It's a quiet, small room."), 5)
    }
}
