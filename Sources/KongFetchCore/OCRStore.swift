import Foundation
import CryptoKit

/// Text recognized from one scanned PDF or image.
public struct OCRRecord: Codable, Equatable {
    public var path: String
    /// File size and modification date when recognized; a change means the text is stale.
    public var size: Int
    public var modified: Date
    /// One string per recognized page (a single entry for an image).
    public var pages: [String]
    /// Pages in the document; more than `pages.count` when the page limit cut recognition short.
    public var totalPages: Int
    public var recognized: Date

    public init(path: String, size: Int, modified: Date, pages: [String], totalPages: Int, recognized: Date = Date()) {
        self.path = path
        self.size = size
        self.modified = modified
        self.pages = pages
        self.totalPages = totalPages
        self.recognized = recognized
    }

    public var isTruncated: Bool { pages.count < totalPages }
    public var characterCount: Int { pages.reduce(0) { $0 + $1.count } }
}

/// A place in recognized text that matches a search.
public struct OCRHit: Equatable {
    public var path: String
    /// 1-based page, or nil for an image.
    public var page: Int?
    public var snippet: Snippet
}

/// Stores recognized text on disk (one small JSON file per document) and searches it in memory.
/// Thread-safe.
public final class OCRStore {
    public let directory: URL
    private var records: [String: OCRRecord] = [:]
    private let lock = NSLock()

    public init(directory: URL) {
        self.directory = directory
    }

    /// Reads every saved record. Unreadable files are skipped.
    public func load() {
        let fm = FileManager.default
        var loaded: [String: OCRRecord] = [:]
        let names = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
        let decoder = JSONDecoder()
        for name in names where name.hasSuffix(".json") {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)),
                  let record = try? decoder.decode(OCRRecord.self, from: data) else { continue }
            loaded[record.path] = record
        }
        lock.lock()
        records = loaded
        lock.unlock()
    }

    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return records.count
    }

    /// Documents with recognized text (not counting PDFs that already had text, or failures).
    public var recognizedDocumentCount: Int {
        lock.lock(); defer { lock.unlock() }
        return records.values.filter { $0.characterCount > 0 }.count
    }

    public var allPaths: [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(records.keys)
    }

    public func record(for path: String) -> OCRRecord? {
        lock.lock(); defer { lock.unlock() }
        return records[path]
    }

    /// True when the file was recognized as it is now, with at least `pageLimit` pages (or all of them).
    public func isCurrent(path: String, size: Int, modified: Date, pageLimit: Int) -> Bool {
        guard let record = record(for: path) else { return false }
        let sameFile = record.size == size && abs(record.modified.timeIntervalSince(modified)) < 1
        let enoughPages = !record.isTruncated || record.pages.count >= pageLimit
        return sameFile && enoughPages
    }

    public func save(_ record: OCRRecord) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(record)
        try data.write(to: fileURL(for: record.path), options: .atomic)
        lock.lock()
        records[record.path] = record
        lock.unlock()
    }

    public func remove(_ path: String) {
        try? FileManager.default.removeItem(at: fileURL(for: path))
        lock.lock()
        records[path] = nil
        lock.unlock()
    }

    /// Removes records for which `keep` returns false.
    public func prune(keep: (String) -> Bool) {
        for path in allPaths where !keep(path) { remove(path) }
    }

    public func clear() {
        for path in allPaths { remove(path) }
    }

    /// Documents whose recognized text contains every needle, best first.
    public func search(_ needles: [String], limit: Int = 200, accept: (String) -> Bool = { _ in true }) -> [OCRHit] {
        let needles = needles.filter { !$0.isEmpty }
        guard !needles.isEmpty else { return [] }
        lock.lock()
        let snapshot = Array(records.values)
        lock.unlock()
        var hits: [OCRHit] = []
        for record in snapshot where accept(record.path) {
            if let hit = Self.match(record, needles: needles) { hits.append(hit) }
            if hits.count >= limit { break }
        }
        return hits
    }

    /// The first passage in a document matching the needles.
    public func hit(for path: String, needles: [String]) -> OCRHit? {
        guard let record = record(for: path) else { return nil }
        return Self.match(record, needles: needles.filter { !$0.isEmpty })
    }

    static func match(_ record: OCRRecord, needles: [String]) -> OCRHit? {
        guard !needles.isEmpty else { return nil }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]
        // Every needle must occur somewhere in the document.
        for needle in needles where !record.pages.contains(where: { $0.range(of: needle, options: options) != nil }) {
            return nil
        }
        for (index, page) in record.pages.enumerated() {
            if let snippet = Snippet.find(in: page, needles: needles) {
                let isDocument = record.totalPages > 1 || (record.path as NSString).pathExtension.lowercased() == "pdf"
                return OCRHit(path: record.path, page: isDocument ? index + 1 : nil, snippet: snippet)
            }
        }
        return nil
    }

    private func fileURL(for path: String) -> URL {
        let digest = SHA256.hash(data: Data(path.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(digest + ".json")
    }
}
