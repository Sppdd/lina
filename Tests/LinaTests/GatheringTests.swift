import XCTest
@testable import Lina

final class GatheringTests: XCTestCase {
    private let ctx = WritingContext(before: "The launch was the summer my grandfather")

    func testLookUpUsesSourcesWhenGiven() {
        let src = WebLookup.Source(title: "Apollo 11", extract: "Apollo 11 landed on July 20, 1969.",
                                   url: URL(string: "https://en.wikipedia.org/wiki/Apollo_11")!)
        let msgs = Prompts.action(.lookUp, ctx: ctx, query: "When did Apollo 11 land?", voice: .journal,
                                  aboutMe: "", sources: [src])
        XCTAssertTrue(msgs[1].content.contains("<sources>"))
        XCTAssertTrue(msgs[1].content.contains("[1] Apollo 11: Apollo 11 landed on July 20, 1969."))
    }

    func testLookUpWithoutSourcesWarnsAgainstInventing() {
        let msgs = Prompts.action(.lookUp, ctx: ctx, query: "When did Apollo 11 land?", voice: .journal, aboutMe: "")
        XCTAssertFalse(msgs[1].content.contains("<sources>"))
        XCTAssertTrue(msgs[1].content.contains("Don't make up sources"))
    }

    func testGatheredPromptCarriesClippingsAndDraft() {
        let msgs = Prompts.action(.gathered, ctx: ctx, query: "", voice: .journal, aboutMe: "",
                                  gathered: "- [Safari] Apollo 11 landed on July 20, 1969.")
        XCTAssertTrue(msgs[1].content.contains("<clippings>\n- [Safari] Apollo 11"))
        XCTAssertTrue(msgs[1].content.contains("my grandfather"))
        XCTAssertEqual(WritingAction.gathered.outcome, .insert)
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
