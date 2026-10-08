import Foundation

/// Names of the files inside .zip archives, so a search can find a file packed in an archive. Thread-safe.
public final class ArchiveIndex {
    public struct Archive: Codable, Equatable {
        public var path: String
        public var size: Int
        public var modified: Double
        /// Paths inside the archive (files only).
        public var names: [String]
        public init(path: String, size: Int, modified: Double, names: [String]) {
            self.path = path
            self.size = size
            self.modified = modified
            self.names = names
        }
    }

    public struct Hit: Equatable {
        public var archive: String
        public var inner: String
        public var score: Int
    }

    private var archives: [String: Archive] = [:]
    /// Folded file names (last path component) per archive, matching `names`, for fast searching.
    private var foldedNames: [String: [String]] = [:]
    private let lock = NSLock()

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }

    public init() {}

    public var archiveCount: Int { locked { archives.count } }
    public var entryCount: Int { locked { archives.values.reduce(0) { $0 + $1.names.count } } }

    public func isCurrent(path: String, size: Int, modified: Date) -> Bool {
        locked {
            guard let archive = archives[path] else { return false }
            return archive.size == size && abs(archive.modified - modified.timeIntervalSince1970) < 1
        }
    }

    public func update(_ archive: Archive) {
        let folded = archive.names.map { TextFolding.fold(($0 as NSString).lastPathComponent) }
        locked {
            archives[archive.path] = archive
            foldedNames[archive.path] = folded
        }
    }

    /// Forgets archives for which `keep` is false (deleted, or no longer in a scanned folder).
    public func prune(keeping keep: (String) -> Bool) {
        locked {
            archives = archives.filter { keep($0.key) }
            foldedNames = foldedNames.filter { archives[$0.key] != nil }
        }
    }

    /// Files inside archives whose own name (not folder) contains every needle; ranked like file names.
    public func search(_ needles: [String], limit: Int = 100, accept: (String) -> Bool = { _ in true }) -> [Hit] {
        let folded = needles.map(TextFolding.fold).filter { !$0.isEmpty }
        guard !folded.isEmpty else { return [] }
        let snapshot = locked { archives.values.map { ($0, foldedNames[$0.path] ?? []) } }
        var hits: [Hit] = []
        for (archive, names) in snapshot where accept(archive.path) && names.count == archive.names.count {
            for (index, foldedName) in names.enumerated() where folded.allSatisfy({ foldedName.contains($0) }) {
                let inner = archive.names[index]
                guard let score = Ranker.nameScore(name: (inner as NSString).lastPathComponent, needles: needles) else { continue }
                hits.append(Hit(archive: archive.path, inner: inner, score: score))
            }
        }
        return Array(hits.sorted { $0.score != $1.score ? $0.score > $1.score : $0.inner < $1.inner }.prefix(limit))
    }

    public func save(to url: URL) throws {
        let data = try locked { try JSONEncoder().encode(Array(archives.values)) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    public func load(from url: URL) {
        guard let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([Archive].self, from: data) else { return }
        for archive in list { update(archive) }
    }
}
