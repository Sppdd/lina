import XCTest
@testable import Lina

/// Memory, gathered clippings, Wikipedia lookups and problem reports, carried over from Lina 1.3.
final class PortedTests: XCTestCase {
    func testNewCommandWords() {
        XCTAssertEqual(CommandParser.parse("remember"), .remember(""))
        XCTAssertEqual(CommandParser.parse("remember my sister is Noor"), .remember("my sister is Noor"))
        XCTAssertEqual(CommandParser.parse("gathered"), .gathered(""))
        XCTAssertEqual(CommandParser.parse("research make it vivid"), .gathered("make it vivid"))
        XCTAssertEqual(CommandParser.parse("bug the card was empty"), .bug("the card was empty"))
    }

    func testRememberRunsFromTheText() throws {
        let s = "Noor is my sister. /lina remember this."
        let c = try XCTUnwrap(CommandParser.command(in: s as NSString, caret: (s as NSString).length))
        XCTAssertEqual(c.kind, .remember("this"))
    }

    func testSearchWithWikipediaPagesUsesOnlyThem() {
        let page = WebLookup.Source(title: "Apollo 11", extract: "Apollo 11 landed on July 20, 1969.",
                                    url: URL(string: "https://en.wikipedia.org/wiki/Apollo_11")!)
        let msgs = Prompts.search(question: "when did Apollo 11 land", before: "It was", after: "", voice: .journal,
                                  aboutMe: "", pages: [page])
        XCTAssertTrue(msgs[1].content.contains("<sources>\n[1] Apollo 11: Apollo 11 landed on July 20, 1969."))
        XCTAssertFalse(Prompts.search(question: "q", before: "", after: "", voice: .journal, aboutMe: "")[1]
            .content.contains("<sources>"))
    }

    func testGatheredPromptCarriesClippingsAndDraft() {
        let msgs = Prompts.gathered(before: "The summer my grandfather turned twelve,",
                                    clippings: "- [Safari] Apollo 11 landed on July 20, 1969.", how: "",
                                    voice: .journal, aboutMe: "")
        XCTAssertTrue(msgs[1].content.contains("<clippings>\n- [Safari] Apollo 11"))
        XCTAssertTrue(msgs[1].content.contains("my grandfather"))
    }

    func testWikipediaLanguageFollowsTheQuestion() {
        XCTAssertEqual(WebLookup.language(of: "When did the first moon landing happen?"), "en")
        XCTAssertEqual(WebLookup.language(of: "Quand a eu lieu le premier alunissage ?"), "fr")
        XCTAssertEqual(WebLookup.language(of: "short"), "en")
    }

    @MainActor
    func testRecommendedModelIsASuggestion() {
        XCTAssertTrue(LocalModels.suggestions.contains { $0.name == LocalModels.recommended.name })
    }
}
