import AVFoundation
import CoreVideo
import Foundation

@available(macOS 14.0, *)
@MainActor
final class VerificationRegionRecorder {
    static let framesPerSecond: Int32 = 10

    private let outputDirectory: URL
    private let now: () -> Date
    private var writer: AVAssetWriter?
    private var input: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var bodyRect: CGRect?
    private var outputSize: CGSize?
    private var frameIndex: Int64 = 0
    private(set) var outputURL: URL?

    var isRecording: Bool { writer != nil }

    init(
        outputDirectory: URL? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.outputDirectory = outputDirectory ?? Self.applicationRootURL
        self.now = now
    }

    static var applicationRootURL: URL {
        Bundle.main.bundleURL.deletingLastPathComponent()
    }

    func start(frame: ImageBuffer, bodyRect: CGRect) throws -> URL {
        if let outputURL, isRecording { return outputURL }
        guard let normalizedRect = Self.normalized(rect: bodyRect, in: frame),
              let crop = frame.cropped(
                x: Int(normalizedRect.minX),
                y: Int(normalizedRect.minY),
                width: Int(normalizedRect.width),
                height: Int(normalizedRect.height)
              ) else {
            throw RecordingError.invalidRegion
        }

        try FileManager.default.createDirectory(
            at: outputDirectory,
            withIntermediateDirectories: true
        )
        let url = Self.availableOutputURL(in: outputDirectory, at: now())
        let assetWriter = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let settings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: crop.width,
            AVVideoHeightKey: crop.height,
        ]
        let assetInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        assetInput.expectsMediaDataInRealTime = true
        let pixelAdaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: assetInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: crop.width,
                kCVPixelBufferHeightKey as String: crop.height,
            ]
        )
        guard assetWriter.canAdd(assetInput) else { throw RecordingError.cannotCreateWriter }
        assetWriter.add(assetInput)
        guard assetWriter.startWriting() else {
            throw assetWriter.error ?? RecordingError.cannotCreateWriter
        }
        assetWriter.startSession(atSourceTime: .zero)

        writer = assetWriter
        input = assetInput
        adaptor = pixelAdaptor
        self.bodyRect = normalizedRect
        outputSize = CGSize(width: crop.width, height: crop.height)
        outputURL = url
        frameIndex = 0
        try appendPrepared(crop)
        return url
    }

    @discardableResult
    func append(frame: ImageBuffer, bodyRect updatedRect: CGRect? = nil) throws -> Bool {
        guard isRecording, let outputSize else { return false }
        if let updatedRect, let normalized = Self.normalized(rect: updatedRect, in: frame) {
            bodyRect = normalized
        }
        guard let bodyRect,
              let crop = frame.cropped(
                x: Int(bodyRect.minX),
                y: Int(bodyRect.minY),
                width: Int(bodyRect.width),
                height: Int(bodyRect.height)
              ) else { return false }
        let prepared = crop.width == Int(outputSize.width) && crop.height == Int(outputSize.height)
            ? crop
            : Self.resized(crop, width: Int(outputSize.width), height: Int(outputSize.height))
        guard let prepared else { return false }
        try appendPrepared(prepared)
        return true
    }

    @discardableResult
    func stop() -> URL? {
        guard let writer else { return nil }
        let completedURL = outputURL
        input?.markAsFinished()
        self.writer = nil
        input = nil
        adaptor = nil
        bodyRect = nil
        outputSize = nil
        outputURL = nil
        frameIndex = 0
        writer.finishWriting { }
        return completedURL
    }

    static func availableOutputURL(in directory: URL, at date: Date) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let stem = "鼠标跟随验证_\(formatter.string(from: date))"
        var candidate = directory.appendingPathComponent(stem).appendingPathExtension("mp4")
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory
                .appendingPathComponent("\(stem)_\(suffix)")
                .appendingPathExtension("mp4")
            suffix += 1
        }
        return candidate
    }

    static func normalized(rect: CGRect, in frame: ImageBuffer) -> CGRect? {
        let bounds = CGRect(x: 0, y: 0, width: frame.width, height: frame.height)
        let clipped = rect.integral.intersection(bounds)
        guard !clipped.isNull else { return nil }
        let width = Int(clipped.width) / 2 * 2
        let height = Int(clipped.height) / 2 * 2
        guard width >= 2, height >= 2 else { return nil }
        return CGRect(x: Int(clipped.minX), y: Int(clipped.minY), width: width, height: height)
    }

    private func appendPrepared(_ frame: ImageBuffer) throws {
        guard let writer, let input, let adaptor else { throw RecordingError.notStarted }
        guard writer.status == .writing else {
            throw writer.error ?? RecordingError.writerStopped
        }
        guard input.isReadyForMoreMediaData else { return }
        guard let pixelBuffer = Self.pixelBuffer(from: frame) else {
            throw RecordingError.pixelBufferCreationFailed
        }
        let presentationTime = CMTime(
            value: frameIndex,
            timescale: Self.framesPerSecond
        )
        guard adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
            throw writer.error ?? RecordingError.appendFailed
        }
        frameIndex += 1
    }

    private static func pixelBuffer(from frame: ImageBuffer) -> CVPixelBuffer? {
        var optionalBuffer: CVPixelBuffer?
        let attributes: [String: Any] = [
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
        ]
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            frame.width,
            frame.height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &optionalBuffer
        ) == kCVReturnSuccess, let pixelBuffer = optionalBuffer else { return nil }
        guard CVPixelBufferLockBaseAddress(pixelBuffer, []) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let destination = baseAddress.assumingMemoryBound(to: UInt8.self)
        for y in 0..<frame.height {
            let row = destination.advanced(by: y * bytesPerRow)
            for x in 0..<frame.width {
                let sourceIndex = (y * frame.width + x) * 3
                let destinationIndex = x * 4
                row[destinationIndex] = frame.bgr[sourceIndex]
                row[destinationIndex + 1] = frame.bgr[sourceIndex + 1]
                row[destinationIndex + 2] = frame.bgr[sourceIndex + 2]
                row[destinationIndex + 3] = 255
            }
        }
        return pixelBuffer
    }

    private static func resized(_ source: ImageBuffer, width: Int, height: Int) -> ImageBuffer? {
        guard width > 0, height > 0, !source.isEmpty else { return nil }
        var pixels = [UInt8](repeating: 0, count: width * height * 3)
        for y in 0..<height {
            let sourceY = min(source.height - 1, y * source.height / height)
            for x in 0..<width {
                let sourceX = min(source.width - 1, x * source.width / width)
                let sourceIndex = (sourceY * source.width + sourceX) * 3
                let destinationIndex = (y * width + x) * 3
                pixels[destinationIndex] = source.bgr[sourceIndex]
                pixels[destinationIndex + 1] = source.bgr[sourceIndex + 1]
                pixels[destinationIndex + 2] = source.bgr[sourceIndex + 2]
            }
        }
        return ImageBuffer(width: width, height: height, bgr: pixels)
    }

    enum RecordingError: LocalizedError {
        case invalidRegion
        case cannotCreateWriter
        case notStarted
        case writerStopped
        case pixelBufferCreationFailed
        case appendFailed

        var errorDescription: String? {
            switch self {
            case .invalidRegion: return "验证区域超出游戏画面"
            case .cannotCreateWriter: return "无法创建验证录像文件"
            case .notStarted: return "验证录像尚未开始"
            case .writerStopped: return "验证录像写入器已停止"
            case .pixelBufferCreationFailed: return "无法转换验证录像帧"
            case .appendFailed: return "无法写入验证录像帧"
            }
        }
    }
}
