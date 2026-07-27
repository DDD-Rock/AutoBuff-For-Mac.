import CoreGraphics
import Foundation

@available(macOS 14.0, *)
final class MinimapMonitor {
    private let captureService = GameCaptureService()
    private var windowID: CGWindowID = 0
    private var minimapRegion: CGRect?
    private var windowBounds: CGRect = .zero
    private var expectedPlayerPoint: CGPoint?
    private(set) var lastCaptureSize: CGSize = .zero
    private(set) var lastWhiteFrameDiagnostics = "尚未执行白框诊断"
    private(set) var lastDetectionSummary = "尚未执行小地图检测"
    private(set) var lastPlayerDetectionSummary = "尚未执行玩家黄点检测"
    
    func setWindow(_ windowID: CGWindowID) {
        if self.windowID != windowID {
            minimapRegion = nil
            expectedPlayerPoint = nil
            captureService.clearCaptureCache()
        }
        self.windowID = windowID
    }
    
    func setMinimapRegion(_ rect: CGRect) {
        minimapRegion = rect
    }
    
    func clearMinimapRegion() {
        minimapRegion = nil
    }

    func setExpectedPlayerPoint(_ point: CGPoint?) {
        expectedPlayerPoint = point
    }
    
    var minimapSize: CGSize? {
        guard let region = minimapRegion else { return nil }
        return region.size
    }
    
    func autoDetectDarkRegion() async throws -> CGRect? {
        let captured = try await captureService.captureBGR(windowID: windowID)
        windowBounds = captured.windowBounds
        lastCaptureSize = CGSize(
            width: captured.buffer.width,
            height: captured.buffer.height
        )
        let output = await Task.detached(priority: .userInitiated, operation: {
            (
                ColorDetector.detectMinimapRegion(in: captured.buffer),
                ColorDetector.minimapWhiteFrameDiagnostics(in: captured.buffer)
            )
        }).value
        let result = output.0
        lastWhiteFrameDiagnostics = output.1
        lastDetectionSummary = result.summary
        if let rect = result.rect {
            minimapRegion = rect
            return rect
        }
        return nil
    }

    func captureMinimap() async throws -> ImageBuffer {
        if minimapRegion == nil {
            _ = try await autoDetectDarkRegion()
        }
        if let region = minimapRegion {
            return try await captureService.captureRegion(windowID: windowID, rect: region)
        }
        return try await captureService.captureRegion(windowID: windowID, rect: CGRect(x: 0, y: 0, width: 300, height: 200))
    }

    func startMinimapStream(
        targetFramesPerSecond: Double
    ) async throws -> GameRegionCaptureStream {
        guard let minimapRegion else {
            throw GameCaptureError.noImage
        }
        return try await captureService.startRegionStream(
            windowID: windowID,
            rect: minimapRegion,
            targetFramesPerSecond: targetFramesPerSecond
        )
    }
    
    func findPlayerPosition(minArea: Int = 2) async throws -> CGPoint? {
        let minimap = try await captureMinimap()
        let expectedPlayerPoint = self.expectedPlayerPoint
        let result = await Task.detached(priority: .userInitiated, operation: {
            ColorDetector.detectPlayerMarker(
                in: minimap,
                minArea: minArea,
                near: expectedPlayerPoint
            )
        }).value
        lastPlayerDetectionSummary = result.summary
        if let point = result.point {
            self.expectedPlayerPoint = point
        }
        return result.point
    }
    
    func findBluePortal(leftmost: Bool = true) async throws -> CGPoint? {
        let minimap = try await captureMinimap()
        return await Task.detached(priority: .userInitiated, operation: {
            ColorDetector.findBluePortal(in: minimap, leftmost: leftmost)
        }).value
    }
    
    func captureGameScreen() async throws -> ImageBuffer {
        let captured = try await captureService.captureBGR(windowID: windowID)
        windowBounds = captured.windowBounds
        return captured.buffer
    }
    
    func screenPoint(for imagePoint: CGPoint) -> CGPoint {
        let originX = (minimapRegion?.origin.x ?? 0) + imagePoint.x
        let originY = (minimapRegion?.origin.y ?? 0) + imagePoint.y
        let imageSize = CGSize(width: windowBounds.width, height: windowBounds.height)
        return ImagePipeline.imagePointToScreenPoint(
            CGPoint(x: originX, y: originY),
            imageSize: imageSize,
            windowBounds: windowBounds
        )
    }
}
