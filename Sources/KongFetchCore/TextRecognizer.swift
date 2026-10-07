import Foundation
import CoreGraphics
import Vision

/// On-device text recognition (Apple Vision). Nothing leaves the Mac.
public enum TextRecognizer {
    /// Simplified and traditional Chinese first, then English.
    public static let preferredLanguages = ["zh-Hans", "zh-Hant", "en-US"]

    /// Recognized lines, top to bottom, joined with newlines. Empty when the image has no text.
    public static func recognize(_ image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let supported = (try? request.supportedRecognitionLanguages()) ?? []
        let languages = preferredLanguages.filter { supported.contains($0) }
        if !languages.isEmpty { request.recognitionLanguages = languages }
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let observations = request.results ?? []
        return orderedLines(observations.compactMap { observation in
            observation.topCandidates(1).first.map { (text: $0.string, box: observation.boundingBox) }
        }).joined(separator: "\n")
    }

    /// Reading order for horizontal text: rows from the top (Vision's y grows upwards), then left to right.
    static func orderedLines(_ lines: [(text: String, box: CGRect)]) -> [String] {
        lines.sorted { a, b in
            let sameRow = abs(a.box.midY - b.box.midY) < min(a.box.height, b.box.height) * 0.5
            return sameRow ? a.box.minX < b.box.minX : a.box.midY > b.box.midY
        }.map(\.text)
    }
}
