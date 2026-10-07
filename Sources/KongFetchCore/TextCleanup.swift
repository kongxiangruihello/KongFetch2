import Foundation

/// Tidies text copied from PDFs and web pages: hard line breaks, broken words, half-width
/// punctuation in Chinese, stray spaces, and traditional/simplified characters.
public enum TextCleanup {
    public enum Operation: String, CaseIterable, Codable, Identifiable {
        /// Joins lines that were broken only by the page width, keeping real paragraphs.
        case joinLines
        /// Turns , . ; : ? ! ( ) " next to Chinese into their full-width forms.
        case chinesePunctuation
        /// Removes spaces between Chinese characters, collapses runs and odd space characters.
        case spaces
        case toSimplified
        case toTraditional

        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .joinLines: return "去除多余换行（保留段落）"
            case .chinesePunctuation: return "中文标点改为全角"
            case .spaces: return "清理多余空格"
            case .toSimplified: return "转为简体"
            case .toTraditional: return "转为繁体"
            }
        }

        public var shortTitle: String {
            switch self {
            case .joinLines: return "去换行"
            case .chinesePunctuation: return "全角标点"
            case .spaces: return "清理空格"
            case .toSimplified: return "转简体"
            case .toTraditional: return "转繁体"
            }
        }
    }

    /// The operations "整理" applies unless the user chose others.
    public static let defaultOperations: [Operation] = [.joinLines, .spaces, .chinesePunctuation]

    /// Applies operations in a fixed, sensible order whatever order they were given in.
    public static func apply(_ operations: [Operation], to text: String) -> String {
        var result = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let set = Set(operations)
        if set.contains(.spaces) { result = normalizeSpaces(result) }
        if set.contains(.joinLines) { result = joinLines(result) }
        if set.contains(.chinesePunctuation) { result = chinesePunctuation(result) }
        if set.contains(.spaces) { result = normalizeSpaces(result) }
        if set.contains(.toSimplified) { result = convertScript(result, toSimplified: true) }
        else if set.contains(.toTraditional) { result = convertScript(result, toSimplified: false) }
        return result
    }

    // MARK: Character classes

    /// Han characters, kana and hangul: scripts written without spaces between words.
    static func isWideLetter(_ c: Character) -> Bool {
        guard let v = c.unicodeScalars.first?.value else { return false }
        return (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v) || (0x20000...0x3134F).contains(v) ||
            (0xF900...0xFAFF).contains(v) || (0x3040...0x30FF).contains(v) || (0xAC00...0xD7AF).contains(v) ||
            (0x2E80...0x2FDF).contains(v) || v == 0x3007
    }

    /// CJK and full-width punctuation (unambiguously Chinese/Japanese).
    static func isCJKPunctuation(_ c: Character) -> Bool {
        guard let v = c.unicodeScalars.first?.value else { return false }
        return (0x3001...0x303F).contains(v) || (0xFF01...0xFF0F).contains(v) || (0xFF1A...0xFF20).contains(v) ||
            (0xFF3B...0xFF40).contains(v) || (0xFF5B...0xFF65).contains(v) || (0xFE10...0xFE1F).contains(v) ||
            (0xFE30...0xFE4F).contains(v)
    }

    /// Curly quotes, dashes and the ellipsis: Chinese text uses them, but so does English.
    static func isSharedPunctuation(_ c: Character) -> Bool { "“”‘’—…·".contains(c) }

    static func isWidePunctuation(_ c: Character) -> Bool { isCJKPunctuation(c) || isSharedPunctuation(c) }

    static func isWide(_ c: Character) -> Bool { isWideLetter(c) || isWidePunctuation(c) }

    /// Whether `c` belongs to running Chinese text. Shared punctuation counts only when the text is mostly Chinese.
    static func isWide(_ c: Character, chinese: Bool) -> Bool {
        isWideLetter(c) || isCJKPunctuation(c) || (chinese && isSharedPunctuation(c))
    }

    /// More Han characters than Latin letters.
    static func isMostlyChinese(_ text: String) -> Bool {
        var han = 0, latin = 0
        for c in text {
            if isWideLetter(c) { han += 1 } else if c.isASCII && c.isLetter { latin += 1 }
        }
        return han > latin
    }

    static func isHan(_ c: Character?) -> Bool { c.map(isWideLetter) ?? false }

    static func isASCIIAlphanumeric(_ c: Character?) -> Bool {
        guard let c, c.isASCII else { return false }
        return c.isLetter || c.isNumber
    }

    /// Display width: wide characters count as two.
    static func width(_ s: Substring) -> Int {
        s.reduce(0) { $0 + (isWide($1) ? 2 : 1) }
    }

    // MARK: Line breaks

    private static let sentenceEnds: Set<Character> = ["。", "！", "？", "!", "?", ".", "…", "”", "」", "』", "：", ":", "；", ";", "）", ")"]
    private static let listItem = try! NSRegularExpression(
        pattern: #"^\s*(?:[•·▪●■◆\-\*–—]\s|\d{1,3}[\.、．)）](?!\d)\s*\S|[（(][一二三四五六七八九十\d]{1,3}[)）]|[一二三四五六七八九十]{1,3}、|第[一二三四五六七八九十百\d]+[章节編编卷部篇条])"#)

    /// Joins lines broken only by the page width. Blank lines, indented lines, list items and lines that
    /// end a sentence well short of the full width start new paragraphs.
    public static func joinLines(_ text: String) -> String {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
        // Split into blocks at blank lines.
        var blocks: [[Substring]] = [[]]
        for line in lines {
            if line.allSatisfy({ $0.isWhitespace }) {
                if !(blocks.last?.isEmpty ?? true) { blocks.append([]) }
            } else {
                blocks[blocks.count - 1].append(line)
            }
        }
        blocks.removeAll { $0.isEmpty }
        guard !blocks.isEmpty else { return text.trimmingCharacters(in: .whitespacesAndNewlines) }
        // Some PDF viewers put a blank line after every line; then the blank lines mean nothing.
        if blocks.count >= 3, blocks.allSatisfy({ $0.count == 1 }) {
            blocks = [blocks.map { $0[0] }]
        }
        let chinese = isMostlyChinese(normalized)
        return blocks.flatMap { paragraphs(in: $0, chinese: chinese) }.joined(separator: "\n")
    }

    private static func paragraphs(in block: [Substring], chinese: Bool) -> [String] {
        let trimmedLines = block.map { line -> Substring in
            var end = line.endIndex
            while end > line.startIndex, line[line.index(before: end)].isWhitespace { end = line.index(before: end) }
            return line[line.startIndex..<end]
        }
        let fullWidth = trimmedLines.map(width).max() ?? 0
        var result: [String] = []
        var current = String(trimmedLines[0])
        for index in trimmedLines.indices.dropFirst() {
            let previous = trimmedLines[index - 1]
            let next = trimmedLines[index]
            if startsParagraph(previous: previous, next: next, previousIsFirst: index == 1, fullWidth: fullWidth, chinese: chinese) {
                result.append(current)
                current = String(next)
                continue
            }
            let body = next.drop { $0.isWhitespace }
            guard let last = current.last, let first = body.first else { current.append(contentsOf: body); continue }
            if last == "-", current.count >= 2, current[current.index(current.endIndex, offsetBy: -2)].isLetter,
               first.isLowercase, first.isASCII {
                current.removeLast()           // "compre-\nhensive" → "comprehensive"
                current.append(contentsOf: body)
            } else if isWide(last, chinese: chinese) || isWide(first, chinese: chinese) || last == "-" || last == "/" {
                current.append(contentsOf: body)
            } else {
                current.append(" ")
                current.append(contentsOf: body)
            }
        }
        result.append(current)
        return result
    }

    private static func startsParagraph(previous: Substring, next: Substring, previousIsFirst: Bool, fullWidth: Int, chinese: Bool) -> Bool {
        // Indented: two full-width spaces, a tab, or two or more spaces.
        if next.hasPrefix("\u{3000}") || next.hasPrefix("\t") || next.hasPrefix("  ") { return true }
        if looksLikeListItem(next) { return true }
        guard fullWidth >= 20 else { return false }
        let previousWidth = width(previous)
        // Chinese lines are nearly equal in width; proportional Latin text varies more.
        let sentenceLimit = chinese ? 85 : 70
        let shortLimit = chinese ? 60 : 50
        // The first line may be short only because the selection started in the middle of it;
        // a numbered heading such as "第一章" still stands alone.
        if previousIsFirst { return looksLikeListItem(previous) && previousWidth < fullWidth * shortLimit / 100 }
        // A sentence that ends well before the right margin ends its paragraph.
        if let last = previous.last, sentenceEnds.contains(last), previousWidth < fullWidth * sentenceLimit / 100 { return true }
        // A much shorter line is a heading or the end of a paragraph.
        return previousWidth < fullWidth * shortLimit / 100
    }

    private static func looksLikeListItem(_ line: Substring) -> Bool {
        let string = String(line)
        return listItem.firstMatch(in: string, range: NSRange(location: 0, length: (string as NSString).length)) != nil
    }

    // MARK: Punctuation

    private static let fullWidthForms: [Character: Character] = [",": "，", ";": "；", ":": "：", "?": "？", "!": "！"]

    /// Converts half-width punctuation that sits next to Chinese characters. Numbers, URLs and
    /// English sentences are left alone.
    public static func chinesePunctuation(_ text: String) -> String {
        guard text.contains(where: isWideLetter) else { return text }
        let chars = Array(text)
        var out: [Character] = []
        out.reserveCapacity(chars.count)
        var quoteOpen = false
        /// For each "(" still open: whether it was converted, so its ")" matches.
        var parens: [Bool] = []
        var i = 0

        func nextNonSpace(after index: Int) -> Character? {
            var j = index + 1
            while j < chars.count, chars[j] == " " { j += 1 }
            return j < chars.count ? chars[j] : nil
        }
        /// Index of the first character after the spaces following `index`.
        func afterSpaces(_ index: Int) -> Int {
            var j = index + 1
            while j < chars.count, chars[j] == " " { j += 1 }
            return j
        }

        while i < chars.count {
            let c = chars[i]
            if c == "\n" { quoteOpen = false; parens.removeAll() }
            let prev = out.last(where: { $0 != " " })
            let next = nextNonSpace(after: i)
            let prevIsWide = prev.map { isWideLetter($0) || isWidePunctuation($0) } ?? false
            let nextIsWide = next.map { isWideLetter($0) || isWidePunctuation($0) } ?? false
            func dropTrailingSpaces() { while out.last == " " { out.removeLast() } }

            switch c {
            case ".":
                var run = 0
                while i + run < chars.count, chars[i + run] == "." { run += 1 }
                if run >= 3, prevIsWide {
                    // "..." after Chinese is an ellipsis.
                    dropTrailingSpaces()
                    out += ["…", "…"]
                    let j = afterSpaces(i + run - 1)
                    i = j < chars.count && isWide(chars[j]) ? j : i + run
                    continue
                }
                if run == 1, isHan(prev), next == nil || next == "\n" || nextIsWide {
                    dropTrailingSpaces()
                    out.append("。")
                    i = afterSpaces(i)
                    continue
                }
                out += Array(repeating: Character("."), count: run)
                i += run
                continue
            case ",", ";", ":", "?", "!":
                if isHan(prev) || (isHan(next) && prev != nil && !isASCIIAlphanumeric(prev)) {
                    dropTrailingSpaces()
                    out.append(fullWidthForms[c]!)
                    i = afterSpaces(i)
                    continue
                }
            case "(":
                let convert = isHan(prev) || isHan(next)
                parens.append(convert)
                if convert {
                    if isHan(prev) { dropTrailingSpaces() }
                    out.append("（")
                    i = afterSpaces(i)
                    continue
                }
            case ")":
                let convert = parens.isEmpty ? (isHan(prev) || isHan(next)) : parens.removeLast()
                if convert {
                    dropTrailingSpaces()
                    out.append("）")
                    i = isHan(next) ? afterSpaces(i) : i + 1
                    continue
                }
            case "\"":
                if quoteOpen {
                    dropTrailingSpaces()
                    out.append("”")
                    quoteOpen = false
                    i += 1
                    continue
                }
                if isHan(prev) || isHan(next) {
                    if prevIsWide { dropTrailingSpaces() }
                    out.append("“")
                    quoteOpen = true
                    i = afterSpaces(i)
                    continue
                }
            default:
                break
            }
            out.append(c)
            i += 1
        }
        return String(out)
    }

    // MARK: Spaces

    /// Removes zero-width characters, turns odd space characters into plain spaces, removes spaces
    /// between Chinese characters and next to Chinese punctuation, collapses runs, trims line ends
    /// and allows at most one blank line in a row. Indentation at the start of a line is kept.
    public static func normalizeSpaces(_ text: String) -> String {
        var cleaned = ""
        cleaned.unicodeScalars.reserveCapacity(text.unicodeScalars.count)
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x200B, 0x200C, 0x200D, 0x2060, 0xFEFF, 0x00AD: continue
            case 0x00A0, 0x2000...0x200A, 0x202F, 0x205F: cleaned.unicodeScalars.append(" ")
            default: cleaned.unicodeScalars.append(scalar)
            }
        }
        let chinese = isMostlyChinese(cleaned)
        var lines: [String] = []
        var blankRun = 0
        for line in cleaned.split(separator: "\n", omittingEmptySubsequences: false) {
            let indentEnd = line.firstIndex { $0 != " " && $0 != "\t" && $0 != "\u{3000}" } ?? line.endIndex
            let indent = line[line.startIndex..<indentEnd]
            let body = Array(line[indentEnd...])
            var out: [Character] = []
            var k = 0
            while k < body.count {
                let c = body[k]
                guard c == " " || c == "\t" else {
                    out.append(c)
                    k += 1
                    continue
                }
                var j = k
                while j < body.count, body[j] == " " || body[j] == "\t" { j += 1 }
                if j < body.count, let before = out.last {
                    let after = body[j]
                    let bothWide = isWide(before, chinese: chinese) && isWide(after, chinese: chinese)
                    let touchesCJKPunctuation = isCJKPunctuation(before) || isCJKPunctuation(after)
                    if !bothWide && !touchesCJKPunctuation { out.append(" ") }
                }
                k = j
            }
            if out.isEmpty {
                blankRun += 1
                if blankRun == 1 { lines.append("") }
            } else {
                blankRun = 0
                lines.append(String(indent) + String(out))
            }
        }
        while lines.first == "" { lines.removeFirst() }
        while lines.last == "" { lines.removeLast() }
        return lines.joined(separator: "\n")
    }

    // MARK: Traditional and simplified

    /// Character-by-character conversion with the ICU transforms built into macOS. Simplified to
    /// traditional is one-to-many (发 → 發/髮), so the result needs proofreading.
    public static func convertScript(_ text: String, toSimplified: Bool) -> String {
        let id = toSimplified ? "Traditional-Simplified" : "Simplified-Traditional"
        return text.applyingTransform(StringTransform(rawValue: id), reverse: false) ?? text
    }
}
