import CoreGraphics
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

@available(macOS 14.0, *)
final class GameCaptureService {
    private let windowSelector = WindowSelector()
    
    func captureWindow(windowID: CGWindowID) async throws -> (image: CGImage, bounds: CGRect) {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw GameCaptureError.windowNotFound
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        // Capture at Quartz point resolution. This keeps template sizes, screenshot
        // coordinates and CGEvent coordinates in the same scale on Retina displays.
        config.width = max(1, Int(window.frame.width.rounded()))
        config.height = max(1, Int(window.frame.height.rounded()))
        config.showsCursor = false
        config.captureResolution = .nominal
        
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        let bounds = windowSelector.getWindowInfo(windowID: windowID)?.bounds ?? window.frame
        return (image, bounds)
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
}
