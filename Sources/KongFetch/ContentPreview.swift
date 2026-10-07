import AppKit
import PDFKit
import KongFetchCore

/// Finds where a search word occurs inside a file, for the preview pane in content mode.
enum ContentPreview {
    struct Found {
        var snippet: Snippet
        /// 1-based PDF page, if known.
        var page: Int?
        /// From text recognition rather than the file's own text.
        var recognized = false
    }

    enum Outcome {
        case found(Found)
        case notFound
        /// An iCloud file that is not on this Mac; reading it would start a download.
        case notDownloaded
        case unsupported
    }

    private static let plainTextExtensions: Set<String> = [
        "txt", "md", "markdown", "csv", "tsv", "tex", "bib", "json", "xml", "html", "htm", "yaml", "yml", "log",
        "swift", "py", "js", "ts", "css", "sh", "c", "h", "m"
    ]
    private static let richTextExtensions: Set<String> = ["docx", "doc", "rtf", "rtfd", "odt", "wordml"]

    /// Slow for big files: call off the main thread. Recognized (OCR) text is used first when available.
    static func find(in url: URL, needles: [String], ocr: OCRStore? = nil) -> Outcome {
        if let hit = ocr?.hit(for: url.path, needles: needles) {
            return .found(Found(snippet: hit.snippet, page: hit.page, recognized: true))
        }
        let ext = url.pathExtension.lowercased()
        guard ext == "pdf" || plainTextExtensions.contains(ext) || richTextExtensions.contains(ext) else { return .unsupported }
        let values = try? url.resourceValues(forKeys: [.fileSizeKey, .ubiquitousItemDownloadingStatusKey])
        // "downloaded" and "current" both mean the data is on this Mac.
        if values?.ubiquitousItemDownloadingStatus == .notDownloaded {
            return .notDownloaded
        }
        let size = values?.fileSize ?? 0
        guard size <= 300_000_000 else { return .unsupported }

        if ext == "pdf" {
            guard let document = PDFDocument(url: url) else { return .notFound }
            for index in 0..<min(document.pageCount, 1000) {
                if let text = document.page(at: index)?.string, let snippet = Snippet.find(in: text, needles: needles) {
                    return .found(Found(snippet: snippet, page: index + 1))
                }
            }
            return .notFound
        }

        let text: String?
        if plainTextExtensions.contains(ext) {
            guard size <= 30_000_000, let data = try? Data(contentsOf: url) else { return .notFound }
            text = String(data: data, encoding: .utf8) ?? decodeGB18030(data)
        } else {
            text = (try? NSAttributedString(url: url, options: [:], documentAttributes: nil))?.string
        }
        guard let text, let snippet = Snippet.find(in: text, needles: needles) else { return .notFound }
        return .found(Found(snippet: snippet, page: nil))
    }

    /// Older Chinese text files are often GB18030 / GBK rather than UTF-8.
    private static func decodeGB18030(_ data: Data) -> String? {
        let encoding = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        return String(data: data, encoding: String.Encoding(rawValue: encoding))
    }
}
