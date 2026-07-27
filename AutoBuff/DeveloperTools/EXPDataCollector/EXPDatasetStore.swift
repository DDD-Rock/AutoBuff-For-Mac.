import AppKit
import CoreGraphics
import Foundation

struct EXPDatasetSaveResult {
    let rowURL: URL?
    let savedGlyphCount: Int
    let wasDuplicate: Bool
}

final class EXPDatasetStore {
    static var defaultDirectoryURL: URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        return applicationSupport
            .appendingPathComponent(AppConstants.settingsDirectoryName, isDirectory: true)
            .appendingPathComponent("EXP-Dataset", isDirectory: true)
    }

    let rootURL: URL

    private let fileManager: FileManager
    private var signaturesByLabel: [String: Set<UInt64>] = [:]
    private var reviewSignatures: Set<UInt64> = []
    private let maximumVariantsPerLabel = 3

    init(
        rootURL: URL = EXPDatasetStore.defaultDirectoryURL,
        fileManager: FileManager = .default
    ) {
        self.rootURL = rootURL
        self.fileManager = fileManager
    }

    func saveAutomatic(
        searchRegion: ImageBuffer,
        reading: EXPTextReading
    ) throws -> EXPDatasetSaveResult {
        guard let row = crop(
            searchRegion,
            normalizedBox: reading.normalizedLineBox,
            padding: 4
        ) else {
            return EXPDatasetSaveResult(
                rowURL: nil,
                savedGlyphCount: 0,
                wasDuplicate: false
            )
        }

        let signature = Self.signature(for: row)
        let known = signaturesByLabel[reading.key, default: []]
        if known.contains(signature) || known.count >= maximumVariantsPerLabel {
            return EXPDatasetSaveResult(
                rowURL: nil,
                savedGlyphCount: 0,
                wasDuplicate: true
            )
        }

        try prepareDirectories()
        let sampleID = Self.sampleID()
        let safePercent = EXPTextParser.format(percent: reading.percent)
            .replacingOccurrences(of: ".", with: "_")
        let baseName = "exp_\(reading.currentEXP)_pct_\(safePercent)_\(sampleID)"
        let rowURL = rootURL
            .appendingPathComponent("rows/auto", isDirectory: true)
            .appendingPathComponent("\(baseName).png")
        let contextURL = rootURL
            .appendingPathComponent("context/auto", isDirectory: true)
            .appendingPathComponent("\(baseName).png")

        try writePNG(row, to: rowURL)
        try writePNG(searchRegion, to: contextURL)

        var savedGlyphCount = 0
        for (index, glyph) in reading.glyphBoxes.enumerated() {
            guard let glyphImage = crop(
                searchRegion,
                normalizedBox: glyph.normalizedBox,
                padding: 2
            ) else {
                continue
            }
            let directory = rootURL
                .appendingPathComponent("chars/auto", isDirectory: true)
                .appendingPathComponent(glyph.label, isDirectory: true)
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            let glyphURL = directory.appendingPathComponent(
                "\(baseName)_\(String(format: "%02d", index)).png"
            )
            try writePNG(glyphImage, to: glyphURL)
            savedGlyphCount += 1
        }

        signaturesByLabel[reading.key, default: []].insert(signature)
        try appendManifest(
            [
                "id": sampleID,
                "kind": "auto",
                "current_exp": reading.currentEXP,
                "percent": reading.percent,
                "raw_text": reading.rawText,
                "confidence": reading.confidence,
                "preprocessing_agreement": reading.preprocessingAgreement,
                "row": relativePath(rowURL),
                "context": relativePath(contextURL),
                "glyph_count": savedGlyphCount,
                "created_at": ISO8601DateFormatter().string(from: Date()),
            ]
        )
        return EXPDatasetSaveResult(
            rowURL: rowURL,
            savedGlyphCount: savedGlyphCount,
            wasDuplicate: false
        )
    }

    @discardableResult
    func saveForReview(
        searchRegion: ImageBuffer,
        suspectedText: String?,
        confidence: Float
    ) throws -> Bool {
        let signature = Self.signature(for: searchRegion)
        guard reviewSignatures.insert(signature).inserted else { return false }

        try prepareDirectories()
        let sampleID = Self.sampleID()
        let url = rootURL
            .appendingPathComponent("review", isDirectory: true)
            .appendingPathComponent("review_\(sampleID).png")
        try writePNG(searchRegion, to: url)
        try appendManifest(
            [
                "id": sampleID,
                "kind": "review",
                "suspected_text": suspectedText ?? "",
                "confidence": confidence,
                "context": relativePath(url),
                "created_at": ISO8601DateFormatter().string(from: Date()),
            ]
        )
        return true
    }

    private func prepareDirectories() throws {
        for path in [
            "rows/auto",
            "context/auto",
            "chars/auto",
            "review",
        ] {
            try fileManager.createDirectory(
                at: rootURL.appendingPathComponent(path, isDirectory: true),
                withIntermediateDirectories: true
            )
        }
    }

    private func writePNG(_ image: ImageBuffer, to url: URL) throws {
        guard let data = EXPImageCodec.pngData(from: image) else {
            throw EXPDatasetStoreError.cannotEncodePNG
        }
        try data.write(to: url, options: .atomic)
    }

    private func appendManifest(_ object: [String: Any]) throws {
        let manifestURL = rootURL.appendingPathComponent("manifest.jsonl")
        var data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys]
        )
        data.append(0x0A)
        if !fileManager.fileExists(atPath: manifestURL.path) {
            try data.write(to: manifestURL, options: .atomic)
            return
        }
        let handle = try FileHandle(forWritingTo: manifestURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    private func relativePath(_ url: URL) -> String {
        String(url.path.dropFirst(rootURL.path.count + 1))
    }

    private func crop(
        _ image: ImageBuffer,
        normalizedBox: CGRect,
        padding: Int
    ) -> ImageBuffer? {
        guard normalizedBox.width > 0, normalizedBox.height > 0 else { return nil }
        let rawX = Int((normalizedBox.minX * Double(image.width)).rounded(.down))
        let rawY = Int(((1 - normalizedBox.maxY) * Double(image.height)).rounded(.down))
        let rawMaxX = Int((normalizedBox.maxX * Double(image.width)).rounded(.up))
        let rawMaxY = Int(((1 - normalizedBox.minY) * Double(image.height)).rounded(.up))
        let x = max(0, rawX - padding)
        let y = max(0, rawY - padding)
        let maxX = min(image.width, rawMaxX + padding)
        let maxY = min(image.height, rawMaxY + padding)
        return image.cropped(
            x: x,
            y: y,
            width: maxX - x,
            height: maxY - y
        )
    }

    private static func sampleID() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd_HHmmss_SSS"
        return "\(formatter.string(from: Date()))_\(UUID().uuidString.prefix(6))"
    }

    private static func signature(for image: ImageBuffer) -> UInt64 {
        var hash: UInt64 = 14_695_981_039_346_656_037
        let xStep = max(1, image.width / 96)
        let yStep = max(1, image.height / 32)
        for y in stride(from: 0, to: image.height, by: yStep) {
            for x in stride(from: 0, to: image.width, by: xStep) {
                let index = (y * image.width + x) * 3
                let luminance = (
                    Int(image.bgr[index]) * 29
                        + Int(image.bgr[index + 1]) * 150
                        + Int(image.bgr[index + 2]) * 77
                ) >> 8
                hash ^= UInt64(luminance)
                hash &*= 1_099_511_628_211
            }
        }
        return hash
    }
}

enum EXPDatasetStoreError: LocalizedError {
    case cannotEncodePNG

    var errorDescription: String? {
        switch self {
        case .cannotEncodePNG:
            return "无法将 EXP 样本编码为 PNG"
        }
    }
}

enum EXPImageCodec {
    static func cgImage(from image: ImageBuffer) -> CGImage? {
        guard image.width > 0,
              image.height > 0,
              image.bgr.count == image.width * image.height * 3 else {
            return nil
        }
        var rgba = [UInt8](repeating: 255, count: image.width * image.height * 4)
        var destination = 0
        for source in stride(from: 0, to: image.bgr.count, by: 3) {
            rgba[destination] = image.bgr[source + 2]
            rgba[destination + 1] = image.bgr[source + 1]
            rgba[destination + 2] = image.bgr[source]
            rgba[destination + 3] = 255
            destination += 4
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else {
            return nil
        }
        return CGImage(
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: image.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(
                rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
            ),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }

    static func scaledImage(_ image: CGImage, scale: Int) -> CGImage? {
        let width = image.width * max(1, scale)
        let height = image.height * max(1, scale)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    static func pngData(from image: ImageBuffer) -> Data? {
        guard let cgImage = cgImage(from: image) else { return nil }
        return NSBitmapImageRep(cgImage: cgImage).representation(
            using: .png,
            properties: [:]
        )
    }
}
