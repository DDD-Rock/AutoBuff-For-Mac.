import CoreGraphics
import Foundation

@available(macOS 14.0, *)
final class PartyInviteDetector {
    private let captureService = GameCaptureService()
    private var windowID: CGWindowID = 0
    var confidence: Double = 0.58

    private struct OrangeBlob: Sendable {
        let minX: Int
        let minY: Int
        let maxX: Int
        let maxY: Int
        let area: Int

        var width: Int { maxX - minX + 1 }
        var height: Int { maxY - minY + 1 }
        var center: CGPoint {
            CGPoint(x: CGFloat(minX + maxX) / 2, y: CGFloat(minY + maxY) / 2)
        }
    }

    func setWindow(_ windowID: CGWindowID) {
        self.windowID = windowID
    }

    func findAcceptButtonScreenPoint() async throws -> CGPoint? {
        let captured = try await captureService.captureBGR(windowID: windowID)
        let searchRect = searchRect(for: captured.buffer)
        guard let region = captured.buffer.cropped(
            x: searchRect.x,
            y: searchRect.y,
            width: searchRect.width,
            height: searchRect.height
        ) else {
            return nil
        }

        if let colorPoint = await Task.detached(priority: .userInitiated, operation: {
            Self.findInviteButtonsByColor(in: region)
        }).value {
            let gamePoint = CGPoint(
                x: CGFloat(searchRect.x) + colorPoint.x,
                y: CGFloat(searchRect.y) + colorPoint.y
            )
            return captured.screenPoint(for: gamePoint)
        }

        guard let acceptTemplate = TemplatePaths.load(TemplatePaths.partyAcceptButton),
              let declineTemplate = TemplatePaths.load(TemplatePaths.partyDeclineButton) else {
            return nil
        }

        let threshold = confidence
        let scales = [0.45, 0.55, 0.65, 0.75, 0.85, 0.95, 1.0, 1.1, 1.2, 1.3, 1.45, 1.6]
        let match = await Task.detached(priority: .userInitiated) {
            Self.findInviteButtonsByTemplate(
                in: region,
                acceptTemplate: acceptTemplate,
                declineTemplate: declineTemplate,
                threshold: threshold,
                scales: scales
            )
        }.value

        guard let match else { return nil }
        let gamePoint = CGPoint(
            x: CGFloat(searchRect.x) + match.accept.center.x,
            y: CGFloat(searchRect.y) + match.accept.center.y
        )
        return captured.screenPoint(for: gamePoint)
    }

    private func searchRect(for image: ImageBuffer) -> (x: Int, y: Int, width: Int, height: Int) {
        let x = max(0, Int(Double(image.width) * 0.43))
        let y = max(0, Int(Double(image.height) * 0.67))
        let maxWidth = image.width - x
        let maxHeight = image.height - y
        return (x, y, maxWidth, maxHeight)
    }

    private static func findInviteButtonsByColor(in region: ImageBuffer) -> CGPoint? {
        let blobs = orangeBlobs(in: region)
        var bestPair: (accept: OrangeBlob, decline: OrangeBlob, score: CGFloat)?

        for accept in blobs {
            for decline in blobs where accept.minY != decline.minY || accept.minX != decline.minX {
                let dx = abs(decline.center.x - accept.center.x)
                let dy = decline.center.y - accept.center.y
                let buttonSize = CGFloat(
                    max(max(accept.width, accept.height), max(decline.width, decline.height))
                )
                guard dy >= max(20, buttonSize * 1.5),
                      dy <= max(115, buttonSize * 5.5),
                      dx <= max(12, buttonSize * 0.9),
                      decline.center.y <= CGFloat(region.height) * 0.72 else {
                    continue
                }

                let preferredGap = max(38, buttonSize * 2.4)
                let sizeBalance = CGFloat(abs(accept.area - decline.area)) * 0.15
                let score = CGFloat(accept.area + decline.area)
                    - dx * 4
                    - abs(dy - preferredGap)
                    - sizeBalance

                if bestPair == nil || score > bestPair!.score {
                    bestPair = (accept, decline, score)
                }
            }
        }

        guard let bestPair, bestPair.score > 30 else { return nil }
        return bestPair.accept.center
    }

    private static func orangeBlobs(in image: ImageBuffer) -> [OrangeBlob] {
        guard image.width > 0, image.height > 0 else { return [] }

        var visited = [Bool](repeating: false, count: image.width * image.height)
        var blobs: [OrangeBlob] = []
        blobs.reserveCapacity(24)

        for y in 0..<image.height {
            for x in 0..<image.width {
                let index = y * image.width + x
                guard !visited[index], isInviteOrange(image, x: x, y: y) else {
                    visited[index] = true
                    continue
                }

                var stack = [(x, y)]
                visited[index] = true
                var minX = x
                var maxX = x
                var minY = y
                var maxY = y
                var area = 0

                while let (currentX, currentY) = stack.popLast() {
                    area += 1
                    minX = min(minX, currentX)
                    maxX = max(maxX, currentX)
                    minY = min(minY, currentY)
                    maxY = max(maxY, currentY)

                    for ny in max(0, currentY - 1)...min(image.height - 1, currentY + 1) {
                        for nx in max(0, currentX - 1)...min(image.width - 1, currentX + 1) {
                            let neighborIndex = ny * image.width + nx
                            guard !visited[neighborIndex] else { continue }
                            visited[neighborIndex] = true
                            if isInviteOrange(image, x: nx, y: ny) {
                                stack.append((nx, ny))
                            }
                        }
                    }
                }

                let width = maxX - minX + 1
                let height = maxY - minY + 1
                if area >= 18,
                   width >= 4,
                   height >= 4,
                   width <= 85,
                   height <= 85 {
                    blobs.append(
                        OrangeBlob(
                            minX: minX,
                            minY: minY,
                            maxX: maxX,
                            maxY: maxY,
                            area: area
                        )
                    )
                }
            }
        }

        return blobs.sorted { $0.area > $1.area }.prefix(80).map { $0 }
    }

    private static func isInviteOrange(_ image: ImageBuffer, x: Int, y: Int) -> Bool {
        guard let pixel = image.pixelBGR(x: x, y: y) else { return false }
        let b = Int(pixel.b)
        let g = Int(pixel.g)
        let r = Int(pixel.r)
        return r >= 190
            && g >= 60
            && g <= 170
            && b <= 85
            && r - g >= 55
            && g - b >= 20
    }

    private static func findInviteButtonsByTemplate(
        in region: ImageBuffer,
        acceptTemplate: ImageBuffer,
        declineTemplate: ImageBuffer,
        threshold: Double,
        scales: [Double]
    ) -> (accept: MatchResult, decline: MatchResult)? {
        guard let accept = TemplateMatcher.match(
            image: region,
            template: acceptTemplate,
            threshold: threshold,
            scales: scales
        ) else {
            return nil
        }

        let searchX = max(0, accept.x - accept.width)
        let searchY = max(0, accept.y + accept.height / 2)
        let searchWidth = min(region.width - searchX, max(accept.width * 3, 40))
        let searchHeight = min(region.height - searchY, max(accept.height * 4, 60))
        guard searchWidth > 0,
              searchHeight > 0,
              let declineRegion = region.cropped(
                x: searchX,
                y: searchY,
                width: searchWidth,
                height: searchHeight
              ),
              let localDecline = TemplateMatcher.match(
                image: declineRegion,
                template: declineTemplate,
                threshold: threshold,
                scales: scales
              ) else {
            return nil
        }

        let decline = MatchResult(
            x: searchX + localDecline.x,
            y: searchY + localDecline.y,
            width: localDecline.width,
            height: localDecline.height,
            confidence: localDecline.confidence,
            scaleX: localDecline.scaleX,
            scaleY: localDecline.scaleY
        )

        let dx = abs(decline.center.x - accept.center.x)
        let dy = decline.center.y - accept.center.y
        let maxHorizontalDrift = CGFloat(max(accept.width, decline.width))
        let minVerticalGap = CGFloat(max(accept.height, decline.height)) * 0.65
        let maxVerticalGap = CGFloat(max(accept.height, decline.height)) * 2.4
        guard dx <= maxHorizontalDrift,
              dy >= minVerticalGap,
              dy <= maxVerticalGap else {
            return nil
        }

        return (accept, decline)
    }
}
