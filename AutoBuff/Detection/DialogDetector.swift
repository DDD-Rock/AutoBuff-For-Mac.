import CoreGraphics
import Foundation

@available(macOS 14.0, *)
final class DialogDetector {
    private let captureService = GameCaptureService()
    private var windowID: CGWindowID = 0
    var confidence: Double = 0.5
    
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
        }).value else { return nil }
        let gamePoint = CGPoint(x: match.center.x, y: CGFloat(searchStart) + match.center.y)
        return captured.screenPoint(for: gamePoint)
    }
}
