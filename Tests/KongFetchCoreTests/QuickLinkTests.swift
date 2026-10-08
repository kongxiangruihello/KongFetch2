import XCTest
@testable import KongFetchCore

final class QuickLinkTests: XCTestCase {
    func testMatchSplitsKeywordAndQuery() throws {
        let match = try XCTUnwrap(QuickLinks.match("HD 学而 时习", in: QuickLinks.defaults))
        XCTAssertEqual(match.link.name, "汉典")
        XCTAssertEqual(match.query, "学而 时习")
        XCTAssertNotNil(QuickLinks.match("hd\u{3000}仁", in: QuickLinks.defaults))
        XCTAssertNil(QuickLinks.match("hd", in: QuickLinks.defaults))
        XCTAssertNil(QuickLinks.match("hd   ", in: QuickLinks.defaults))
        XCTAssertNil(QuickLinks.match("论语 译注", in: QuickLinks.defaults))
    }

    func testURLEncodesQuery() throws {
        let link = QuickLink(keyword: "g", name: "Google", template: "https://www.google.com/search?q={query}")
        XCTAssertEqual(try XCTUnwrap(link.url(for: "a&b c")).absoluteString, "https://www.google.com/search?q=a%26b%20c")
        XCTAssertEqual(try XCTUnwrap(QuickLinks.defaults[2].url(for: "仁")).absoluteString, "https://www.zdic.net/hans/%E4%BB%81")
        XCTAssertNil(QuickLink(keyword: "x", name: "x", template: "file:///etc/{query}").url(for: "passwd"))
        XCTAssertNil(QuickLink(keyword: "x", name: "x", template: "javascript:alert({query})").url(for: "1"))
        XCTAssertEqual(try XCTUnwrap(QuickLink(keyword: "kr", name: "kr", template: "kongreview://add?text={query}").url(for: "学而 & 时习")).absoluteString,
                       "kongreview://add?text=%E5%AD%A6%E8%80%8C%20%26%20%E6%97%B6%E4%B9%A0")
        XCTAssertNil(QuickLink(keyword: "x", name: "x", template: "not a url {query}").url(for: "q"))
    }

    func testDefaultsAreValid() {
        let keywords = QuickLinks.defaults.map(\.keyword)
        XCTAssertEqual(Set(keywords).count, keywords.count)
        for link in QuickLinks.defaults { XCTAssertNotNil(link.url(for: "论语"), link.name) }
    }
}
