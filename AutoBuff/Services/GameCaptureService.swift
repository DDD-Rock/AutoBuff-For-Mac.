import CoreGraphics
import CoreMedia
import ScreenCaptureKit
import AppKit

struct CapturedGameFrame {
    let buffer: ImageBuffer
    let windowBounds: CGRect
    
    func screenPoint(for imagePoint: CGPoint) -> CGPoint {
        ImagePipeline.imagePointToScreenPoint(
            imagePoint,
            imageSize: CGSize(width: buffer.width, height: buffer.height),
            windowBounds: windowBounds
        )
    }
}

enum GameCaptureError: Error, LocalizedError {
    case windowNotFound
    case captureFailed
    case noImage
    
    var errorDescription: String? {
        switch self {
        case .windowNotFound: return "未找到目标窗口"
        case .captureFailed: return "截图失败，请检查屏幕录制权限"
        case .noImage: return "无法生成图像"
        }
    }
}

enum MonitorStreamConfiguration {
    static let queueDepth = 3

    static func make(
        region: CGRect,
        targetFramesPerSecond: Double
    ) -> SCStreamConfiguration {
        let captureRegion = region.standardized.integral
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = captureRegion
        configuration.width = max(1, Int(captureRegion.width))
        configuration.height = max(1, Int(captureRegion.height))
        configuration.minimumFrameInterval = CMTime(
            value: 1,
            timescale: CMTimeScale(max(1, Int32(targetFramesPerSecond.rounded())))
        )
        configuration.queueDepth = queueDepth
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = false
        configuration.scalesToFit = true
        configuration.preservesAspectRatio = false
        configuration.captureResolution = .nominal
        return configuration
    }
}

enum LatestMinimapFrameStream {
    typealias Frames = AsyncThrowingStream<ImageBuffer, Error>

    static func make() -> (
        frames: Frames,
        continuation: Frames.Continuation
    ) {
        var storedContinuation: Frames.Continuation?
        let frames = Frames(bufferingPolicy: .bufferingNewest(1)) { continuation in
            storedContinuation = continuation
        }
        return (frames, storedContinuation!)
    }
}

@available(macOS 14.0, *)
private final class GameRegionCaptureOutput: NSObject, SCStreamOutput, SCStreamDelegate {
    private let continuation: LatestMinimapFrameStream.Frames.Continuation

    init(continuation: LatestMinimapFrameStream.Frames.Continuation) {
        self.continuation = continuation
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard outputType == .screen,
              CMSampleBufferIsValid(sampleBuffer),
              CMSampleBufferDataIsReady(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let frame = ImagePipeline.pixelBufferToBGRBuffer(pixelBuffer) else {
            return
        }
        continuation.yield(frame)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        continuation.finish(throwing: error)
    }
}

@available(macOS 14.0, *)
final class GameRegionCaptureStream: @unchecked Sendable {
    let frames: LatestMinimapFrameStream.Frames

    private let continuation: LatestMinimapFrameStream.Frames.Continuation
    private let outputQueue = DispatchQueue(
        label: "cc.juanwang.AutoBuff.monitor-capture",
        qos: .userInteractive
    )
    private let output: GameRegionCaptureOutput
    private let captureStream: SCStream
    private let stateLock = NSLock()
    private var isCapturing = false

    init(filter: SCContentFilter, configuration: SCStreamConfiguration) {
        let channel = LatestMinimapFrameStream.make()
        frames = channel.frames
        continuation = channel.continuation
        output = GameRegionCaptureOutput(continuation: channel.continuation)
        captureStream = SCStream(
            filter: filter,
            configuration: configuration,
            delegate: output
        )
    }

    func start() async throws {
        do {
            try captureStream.addStreamOutput(
                output,
                type: .screen,
                sampleHandlerQueue: outputQueue
            )
            try await captureStream.startCapture()
            setCapturing(true)
        } catch {
            continuation.finish(throwing: error)
            throw error
        }
    }

    func stop() async {
        let shouldStop = takeCapturingState()

        if shouldStop {
            try? await captureStream.stopCapture()
        }
        continuation.finish()
    }

    private func setCapturing(_ value: Bool) {
        stateLock.lock()
        isCapturing = value
        stateLock.unlock()
    }

    private func takeCapturingState() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        let wasCapturing = isCapturing
        isCapturing = false
        return wasCapturing
    }
}

@available(macOS 14.0, *)
final class GameCaptureService {
    private let windowSelector = WindowSelector()
    private var cachedWindowID: CGWindowID?
    private var cachedFilter: SCContentFilter?
    private var cachedConfiguration: SCStreamConfiguration?
    private var cachedBounds: CGRect = .zero

    func clearCaptureCache() {
        cachedWindowID = nil
        cachedFilter = nil
        cachedConfiguration = nil
        cachedBounds = .zero
    }
    
    func captureWindow(windowID: CGWindowID) async throws -> (image: CGImage, bounds: CGRect) {
        let context = try await captureContext(windowID: windowID)
        let bounds = windowSelector.getWindowInfo(windowID: windowID)?.bounds ?? cachedBounds
        if bounds.width > 0,
           bounds.height > 0,
           (
               context.configuration.width != Int(bounds.width.rounded())
                   || context.configuration.height != Int(bounds.height.rounded())
           ) {
            context.configuration.width = max(1, Int(bounds.width.rounded()))
            context.configuration.height = max(1, Int(bounds.height.rounded()))
            cachedBounds = bounds
        }

        do {
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: context.filter,
                configuration: context.configuration
            )
            return (image, bounds)
        } catch {
            clearCaptureCache()
            throw error
        }
    }
    
    func captureBGR(windowID: CGWindowID) async throws -> CapturedGameFrame {
        let result = try await captureWindow(windowID: windowID)
        guard let buffer = ImagePipeline.cgImageToBGRBuffer(result.image) else {
            throw GameCaptureError.noImage
        }
        return CapturedGameFrame(buffer: buffer, windowBounds: result.bounds)
    }
    
    func captureRegion(windowID: CGWindowID, rect: CGRect) async throws -> ImageBuffer {
        let captured = try await captureBGR(windowID: windowID)
        let x = max(0, Int(rect.origin.x))
        let y = max(0, Int(rect.origin.y))
        let w = min(Int(rect.width), captured.buffer.width - x)
        let h = min(Int(rect.height), captured.buffer.height - y)
        guard let cropped = captured.buffer.cropped(x: x, y: y, width: w, height: h) else {
            throw GameCaptureError.noImage
        }
        return cropped
    }

    func startRegionStream(
        windowID: CGWindowID,
        rect: CGRect,
        targetFramesPerSecond: Double
    ) async throws -> GameRegionCaptureStream {
        guard rect.width > 0, rect.height > 0 else {
            throw GameCaptureError.noImage
        }
        let context = try await captureContext(windowID: windowID)
        let configuration = MonitorStreamConfiguration.make(
            region: rect,
            targetFramesPerSecond: targetFramesPerSecond
        )
        let stream = GameRegionCaptureStream(
            filter: context.filter,
            configuration: configuration
        )
        try await stream.start()
        return stream
    }

    private func captureContext(
        windowID: CGWindowID
    ) async throws -> (filter: SCContentFilter, configuration: SCStreamConfiguration) {
        if cachedWindowID == windowID,
           let cachedFilter,
           let cachedConfiguration {
            return (cachedFilter, cachedConfiguration)
        }

        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            clearCaptureCache()
            throw GameCaptureError.windowNotFound
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        // Capture at Quartz point resolution. This keeps template sizes, screenshot
        // coordinates and CGEvent coordinates in the same scale on Retina displays.
        configuration.width = max(1, Int(window.frame.width.rounded()))
        configuration.height = max(1, Int(window.frame.height.rounded()))
        configuration.showsCursor = false
        configuration.captureResolution = .nominal

        cachedWindowID = windowID
        cachedFilter = filter
        cachedConfiguration = configuration
        cachedBounds = windowSelector.getWindowInfo(windowID: windowID)?.bounds ?? window.frame
        return (filter, configuration)
    }
}
