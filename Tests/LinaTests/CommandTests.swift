import XCTest
@testable import Lina

final class CommandTests: XCTestCase {
    private func find(_ s: String) -> LinaCommand? {
        LinaCommand.find(in: s as NSString, caret: (s as NSString).length)
    }

    func testCommandOnItsOwnLineTargetsParagraphAbove() throws {
        let text = "First paragraph.\n\ni went to the store and it was closed so i came home\n/lina edit this paragraph"
        let cmd = try XCTUnwrap(find(text))
        XCTAssertEqual(cmd.instruction, "edit this paragraph")
        XCTAssertEqual(cmd.kind, .write)
        XCTAssertEqual(cmd.targetText, "i went to the store and it was closed so i came home")
        XCTAssertEqual(cmd.gap, "\n")
        XCTAssertFalse(cmd.targetOnSameLine)
        let ns = text as NSString
        XCTAssertEqual(ns.substring(with: cmd.range), "/lina edit this paragraph")
        XCTAssertEqual(ns.substring(with: cmd.replaceRange),
                       "i went to the store and it was closed so i came home\n/lina edit this paragraph")
    }

    func testCommandAfterTextOnTheSameLine() throws {
        let cmd = try XCTUnwrap(find("their going too the park /lina fix this"))
        XCTAssertEqual(cmd.targetText, "their going too the park")
        XCTAssertEqual(cmd.gap, " ")
        XCTAssertTrue(cmd.targetOnSameLine)
    }

    func testNoCommand() {
        XCTAssertNil(find("just writing about /linage and lineage"))
        XCTAssertNil(find("ends with /lina "))
        XCTAssertNil(find("path/lina edit"))
        // The command has to be on the caret's line.
        XCTAssertNil(find("/lina edit this\nand then more writing"))
    }

    func testEmptyDocumentHasNoTarget() throws {
        let cmd = try XCTUnwrap(find("/lina write a haiku about rain"))
        XCTAssertEqual(cmd.target.length, 0)
        XCTAssertEqual(cmd.replaceRange, cmd.range)
    }

    func testKinds() {
        XCTAssertEqual(LinaCommand.classify("turn this description to a photo"), .image)
        XCTAssertEqual(LinaCommand.classify("draw this scene"), .image)
        XCTAssertEqual(LinaCommand.classify("remember this"), .remember)
        XCTAssertEqual(LinaCommand.classify("save this to memory"), .remember)
        XCTAssertEqual(LinaCommand.classify("make it shorter"), .write)
        XCTAssertEqual(LinaCommand.classify("write the next paragraph"), .write)
        XCTAssertEqual(LinaCommand.classify("bug it rewrote the wrong sentence"), .report)
        XCTAssertEqual(LinaCommand.classify("report"), .report)
        XCTAssertEqual(LinaCommand.classify("report on the quarterly numbers"), .write)
        XCTAssertEqual(LinaCommand.classify("write a report about rain"), .write)
    }

    func testMemoryText() throws {
        let pointing = try XCTUnwrap(find("My sister is called Noor.\n/lina remember this"))
        XCTAssertEqual(pointing.memoryText, "My sister is called Noor.")
        let said = try XCTUnwrap(find("/lina remember that I write in British English"))
        XCTAssertEqual(said.memoryText, "I write in British English")
    }

    func testReportNote() throws {
        let cmd = try XCTUnwrap(find("/lina bug: the drop vanished"))
        XCTAssertEqual(cmd.reportNote, "the drop vanished")
    }

    func testReplyParsing() {
        XCTAssertEqual(CommandReply.parse("REPLACE\nI went to the store.", hasTarget: true),
                       CommandReply(replace: true, text: "I went to the store."))
        XCTAssertEqual(CommandReply.parse("INSERT: Rain on tin,", hasTarget: true),
                       CommandReply(replace: false, text: "Rain on tin,"))
        XCTAssertEqual(CommandReply.parse("**REPLACE**\nShorter.", hasTarget: true),
                       CommandReply(replace: true, text: "Shorter."))
        // Nothing to replace: always insert.
        XCTAssertEqual(CommandReply.parse("REPLACE\nA poem.", hasTarget: false),
                       CommandReply(replace: false, text: "A poem."))
        XCTAssertEqual(CommandReply.parse("Just text", hasTarget: true),
                       CommandReply(replace: false, text: "Just text"))
    }
}
