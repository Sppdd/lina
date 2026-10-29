import XCTest
@testable import Lina

final class CommandTests: XCTestCase {
    private func command(_ s: String) -> LinaCommand? {
        CommandParser.command(in: s as NSString, caret: (s as NSString).length)
    }

    func testSearchMidSentenceKeepsTheComma() throws {
        let s = "The final ended /lina who won last night,"
        let c = try XCTUnwrap(command(s))
        XCTAssertEqual(c.kind, .search("who won last night"))
        XCTAssertEqual(c.terminator, ",")
        XCTAssertEqual((s as NSString).substring(with: c.bodyRange), "/lina who won last night")
        XCTAssertEqual((s as NSString).substring(with: c.range), "/lina who won last night,")
    }

    func testQuestionMarkBelongsToTheQuestion() throws {
        let s = "/lina who won?"
        let c = try XCTUnwrap(command(s))
        XCTAssertEqual(c.kind, .search("who won?"))
        XCTAssertEqual((s as NSString).substring(with: c.bodyRange), "/lina who won?")
    }

    func testCommandWords() {
        XCTAssertEqual(command("I want to quit. /lina.")?.kind, .ask)
        XCTAssertEqual(command("/Lina fix.")?.kind, .fix)
        XCTAssertEqual(command("/lina rewrite warmer.")?.kind, .rewrite("warmer"))
        XCTAssertEqual(command("/lina rewrite.")?.kind, .rewrite(""))
        XCTAssertEqual(command("/lina edit make it formal.")?.kind, .edit("make it formal"))
        XCTAssertEqual(command("/lina image a cat in the rain.")?.kind, .image("a cat in the rain"))
        XCTAssertEqual(command("/lina imagine a red fox.")?.kind, .image("a red fox"))
        XCTAssertEqual(command("/lina model\n")?.kind, .model(""))
        XCTAssertEqual(command("/lina model flux.")?.kind, .model("flux"))
        XCTAssertEqual(command("/lina help.")?.kind, .help)
        XCTAssertEqual(command("/lina saved.")?.kind, .saved)
    }

    func testNeedsATerminator() {
        XCTAssertNil(command("/lina who won"))
        XCTAssertNil(command("/lina what is 3.5"))
    }

    func testTrailingSpaceAfterTerminator() throws {
        let c = try XCTUnwrap(command("Text /lina help. "))
        XCTAssertEqual(c.kind, .help)
        XCTAssertEqual(c.text, "/lina help. ")
    }

    func testTriggerMustStandAlone() {
        XCTAssertNil(command("see example.com/lina."))
        XCTAssertNil(command("/linax."))
    }

    func testCommandStaysOnOneLine() {
        XCTAssertNil(command("/lina who\nwon."))
    }

    func testTargetIsTheTextBeforeTheCommand() throws {
        let s = "hey can u send the report asap /lina rewrite polite." as NSString
        let c = try XCTUnwrap(CommandParser.command(in: s, caret: s.length))
        let t = try XCTUnwrap(CommandParser.target(for: c, in: s))
        XCTAssertEqual(s.substring(with: t), "hey can u send the report asap")
    }

    func testTargetIsTheParagraphAboveWhenAlone() throws {
        let s = "First para here.\n\n/lina fix." as NSString
        let c = try XCTUnwrap(CommandParser.command(in: s, caret: s.length))
        let t = try XCTUnwrap(CommandParser.target(for: c, in: s))
        XCTAssertEqual(s.substring(with: t), "First para here.")
    }

    func testFinishedSentence() throws {
        let s = "I realy like it. Next" as NSString
        let r = try XCTUnwrap(Sentences.lastFinished(in: s, caret: s.length))
        XCTAssertEqual(s.substring(with: r), "I realy like it.")
    }

    func testSentenceStartsAfterThePreviousOne() throws {
        let s = "It was late. She said she was fine?" as NSString
        let r = try XCTUnwrap(Sentences.lastFinished(in: s, caret: s.length))
        XCTAssertEqual(s.substring(with: r), "She said she was fine?")
    }

    func testRecentSentencesWhenTheWriterKeepsGoing() {
        let s = "First one is here. Second one too! Third is fine. Fourth" as NSString
        let found = Sentences.recentFinished(in: s, caret: s.length).map { s.substring(with: $0) }
        XCTAssertEqual(found, ["First one is here.", "Second one too!", "Third is fine."])
    }

    func testCommandBarText() {
        XCTAssertEqual(CommandParser.parseBar(""), .ask)
        XCTAssertEqual(CommandParser.parseBar("rewrite polite"), .rewrite("polite"))
        XCTAssertEqual(CommandParser.parseBar("who won the final, "), .search("who won the final"))
        XCTAssertEqual(CommandParser.parseBar("who won the final?"), .search("who won the final?"))
        XCTAssertEqual(CommandParser.parseBar("/lina model"), .model(""))
    }

    func testTargetBeforeTheCaret() throws {
        let s = "First para here.\n\nSecond one starts" as NSString
        let t = try XCTUnwrap(CommandParser.target(before: s.length, in: s))
        XCTAssertEqual(s.substring(with: t), "Second one starts")
    }

    func testShortOrCommandSentencesAreSkipped() {
        XCTAssertNil(Sentences.lastFinished(in: "Hi." as NSString, caret: 3))
        let cmd = "Tell me /lina who won." as NSString
        XCTAssertNil(Sentences.lastFinished(in: cmd, caret: cmd.length))
        XCTAssertNil(Sentences.lastFinished(in: "No ending here" as NSString, caret: 14))
    }
}
