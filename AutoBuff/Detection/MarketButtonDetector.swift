import CoreGraphics
import Foundation

enum GameLocationState: Equatable, Sendable {
    case market
    case monsterMap
    case unknown
}

struct GameLocationDetection: Equatable, Sendable {
    let state: GameLocationState
    let marketLogoConfidence: Double?
    let marketButtonConfidence: Double?

    var debugSummary: String {
        let logo = marketLogoConfidence.map { String(format: "%.3f", $0) } ?? "无"
        let button = marketButtonConfidence.map { String(format: "%.3f", $0) } ?? "无"
        return "市场图标=\(logo), 市场按钮=\(button)"
    }
}

@available(macOS 14.0, *)
final class MarketButtonDetector {
    static let marketLogoConfidence = 0.55
    static let marketLogoScales = [
        0.45, 0.5, 0.55,
        0.6, 0.7, 0.8, 0.9, 1.0, 1.1, 1.2, 1.3, 1.4,
    ]

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
    
    func isMarketLogoVisible(confidence: Double = 0.55) async throws -> Bool {
        guard let template = TemplatePaths.load(TemplatePaths.marketLogo) else { return false }
        let minimap = try await captureMinimapRegion()
        return await Task.detached(priority: .userInitiated, operation: {
            TemplateMatcher.match(
                image: minimap,
                template: template,
                threshold: confidence,
                scales: Self.marketLogoScales
            )
        }).value != nil
    }

    func detectLocation() async throws -> GameLocationDetection {
        guard let logoTemplate = TemplatePaths.load(TemplatePaths.marketLogo),
              let buttonTemplate = TemplatePaths.load(TemplatePaths.marketButton) else {
            return GameLocationDetection(
                state: .unknown,
                marketLogoConfidence: nil,
                marketButtonConfidence: nil
            )
        }

        let captured = try await captureGameScreen()
        let buttonThreshold = confidence
        let matches = await Task.detached(priority: .userInitiated) {
            let minimap = captured.buffer.cropped(
                x: 0,
                y: 0,
                width: min(200, captured.buffer.width),
                height: min(150, captured.buffer.height)
            )
            let logoMatch = minimap.flatMap {
                TemplateMatcher.match(
                    image: $0,
                    template: logoTemplate,
                    threshold: -1,
                    scales: Self.marketLogoScales
                )
            }

            let bottomStart = Int(Double(captured.buffer.height) * 0.85)
            let bottom = captured.buffer.subBuffer(fromY: bottomStart)
            let buttonMatch = bottom.flatMap {
                TemplateMatcher.match(image: $0, template: buttonTemplate, threshold: -1)
            }
            return (logoMatch, buttonMatch)
        }.value

        let logoConfidence = matches.0?.confidence
        let buttonConfidence = matches.1?.confidence
        let state = Self.classifyLocation(
            hasMarketButton: (buttonConfidence ?? -.infinity) >= buttonThreshold,
            marketLogoConfidence: logoConfidence,
            marketLogoThreshold: Self.marketLogoConfidence
        )
        return GameLocationDetection(
            state: state,
            marketLogoConfidence: logoConfidence,
            marketButtonConfidence: buttonConfidence
        )
    }

    static func classifyLocation(
        hasMarketButton: Bool,
        marketLogoConfidence: Double?,
        marketLogoThreshold: Double = 0.55
    ) -> GameLocationState {
        guard hasMarketButton else { return .unknown }
        guard (marketLogoConfidence ?? -.infinity) >= marketLogoThreshold else {
            return .monsterMap
        }
        return .market
    }
    
    func isInMarket() async throws -> Bool {
        try await detectLocation().state == .market
    }
    
    func isInMonsterMap() async throws -> Bool {
        try await detectLocation().state == .monsterMap
    }
}
