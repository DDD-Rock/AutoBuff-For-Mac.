import CoreGraphics
import Foundation

enum DialogConfirmButtonValidator {
    static let minimumOrangePixelRatio = 0.30

    static func orangePixelRatio(in image: ImageBuffer, match: MatchResult) -> Double {
        guard let candidate = image.cropped(
            x: match.x,
            y: match.y,
            width: match.width,
            height: match.height
        ) else {
            return 0
        }

        var orangePixels = 0
        let pixelCount = candidate.width * candidate.height
        guard pixelCount > 0 else { return 0 }

        for index in stride(from: 0, to: candidate.bgr.count, by: 3) {
            let blue = Int(candidate.bgr[index])
            let green = Int(candidate.bgr[index + 1])
            let red = Int(candidate.bgr[index + 2])

            // The actual confirm button has an orange/brown background with
            // white glyphs. Grayscale-only matching can otherwise confuse the
            // bright market toolbar with that layout.
            if red >= 130, red - green >= 25, green - blue >= 15 {
                orangePixels += 1
            }
        }

        return Double(orangePixels) / Double(pixelCount)
    }

    static func isPlausible(in image: ImageBuffer, match: MatchResult) -> Bool {
        orangePixelRatio(in: image, match: match) >= minimumOrangePixelRatio
    }
}

@available(macOS 14.0, *)
final class DialogDetector {
    private let captureService = GameCaptureService()
    private var windowID: CGWindowID = 0
    var confidence: Double = 0.5
    private(set) var lastDetectionSummary = "尚未检测弹窗"
    
    func setWindow(_ windowID: CGWindowID) {
        self.windowID = windowID
    }
    
    func findConfirmButtonScreenPoint() async throws -> CGPoint? {
        guard let template = TemplatePaths.load(TemplatePaths.confirmButton) else { return nil }
        let captured = try await captureService.captureBGR(windowID: windowID)
        let searchStart = Int(Double(captured.buffer.height) * 0.3)
        guard let region = captured.buffer.subBuffer(fromY: searchStart) else { return nil }
        let threshold = confidence
        guard let match = await Task.detached(priority: .userInitiated, operation: {
            TemplateMatcher.match(image: region, template: template, threshold: threshold)
        }).value else {
            lastDetectionSummary = "未匹配到确定按钮"
            return nil
        }

        let orangeRatio = DialogConfirmButtonValidator.orangePixelRatio(in: region, match: match)
        guard DialogConfirmButtonValidator.isPlausible(in: region, match: match) else {
            lastDetectionSummary = String(
                format: "已排除灰度误匹配：置信度=%.2f，橙色占比=%.2f",
                match.confidence,
                orangeRatio
            )
            return nil
        }

        lastDetectionSummary = String(
            format: "确定按钮：置信度=%.2f，橙色占比=%.2f",
            match.confidence,
            orangeRatio
        )
        let gamePoint = CGPoint(x: match.center.x, y: CGFloat(searchStart) + match.center.y)
        return captured.screenPoint(for: gamePoint)
    }
}
