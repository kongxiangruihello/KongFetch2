import Foundation

public enum TextFolding {
    /// Case-, accent- and width-insensitive form used for all name comparisons.
    public static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }
}

/// Pinyin spellings of a name that contains Chinese characters.
public struct PinyinForms: Equatable {
    /// All syllables joined, without tones: "年度合同" → "nianduhetong".
    public let full: String
    /// First letter of each syllable / word: "ndht".
    public let initials: String

    public init(full: String, initials: String) {
        self.full = full
        self.initials = initials
    }
}

public enum Pinyin {
    public static func containsHan(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value) || (0x3400...0x4DBF).contains(scalar.value) || (0xF900...0xFAFF).contains(scalar.value)
        }
    }

    /// Returns nil when the text has no Chinese characters.
    public static func forms(for text: String) -> PinyinForms? {
        guard containsHan(text) else { return nil }
        let latin = text.applyingTransform(.toLatin, reverse: false) ?? text
        let plain = (latin.applyingTransform(.stripDiacritics, reverse: false) ?? latin).lowercased()
        let words = plain.split(whereSeparator: { !($0.isLetter || $0.isNumber) || !$0.isASCII })
        guard !words.isEmpty else { return nil }
        return PinyinForms(full: words.joined(), initials: String(words.compactMap(\.first)))
    }
}

public enum Ranker {
    /// Scores how well `name` matches every needle. Nil means it does not match.
    ///
    /// The first needle decides the base score (exact > prefix > word start > anywhere);
    /// later needles only need to appear. Shorter names win ties.
    public static func nameScore(name: String, needles: [String]) -> Int? {
        let needles = needles.map(TextFolding.fold).filter { !$0.isEmpty }
        guard !needles.isEmpty else { return 0 }
        let full = TextFolding.fold(name)
        let base = TextFolding.fold(stem(of: name))
        var total = 0
        for (index, needle) in needles.enumerated() {
            let score: Int
            if base == needle || full == needle {
                score = 1000
            } else if base.hasPrefix(needle) {
                score = 800
            } else if startsWord(in: base, needle) {
                score = 600
            } else if full.contains(needle) {
                score = 400
            } else {
                return nil
            }
            total += index == 0 ? score : score / 8
        }
        return total - min(base.count, 80)
    }

    /// Scores an ASCII query typed as pinyin against a Chinese name. Nil means no match.
    public static func pinyinScore(forms: PinyinForms, query: String) -> Int? {
        let q = TextFolding.fold(query)
        guard !q.isEmpty, q.allSatisfy({ $0.isASCII && $0.isLetter }) else { return nil }
        if forms.full == q { return 760 }
        if forms.initials == q { return 750 }
        if forms.full.hasPrefix(q) { return 700 }
        if forms.initials.hasPrefix(q) { return 650 }
        if q.count >= 2, forms.full.contains(q) { return 380 }
        if q.count >= 2, forms.initials.contains(q) { return 340 }
        return nil
    }

    /// Name without its extension; folders like "v1.2" keep their dots only if the tail is not a short extension.
    static func stem(of name: String) -> String {
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty, ext.count <= 10, ext.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return name }
        return (name as NSString).deletingPathExtension
    }

    static func startsWord(in haystack: String, _ needle: String) -> Bool {
        let separators: Set<Character> = [" ", "-", "_", ".", "(", "（", "[", "【", "《", "·"]
        var searchStart = haystack.startIndex
        while searchStart < haystack.endIndex, let range = haystack.range(of: needle, range: searchStart..<haystack.endIndex) {
            if range.lowerBound == haystack.startIndex { return true }
            if separators.contains(haystack[haystack.index(before: range.lowerBound)]) { return true }
            searchStart = haystack.index(after: range.lowerBound)
        }
        return false
    }

    /// Penalty for results buried deep in the file system or in places people rarely mean.
    public static func locationPenalty(path: String, home: String) -> Int {
        var penalty = 0
        let depth = path.split(separator: "/").count
        if depth > 7 { penalty += (depth - 7) * 12 }
        if path.contains("/.") { penalty += 300 }
        if path.hasPrefix(home + "/Library/") || path.hasPrefix("/Library/") || path.hasPrefix("/System/Library/") { penalty += 200 }
        if path.contains("/node_modules/") || path.contains("/DerivedData/") || path.contains(".build/") { penalty += 250 }
        return penalty
    }
}
