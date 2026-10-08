import Foundation

/// Plans new names for a set of files: find and replace, or a template with numbering, plus optional
/// traditional/simplified conversion. Planning never touches the disk; problems are reported per file.
public enum BatchRename {
    public struct Item: Equatable {
        public var path: String
        public var modified: Date?
        public init(path: String, modified: Date? = nil) {
            self.path = path
            self.modified = modified
        }
        public var name: String { (path as NSString).lastPathComponent }
        public var folder: String { (path as NSString).deletingLastPathComponent }
    }

    public enum Mode: String, CaseIterable, Identifiable {
        case replace, template
        public var id: String { rawValue }
        public var title: String { self == .replace ? "查找替换" : "按模板编号" }
    }

    public enum Order: String, CaseIterable, Identifiable {
        case list, name, modified
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .list: return "列表顺序"
            case .name: return "按名称"
            case .modified: return "按修改时间"
            }
        }
    }

    public enum Script: String, CaseIterable, Identifiable {
        case unchanged, simplified, traditional
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .unchanged: return "不转换"
            case .simplified: return "转为简体"
            case .traditional: return "转为繁体"
            }
        }
    }

    public struct Rule: Equatable {
        public var mode: Mode = .replace
        public var find = ""
        public var replacement = ""
        public var useRegex = false
        public var ignoreCase = true
        /// Tokens: {name} original name without extension, {n} number, {date} modified date (yyyyMMdd), {parent} folder name.
        public var template = "{name}"
        public var start = 1
        public var digits = 2
        public var order: Order = .list
        /// Leave the extension alone (the rule applies to the part before it).
        public var keepExtension = true
        public var script: Script = .unchanged
        public init() {}
    }

    public enum Problem: Equatable {
        case empty, invalidCharacter, duplicate, exists, badPattern
        public var message: String {
            switch self {
            case .empty: return "新名称为空"
            case .invalidCharacter: return "不能包含 “/” 或 “:”，也不能以 “.” 开头"
            case .duplicate: return "与本次另一个文件重名"
            case .exists: return "文件夹里已有同名文件"
            case .badPattern: return "正则表达式有误"
            }
        }
    }

    public struct Preview: Equatable {
        public var item: Item
        public var newName: String
        public var problem: Problem?
        public var changed: Bool { newName != item.name }
        public var newPath: String { (item.folder as NSString).appendingPathComponent(newName) }
    }

    /// New names for `items`, in the order numbering used. `exists` answers whether a path is taken on disk.
    public static func plan(_ items: [Item], rule: Rule, exists: (String) -> Bool) -> [Preview] {
        let ordered: [Item]
        switch rule.order {
        case .list: ordered = items
        case .name: ordered = items.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .modified: ordered = items.sorted { ($0.modified ?? .distantPast) < ($1.modified ?? .distantPast) }
        }
        var regex: NSRegularExpression?
        if rule.mode == .replace && rule.useRegex && !rule.find.isEmpty {
            regex = try? NSRegularExpression(pattern: rule.find, options: rule.ignoreCase ? [.caseInsensitive] : [])
            if regex == nil {
                return ordered.map { Preview(item: $0, newName: $0.name, problem: .badPattern) }
            }
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"

        var previews: [Preview] = []
        var emptyStems = Set<Int>()
        for (index, item) in ordered.enumerated() {
            let ext = (item.name as NSString).pathExtension
            let stem = rule.keepExtension && !ext.isEmpty ? (item.name as NSString).deletingPathExtension : item.name
            var newStem: String
            switch rule.mode {
            case .replace:
                if rule.find.isEmpty {
                    newStem = stem
                } else if let regex {
                    newStem = regex.stringByReplacingMatches(in: stem, range: NSRange(location: 0, length: (stem as NSString).length),
                                                             withTemplate: rule.replacement)
                } else {
                    newStem = stem.replacingOccurrences(of: rule.find, with: rule.replacement,
                                                        options: rule.ignoreCase ? [.caseInsensitive] : [])
                }
            case .template:
                let number = String(rule.start + index)
                let padded = String(repeating: "0", count: max(0, rule.digits - number.count)) + number
                newStem = rule.template
                    .replacingOccurrences(of: "{name}", with: stem)
                    .replacingOccurrences(of: "{n}", with: padded)
                    .replacingOccurrences(of: "{date}", with: item.modified.map(formatter.string(from:)) ?? "")
                    .replacingOccurrences(of: "{parent}", with: (item.folder as NSString).lastPathComponent)
            }
            switch rule.script {
            case .unchanged: break
            case .simplified: newStem = TextCleanup.convertScript(newStem, toSimplified: true)
            case .traditional: newStem = TextCleanup.convertScript(newStem, toSimplified: false)
            }
            newStem = newStem.trimmingCharacters(in: .whitespaces)
            if newStem.isEmpty { emptyStems.insert(index) }
            let newName = rule.keepExtension && !ext.isEmpty ? newStem + "." + ext : newStem
            previews.append(Preview(item: item, newName: newName, problem: nil))
        }

        // Problems: invalid names, two files ending up with one name, or a name already used by another file.
        let originals = Set(items.map(\.path))
        var counts: [String: Int] = [:]
        for preview in previews { counts[preview.newPath.lowercased(), default: 0] += 1 }
        for index in previews.indices {
            let preview = previews[index]
            if emptyStems.contains(index) {
                previews[index].problem = .empty
            } else if preview.newName.contains("/") || preview.newName.contains(":") || preview.newName.hasPrefix(".") {
                previews[index].problem = .invalidCharacter
            } else if counts[preview.newPath.lowercased(), default: 0] > 1 {
                previews[index].problem = .duplicate
            } else if preview.changed, preview.newPath.lowercased() != preview.item.path.lowercased(),
                      !originals.contains(preview.newPath), exists(preview.newPath) {
                previews[index].problem = .exists
            }
        }
        return previews
    }

    /// The moves that carry out a plan safely even when names are swapped (a→b, b→a): every changed file first
    /// goes to a temporary name in its folder, then to its final name.
    public static func steps(for previews: [Preview], token: String = UUID().uuidString) -> [(from: String, to: String)] {
        let changed = previews.filter { $0.changed && $0.problem == nil }
        var first: [(String, String)] = []
        var second: [(String, String)] = []
        for (index, preview) in changed.enumerated() {
            let temporary = (preview.item.folder as NSString).appendingPathComponent(".kongfetch-rename-\(token)-\(index)")
            first.append((preview.item.path, temporary))
            second.append((temporary, preview.newPath))
        }
        return first + second
    }
}
