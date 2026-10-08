import XCTest
@testable import KongFetchCore

final class BatchRenameTests: XCTestCase {
    private let items = [
        BatchRename.Item(path: "/d/讲义 第二讲.pdf", modified: Date(timeIntervalSince1970: 200)),
        BatchRename.Item(path: "/d/讲义 第一讲.pdf", modified: Date(timeIntervalSince1970: 100)),
        BatchRename.Item(path: "/d/附录.docx", modified: Date(timeIntervalSince1970: 300))
    ]

    func testReplaceKeepsExtension() {
        var rule = BatchRename.Rule()
        rule.find = "讲义 "
        rule.replacement = "论语导读-"
        let result = BatchRename.plan(items, rule: rule) { _ in false }
        XCTAssertEqual(result.map(\.newName), ["论语导读-第二讲.pdf", "论语导读-第一讲.pdf", "附录.docx"])
        XCTAssertEqual(result.filter(\.changed).count, 2)
        XCTAssertTrue(result.allSatisfy { $0.problem == nil })
    }

    func testRegexAndBadPattern() {
        var rule = BatchRename.Rule()
        rule.useRegex = true
        rule.find = "第(.)讲"
        rule.replacement = "L$1"
        XCTAssertEqual(BatchRename.plan(items, rule: rule) { _ in false }.map(\.newName), ["讲义 L二.pdf", "讲义 L一.pdf", "附录.docx"])
        rule.find = "("
        XCTAssertEqual(BatchRename.plan(items, rule: rule) { _ in false }.first?.problem, .badPattern)
    }

    func testTemplateNumbersInChosenOrder() {
        var rule = BatchRename.Rule()
        rule.mode = .template
        rule.template = "{n}_{name}"
        rule.order = .modified
        rule.start = 9
        let result = BatchRename.plan(items, rule: rule) { _ in false }
        XCTAssertEqual(result.map(\.newName), ["09_讲义 第一讲.pdf", "10_讲义 第二讲.pdf", "11_附录.docx"])
    }

    func testProblems() {
        var rule = BatchRename.Rule()
        rule.mode = .template
        rule.template = "同名"
        let duplicates = BatchRename.plan(Array(items.prefix(2)), rule: rule) { _ in false }
        XCTAssertEqual(duplicates.map(\.problem), [.duplicate, .duplicate])

        rule.template = "a/b"
        XCTAssertEqual(BatchRename.plan([items[0]], rule: rule) { _ in false }.first?.problem, .invalidCharacter)
        rule.template = ""
        XCTAssertEqual(BatchRename.plan([items[0]], rule: rule) { _ in false }.first?.problem, .empty)

        rule.template = "已有"
        XCTAssertEqual(BatchRename.plan([items[0]], rule: rule) { $0 == "/d/已有.pdf" }.first?.problem, .exists)
    }

    func testSwapUsesTemporaryNames() {
        let swap = [BatchRename.Item(path: "/d/a.txt"), BatchRename.Item(path: "/d/b.txt")]
        var rule = BatchRename.Rule()
        rule.mode = .template
        rule.template = "{n}"
        rule.digits = 1
        // Names that swap: a.txt→b.txt and b.txt→a.txt.
        let previews = [
            BatchRename.Preview(item: swap[0], newName: "b.txt", problem: nil),
            BatchRename.Preview(item: swap[1], newName: "a.txt", problem: nil)
        ]
        let steps = BatchRename.steps(for: previews, token: "T")
        XCTAssertEqual(steps.map(\.from), ["/d/a.txt", "/d/b.txt", "/d/.kongfetch-rename-T-0", "/d/.kongfetch-rename-T-1"])
        XCTAssertEqual(steps.map(\.to), ["/d/.kongfetch-rename-T-0", "/d/.kongfetch-rename-T-1", "/d/b.txt", "/d/a.txt"])
        // Taking a name that another file in the set is giving up is not reported as "exists".
        let shifted = [BatchRename.Item(path: "/d/1.txt"), BatchRename.Item(path: "/d/2.txt")]
        rule.start = 2
        let originals: Set<String> = ["/d/1.txt", "/d/2.txt"]
        let result = BatchRename.plan(shifted, rule: rule) { originals.contains($0) }
        XCTAssertEqual(result.map(\.newName), ["2.txt", "3.txt"])
        XCTAssertTrue(result.allSatisfy { $0.problem == nil })
    }
}
