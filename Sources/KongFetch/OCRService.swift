import AppKit
import PDFKit
import ImageIO
import IOKit.ps
import KongFetchCore

/// Recognizes text in scanned PDFs and images in the folders the user chose, one file at a time
/// in the background, so full-text search can find them.
final class OCRService {
    struct Settings: Equatable {
        var enabled = true
        var folders: [String] = []
        var pageLimit = 200
        var onlyOnPower = true
    }

    /// Progress, read on the main thread.
    struct Progress: Equatable {
        var pending = 0
        var currentFile: String?
        var currentPage = 0
        var currentPages = 0
        var pausedReason: String?
        var lastError: String?
        var lastCheck: Date?
    }

    let store: OCRStore
    private(set) var progress = Progress()
    var onChange: (() -> Void)?

    private var settings = Settings()
    private let queue = DispatchQueue(label: "KongFetch.ocr", qos: .utility)
    private var generation = 0
    private var timer: Timer?
    private var isPaused = false

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "heif", "tif", "tiff", "bmp", "gif", "webp"]

    init(directory: URL) {
        store = OCRStore(directory: directory)
        queue.async { [store] in store.load() }
    }

    func configure(_ new: Settings) {
        let changed = new != settings
        settings = new
        if timer == nil {
            // Look for new or changed files every half hour.
            let timer = Timer(timeInterval: 1800, repeats: true) { [weak self] _ in self?.checkNow() }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        if changed { checkNow() }
    }

    func setPaused(_ paused: Bool) {
        isPaused = paused
        if paused {
            generation += 1
            update { $0.pausedReason = "已暂停"; $0.currentFile = nil }
        } else {
            update { $0.pausedReason = nil }
            checkNow()
        }
    }

    var paused: Bool { isPaused }

    /// Finds files that need recognition and works through them.
    func checkNow() {
        generation += 1
        let current = generation
        let settings = self.settings
        guard settings.enabled, !isPaused else {
            update { $0.pending = 0; $0.currentFile = nil }
            return
        }
        queue.async { [weak self] in
            guard let self else { return }
            let folders = settings.folders.map { ($0 as NSString).expandingTildeInPath }
            // Forget results for files that are gone or no longer in an OCR folder.
            self.store.prune { path in
                folders.contains { path.hasPrefix($0 + "/") } && FileManager.default.fileExists(atPath: path)
            }
            let candidates = folders.flatMap { self.candidates(in: $0, pageLimit: settings.pageLimit) }
            self.update { $0.pending = candidates.count; $0.lastCheck = Date() }
            for (index, url) in candidates.enumerated() {
                guard current == self.generation else { return }
                if settings.onlyOnPower && !Self.isOnACPower {
                    self.update { $0.pausedReason = "使用电池中，接通电源后继续"; $0.currentFile = nil }
                    // Try again in ten minutes.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 600) { [weak self] in
                        if current == self?.generation { self?.checkNow() }
                    }
                    return
                }
                self.update { $0.pausedReason = nil; $0.pending = candidates.count - index }
                self.recognize(url, pageLimit: settings.pageLimit, generation: current)
            }
            self.update { $0.pending = 0; $0.currentFile = nil }
        }
    }

    func clearResults() {
        generation += 1
        queue.async { [weak self] in
            self?.store.clear()
            self?.update { $0.currentFile = nil; $0.pending = 0 }
            DispatchQueue.main.async { self?.checkNow() }
        }
    }

    // MARK: Work (on `queue`)

    /// Files in a folder that are scanned PDFs or images and are not yet recognized as they are now.
    private func candidates(in folder: String, pageLimit: Int) -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey, .ubiquitousItemDownloadingStatusKey]
        guard let enumerator = FileManager.default.enumerator(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: keys,
                                                              options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var result: [URL] = []
        for case let url as URL in enumerator {
            let ext = url.pathExtension.lowercased()
            guard ext == "pdf" || Self.imageExtensions.contains(ext),
                  let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            // Never force iCloud downloads; files appear here once they are on this Mac.
            if let status = values.ubiquitousItemDownloadingStatus, status != .current { continue }
            let size = values.fileSize ?? 0
            guard size > 2_000, size < 500_000_000 else { continue }
            if store.isCurrent(path: url.path, size: size, modified: values.contentModificationDate ?? .distantPast, pageLimit: pageLimit) { continue }
            result.append(url)
        }
        return result
    }

    private func recognize(_ url: URL, pageLimit: Int, generation: Int) {
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let name = url.lastPathComponent
        var pages: [String] = []
        var totalPages = 1
        do {
            if url.pathExtension.lowercased() == "pdf" {
                guard let document = PDFDocument(url: url) else { throw CocoaError(.fileReadCorruptFile) }
                totalPages = document.pageCount
                if Self.hasTextLayer(document) {
                    // Spotlight already indexes its text; remember that so it is not checked again.
                    try store.save(OCRRecord(path: url.path, size: values?.fileSize ?? 0, modified: values?.contentModificationDate ?? .distantPast,
                                             pages: [], totalPages: 0))
                    return
                }
                let count = min(totalPages, pageLimit)
                for index in 0..<count {
                    guard generation == self.generation else { return }
                    update { $0.currentFile = name; $0.currentPage = index + 1; $0.currentPages = count }
                    let text: String = try autoreleasepool {
                        guard let page = document.page(at: index), let image = Self.render(page) else { return "" }
                        return try TextRecognizer.recognize(image)
                    }
                    pages.append(text)
                }
            } else {
                update { $0.currentFile = name; $0.currentPage = 1; $0.currentPages = 1 }
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                        kCGImageSourceThumbnailMaxPixelSize: 4000
                      ] as CFDictionary) else { throw CocoaError(.fileReadCorruptFile) }
                // Icons and tiny pictures carry no useful text.
                pages.append(try (image.width >= 200 && image.height >= 100 ? TextRecognizer.recognize(image) : ""))
            }
            guard generation == self.generation else { return }
            try store.save(OCRRecord(path: url.path, size: values?.fileSize ?? 0, modified: values?.contentModificationDate ?? .distantPast,
                                     pages: pages, totalPages: totalPages))
        } catch {
            update { $0.lastError = "\(name)：\(error.localizedDescription)" }
            // Record the failure so the same file is not retried until it changes.
            try? store.save(OCRRecord(path: url.path, size: values?.fileSize ?? 0, modified: values?.contentModificationDate ?? .distantPast,
                                      pages: [], totalPages: 0))
        }
    }

    /// A PDF whose first pages already carry text is not a scan.
    static func hasTextLayer(_ document: PDFDocument) -> Bool {
        let sample = (0..<min(document.pageCount, 3)).compactMap { document.page(at: $0)?.string }.joined()
        return sample.filter { !$0.isWhitespace }.count >= 30
    }

    /// Renders a page at roughly 2400 pixels on its long side on white, with Core Graphics (safe off the main thread).
    static func render(_ page: PDFPage) -> CGImage? {
        guard let ref = page.pageRef else { return nil }
        var box = ref.getBoxRect(.mediaBox)
        if abs(Int(ref.rotationAngle)) % 180 == 90 { box = CGRect(x: 0, y: 0, width: box.height, height: box.width) }
        guard box.width > 1, box.height > 1 else { return nil }
        let scale = min(4, 2400 / max(box.width, box.height))
        let width = Int(box.width * scale), height = Int(box.height * scale)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.interpolationQuality = .high
        context.scaleBy(x: scale, y: scale)
        context.concatenate(ref.getDrawingTransform(.mediaBox, rect: CGRect(origin: .zero, size: box.size), rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(ref)
        return context.makeImage()
    }

    static var isOnACPower: Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String? else { return true }
        return type == kIOPMACPowerKey
    }

    private func update(_ change: @escaping (inout Progress) -> Void) {
        DispatchQueue.main.async {
            var next = self.progress
            change(&next)
            if next != self.progress {
                self.progress = next
                self.onChange?()
            }
        }
    }
}
