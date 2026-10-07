import Foundation

/// On-disk storage: a small JSON index plus one blob file per image / rich text.
///
/// Layout: `<directory>/index.json`, `<directory>/blobs/<uuid>.png|jpg|rtf`.
/// The directory is private (0700) and excluded from Time Machine backups.
public final class ClipboardStore {
    public struct LoadResult {
        public var items: [ClipItem]
        /// Entries skipped because they were invalid or their blob was missing.
        public var dropped: Int
        /// If the index could not be read at all, it was moved here instead of being overwritten.
        public var quarantinedIndex: URL?
    }

    private struct IndexFile: Codable {
        var version: Int
        var items: [ClipItem]
    }

    /// Decodes each entry independently so one bad entry cannot discard the whole history.
    private struct LossyIndexFile: Decodable {
        var items: [ClipItem?]

        private enum CodingKeys: String, CodingKey { case version, items }
        private struct Skip: Decodable { init(from decoder: Decoder) throws {} }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            var list = try container.nestedUnkeyedContainer(forKey: .items)
            var result: [ClipItem?] = []
            while !list.isAtEnd {
                if let item = try? list.decode(ClipItem.self) {
                    result.append(item)
                } else {
                    _ = try? list.decode(Skip.self)
                    result.append(nil)
                }
            }
            items = result
        }
    }

    public let directory: URL
    public var indexURL: URL { directory.appendingPathComponent("index.json") }
    public var blobsURL: URL { directory.appendingPathComponent("blobs", isDirectory: true) }

    public init(directory: URL) {
        self.directory = directory
    }

    public func load() -> LoadResult {
        let fm = FileManager.default
        guard fm.fileExists(atPath: indexURL.path) else { return LoadResult(items: [], dropped: 0, quarantinedIndex: nil) }
        do {
            let data = try Data(contentsOf: indexURL)
            let decoded = try JSONDecoder().decode(LossyIndexFile.self, from: data)
            var seenIDs = Set<UUID>()
            var seenFingerprints = Set<String>()
            var items: [ClipItem] = []
            var dropped = 0
            for candidate in decoded.items {
                guard let item = candidate,
                      item.isStructurallyValid,
                      !seenIDs.contains(item.id),
                      !seenFingerprints.contains(item.fingerprint),
                      blobsExist(for: item) else {
                    dropped += 1
                    continue
                }
                seenIDs.insert(item.id)
                seenFingerprints.insert(item.fingerprint)
                items.append(item)
            }
            return LoadResult(items: items, dropped: dropped, quarantinedIndex: nil)
        } catch {
            // Keep the unreadable file for inspection instead of overwriting it on the next save.
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            let target = directory.appendingPathComponent("index-unreadable-\(stamp).json")
            try? fm.moveItem(at: indexURL, to: target)
            return LoadResult(items: [], dropped: 0, quarantinedIndex: target)
        }
    }

    public func save(_ items: [ClipItem]) throws {
        try prepareDirectory()
        let data = try JSONEncoder().encode(IndexFile(version: 1, items: items))
        try data.write(to: indexURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: indexURL.path)
    }

    /// Writes a blob and returns its file name.
    public func writeBlob(_ data: Data, fileExtension: String) throws -> String {
        try prepareDirectory()
        let name = UUID().uuidString + "." + fileExtension
        guard ClipItem.isSafeBlobName(name) else { throw CocoaError(.fileWriteInvalidFileName) }
        let url = blobsURL.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return name
    }

    public func blobURL(_ name: String) -> URL? {
        guard ClipItem.isSafeBlobName(name) else { return nil }
        return blobsURL.appendingPathComponent(name)
    }

    public func readBlob(_ name: String) -> Data? {
        blobURL(name).flatMap { try? Data(contentsOf: $0) }
    }

    public func removeBlob(_ name: String?) {
        guard let name, let url = blobURL(name) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Deletes blob files no entry refers to (left over from crashes).
    public func removeOrphanBlobs(keeping items: [ClipItem]) {
        let referenced = Set(items.flatMap { [$0.imageFile, $0.richTextFile].compactMap { $0 } })
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: blobsURL.path) else { return }
        for name in names where ClipItem.isSafeBlobName(name) && !referenced.contains(name) {
            removeBlob(name)
        }
    }

    private func blobsExist(for item: ClipItem) -> Bool {
        for name in [item.imageFile, item.richTextFile].compactMap({ $0 }) {
            guard let url = blobURL(name), FileManager.default.fileExists(atPath: url.path) else { return false }
        }
        return true
    }

    private func prepareDirectory() throws {
        let fm = FileManager.default
        for url in [directory, blobsURL] {
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: url.path, isDirectory: &isDirectory) {
                let attributes = try fm.attributesOfItem(atPath: url.path)
                if attributes[.type] as? FileAttributeType == .typeSymbolicLink || !isDirectory.boolValue {
                    throw CocoaError(.fileWriteNoPermission)
                }
            } else {
                try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
        }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutable = directory
        try? mutable.setResourceValues(values)
    }
}
