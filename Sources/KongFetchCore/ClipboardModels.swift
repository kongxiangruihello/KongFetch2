import Foundation
import CryptoKit

/// One remembered clipboard entry. Large payloads (images, rich text) live in separate blob files.
public struct ClipItem: Codable, Equatable, Identifiable {
    public enum Kind: String, Codable {
        case text, image, files
    }

    public var id: UUID
    public var kind: Kind
    /// When it was first copied.
    public var created: Date
    /// When it was last copied or pasted again; the list is ordered by this.
    public var lastUsed: Date
    public var pinned: Bool
    public var text: String?
    public var filePaths: [String]?
    /// Blob file name of the image (PNG or JPEG).
    public var imageFile: String?
    public var imageWidth: Int?
    public var imageHeight: Int?
    /// Blob file name of the RTF that accompanied copied text, so formatting can be restored.
    public var richTextFile: String?
    public var sourceBundleID: String?
    public var sourceName: String?
    public var fingerprint: String
    /// Bytes this entry occupies: text plus blobs.
    public var byteSize: Int
    /// Text recognized in an image entry (nil until recognized, empty if the image has none).
    public var recognizedText: String?

    public var title: String {
        switch kind {
        case .text:
            let flattened = (text ?? "").replacingOccurrences(of: "\r\n", with: " ").replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\t", with: " ")
            return String(flattened.trimmingCharacters(in: .whitespaces).prefix(160))
        case .image:
            if let recognized = recognizedText?.trimmingCharacters(in: .whitespacesAndNewlines), !recognized.isEmpty {
                return "图片：" + String(recognized.replacingOccurrences(of: "\n", with: " ").prefix(120))
            }
            if let w = imageWidth, let h = imageHeight { return "图片 \(w)×\(h)" }
            return "图片"
        case .files:
            let paths = filePaths ?? []
            let first = paths.first.map { ($0 as NSString).lastPathComponent } ?? "文件"
            return paths.count > 1 ? "\(first) 等 \(paths.count) 项" : first
        }
    }

    public var searchText: String {
        [text ?? "", (filePaths ?? []).joined(separator: " "), sourceName ?? "", kind == .image ? "图片 image" : "",
         recognizedText ?? ""].joined(separator: " ")
    }

    static func isSafeBlobName(_ name: String) -> Bool {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, UUID(uuidString: String(parts[0])) != nil else { return false }
        return ["png", "jpg", "rtf"].contains(String(parts[1]))
    }

    /// Structural validity, checked when loading from disk.
    public var isStructurallyValid: Bool {
        guard fingerprint.count == 64, byteSize >= 0 else { return false }
        if let imageFile, !Self.isSafeBlobName(imageFile) { return false }
        if let richTextFile, !Self.isSafeBlobName(richTextFile) { return false }
        switch kind {
        case .text:
            return text.map { !$0.isEmpty } ?? false
        case .image:
            return imageFile != nil
        case .files:
            guard let paths = filePaths, !paths.isEmpty, paths.count <= 1000 else { return false }
            return paths.allSatisfy { $0.hasPrefix("/") && !$0.contains("\0") }
        }
    }
}

/// What the pasteboard reader hands to the history.
public struct ClipCandidate: Equatable {
    public enum Payload: Equatable {
        case text(String, rtf: Data?)
        case image(Data, fileExtension: String, width: Int, height: Int)
        case files([String])
    }

    public var payload: Payload
    public var sourceBundleID: String?
    public var sourceName: String?

    public init(payload: Payload, sourceBundleID: String? = nil, sourceName: String? = nil) {
        self.payload = payload
        self.sourceBundleID = sourceBundleID
        self.sourceName = sourceName
    }

    public var kind: ClipItem.Kind {
        switch payload {
        case .text: return .text
        case .image: return .image
        case .files: return .files
        }
    }

    /// Identity used to merge repeated copies of the same thing. Rich text formatting is ignored.
    public var fingerprint: String {
        var data = Data(kind.rawValue.utf8)
        data.append(0)
        switch payload {
        case .text(let text, _): data.append(Data(text.utf8))
        case .image(let bytes, _, _, _): data.append(bytes)
        case .files(let paths): data.append(Data(paths.joined(separator: "\n").utf8))
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
