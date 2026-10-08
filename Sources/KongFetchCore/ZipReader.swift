import Foundation
import Compression

/// Reads the table of contents of a .zip file and extracts single entries, without unpacking the whole archive.
/// Handles Zip64, UTF-8 names and the GBK names written by Chinese Windows. Stored and Deflate entries only.
public enum ZipReader {
    public struct Entry: Equatable {
        /// Path inside the archive, e.g. "讲义/第一讲.pdf".
        public var name: String
        public var compressedSize: UInt64
        public var uncompressedSize: UInt64
        public var method: UInt16
        public var flags: UInt16
        public var localHeaderOffset: UInt64
        public var isDirectory: Bool { name.hasSuffix("/") }
        public var isEncrypted: Bool { flags & 1 != 0 }
        public var fileName: String { (name as NSString).lastPathComponent }
    }

    public enum ZipError: LocalizedError {
        case notZip, truncated, unsupportedMethod(UInt16), encrypted, tooLarge, corrupt

        public var errorDescription: String? {
            switch self {
            case .notZip: return "不是 zip 压缩包"
            case .truncated: return "压缩包不完整"
            case .unsupportedMethod(let method): return "不支持的压缩方式（\(method)）"
            case .encrypted: return "这个文件有密码保护"
            case .tooLarge: return "文件太大，请用“归档实用工具”解压"
            case .corrupt: return "压缩包已损坏"
            }
        }
    }

    /// Every entry, in archive order. `limit` caps how many are read from very large archives.
    public static func entries(at url: URL, limit: Int = 100_000) throws -> [Entry] {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let fileSize = try handle.seekToEnd()
        guard fileSize >= 22 else { throw ZipError.notZip }

        // The end-of-central-directory record sits in the last 22 + up to 65535 (comment) bytes.
        let tailLength = min(fileSize, 22 + 65_535)
        try handle.seek(toOffset: fileSize - tailLength)
        let tail = try handle.read(upToCount: Int(tailLength)) ?? Data()
        guard let eocd = lastIndex(of: 0x06054b50, in: tail) else { throw ZipError.notZip }

        var count = UInt64(tail.uint16(at: eocd + 10))
        var directorySize = UInt64(tail.uint32(at: eocd + 12))
        var directoryOffset = UInt64(tail.uint32(at: eocd + 16))

        if count == 0xFFFF || directorySize == 0xFFFF_FFFF || directoryOffset == 0xFFFF_FFFF {
            // Zip64: a locator just before the record points at the Zip64 end record.
            guard eocd >= 20, tail.uint32(at: eocd - 20) == 0x07064b50 else { throw ZipError.corrupt }
            let recordOffset = tail.uint64(at: eocd - 20 + 8)
            try handle.seek(toOffset: recordOffset)
            let record = try handle.read(upToCount: 56) ?? Data()
            guard record.count == 56, record.uint32(at: 0) == 0x06064b50 else { throw ZipError.corrupt }
            count = record.uint64(at: 32)
            directorySize = record.uint64(at: 40)
            directoryOffset = record.uint64(at: 48)
        }
        guard directoryOffset + directorySize <= fileSize, directorySize < 512 * 1024 * 1024 else { throw ZipError.corrupt }
        try handle.seek(toOffset: directoryOffset)
        let directory = try handle.read(upToCount: Int(directorySize)) ?? Data()
        guard directory.count == Int(directorySize) else { throw ZipError.truncated }

        var entries: [Entry] = []
        var position = 0
        for _ in 0..<min(count, UInt64(limit)) {
            guard position + 46 <= directory.count, directory.uint32(at: position) == 0x02014b50 else { break }
            let flags = directory.uint16(at: position + 8)
            let method = directory.uint16(at: position + 10)
            var compressed = UInt64(directory.uint32(at: position + 20))
            var uncompressed = UInt64(directory.uint32(at: position + 24))
            let nameLength = Int(directory.uint16(at: position + 28))
            let extraLength = Int(directory.uint16(at: position + 30))
            let commentLength = Int(directory.uint16(at: position + 32))
            var offset = UInt64(directory.uint32(at: position + 42))
            let nameStart = position + 46
            guard nameStart + nameLength + extraLength <= directory.count else { break }
            let nameData = directory.subdata(in: nameStart..<nameStart + nameLength)

            // Zip64 extra field: the 8-byte values for whichever fields were 0xFFFFFFFF, in this order.
            var extra = nameStart + nameLength
            let extraEnd = extra + extraLength
            while extra + 4 <= extraEnd {
                let id = directory.uint16(at: extra)
                let size = Int(directory.uint16(at: extra + 2))
                if id == 0x0001 {
                    var field = extra + 4
                    if uncompressed == 0xFFFF_FFFF, field + 8 <= extraEnd { uncompressed = directory.uint64(at: field); field += 8 }
                    if compressed == 0xFFFF_FFFF, field + 8 <= extraEnd { compressed = directory.uint64(at: field); field += 8 }
                    if offset == 0xFFFF_FFFF, field + 8 <= extraEnd { offset = directory.uint64(at: field) }
                }
                extra += 4 + size
            }
            entries.append(Entry(name: decodeName(nameData, utf8Flag: flags & 0x0800 != 0), compressedSize: compressed,
                                 uncompressedSize: uncompressed, method: method, flags: flags, localHeaderOffset: offset))
            position = nameStart + nameLength + extraLength + commentLength
        }
        return entries
    }

    /// Names are UTF-8 when the archive says so; otherwise UTF-8 if valid, else GBK/GB18030 (Chinese Windows), else CP437-ish Latin-1.
    static func decodeName(_ data: Data, utf8Flag: Bool) -> String {
        if utf8Flag, let text = String(data: data, encoding: .utf8) { return text }
        if let text = String(data: data, encoding: .utf8) { return text }
        let gb18030 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        if let text = String(data: data, encoding: gb18030) { return text }
        return String(data: data, encoding: .isoLatin1) ?? ""
    }

    /// Files worth listing: no folders, macOS metadata or hidden files.
    public static func isListable(_ entry: Entry) -> Bool {
        guard !entry.isDirectory else { return false }
        if entry.name.hasPrefix("__MACOSX/") || entry.name.contains("/__MACOSX/") { return false }
        return !entry.fileName.hasPrefix(".")
    }

    /// Writes one entry to `destination` (a file path).
    public static func extract(_ entry: Entry, from url: URL, to destination: URL, maximumSize: UInt64 = 1_000_000_000) throws {
        guard !entry.isEncrypted else { throw ZipError.encrypted }
        guard entry.uncompressedSize <= maximumSize, entry.compressedSize <= maximumSize else { throw ZipError.tooLarge }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: entry.localHeaderOffset)
        let header = try handle.read(upToCount: 30) ?? Data()
        guard header.count == 30, header.uint32(at: 0) == 0x04034b50 else { throw ZipError.corrupt }
        let skip = UInt64(header.uint16(at: 26)) + UInt64(header.uint16(at: 28))
        try handle.seek(toOffset: entry.localHeaderOffset + 30 + skip)
        let compressed = try handle.read(upToCount: Int(entry.compressedSize)) ?? Data()
        guard compressed.count == Int(entry.compressedSize) else { throw ZipError.truncated }

        let output: Data
        switch entry.method {
        case 0:
            output = compressed
        case 8:
            output = try inflate(compressed, expectedSize: Int(entry.uncompressedSize))
        default:
            throw ZipError.unsupportedMethod(entry.method)
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try output.write(to: destination, options: .atomic)
    }

    /// Raw DEFLATE (what zip uses) through Apple's Compression framework, whose ZLIB codec is raw deflate.
    static func inflate(_ data: Data, expectedSize: Int) throws -> Data {
        if expectedSize == 0 { return Data() }
        var output = Data(count: expectedSize)
        let written = output.withUnsafeMutableBytes { destination -> Int in
            data.withUnsafeBytes { source -> Int in
                guard let dst = destination.bindMemory(to: UInt8.self).baseAddress,
                      let src = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(dst, expectedSize, src, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == expectedSize else { throw ZipError.corrupt }
        return output
    }

    private static func lastIndex(of signature: UInt32, in data: Data) -> Int? {
        guard data.count >= 22 else { return nil }
        var index = data.count - 22
        while index >= 0 {
            if data.uint32(at: index) == signature { return index }
            index -= 1
        }
        return nil
    }
}

extension Data {
    func uint16(at offset: Int) -> UInt16 {
        let base = startIndex + offset
        return UInt16(self[base]) | UInt16(self[base + 1]) << 8
    }

    func uint32(at offset: Int) -> UInt32 {
        let base = startIndex + offset
        return UInt32(self[base]) | UInt32(self[base + 1]) << 8 | UInt32(self[base + 2]) << 16 | UInt32(self[base + 3]) << 24
    }

    func uint64(at offset: Int) -> UInt64 {
        UInt64(uint32(at: offset)) | UInt64(uint32(at: offset + 4)) << 32
    }
}
