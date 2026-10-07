import XCTest
@testable import KongFetchCore

final class SnippetTests: XCTestCase {
    func testExcerptAroundMatch() throws {
        let text = String(repeating: "甲", count: 100) + "学而时习之，不亦说乎" + String(repeating: "乙", count: 100)
        let snippet = try XCTUnwrap(Snippet.find(in: text, needles: ["时习"], radius: 5))
        XCTAssertEqual(snippet.text, "…甲甲甲学而时习之，不亦说…")
        XCTAssertEqual((snippet.text as NSString).substring(with: snippet.highlight), "时习")
    }

    func testCaseInsensitiveAndWhitespace() throws {
        let snippet = try XCTUnwrap(Snippet.find(in: "The   Analects\n\nof Confucius", needles: ["analects"], radius: 20))
        XCTAssertEqual(snippet.text, "The Analects of Confucius")
        XCTAssertEqual((snippet.text as NSString).substring(with: snippet.highlight), "Analects")
    }

    func testEarliestNeedleWinsAndMissingIsNil() throws {
        let snippet = try XCTUnwrap(Snippet.find(in: "孔子曰：学而时习之", needles: ["时习", "孔子"], radius: 2))
        XCTAssertEqual((snippet.text as NSString).substring(with: snippet.highlight), "孔子")
        XCTAssertNil(Snippet.find(in: "abc", needles: ["论语"]))
    }
}
