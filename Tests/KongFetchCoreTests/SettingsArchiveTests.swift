import XCTest
@testable import KongFetchCore

final class SettingsArchiveTests: XCTestCase {
    func testRoundTripKeepsOnlyKongFetchChoices() throws {
        let defaults: [String: Any] = [
            "kf4.autoPaste": true,
            "kf4.ocrFolders": ["~/Documents/扫描"],
            "kf4.searchShortcut": Data([1, 2, 3]),
            "kf4.folderAccessRequested": true,
            "NSWindow Frame Settings": "0 0 100 100",
            "kf3.old": 1
        ]
        let snippet = TextSnippet(name: "落款", keyword: ";lk", content: "此致\n敬礼")
        let archive = SettingsArchive(defaults: defaults, snippets: [snippet], appVersion: "4.7")
        XCTAssertEqual(Set(archive.defaults.keys), ["kf4.autoPaste", "kf4.ocrFolders", "kf4.searchShortcut"])

        let decoded = try SettingsArchive.decode(archive.encoded())
        XCTAssertEqual(Set(decoded.defaults.keys), Set(archive.defaults.keys))
        XCTAssertEqual(decoded.defaults["kf4.autoPaste"] as? Bool, true)
        XCTAssertEqual(decoded.defaults["kf4.ocrFolders"] as? [String], ["~/Documents/扫描"])
        XCTAssertEqual(decoded.defaults["kf4.searchShortcut"] as? Data, Data([1, 2, 3]))
        XCTAssertEqual(decoded.snippets.map(\.content), ["此致\n敬礼"])
        XCTAssertEqual(decoded.appVersion, "4.7")
    }

    func testRejectsOtherFiles() {
        XCTAssertThrowsError(try SettingsArchive.decode(Data("hello".utf8)))
        let other = try! PropertyListSerialization.data(fromPropertyList: ["a": 1], format: .xml, options: 0)
        XCTAssertThrowsError(try SettingsArchive.decode(other)) { error in
            XCTAssertEqual(error.localizedDescription, "这不是 KongFetch 导出的设置文件。")
        }
    }
}
