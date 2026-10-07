import Foundation

/// Files and apps opened through KongFetch, used for the empty-query list and ranking.
public final class RecentItems {
    public struct Entry: Codable, Equatable {
        public var path: String
        public var lastOpened: Date
        public var count: Int
    }

    public let fileURL: URL
    public private(set) var entries: [Entry] = []
    public var maximumEntries = 200

    public init(fileURL: URL) {
        self.fileURL = fileURL
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = decoded.filter { $0.path.hasPrefix("/") }.sorted { $0.lastOpened > $1.lastOpened }
        }
    }

    public func record(_ path: String, now: Date = Date()) {
        if let index = entries.firstIndex(where: { $0.path == path }) {
            var entry = entries.remove(at: index)
            entry.lastOpened = now
            entry.count += 1
            entries.insert(entry, at: 0)
        } else {
            entries.insert(Entry(path: path, lastOpened: now, count: 1), at: 0)
        }
        if entries.count > maximumEntries { entries.removeLast(entries.count - maximumEntries) }
        save()
    }

    public func remove(_ path: String) {
        entries.removeAll { $0.path == path }
        save()
    }

    /// Ranking bonus for something opened before: frequency plus recency.
    public func boost(for path: String, now: Date = Date()) -> Int {
        guard let entry = entries.first(where: { $0.path == path }) else { return 0 }
        let age = now.timeIntervalSince(entry.lastOpened)
        let recency: Int
        switch age {
        case ..<86_400: recency = 150
        case ..<(7 * 86_400): recency = 80
        case ..<(30 * 86_400): recency = 30
        default: recency = 0
        }
        return min(entry.count, 20) * 10 + recency
    }

    public func save() {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(entries).write(to: fileURL, options: .atomic)
        } catch {
            // Recents are a convenience; failing to save them must never interrupt opening a file.
        }
    }
}
