import XCTest
@testable import KongFetchCore

final class SearchQueryTests: XCTestCase {
    func testPlainTerms() {
        let q = SearchQuery.parse("  年度  合同 ")
        XCTAssertEqual(q.terms, ["年度", "合同"])
        XCTAssertTrue(q.phrases.isEmpty)
    }

    func testPhrasesAndExclusions() {
        let q = SearchQuery.parse(#"ext:pdf "年度 合同" -草稿 -"旧 版""#)
        XCTAssertEqual(q.extensions, ["pdf"])
        XCTAssertEqual(q.phrases, ["年度 合同"])
        XCTAssertEqual(q.excluded, ["草稿", "旧 版"])
        XCTAssertTrue(q.terms.isEmpty)
    }

    func testChineseQuotes() {
        let q = SearchQuery.parse("“论语 译注” kind:文档")
        XCTAssertEqual(q.phrases, ["论语 译注"])
        XCTAssertEqual(q.kind, .document)
    }

    func testFilters() {
        let q = SearchQuery.parse("报告 ext:.DOCX,pdf kind:folder days:7 .key")
        XCTAssertEqual(q.terms, ["报告"])
        XCTAssertEqual(q.extensions, ["docx", "pdf", "key"])
        XCTAssertEqual(q.kind, .folder)
        XCTAssertEqual(q.modifiedWithinDays, 7)
    }

    func testUnknownFilterIsATerm() {
        let q = SearchQuery.parse("foo:bar days:abc kind:nonsense")
        XCTAssertEqual(q.terms, ["foo:bar", "days:abc", "kind:nonsense"])
    }

    func testUnclosedQuoteAndLoneDash() {
        let q = SearchQuery.parse(#"- "abc"#)
        XCTAssertEqual(q.phrases, ["abc"])
        XCTAssertTrue(q.excluded.isEmpty)
    }

    func testPinyinCandidate() {
        XCTAssertEqual(SearchQuery.parse("WeiXin").pinyinCandidate, "weixin")
        XCTAssertNil(SearchQuery.parse("wei xin").pinyinCandidate)
        XCTAssertNil(SearchQuery.parse("ht ext:pdf").pinyinCandidate)
        XCTAssertNil(SearchQuery.parse("合同").pinyinCandidate)
    }

    func testLocalMatching() {
        let q = SearchQuery.parse("合同 -草稿 ext:pdf")
        XCTAssertTrue(q.matchesName("2024年度合同.pdf"))
        XCTAssertFalse(q.matchesName("合同草稿.pdf"))
        XCTAssertFalse(q.matchesName("合同.docx"))
        XCTAssertTrue(SearchQuery.parse("wechat").matchesName("微信.app", alternateName: "WeChat.app"))
    }
}

final class RankingTests: XCTestCase {
    func testOrdering() {
        let needles = ["report"]
        let exact = Ranker.nameScore(name: "Report.pdf", needles: needles)!
        let prefix = Ranker.nameScore(name: "Report final.pdf", needles: needles)!
        let word = Ranker.nameScore(name: "2024 report.pdf", needles: needles)!
        let inside = Ranker.nameScore(name: "myreports.pdf", needles: needles)!
        XCTAssertGreaterThan(exact, prefix)
        XCTAssertGreaterThan(prefix, word)
        XCTAssertGreaterThan(word, inside)
        XCTAssertNil(Ranker.nameScore(name: "notes.txt", needles: needles))
    }

    func testAllNeedlesRequired() {
        XCTAssertNotNil(Ranker.nameScore(name: "论语译注 第二稿.docx", needles: ["论语", "二稿"]))
        XCTAssertNil(Ranker.nameScore(name: "论语译注.docx", needles: ["论语", "二稿"]))
    }

    func testFoldingIgnoresCaseAndWidth() {
        XCTAssertNotNil(Ranker.nameScore(name: "ＫｏｎｇＦｅｔｃｈ", needles: ["kongfetch"]))
        XCTAssertNotNil(Ranker.nameScore(name: "Café.txt", needles: ["cafe"]))
    }

    func testPinyin() throws {
        let forms = try XCTUnwrap(Pinyin.forms(for: "年度合同"))
        XCTAssertEqual(forms.full, "nianduhetong")
        XCTAssertEqual(forms.initials, "ndht")
        XCTAssertNotNil(Ranker.pinyinScore(forms: forms, query: "ndht"))
        XCTAssertNotNil(Ranker.pinyinScore(forms: forms, query: "niandu"))
        XCTAssertNotNil(Ranker.pinyinScore(forms: forms, query: "hetong"))
        XCTAssertNil(Ranker.pinyinScore(forms: forms, query: "xyz"))
        XCTAssertNil(Pinyin.forms(for: "Safari"))
        XCTAssertGreaterThan(Ranker.pinyinScore(forms: forms, query: "ndht")!, Ranker.pinyinScore(forms: forms, query: "ht")!)
    }

    func testLocationPenalty() {
        let home = "/Users/k"
        XCTAssertEqual(Ranker.locationPenalty(path: "/Users/k/Documents/a.pdf", home: home), 0)
        XCTAssertGreaterThan(Ranker.locationPenalty(path: "/Users/k/Library/Caches/a.pdf", home: home), 0)
        XCTAssertGreaterThan(Ranker.locationPenalty(path: "/Users/k/.Trash/a.pdf", home: home), 0)
        XCTAssertEqual(Ranker.locationPenalty(path: "/Users/k/Library/Mobile Documents/com~apple~CloudDocs/a.pdf", home: home), 0)
    }

    func testSystemLocations() {
        let home = "/Users/k"
        XCTAssertFalse(Ranker.isSystemLocation("/Users/k/Documents/论语.docx", home: home))
        XCTAssertFalse(Ranker.isSystemLocation("/Users/k/Library/Mobile Documents/com~apple~CloudDocs/论语.docx", home: home))
        XCTAssertFalse(Ranker.isSystemLocation("/Users/k/Library/CloudStorage/GoogleDrive-a/讲稿.docx", home: home))
        XCTAssertFalse(Ranker.isSystemLocation("/Applications/Safari.app", home: home))
        XCTAssertFalse(Ranker.isSystemLocation("/System/Applications/Notes.app", home: home))
        XCTAssertTrue(Ranker.isSystemLocation("/Users/k/Library/Caches/x", home: home))
        XCTAssertTrue(Ranker.isSystemLocation("/Library/Developer/CommandLineTools/Safari.framework", home: home))
        XCTAssertTrue(Ranker.isSystemLocation("/Applications/Xcode.app/Contents/Info.plist", home: home))
        XCTAssertTrue(Ranker.isSystemLocation("/Users/k/.Trash/a.pdf", home: home))
    }

    func testRecentItemsBoost() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let recents = RecentItems(fileURL: dir.appendingPathComponent("recents.json"))
        let now = Date()
        recents.record("/a", now: now)
        recents.record("/a", now: now)
        recents.record("/b", now: now.addingTimeInterval(-40 * 86_400))
        XCTAssertGreaterThan(recents.boost(for: "/a", now: now), recents.boost(for: "/b", now: now))
        XCTAssertEqual(recents.boost(for: "/c", now: now), 0)
        let reloaded = RecentItems(fileURL: dir.appendingPathComponent("recents.json"))
        XCTAssertEqual(reloaded.entries.first?.path, "/a")
        XCTAssertEqual(reloaded.entries.first?.count, 2)
    }
}
