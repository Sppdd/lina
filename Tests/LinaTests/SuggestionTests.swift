import XCTest
@testable import Lina

final class SuggestionTests: XCTestCase {
    func testJoinAfterSpaceTrimsLeadingSpace() {
        XCTAssertEqual(Suggestion.joinSpacing("  and then", before: "I walked "), "and then")
    }

    func testJoinAfterPunctuationAddsSpace() {
        XCTAssertEqual(Suggestion.joinSpacing("but it rained", before: "I walked,"), " but it rained")
        XCTAssertEqual(Suggestion.joinSpacing(".", before: "I walked,"), ".")
    }

    func testCleanKeepsFirstLineAndStripsQuotes() {
        let s = Suggestion.clean("\"the river was cold\"\nsecond line", before: "We swam until ", length: .sentence)
        XCTAssertEqual(s, "the river was cold")
    }

    func testCleanCapsWords() {
        let s = Suggestion.clean("one two three four five six seven eight nine", before: "Go ", length: .words)
        XCTAssertLessThanOrEqual(s.split(separator: " ").count, 7)
    }

    func testGoodMoment() {
        XCTAssertTrue(Suggestion.isGoodMoment(before: "Today I finally went to the ", after: ""))
        XCTAssertFalse(Suggestion.isGoodMoment(before: "Today I finally went to th", after: ""))
        XCTAssertFalse(Suggestion.isGoodMoment(before: "Short ", after: ""))
        XCTAssertFalse(Suggestion.isGoodMoment(before: "Today I finally went to the ", after: "park"))
        XCTAssertTrue(Suggestion.isGoodMoment(before: "Today I finally went to the ", after: "\nNext"))
    }

    func testOptionsParsing() {
        let opts = Suggestion.options("1. luminous\n- radiant\n• glowing\n\nluminous\n\"bright\"")
        XCTAssertEqual(opts, ["luminous", "radiant", "glowing", "bright"])
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
