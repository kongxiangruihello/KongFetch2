import XCTest
@testable import KongFetchCore

final class NameIndexTests: XCTestCase {
    var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("kf-index-" + UUID().uuidString)
        let fm = FileManager.default
        for dir in ["教案/第一讲", "电子书", "node_modules/中文包", ".隐藏", "Plain"] {
            try fm.createDirectory(at: root.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        for file in ["教案/第一讲/论语译注.docx", "电子书/年度合同.pdf", "node_modules/中文包/索引.js",
                     ".隐藏/秘密.txt", "Plain/readme.txt", "Plain/孔子.key"] {
            try Data("x".utf8).write(to: root.appendingPathComponent(file))
        }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    func testScanKeepsOnlyChineseNamesAndSkipsNoise() {
        let entries = NameIndexScanner.scan(root)
        let names = Set(entries.map(\.name))
        XCTAssertEqual(names, ["教案", "第一讲", "论语译注.docx", "电子书", "年度合同.pdf", "孔子.key"])
        XCTAssertTrue(entries.first { $0.name == "教案" }!.isDirectory)
        XCTAssertFalse(entries.first { $0.name == "孔子.key" }!.isDirectory)
    }

    func testPinyinMatching() {
        let index = NameIndex()
        index.replaceSubtree(root.path, with: NameIndexScanner.scan(root))
        XCTAssertEqual(index.matches(pinyin: "lyyz").first?.entry.name, "论语译注.docx")
        XCTAssertEqual(index.matches(pinyin: "niandu").first?.entry.name, "年度合同.pdf")
        XCTAssertEqual(index.matches(pinyin: "kongzi").first?.entry.name, "孔子.key")
        XCTAssertTrue(index.matches(pinyin: "x").isEmpty, "single letters are too broad")
        XCTAssertTrue(index.matches(pinyin: "ja", accept: { !$0.isDirectory }).allSatisfy { !$0.entry.isDirectory })
    }

    func testIncrementalUpdates() throws {
        let index = NameIndex()
        index.replaceSubtree(root.path, with: NameIndexScanner.scan(root))
        let lessons = root.appendingPathComponent("教案").path
        index.removeSubtree(lessons)
        XCTAssertTrue(index.matches(pinyin: "lyyz").isEmpty)
        XCTAssertFalse(index.matches(pinyin: "ndht").isEmpty, "other folders are untouched")

        let new = root.appendingPathComponent("电子书/礼记.pdf")
        try Data("x".utf8).write(to: new)
        index.update(new.path, with: NameIndexScanner.entry(for: new, isDirectory: false))
        XCTAssertEqual(index.matches(pinyin: "liji").first?.entry.path, new.path)
        index.update(new.path, with: nil)
        XCTAssertTrue(index.matches(pinyin: "liji").isEmpty)

        index.retainOnly(roots: [root.appendingPathComponent("Plain").path])
        XCTAssertEqual(index.count, 1)
    }

    func testSaveAndLoad() throws {
        let index = NameIndex()
        index.replaceSubtree(root.path, with: NameIndexScanner.scan(root))
        let file = root.appendingPathComponent("index.txt")
        try index.save(to: file)
        let reloaded = NameIndex()
        XCTAssertTrue(reloaded.load(from: file))
        XCTAssertEqual(reloaded.count, index.count)
        XCTAssertEqual(reloaded.matches(pinyin: "lyyz").first?.entry.name, "论语译注.docx")
        XCTAssertFalse(NameIndex().load(from: root.appendingPathComponent("missing.txt")))
    }
}
