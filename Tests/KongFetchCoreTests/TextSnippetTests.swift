import XCTest
@testable import KongFetchCore

final class TextSnippetTests: XCTestCase {
    private func snippet(_ keyword: String) -> TextSnippet {
        TextSnippet(name: keyword, keyword: keyword, content: "x")
    }

    func testExpanderFiresOnKeyword() {
        let a = snippet(";qm"), b = snippet("addr")
        var expander = SnippetExpander()
        expander.setSnippets([a, b, snippet("x"), snippet("a b")])
        XCTAssertNil(expander.type("hello ;q"))
        let hit = expander.type("m")
        XCTAssertEqual(hit?.id, a.id)
        XCTAssertEqual(hit?.keywordLength, 3)
        // The buffer is cleared after a hit.
        XCTAssertNil(expander.type("m"))
        XCTAssertEqual(expander.type("my addr")?.id, b.id)
    }

    func testBackspaceResetAndNewline() {
        let a = snippet(";qm")
        var expander = SnippetExpander()
        expander.setSnippets([a])
        XCTAssertNil(expander.type(";qx"))
        expander.deleteBackward()
        XCTAssertEqual(expander.type("m")?.id, a.id)
        XCTAssertNil(expander.type(";q"))
        expander.reset()
        XCTAssertNil(expander.type("m"))
        XCTAssertNil(expander.type(";q\nm"))
    }

    func testLongestKeywordWins() {
        let short = snippet("lk"), long = snippet(";lk")
        var expander = SnippetExpander()
        expander.setSnippets([short, long])
        XCTAssertEqual(expander.type(";lk")?.id, long.id)
        XCTAssertEqual(expander.type("lk")?.id, short.id)
    }

    func testTemplatePlaceholders() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let date = calendar.date(from: DateComponents(year: 2026, month: 10, day: 8, hour: 14, minute: 5))!
        let rendered = SnippetTemplate.render("{日期} {date} {time} {weekday} [{clipboard}] 第{cursor}页。", now: date,
                                              clipboard: "学而", calendar: calendar)
        XCTAssertEqual(rendered.text, "2026年10月8日 2026-10-08 14:05 星期四 [学而] 第页。")
        XCTAssertEqual(rendered.cursorOffsetFromEnd, 2)
        XCTAssertEqual(SnippetTemplate.render("abc").cursorOffsetFromEnd, 0)
    }

    func testStoreRoundTripAndCorruptFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = dir.appendingPathComponent("snippets.json")
        let store = SnippetStore(fileURL: url)
        XCTAssertEqual(store.snippets.count, TextSnippet.examples.count) // first run shows examples
        store.replaceAll([snippet(";a1"), snippet(";a1")])
        XCTAssertEqual(store.duplicateKeywords, [";a1"])
        XCTAssertEqual(SnippetStore(fileURL: url).snippets.count, 2)
        store.replaceAll([])
        XCTAssertEqual(SnippetStore(fileURL: url).snippets.count, 0) // emptied on purpose stays empty
        try Data("not json".utf8).write(to: url)
        XCTAssertEqual(SnippetStore(fileURL: url).snippets.count, 0)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertTrue(leftovers.contains { $0.contains("corrupt") })
    }
}
