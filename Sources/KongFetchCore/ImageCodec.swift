import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Normalises copied images before they are stored: PNG when small enough,
/// otherwise scaled down and, if still too large, saved as JPEG.
public enum ImageCodec {
    public struct Normalized: Equatable {
        public var data: Data
        public var fileExtension: String
        public var width: Int
        public var height: Int
        /// True when the stored image is smaller than what was copied.
        public var reduced: Bool
    }

    public static func pixelSize(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0 else { return nil }
        return (width, height)
    }

    public static func normalize(_ data: Data, maximumBytes: Int, maximumPixels: Int = 5000) -> Normalized? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let size = pixelSize(of: data) else { return nil }
        let isPNG = (CGImageSourceGetType(source) as String?) == UTType.png.identifier
        let longest = max(size.width, size.height)

        if isPNG, data.count <= maximumBytes, longest <= maximumPixels {
            return Normalized(data: data, fileExtension: "png", width: size.width, height: size.height, reduced: false)
        }

        // Re-encode, scaling down step by step until it fits.
        var target = min(longest, maximumPixels)
        var reduced = target < longest
        while target >= 256 {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: target
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            if let png = encode(image, type: .png, quality: nil), png.count <= maximumBytes {
                return Normalized(data: png, fileExtension: "png", width: image.width, height: image.height, reduced: reduced)
            }
            if let jpeg = encode(image, type: .jpeg, quality: 0.85), jpeg.count <= maximumBytes {
                return Normalized(data: jpeg, fileExtension: "jpg", width: image.width, height: image.height, reduced: true)
            }
            target = target * 3 / 4
            reduced = true
        }
        return nil
    }

    static func encode(_ image: CGImage, type: UTType, quality: Double?) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else { return nil }
        var properties: [CFString: Any] = [:]
        if let quality { properties[kCGImageDestinationLossyCompressionQuality] = quality }
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
