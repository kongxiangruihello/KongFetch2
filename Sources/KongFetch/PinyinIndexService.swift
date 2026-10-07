import Foundation
import CoreServices
import KongFetchCore

/// Keeps the pinyin name index of the user's main folders current.
///
/// On launch the saved index is loaded (usable at once), then the folders are rescanned in the background
/// and FSEvents keeps the index up to date while KongFetch runs.
final class PinyinIndexService {
    let index = NameIndex()
    private let cacheURL: URL
    private let queue = DispatchQueue(label: "KongFetch.pinyin-index", qos: .utility)
    private var stream: FSEventStreamRef?
    private var roots: [String] = []
    private var scanGeneration = 0
    private var saveScheduled = false

    /// Observed on the main thread.
    private(set) var isScanning = false
    private(set) var lastCompleted: Date?
    var onChange: (() -> Void)?

    init(cacheURL: URL) {
        self.cacheURL = cacheURL
    }

    /// Starts (or restarts) indexing the given folders. An empty list stops indexing and clears the index.
    func start(roots newRoots: [String]) {
        let clean = Array(Set(newRoots.map { ($0 as NSString).standardizingPath })).sorted()
        stopWatching()
        roots = clean
        scanGeneration += 1
        let generation = scanGeneration
        guard !clean.isEmpty else {
            queue.async { self.index.retainOnly(roots: []); try? self.index.save(to: self.cacheURL) }
            notify()
            return
        }
        isScanning = true
        notify()
        queue.async { [weak self] in
            guard let self else { return }
            if self.index.count == 0 { self.index.load(from: self.cacheURL) }
            self.index.retainOnly(roots: clean)
            self.startWatching(clean) // watch first so nothing changed during the scan is missed
            for root in clean {
                guard generation == self.scanGeneration else { return }
                let entries = NameIndexScanner.scan(URL(fileURLWithPath: root)) { generation != self.scanGeneration }
                guard generation == self.scanGeneration else { return }
                self.index.replaceSubtree(root, with: entries)
            }
            try? self.index.save(to: self.cacheURL)
            DispatchQueue.main.async {
                guard generation == self.scanGeneration else { return }
                self.isScanning = false
                self.lastCompleted = Date()
                self.notify()
            }
        }
    }

    func rebuild() {
        let current = roots
        queue.async { self.index.retainOnly(roots: []) }
        start(roots: current)
    }

    private func notify() {
        if Thread.isMainThread { onChange?() } else { DispatchQueue.main.async { self.onChange?() } }
    }

    // MARK: FSEvents

    private func startWatching(_ paths: [String]) {
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                           retain: nil, release: nil, copyDescription: nil)
        let flags = FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagWatchRoot)
        guard let stream = FSEventStreamCreate(kCFAllocatorDefault, pinyinIndexEventCallback, &context, paths as CFArray,
                                               FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 1.5, flags) else { return }
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    private func stopWatching() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    /// Runs on `queue`.
    fileprivate func handle(paths: [String], flags: [FSEventStreamEventFlags]) {
        let fm = FileManager.default
        var rescans = Set<String>()
        for (path, flag) in zip(paths, flags) {
            guard roots.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else { continue }
            if path.split(separator: "/").contains(where: { $0.hasPrefix(".") || NameIndexScanner.skippedFolderNames.contains(String($0)) }) { continue }
            if flag & FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs) != 0 {
                rescans.insert(path)
                continue
            }
            var isDirectory: ObjCBool = false
            if fm.fileExists(atPath: path, isDirectory: &isDirectory) {
                if isDirectory.boolValue {
                    // A new or renamed folder: index everything inside it.
                    rescans.insert(path)
                } else {
                    index.update(path, with: NameIndexScanner.entry(for: URL(fileURLWithPath: path), isDirectory: false))
                }
            } else {
                index.removeSubtree(path)
            }
        }
        // Rescan only the outermost folders.
        for path in rescans where !rescans.contains(where: { $0 != path && path.hasPrefix($0 + "/") }) {
            index.replaceSubtree(path, with: NameIndexScanner.scan(URL(fileURLWithPath: path)))
        }
        scheduleSave()
    }

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        queue.asyncAfter(deadline: .now() + 30) { [weak self] in
            guard let self else { return }
            self.saveScheduled = false
            try? self.index.save(to: self.cacheURL)
        }
    }

    deinit {
        stopWatching()
    }
}

private func pinyinIndexEventCallback(stream: ConstFSEventStreamRef, info: UnsafeMutableRawPointer?, count: Int,
                                      paths: UnsafeMutableRawPointer, flags: UnsafePointer<FSEventStreamEventFlags>,
                                      ids: UnsafePointer<FSEventStreamEventId>) {
    guard let info else { return }
    let service = Unmanaged<PinyinIndexService>.fromOpaque(info).takeUnretainedValue()
    let list = (Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as? [String]) ?? []
    let flagList = Array(UnsafeBufferPointer(start: flags, count: count))
    service.handle(paths: list, flags: flagList)
}
