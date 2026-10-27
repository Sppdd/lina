import XCTest
@testable import Lina

@MainActor
final class DeskTextViewTests: XCTestCase {
    func testGhostIsNotPartOfTheTextUntilAccepted() {
        let (_, tv) = DeskTextView.make()
        tv.load("Title\nThe rain stopped and ")
        tv.showGhost("the city held its breath.")
        XCTAssertEqual(tv.ghostText, "the city held its breath.")
        XCTAssertEqual(tv.cleanString, "Title\nThe rain stopped and ")

        tv.acceptGhost(wordOnly: true)
        XCTAssertEqual(tv.cleanString, "Title\nThe rain stopped and the")
        XCTAssertEqual(tv.ghostText, " city held its breath.")

        tv.acceptGhost()
        XCTAssertEqual(tv.string, "Title\nThe rain stopped and the city held its breath.")
        XCTAssertNil(tv.ghostRange)
    }

    func testClearGhostRestoresText() {
        let (_, tv) = DeskTextView.make()
        tv.load("Hello there, ")
        tv.showGhost("friend.")
        tv.clearGhost()
        XCTAssertEqual(tv.string, "Hello there, ")
        XCTAssertEqual(tv.selectedRange().location, 13)
    }
}
