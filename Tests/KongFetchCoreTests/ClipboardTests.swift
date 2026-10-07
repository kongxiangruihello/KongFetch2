import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import KongFetchCore

final class ClipboardTests: XCTestCase {
    var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("kf-clip-" + UUID().uuidString)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    func makeHistory(_ limits: ClipboardHistory.Limits = .init()) -> ClipboardHistory {
        ClipboardHistory(store: ClipboardStore(directory: directory), limits: limits)
    }

    func text(_ s: String, rtf: Data? = nil, source: String? = "测试") -> ClipCandidate {
        ClipCandidate(payload: .text(s, rtf: rtf), sourceBundleID: "com.example.test", sourceName: source)
    }

    func testInsertMergePersist() {
        let history = makeHistory()
        let now = Date()
        guard case .added(let first) = history.insert(text("论语译注 第一章"), now: now) else { return XCTFail() }
        history.insert(text("另一段"), now: now.addingTimeInterval(1))
        XCTAssertEqual(history.insert(text("论语译注 第一章"), now: now.addingTimeInterval(2)), .merged(first))
        XCTAssertEqual(history.items.count, 2)
        XCTAssertEqual(history.items.first?.id, first, "a repeated copy moves to the top")
        history.flush()

        let reloaded = makeHistory()
        XCTAssertEqual(reloaded.items.map(\.id), history.items.map(\.id))
        XCTAssertNil(reloaded.problem)
    }

    func testRichTextIsKeptAsBlob() throws {
        let history = makeHistory()
        let rtf = Data("{\\rtf1 hello}".utf8)
        history.insert(text("hello", rtf: rtf))
        let item = try XCTUnwrap(history.items.first)
        let name = try XCTUnwrap(item.richTextFile)
        XCTAssertEqual(history.store.readBlob(name), rtf)
        history.remove(item.id)
        XCTAssertNil(history.store.readBlob(name), "removing an entry deletes its blob")
    }

    func testRejections() {
        let history = makeHistory(.init(maximumTextBytes: 10))
        XCTAssertEqual(history.insert(text("   \n ")), .rejected("空白文字不记录"))
        if case .rejected = history.insert(text(String(repeating: "a", count: 11))) {} else { XCTFail() }
        XCTAssertTrue(history.items.isEmpty)
    }

    func testLimitsKeepPinned() throws {
        let history = makeHistory(.init(maximumItems: 3))
        let now = Date()
        history.insert(text("pinned"), now: now)
        let pinned = try XCTUnwrap(history.items.first?.id)
        try history.setPinned(pinned, true)
        for i in 0..<10 { history.insert(text("item \(i)"), now: now.addingTimeInterval(Double(i + 1))) }
        XCTAssertEqual(history.items.count, 3)
        XCTAssertTrue(history.items.contains { $0.id == pinned })
        XCTAssertEqual(history.items.first?.text, "item 9")
    }

    func testRetention() throws {
        let history = makeHistory(.init(retentionDays: 30))
        let now = Date()
        history.insert(text("old"), now: now.addingTimeInterval(-40 * 86_400))
        history.insert(text("old pinned"), now: now.addingTimeInterval(-40 * 86_400))
        try history.setPinned(try XCTUnwrap(history.items.first?.id), true)
        history.insert(text("new"), now: now)
        XCTAssertEqual(Set(history.items.compactMap(\.text)), ["old pinned", "new"])
    }

    func testPinLimit() throws {
        let history = makeHistory(.init(maximumPinned: 1))
        history.insert(text("a")); history.insert(text("b"))
        try history.setPinned(history.items[0].id, true)
        XCTAssertThrowsError(try history.setPinned(history.items[1].id, true))
    }

    func testClear() throws {
        let history = makeHistory()
        history.insert(text("a")); history.insert(text("b"))
        try history.setPinned(history.items[0].id, true)
        history.clear(includingPinned: false)
        XCTAssertEqual(history.items.count, 1)
        history.clear(includingPinned: true)
        XCTAssertTrue(history.items.isEmpty)
    }

    func testFilesAndImages() throws {
        let history = makeHistory()
        history.insert(ClipCandidate(payload: .files(["/Users/k/合同.pdf", "relative/ignored"])))
        XCTAssertEqual(history.items.first?.filePaths, ["/Users/k/合同.pdf"])

        let png = try XCTUnwrap(Self.makePNG(width: 40, height: 20))
        let normalized = try XCTUnwrap(ImageCodec.normalize(png, maximumBytes: 1_000_000))
        XCTAssertEqual(normalized.fileExtension, "png")
        XCTAssertEqual(normalized.width, 40)
        XCTAssertFalse(normalized.reduced)
        history.insert(ClipCandidate(payload: .image(normalized.data, fileExtension: "png", width: 40, height: 20)))
        let image = try XCTUnwrap(history.items.first)
        XCTAssertEqual(image.kind, .image)
        XCTAssertEqual(history.store.readBlob(try XCTUnwrap(image.imageFile)), normalized.data)
    }

    func testLargeImageIsReduced() throws {
        let png = try XCTUnwrap(Self.makePNG(width: 3000, height: 2000, noisy: true))
        let normalized = try XCTUnwrap(ImageCodec.normalize(png, maximumBytes: 200_000, maximumPixels: 2000))
        XCTAssertTrue(normalized.reduced)
        XCTAssertLessThanOrEqual(normalized.data.count, 200_000)
        XCTAssertLessThanOrEqual(max(normalized.width, normalized.height), 2000)
    }

    func testCorruptIndexIsQuarantinedNotOverwritten() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: directory.appendingPathComponent("index.json"))
        let history = makeHistory()
        XCTAssertNotNil(history.problem)
        XCTAssertTrue(history.items.isEmpty)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertTrue(names.contains { $0.hasPrefix("index-unreadable-") })
    }

    func testOneBadEntryDoesNotLoseTheRest() throws {
        let history = makeHistory()
        history.insert(text("good one"))
        history.insert(text("good two"))
        history.flush()
        // Corrupt one entry by hand.
        let url = directory.appendingPathComponent("index.json")
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var items = try XCTUnwrap(json["items"] as? [[String: Any]])
        items[0]["fingerprint"] = "short"
        items.append(["garbage": true])
        json["items"] = items
        try JSONSerialization.data(withJSONObject: json).write(to: url)

        let reloaded = makeHistory()
        XCTAssertEqual(reloaded.items.count, 1)
        XCTAssertNotNil(reloaded.problem)
    }

    func testBlobNamesCannotEscape() {
        XCTAssertFalse(ClipItem.isSafeBlobName("../index.json"))
        XCTAssertFalse(ClipItem.isSafeBlobName("abc.png"))
        XCTAssertTrue(ClipItem.isSafeBlobName(UUID().uuidString + ".png"))
        XCTAssertNil(ClipboardStore(directory: directory).blobURL("../../etc/passwd"))
    }

    static func makePNG(width: Int, height: Int, noisy: Bool = false) -> Data? {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        var seed: UInt32 = 12345
        for i in stride(from: 0, to: pixels.count, by: 4) {
            if noisy {
                seed = seed &* 1_103_515_245 &+ 12345
                pixels[i] = UInt8(truncatingIfNeeded: seed >> 16)
                pixels[i + 1] = UInt8(truncatingIfNeeded: seed >> 8)
                pixels[i + 2] = UInt8(truncatingIfNeeded: seed)
            }
            pixels[i + 3] = 255
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        return ImageCodec.encode(image, type: .png, quality: nil)
    }
}
