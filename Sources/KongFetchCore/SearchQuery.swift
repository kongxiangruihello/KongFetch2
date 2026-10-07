import Foundation

/// A parsed search box input.
///
/// Syntax (all parts optional, combined with AND):
/// - `合同 2024`            every word must appear in the name
/// - `"年度 合同"`           an exact phrase (straight or Chinese quotes)
/// - `-草稿`                 the name must not contain this
/// - `ext:pdf,docx` / `.pdf` file extension
/// - `kind:folder`          application, folder, image, pdf, document, video, audio, archive
/// - `days:7`               modified within the last N days
public struct SearchQuery: Equatable {
    public enum Kind: String, CaseIterable {
        case application, folder, image, pdf, document, video, audio, archive

        public var title: String {
            switch self {
            case .application: return "应用"
            case .folder: return "文件夹"
            case .image: return "图片"
            case .pdf: return "PDF"
            case .document: return "文档"
            case .video: return "视频"
            case .audio: return "音频"
            case .archive: return "压缩包"
            }
        }

        static let aliases: [String: Kind] = [
            "app": .application, "apps": .application, "application": .application, "应用": .application,
            "folder": .folder, "dir": .folder, "directory": .folder, "文件夹": .folder, "目录": .folder,
            "image": .image, "img": .image, "pic": .image, "photo": .image, "图片": .image, "照片": .image,
            "pdf": .pdf,
            "doc": .document, "docs": .document, "document": .document, "文档": .document,
            "video": .video, "movie": .video, "视频": .video,
            "audio": .audio, "music": .audio, "音频": .audio, "音乐": .audio,
            "archive": .archive, "zip": .archive, "压缩包": .archive
        ]
    }

    public var terms: [String] = []
    public var phrases: [String] = []
    public var excluded: [String] = []
    public var extensions: [String] = []
    public var kind: Kind?
    public var modifiedWithinDays: Int?

    public init() {}

    /// Everything that must appear in the name, phrases first.
    public var nameNeedles: [String] { phrases + terms }

    public var isEmpty: Bool {
        terms.isEmpty && phrases.isEmpty && extensions.isEmpty && kind == nil && modifiedWithinDays == nil
    }

    /// A single bare ASCII word with no filters: may be pinyin for a Chinese name.
    public var pinyinCandidate: String? {
        guard phrases.isEmpty, excluded.isEmpty, extensions.isEmpty, modifiedWithinDays == nil,
              kind == nil || kind == .application,
              terms.count == 1, let word = terms.first,
              word.count >= 1, word.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
        return word.lowercased()
    }

    // MARK: Parsing

    public static func parse(_ input: String) -> SearchQuery {
        var query = SearchQuery()
        for token in tokenize(input) {
            if token.quoted {
                guard !token.text.isEmpty else { continue }
                if token.negated { query.excluded.append(token.text) } else { query.phrases.append(token.text) }
                continue
            }
            if token.negated {
                if !token.text.isEmpty { query.excluded.append(token.text) }
                continue
            }
            if query.applyFilter(token.text) { continue }
            query.terms.append(token.text)
        }
        return query
    }

    /// Returns true if `text` was a recognised filter and has been applied.
    private mutating func applyFilter(_ text: String) -> Bool {
        // ".pdf" on its own means ext:pdf
        if text.hasPrefix("."), let ext = Self.cleanExtension(String(text.dropFirst())), text.count <= 11 {
            if !extensions.contains(ext) { extensions.append(ext) }
            return true
        }
        guard let colon = text.firstIndex(where: { $0 == ":" || $0 == "：" }) else { return false }
        let key = text[..<colon].lowercased()
        let value = String(text[text.index(after: colon)...])
        guard !value.isEmpty else { return false }
        switch key {
        case "ext", "扩展名":
            let parts = value.split(separator: ",").compactMap { Self.cleanExtension(String($0)) }
            guard !parts.isEmpty else { return false }
            for ext in parts where !extensions.contains(ext) { extensions.append(ext) }
            return true
        case "kind", "type", "类型":
            guard let kind = Kind.aliases[value.lowercased()] else { return false }
            self.kind = kind
            return true
        case "days", "天":
            guard let days = Int(value), (1...3650).contains(days) else { return false }
            modifiedWithinDays = days
            return true
        default:
            return false
        }
    }

    static func cleanExtension(_ raw: String) -> String? {
        var ext = raw.lowercased()
        while ext.hasPrefix(".") { ext.removeFirst() }
        guard (1...10).contains(ext.count), ext.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        return ext
    }

    struct Token: Equatable {
        var text: String
        var quoted: Bool
        var negated: Bool
    }

    static func tokenize(_ input: String) -> [Token] {
        let chars = Array(input)
        var tokens: [Token] = []
        var i = 0
        while i < chars.count {
            if chars[i].isWhitespace { i += 1; continue }
            var negated = false
            if chars[i] == "-" {
                negated = true
                i += 1
            }
            if i < chars.count, chars[i] == "\"" || chars[i] == "“" {
                let closing: Character = chars[i] == "“" ? "”" : "\""
                i += 1
                var text = ""
                while i < chars.count, chars[i] != closing {
                    text.append(chars[i])
                    i += 1
                }
                i += 1 // skip the closing quote (or step past the end)
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty { tokens.append(Token(text: trimmed, quoted: true, negated: negated)) }
                continue
            }
            var text = ""
            while i < chars.count, !chars[i].isWhitespace {
                text.append(chars[i])
                i += 1
            }
            if !text.isEmpty { tokens.append(Token(text: text, quoted: false, negated: negated)) }
        }
        return tokens
    }

    // MARK: Local matching (used for app / recent candidates and as a safety filter)

    /// Whether a file name satisfies the name, exclusion and extension parts of the query.
    public func matchesName(_ name: String, alternateName: String? = nil) -> Bool {
        let names = [name, alternateName].compactMap { $0 }.map(TextFolding.fold)
        for needle in nameNeedles.map(TextFolding.fold) where !needle.isEmpty {
            guard names.contains(where: { $0.contains(needle) }) else { return false }
        }
        return passesExclusionsAndExtensions(name, alternateName: alternateName)
    }

    public func passesExclusionsAndExtensions(_ name: String, alternateName: String? = nil) -> Bool {
        let names = [name, alternateName].compactMap { $0 }.map(TextFolding.fold)
        for word in excluded.map(TextFolding.fold) where !word.isEmpty {
            if names.contains(where: { $0.contains(word) }) { return false }
        }
        if !extensions.isEmpty {
            let ext = (name as NSString).pathExtension.lowercased()
            guard extensions.contains(ext) else { return false }
        }
        return true
    }
}
