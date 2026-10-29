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
        // An option identical to the original isn't a fix.
        let same = Proofread.parse(#"{"issues":[{"wrong":"x","right":"y"}],"fixed":"All good here."}"#, original: "All good here.")
        XCTAssertTrue(same.isEmpty)
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
