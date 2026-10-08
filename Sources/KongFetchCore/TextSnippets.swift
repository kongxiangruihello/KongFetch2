import Foundation

/// Reusable text: pasted from the clipboard window, or typed by its keyword and expanded in place.
public struct TextSnippet: Codable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    /// Typed anywhere to expand, e.g. ";qm". Empty means the snippet is only picked from the list.
    public var keyword: String
    public var content: String
    public var created: Date
    public var lastUsed: Date?

    public init(id: UUID = UUID(), name: String, keyword: String = "", content: String, created: Date = Date(), lastUsed: Date? = nil) {
        self.id = id
        self.name = name
        self.keyword = keyword
        self.content = content
        self.created = created
        self.lastUsed = lastUsed
    }

    /// Text the clipboard window's search matches against.
    public var searchText: String { [name, keyword, content].joined(separator: "\n") }

    /// Keywords need at least two characters and no spaces, so ordinary typing does not trigger them.
    public static func isValidKeyword(_ keyword: String) -> Bool {
        keyword.count >= 2 && !keyword.contains(where: { $0.isWhitespace || $0.isNewline })
    }

    public static let examples: [TextSnippet] = [
        TextSnippet(name: "今天的日期", keyword: ";rq", content: "{日期}"),
        TextSnippet(name: "邮件落款", keyword: ";lk", content: "此致\n敬礼！\n\n（姓名）\n{日期}"),
        TextSnippet(name: "引文格式（专著）", keyword: ";yw", content: "作者：《书名》，出版社，{cursor}年，第  页。")
    ]
}

/// Placeholders in snippet content.
public enum SnippetTemplate {
    public struct Rendered: Equatable {
        public var text: String
        /// Characters from the end of `text` back to where {cursor} was; 0 if there was none.
        public var cursorOffsetFromEnd: Int
    }

    public static let placeholders: [(token: String, meaning: String)] = [
        ("{日期}", "2026年10月8日"), ("{date}", "2026-10-08"), ("{time}", "14:05"),
        ("{weekday}", "星期四"), ("{clipboard}", "当前剪贴板中的文字"), ("{cursor}", "展开后光标停在这里")
    ]

    public static func render(_ content: String, now: Date = Date(), clipboard: String? = nil,
                              calendar: Calendar = .current) -> Rendered {
        func format(_ pattern: String) -> String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.dateFormat = pattern
            return formatter.string(from: now)
        }
        var text = content
        let values: [(String, () -> String)] = [
            ("{日期}", { format("yyyy年M月d日") }),
            ("{date}", { format("yyyy-MM-dd") }),
            ("{time}", { format("HH:mm") }),
            ("{weekday}", { format("EEEE") }),
            ("{clipboard}", { clipboard ?? "" })
        ]
        for (token, value) in values where text.contains(token) {
            text = text.replacingOccurrences(of: token, with: value())
        }
        guard let range = text.range(of: "{cursor}") else { return Rendered(text: text, cursorOffsetFromEnd: 0) }
        let after = text[range.upperBound...]
        text.removeSubrange(range)
        // Any further {cursor} markers are dropped.
        text = text.replacingOccurrences(of: "{cursor}", with: "")
        let offset = after.replacingOccurrences(of: "{cursor}", with: "").count
        return Rendered(text: text, cursorOffsetFromEnd: offset)
    }
}

/// Remembers what was just typed and reports when it ends with a snippet keyword.
public struct SnippetExpander {
    private var buffer = ""
    private var keywords: [String: UUID] = [:]
    private var longest = 0

    public init() {}

    public mutating func setSnippets(_ snippets: [TextSnippet]) {
        keywords = [:]
        for snippet in snippets where TextSnippet.isValidKeyword(snippet.keyword) && keywords[snippet.keyword] == nil {
            keywords[snippet.keyword] = snippet.id
        }
        longest = keywords.keys.map(\.count).max() ?? 0
        buffer = ""
    }

    public var isEmpty: Bool { keywords.isEmpty }

    /// Feeds typed characters. Returns the snippet whose keyword the text now ends with, and the keyword's length.
    public mutating func type(_ characters: String) -> (id: UUID, keywordLength: Int)? {
        guard !keywords.isEmpty else { return nil }
        for character in characters {
            if character.isNewline || character == "\t" { buffer = ""; continue }
            buffer.append(character)
        }
        if buffer.count > longest { buffer = String(buffer.suffix(longest)) }
        // If several keywords end the typed text (";lk" and "lk"), the longest wins.
        for length in stride(from: min(longest, buffer.count), through: 2, by: -1) {
            let tail = String(buffer.suffix(length))
            if let id = keywords[tail] {
                buffer = ""
                return (id, tail.count)
            }
        }
        return nil
    }

    public mutating func deleteBackward() {
        if !buffer.isEmpty { buffer.removeLast() }
    }

    /// Forget what was typed (a click, an arrow key, a shortcut or switching apps).
    public mutating func reset() {
        buffer = ""
    }
}

/// Saves snippets as JSON in KongFetch's support folder.
public final class SnippetStore {
    public let fileURL: URL
    public private(set) var snippets: [TextSnippet] = []
    public var onChange: (() -> Void)?

    public init(fileURL: URL) {
        self.fileURL = fileURL
        load()
    }

    public func load() {
        guard let data = try? Data(contentsOf: fileURL) else {
            snippets = FileManager.default.fileExists(atPath: fileURL.path) ? [] : TextSnippet.examples
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let decoded = try? decoder.decode([TextSnippet].self, from: data) {
            snippets = decoded
        } else {
            // Keep the unreadable file for inspection instead of overwriting it.
            let aside = fileURL.deletingPathExtension().appendingPathExtension("corrupt-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: fileURL, to: aside)
            snippets = []
        }
    }

    public func save() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(snippets).write(to: fileURL, options: .atomic)
    }

    public func replaceAll(_ new: [TextSnippet]) {
        snippets = new
        try? save()
        onChange?()
    }

    public func upsert(_ snippet: TextSnippet) {
        if let index = snippets.firstIndex(where: { $0.id == snippet.id }) {
            snippets[index] = snippet
        } else {
            snippets.append(snippet)
        }
        try? save()
        onChange?()
    }

    public func remove(_ id: UUID) {
        snippets.removeAll { $0.id == id }
        try? save()
        onChange?()
    }

    public func touch(_ id: UUID, at date: Date = Date()) {
        guard let index = snippets.firstIndex(where: { $0.id == id }) else { return }
        snippets[index].lastUsed = date
        try? save()
    }

    public func snippet(_ id: UUID) -> TextSnippet? {
        snippets.first { $0.id == id }
    }

    /// Keywords used by more than one snippet.
    public var duplicateKeywords: [String] {
        let keywords = snippets.map(\.keyword).filter { !$0.isEmpty }
        return Array(Set(keywords.filter { k in keywords.filter { $0 == k }.count > 1 })).sorted()
    }
}
