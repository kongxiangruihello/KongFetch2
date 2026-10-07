import Foundation

/// The in-memory clipboard history with limits, persistence and blob bookkeeping.
/// Use from the main thread; saving happens on a background queue.
public final class ClipboardHistory {
    public struct Limits: Equatable {
        public var maximumItems: Int
        public var maximumPinned: Int
        /// Unpinned entries unused for this many days are removed. Nil keeps them forever.
        public var retentionDays: Int?
        public var maximumTextBytes: Int
        public var maximumImageBytes: Int
        public var maximumTotalBytes: Int

        public init(maximumItems: Int = 300, maximumPinned: Int = 100, retentionDays: Int? = 30,
                    maximumTextBytes: Int = 1_000_000, maximumImageBytes: Int = 15_000_000,
                    maximumTotalBytes: Int = 400_000_000) {
            self.maximumItems = maximumItems
            self.maximumPinned = maximumPinned
            self.retentionDays = retentionDays
            self.maximumTextBytes = maximumTextBytes
            self.maximumImageBytes = maximumImageBytes
            self.maximumTotalBytes = maximumTotalBytes
        }
    }

    public enum Outcome: Equatable {
        case added(UUID)
        case merged(UUID)
        case rejected(String)
    }

    public let store: ClipboardStore
    /// Newest (by `lastUsed`) first.
    public private(set) var items: [ClipItem] = []
    public var limits: Limits {
        didSet { if limits != oldValue { prune(now: Date()); persist(); onChange?() } }
    }
    /// A message about the last load or save problem, shown in the panel. Nil when all is well.
    public private(set) var problem: String?
    public var onChange: (() -> Void)?

    private let saveQueue = DispatchQueue(label: "KongFetch.clipboard.save", qos: .utility)

    public init(store: ClipboardStore, limits: Limits = Limits(), now: Date = Date()) {
        self.store = store
        self.limits = limits
        let result = store.load()
        items = result.items.sorted { $0.lastUsed > $1.lastUsed }
        if let quarantined = result.quarantinedIndex {
            problem = "历史文件无法读取，已另存为 \(quarantined.lastPathComponent)，并重新开始记录。"
        } else if result.dropped > 0 {
            problem = "有 \(result.dropped) 条历史记录损坏，已跳过。"
        }
        let countBefore = items.count
        prune(now: now)
        store.removeOrphanBlobs(keeping: items)
        if items.count != countBefore || result.dropped > 0 { persist() }
    }

    public var totalBytes: Int { items.reduce(0) { $0 + $1.byteSize } }

    @discardableResult
    public func insert(_ candidate: ClipCandidate, now: Date = Date()) -> Outcome {
        let fingerprint = candidate.fingerprint
        if let index = items.firstIndex(where: { $0.fingerprint == fingerprint }) {
            var existing = items.remove(at: index)
            existing.lastUsed = now
            items.insert(existing, at: 0)
            persist()
            onChange?()
            return .merged(existing.id)
        }

        var item = ClipItem(id: UUID(), kind: candidate.kind, created: now, lastUsed: now, pinned: false,
                            text: nil, filePaths: nil, imageFile: nil, imageWidth: nil, imageHeight: nil,
                            richTextFile: nil, sourceBundleID: candidate.sourceBundleID,
                            sourceName: candidate.sourceName.map { String($0.prefix(200)) },
                            fingerprint: fingerprint, byteSize: 0, recognizedText: nil)
        do {
            switch candidate.payload {
            case .text(let text, let rtf):
                let size = text.utf8.count
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .rejected("空白文字不记录") }
                guard size <= limits.maximumTextBytes else { return .rejected("文字超过 \(limits.maximumTextBytes / 1_000_000) MB，未记录") }
                item.text = text
                item.byteSize = size
                if let rtf, !rtf.isEmpty, rtf.count <= limits.maximumTextBytes * 2 {
                    item.richTextFile = try store.writeBlob(rtf, fileExtension: "rtf")
                    item.byteSize += rtf.count
                }
            case .image(let data, let ext, let width, let height):
                guard data.count <= limits.maximumImageBytes else { return .rejected("图片超过 \(limits.maximumImageBytes / 1_000_000) MB，未记录") }
                guard ext == "png" || ext == "jpg" else { return .rejected("不支持的图片格式") }
                item.imageFile = try store.writeBlob(data, fileExtension: ext)
                item.imageWidth = width
                item.imageHeight = height
                item.byteSize = data.count
            case .files(let paths):
                let clean = paths.filter { $0.hasPrefix("/") && !$0.contains("\0") }
                guard !clean.isEmpty else { return .rejected("没有可记录的文件") }
                guard clean.count <= 1000 else { return .rejected("文件超过 1000 个，未记录") }
                item.filePaths = clean
                item.byteSize = clean.reduce(0) { $0 + $1.utf8.count }
            }
        } catch {
            store.removeBlob(item.imageFile)
            store.removeBlob(item.richTextFile)
            problem = "无法保存剪贴板内容：\(error.localizedDescription)"
            onChange?()
            return .rejected("保存失败")
        }

        items.insert(item, at: 0)
        prune(now: now)
        persist()
        onChange?()
        return .added(item.id)
    }

    /// Moves an entry to the top, e.g. after pasting it again.
    public func touch(_ id: UUID, now: Date = Date()) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var item = items.remove(at: index)
        item.lastUsed = now
        items.insert(item, at: 0)
        persist()
        onChange?()
    }

    /// Stores text recognized in an image entry; it becomes searchable and pasteable as text.
    public func setRecognizedText(_ id: UUID, _ text: String) {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].kind == .image else { return }
        items[index].recognizedText = String(text.prefix(limits.maximumTextBytes))
        persist()
        onChange?()
    }

    public enum PinError: Error, Equatable { case tooManyPinned(Int) }

    public func setPinned(_ id: UUID, _ pinned: Bool) throws {
        guard let index = items.firstIndex(where: { $0.id == id }), items[index].pinned != pinned else { return }
        if pinned, items.filter(\.pinned).count >= limits.maximumPinned { throw PinError.tooManyPinned(limits.maximumPinned) }
        items[index].pinned = pinned
        persist()
        onChange?()
    }

    public func remove(_ id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        discard(items.remove(at: index))
        persist()
        onChange?()
    }

    public func clear(includingPinned: Bool) {
        let removed = items.filter { includingPinned || !$0.pinned }
        items.removeAll { includingPinned || !$0.pinned }
        removed.forEach(discard)
        persist()
        onChange?()
    }

    /// Applies retention and size limits. Pinned entries are never removed here.
    public func prune(now: Date = Date()) {
        var removed: [ClipItem] = []
        if let days = limits.retentionDays {
            let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
            removed += items.filter { !$0.pinned && $0.lastUsed < cutoff }
            items.removeAll { !$0.pinned && $0.lastUsed < cutoff }
        }
        var total = totalBytes
        while items.count > limits.maximumItems || total > limits.maximumTotalBytes {
            guard let index = items.lastIndex(where: { !$0.pinned }) else { break }
            let item = items.remove(at: index)
            total -= item.byteSize
            removed.append(item)
        }
        removed.forEach(discard)
    }

    /// Blocks until pending saves are written. Call before quitting.
    public func flush() {
        saveQueue.sync {}
    }

    public func clearProblem() {
        problem = nil
    }

    private func discard(_ item: ClipItem) {
        store.removeBlob(item.imageFile)
        store.removeBlob(item.richTextFile)
    }

    private func persist() {
        let snapshot = items
        let store = self.store
        saveQueue.async { [weak self] in
            do {
                try store.save(snapshot)
            } catch {
                DispatchQueue.main.async {
                    self?.problem = "历史保存失败：\(error.localizedDescription)"
                    self?.onChange?()
                }
            }
        }
    }
}
