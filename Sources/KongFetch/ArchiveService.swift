import AppKit
import KongFetchCore

/// Keeps the list of files inside .zip archives in the indexed folders, and opens a single file from an archive.
final class ArchiveService {
    let index = ArchiveIndex()
    private let cacheURL: URL
    private let queue = DispatchQueue(label: "KongFetch.archives", qos: .utility)
    private var timer: Timer?
    private var generation = 0
    private(set) var isScanning = false
    private(set) var lastScan: Date?
    var onChange: (() -> Void)?

    /// Archives larger than this are not opened for their table of contents.
    static let maximumArchiveSize = 4_000_000_000
    /// Entries kept per archive.
    static let maximumEntries = 50_000

    init(cacheURL: URL) {
        self.cacheURL = cacheURL
        queue.async { [index] in index.load(from: cacheURL) }
    }

    /// Scans `roots` now and then every two hours; an empty list stops and forgets everything.
    func configure(roots: [String]) {
        timer?.invalidate()
        timer = nil
        guard !roots.isEmpty else {
            generation += 1
            queue.async { [index, cacheURL] in
                index.prune { _ in false }
                try? index.save(to: cacheURL)
            }
            return
        }
        scan(roots)
        let timer = Timer(timeInterval: 2 * 3600, repeats: true) { [weak self] _ in self?.scan(roots) }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func scan(_ roots: [String]) {
        generation += 1
        let current = generation
        isScanning = true
        onChange?()
        queue.async { [weak self] in
            guard let self else { return }
            var seen = Set<String>()
            let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .ubiquitousItemDownloadingStatusKey]
            for root in roots {
                guard let enumerator = FileManager.default.enumerator(at: URL(fileURLWithPath: root), includingPropertiesForKeys: keys,
                                                                      options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
                for case let url as URL in enumerator {
                    guard current == self.generation else { return }
                    let name = url.lastPathComponent
                    if ["node_modules", ".build", "DerivedData", "Pods", ".git"].contains(name) {
                        enumerator.skipDescendants()
                        continue
                    }
                    guard url.pathExtension.lowercased() == "zip",
                          let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true,
                          values.ubiquitousItemDownloadingStatus != .notDownloaded else { continue }
                    let path = url.path
                    seen.insert(path)
                    let size = values.fileSize ?? 0
                    let modified = values.contentModificationDate ?? .distantPast
                    guard size <= Self.maximumArchiveSize, !self.index.isCurrent(path: path, size: size, modified: modified) else { continue }
                    let names = (try? ZipReader.entries(at: url, limit: Self.maximumEntries))?
                        .filter(ZipReader.isListable).map(\.name) ?? []
                    self.index.update(.init(path: path, size: size, modified: modified.timeIntervalSince1970, names: names))
                }
            }
            guard current == self.generation else { return }
            self.index.prune { seen.contains($0) }
            try? self.index.save(to: self.cacheURL)
            DispatchQueue.main.async {
                self.isScanning = false
                self.lastScan = Date()
                self.onChange?()
            }
        }
    }

    /// Extracts one file from an archive into KongFetch's cache and opens it with its default app.
    static func open(inner: String, in archive: URL, completion: @escaping (Error?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                guard let entry = try ZipReader.entries(at: archive).first(where: { $0.name == inner }) else {
                    throw CocoaError(.fileNoSuchFile)
                }
                let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("com.kongxiangrui.KongFetch/压缩包中的文件", isDirectory: true)
                let folder = caches.appendingPathComponent(archive.deletingPathExtension().lastPathComponent + "-" + String(UUID().uuidString.prefix(6)))
                let destination = folder.appendingPathComponent(entry.fileName)
                try ZipReader.extract(entry, from: archive, to: destination)
                DispatchQueue.main.async {
                    NSWorkspace.shared.open(destination)
                    completion(nil)
                }
            } catch {
                DispatchQueue.main.async { completion(error) }
            }
        }
    }
}
