import Foundation

/// A file or folder whose name contains Chinese, with its pinyin.
public struct NameIndexEntry: Equatable {
    public let path: String
    public let isDirectory: Bool
    public let pinyin: PinyinForms

    public init(path: String, isDirectory: Bool, pinyin: PinyinForms) {
        self.path = path
        self.isDirectory = isDirectory
        self.pinyin = pinyin
    }

    public var name: String { (path as NSString).lastPathComponent }
}

/// Pinyin index of file names under a few folders.
///
/// Spotlight cannot match pinyin, so KongFetch keeps its own small index. Only names that contain
/// Chinese characters are stored, which keeps it compact. All methods are thread-safe.
public final class NameIndex {
    private var entries: [String: NameIndexEntry] = [:]
    private let lock = NSLock()

    public init() {}

    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return entries.count
    }

    public func entry(at path: String) -> NameIndexEntry? {
        lock.lock(); defer { lock.unlock() }
        return entries[path]
    }

    /// Replaces everything at or below `root` with `newEntries`.
    public func replaceSubtree(_ root: String, with newEntries: [NameIndexEntry]) {
        let prefix = root.hasSuffix("/") ? root : root + "/"
        lock.lock(); defer { lock.unlock() }
        entries = entries.filter { $0.key != root && !$0.key.hasPrefix(prefix) }
        for entry in newEntries { entries[entry.path] = entry }
    }

    public func removeSubtree(_ root: String) {
        replaceSubtree(root, with: [])
    }

    /// Adds, replaces or removes a single item (nil removes it).
    public func update(_ path: String, with entry: NameIndexEntry?) {
        lock.lock(); defer { lock.unlock() }
        entries[path] = entry
    }

    /// Keeps only entries under the given roots (used when folders are removed from the index).
    public func retainOnly(roots: [String]) {
        let prefixes = roots.map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        lock.lock(); defer { lock.unlock() }
        entries = entries.filter { item in prefixes.contains { item.key.hasPrefix($0) } }
    }

    /// Best pinyin matches for an ASCII word, highest score first.
    public func matches(pinyin word: String, limit: Int = 200, accept: (NameIndexEntry) -> Bool = { _ in true }) -> [(entry: NameIndexEntry, score: Int)] {
        let query = word.lowercased()
        guard query.count >= 2, query.allSatisfy({ $0.isASCII && $0.isLetter }) else { return [] }
        lock.lock()
        var found: [(entry: NameIndexEntry, score: Int)] = []
        for entry in entries.values {
            if let score = Ranker.pinyinScore(forms: entry.pinyin, query: query), accept(entry) {
                found.append((entry, score))
            }
        }
        lock.unlock()
        found.sort { $0.score != $1.score ? $0.score > $1.score : $0.entry.path.count < $1.entry.path.count }
        return Array(found.prefix(limit))
    }

    // MARK: Persistence
    //
    // One line per entry: "d" or "f", path, full pinyin, initials — separated by tabs.

    public func save(to url: URL) throws {
        lock.lock()
        var text = "KFNI1\n"
        for entry in entries.values {
            text += (entry.isDirectory ? "d" : "f") + "\t" + entry.path + "\t" + entry.pinyin.full + "\t" + entry.pinyin.initials + "\n"
        }
        lock.unlock()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url, options: .atomic)
    }

    /// Loads a saved index. Returns false (and stays empty) if the file is missing or not an index.
    @discardableResult
    public func load(from url: URL) -> Bool {
        guard let text = try? String(contentsOf: url, encoding: .utf8), text.hasPrefix("KFNI1\n") else { return false }
        var loaded: [String: NameIndexEntry] = [:]
        for line in text.split(separator: "\n").dropFirst() {
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count == 4, parts[1].hasPrefix("/") else { continue }
            let path = String(parts[1])
            loaded[path] = NameIndexEntry(path: path, isDirectory: parts[0] == "d",
                                          pinyin: PinyinForms(full: String(parts[2]), initials: String(parts[3])))
        }
        lock.lock()
        entries = loaded
        lock.unlock()
        return true
    }
}

/// Walks folders and produces index entries for names that contain Chinese.
public enum NameIndexScanner {
    /// Folders never worth descending into.
    public static let skippedFolderNames: Set<String> = ["node_modules", ".build", "DerivedData", "Pods", ".git", "__pycache__"]

    /// Entry for a single item, or nil if its name has no Chinese or it should be skipped.
    public static func entry(for url: URL, isDirectory: Bool) -> NameIndexEntry? {
        let name = url.lastPathComponent
        guard !name.hasPrefix("."), name.count <= 255, !name.contains("\t"), !name.contains("\n") else { return nil }
        let stem = isDirectory ? name : (name as NSString).deletingPathExtension
        guard let forms = Pinyin.forms(for: stem) else { return nil }
        return NameIndexEntry(path: url.path, isDirectory: isDirectory, pinyin: forms)
    }

    /// Scans `root` recursively. Packages (apps, bundles) count as single items. Stops at `limit` items visited.
    public static func scan(_ root: URL, limit: Int = 2_000_000, isCancelled: () -> Bool = { false }) -> [NameIndexEntry] {
        var result: [NameIndexEntry] = []
        let keys: [URLResourceKey] = [.isDirectoryKey, .isPackageKey]
        if let rootValues = try? root.resourceValues(forKeys: Set(keys)), let entry = entry(for: root, isDirectory: rootValues.isDirectory == true) {
            result.append(entry)
        }
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                              options: [.skipsHiddenFiles, .skipsPackageDescendants],
                                                              errorHandler: { _, _ in true }) else { return result }
        var visited = 0
        for case let url as URL in enumerator {
            visited += 1
            if visited > limit || (visited % 2000 == 0 && isCancelled()) { break }
            let values = try? url.resourceValues(forKeys: Set(keys))
            let isDirectory = values?.isDirectory == true
            if isDirectory && skippedFolderNames.contains(url.lastPathComponent) {
                enumerator.skipDescendants()
                continue
            }
            if let entry = entry(for: url, isDirectory: isDirectory) { result.append(entry) }
        }
        return result
    }
}
