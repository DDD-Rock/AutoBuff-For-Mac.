import CoreGraphics
import Foundation

@available(macOS 14.0, *)
final class MarketButtonDetector {
    private let captureService = GameCaptureService()
    private var windowID: CGWindowID = 0
    var confidence: Double = 0.3
    
    func setWindow(_ windowID: CGWindowID) {
        self.windowID = windowID
    }
    
    func captureGameScreen() async throws -> CapturedGameFrame {
        try await captureService.captureBGR(windowID: windowID)
    }
    
    func findMarketButtonInGame() async throws -> CGPoint? {
        guard let template = TemplatePaths.load(TemplatePaths.marketButton) else { return nil }
        let captured = try await captureGameScreen()
        let bottomStart = Int(Double(captured.buffer.height) * 0.85)
        guard let bottom = captured.buffer.subBuffer(fromY: bottomStart) else { return nil }
        let threshold = confidence
        guard let match = await Task.detached(priority: .userInitiated, operation: {
            TemplateMatcher.match(image: bottom, template: template, threshold: threshold)
        }).value else { return nil }
        return CGPoint(x: match.center.x, y: CGFloat(bottomStart) + match.center.y)
    }
    
    func findMarketButtonScreenPoint() async throws -> CGPoint? {
        guard let template = TemplatePaths.load(TemplatePaths.marketButton) else { return nil }
        let captured = try await captureGameScreen()
        let bottomStart = Int(Double(captured.buffer.height) * 0.85)
        guard let bottom = captured.buffer.subBuffer(fromY: bottomStart) else { return nil }
        let threshold = confidence
        guard let match = await Task.detached(priority: .userInitiated, operation: {
            TemplateMatcher.match(image: bottom, template: template, threshold: threshold)
        }).value else { return nil }
        let gamePoint = CGPoint(x: match.center.x, y: CGFloat(bottomStart) + match.center.y)
        return captured.screenPoint(for: gamePoint)
    }
    
    func captureMinimapRegion() async throws -> ImageBuffer {
        try await captureService.captureRegion(windowID: windowID, rect: CGRect(x: 0, y: 0, width: 200, height: 150))
    }
    
    func isMarketLogoVisible(confidence: Double = 0.5) async throws -> Bool {
        guard let template = TemplatePaths.load(TemplatePaths.marketLogo) else { return false }
        let minimap = try await captureMinimapRegion()
        if await Task.detached(priority: .userInitiated, operation: {
            TemplateMatcher.match(image: minimap, template: template, threshold: confidence)
        }).value != nil {
            return true
        }
        let cropTop = template.height * 4 / 10
        guard let bottomTemplate = template.cropped(x: 0, y: cropTop, width: template.width, height: template.height - cropTop) else {
            return false
        }
        return await Task.detached(priority: .userInitiated, operation: {
            TemplateMatcher.match(image: minimap, template: bottomTemplate, threshold: confidence)
        }).value != nil
    }
    
    func isInMarket() async throws -> Bool {
        let hasLogo = try await isMarketLogoVisible()
        let hasButton = try await findMarketButtonInGame() != nil
        return hasLogo && hasButton
    }
    
    func isInMonsterMap() async throws -> Bool {
        let hasLogo = try await isMarketLogoVisible()
        let hasButton = try await findMarketButtonInGame() != nil
        return !hasLogo && hasButton
    }
}
