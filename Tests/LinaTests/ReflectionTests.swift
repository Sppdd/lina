import XCTest
@testable import Lina

final class ReflectionTests: XCTestCase {
    func testParsesTaggedLines() {
        let r = Reflection.parse("""
        HEARING: You miss him.
        WHY: You never said goodbye.
        ASK: What would you say now?
        NEXT: The empty chair.
        QUOTE: "the empty chair at dinner"
        """)
        XCTAssertEqual(r.hearing, "You miss him.")
        XCTAssertEqual(r.why, "You never said goodbye.")
        XCTAssertEqual(r.ask, "What would you say now?")
        XCTAssertEqual(r.next, "The empty chair.")
        XCTAssertEqual(r.quote, "the empty chair at dinner")
    }

    func testToleratesMarkdownAndWrappedLines() {
        let r = Reflection.parse("**Hearing:** You miss him,\nand it shows.\n- **Ask**: Why now?")
        XCTAssertEqual(r.hearing, "You miss him, and it shows.")
        XCTAssertEqual(r.ask, "Why now?")
        XCTAssertTrue(r.why.isEmpty)
    }

    func testPartialStream() {
        let r = Reflection.parse("HEARING: You miss")
        XCTAssertEqual(r.hearing, "You miss")
        XCTAssertFalse(r.isEmpty)
        XCTAssertTrue(Reflection.parse("").isEmpty)
    }
}
