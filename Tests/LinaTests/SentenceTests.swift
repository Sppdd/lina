import XCTest
@testable import Lina

final class SentenceTests: XCTestCase {
    private func find(_ s: String, finishedOnly: Bool = true, caret: Int? = nil) -> Sentence.Found? {
        let ns = s as NSString
        return Sentence.find(in: ns, caret: caret ?? ns.length, finishedOnly: finishedOnly)
    }

    func testFindsTheSentenceJustFinished() {
        let f = find("It was late. i dont know why i keep waiting. ")
        XCTAssertEqual(f?.text, "i dont know why i keep waiting.")
        XCTAssertEqual(f?.trailing, " ")
        XCTAssertEqual(f?.range, NSRange(location: 13, length: 32))
    }

    func testWaitsForTheEndOfTheSentence() {
        XCTAssertNil(find("It was late. i dont know why i keep"))
        XCTAssertNil(find("Too short. "))
        // Something already follows the caret on this line.
        XCTAssertNil(find("I went to the shop today. And then", caret: 26))
    }

    func testClosingQuotesStillEndASentence() {
        XCTAssertEqual(find("She told me \"go home now.\"")?.text, "She told me \"go home now.\"")
    }

    func testOnlyLooksAtTheCurrentParagraph() {
        XCTAssertEqual(find("First line here is done.\nSecond line is now over too.")?.text, "Second line is now over too.")
        XCTAssertNil(find("First line here is done.\n"))
    }

    func testOnDemandTakesAnUnfinishedSentence() {
        let f = find("It was late. i dont know why i keep", finishedOnly: false)
        XCTAssertEqual(f?.text, "i dont know why i keep")
        XCTAssertEqual(f?.trailing, "")
    }

    func testCleanStripsQuotesAndTags() {
        XCTAssertEqual(Sentence.clean("<sentence>\"I don't know.\"</sentence>\nExplanation", original: "i dont know."),
                       "I don't know.")
        XCTAssertEqual(Sentence.clean("\"Go.\" she said.", original: "\"go.\" she said."), "\"Go.\" she said.")
    }
}

extension SentenceTests {
    func testAbbreviationsDontSplit() {
        XCTAssertEqual(find("I saw Dr. Patel at the shop today.")?.text, "I saw Dr. Patel at the shop today.")
    }

    func testOnDemandMidSentenceRunsToItsEnd() {
        let s = "It was late. i dont know why i keep waiting for him. Then"
        let f = find(s, finishedOnly: false, caret: 25)
        XCTAssertEqual(f?.text, "i dont know why i keep waiting for him.")
        XCTAssertEqual(f?.range.location, 13)
    }
}
