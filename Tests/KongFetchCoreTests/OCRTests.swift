import XCTest
import CoreGraphics
import CoreText
@testable import KongFetchCore

final class OCRTests: XCTestCase {
    var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("kf-ocr-" + UUID().uuidString)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: Store

    func testStoreSaveLoadAndCurrency() throws {
        let store = OCRStore(directory: directory)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        try store.save(OCRRecord(path: "/books/论语.pdf", size: 100, modified: date,
                                 pages: ["子曰：学而时习之", "有朋自远方来"], totalPages: 300))
        let reloaded = OCRStore(directory: directory)
        reloaded.load()
        XCTAssertEqual(reloaded.count, 1)
        XCTAssertTrue(reloaded.isCurrent(path: "/books/论语.pdf", size: 100, modified: date, pageLimit: 2))
        XCTAssertFalse(reloaded.isCurrent(path: "/books/论语.pdf", size: 101, modified: date, pageLimit: 2), "file changed")
        XCTAssertFalse(reloaded.isCurrent(path: "/books/论语.pdf", size: 100, modified: date, pageLimit: 50), "page limit raised")
        XCTAssertFalse(reloaded.isCurrent(path: "/books/孟子.pdf", size: 100, modified: date, pageLimit: 2))
    }

    func testSearchFindsPageAndRequiresAllWords() throws {
        let store = OCRStore(directory: directory)
        try store.save(OCRRecord(path: "/books/论语.pdf", size: 1, modified: Date(),
                                 pages: ["学而第一", "子曰：学而时习之，不亦说乎？有朋自远方来"], totalPages: 2))
        try store.save(OCRRecord(path: "/scans/photo.jpg", size: 1, modified: Date(),
                                 pages: ["巧言令色，鲜矣仁"], totalPages: 1))
        let hit = try XCTUnwrap(store.search(["时习"]).first)
        XCTAssertEqual(hit.path, "/books/论语.pdf")
        XCTAssertEqual(hit.page, 2)
        XCTAssertEqual((hit.snippet.text as NSString).substring(with: hit.snippet.highlight), "时习")
        XCTAssertEqual(store.search(["学而", "远方"]).count, 1, "words may be on different pages")
        XCTAssertTrue(store.search(["学而", "巧言"]).isEmpty, "every word must be in the same document")
        XCTAssertNil(store.search(["巧言"]).first?.page, "images have no page number")
        XCTAssertTrue(store.search(["时习"], accept: { $0.hasPrefix("/scans") }).isEmpty)
    }

    func testPruneAndClear() throws {
        let store = OCRStore(directory: directory)
        try store.save(OCRRecord(path: "/a/1.png", size: 1, modified: Date(), pages: ["x"], totalPages: 1))
        try store.save(OCRRecord(path: "/b/2.png", size: 1, modified: Date(), pages: ["y"], totalPages: 1))
        store.prune { $0.hasPrefix("/a/") }
        XCTAssertEqual(store.allPaths, ["/a/1.png"])
        store.clear()
        let reloaded = OCRStore(directory: directory)
        reloaded.load()
        XCTAssertEqual(reloaded.count, 0, "removal also deletes the files")
    }

    // MARK: Recognition

    func testRecognizesRenderedText() throws {
        let image = try XCTUnwrap(Self.render(["KongFetch 2026", "学而时习之"]))
        let text = try TextRecognizer.recognize(image)
        XCTAssertTrue(text.contains("KongFetch"), text)
        XCTAssertTrue(text.contains("2026"), text)
        XCTAssertTrue(text.contains("时习"), text)
        XCTAssertLessThan(text.range(of: "KongFetch")!.lowerBound, text.range(of: "时习")!.lowerBound, "top line first")
    }

    func testBlankImageHasNoText() throws {
        let image = try XCTUnwrap(Self.render([]))
        XCTAssertEqual(try TextRecognizer.recognize(image), "")
    }

    func testClipboardRecognizedTextIsSearchable() throws {
        let history = ClipboardHistory(store: ClipboardStore(directory: directory))
        let png = try XCTUnwrap(ClipboardTests.makePNG(width: 20, height: 20))
        guard case .added(let id) = history.insert(ClipCandidate(payload: .image(png, fileExtension: "png", width: 20, height: 20))) else {
            return XCTFail()
        }
        history.setRecognizedText(id, "巧言令色")
        let item = try XCTUnwrap(history.items.first)
        XCTAssertTrue(item.searchText.contains("巧言令色"))
        XCTAssertTrue(item.title.contains("巧言令色"))
        history.flush()
        let reloaded = ClipboardHistory(store: ClipboardStore(directory: directory))
        XCTAssertEqual(reloaded.items.first?.recognizedText, "巧言令色")
    }

    /// Black text on white, one line per string.
    static func render(_ lines: [String]) -> CGImage? {
        let width = 1400, height = 120 + lines.count * 110
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let font = CTFontCreateWithName("PingFang SC" as CFString, 64, nil)
        for (index, line) in lines.enumerated() {
            let attributed = NSAttributedString(string: line, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 0, green: 0, blue: 0, alpha: 1)
            ])
            let ctLine = CTLineCreateWithAttributedString(attributed)
            context.textPosition = CGPoint(x: 60, y: CGFloat(height - 120 - index * 110))
            CTLineDraw(ctLine, context)
        }
        return context.makeImage()
    }
}
