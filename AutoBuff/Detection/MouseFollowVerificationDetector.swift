import CoreGraphics
import Foundation

/// 一次「寻找透明图形 / 鼠标跟随验证」弹窗识别结果。
///
/// 这里识别的是整个验证弹窗，而不是中央会快速变暗、形状也不固定的目标图案。
/// 稳定结构为：大面积金黄色纹理主体，以及与主体左右对齐的深灰标题栏和说明栏。
struct MouseFollowVerificationDetection: Equatable, Sendable {
    let rect: CGRect
    let bodyRect: CGRect
    let goldCoverage: Double
    let titleBarDarkCoverage: Double
    let instructionBarDarkCoverage: Double
    let titleGlyphCoverage: Double
    let brightTargetCoverage: Double
    let confidence: Double

    var summary: String {
        "鼠标跟随验证 x=\(Int(rect.minX)) y=\(Int(rect.minY))"
            + " w=\(Int(rect.width)) h=\(Int(rect.height))"
            + "，金色主体=\(String(format: "%.2f", goldCoverage))"
            + "，标题栏=\(String(format: "%.2f", titleBarDarkCoverage))"
            + "，说明栏=\(String(format: "%.2f", instructionBarDarkCoverage))"
            + "，标题字形=\(String(format: "%.2f", titleGlyphCoverage))"
            + "，置信度=\(String(format: "%.2f", confidence))"
    }
}

/// 「寻找透明图形」验证弹窗检测器。
///
/// 不使用固定屏幕坐标，也不要求弹窗占游戏窗口的固定比例。检测流程先在整窗任意位置
/// 找金黄色纹理的连通主体，再完全以候选主体自身宽高为尺度验证上下深灰栏和标题字形。
enum MouseFollowVerificationDetector {
    /// 降采样后的连通域仍需保留足够像素，排除技能图标和小型金色特效。
    static let minimumComponentCells = 900
    /// 仅作为噪声保护的绝对下限，不参与置信度，也不依赖窗口比例。
    static let minimumBodyWidth = 150
    static let minimumBodyHeight = 100
    static let minimumGoldCoverage = 0.55
    static let minimumDarkBarCoverage = 0.48
    static let minimumTitleGlyphCoverage = 0.012
    static let minimumBodyAspectRatio = 0.80
    static let maximumBodyAspectRatio = 3.00

    private static let strongGoldCoverage = 0.85
    private static let strongDarkBarCoverage = 0.72
    private static let strongTitleGlyphCoverage = 0.08

    private struct Component {
        let area: Int
        let minX: Int
        let minY: Int
        let maxX: Int
        let maxY: Int

        var width: Int { maxX - minX + 1 }
        var height: Int { maxY - minY + 1 }
        var coverage: Double { Double(area) / Double(width * height) }
    }

    static func detect(in image: ImageBuffer) -> MouseFollowVerificationDetection? {
        guard !image.isEmpty, image.width >= 240, image.height >= 180 else { return nil }

        let stride = samplingStride(width: image.width, height: image.height)
        let gridWidth = (image.width + stride - 1) / stride
        let gridHeight = (image.height + stride - 1) / stride
        let goldMask = makeGoldMask(
            image: image,
            stride: stride,
            gridWidth: gridWidth,
            gridHeight: gridHeight
        )

        let components = connectedComponents(
            mask: goldMask,
            width: gridWidth,
            height: gridHeight
        )
        .filter { $0.area >= minimumComponentCells }
        .sorted { $0.area > $1.area }

        var best: MouseFollowVerificationDetection?
        for component in components.prefix(8) {
            guard component.coverage >= minimumGoldCoverage else { continue }

            let bodyRect = pixelRect(
                for: component,
                stride: stride,
                imageWidth: image.width,
                imageHeight: image.height
            )
            guard bodyRect.width >= Double(minimumBodyWidth),
                  bodyRect.height >= Double(minimumBodyHeight) else {
                continue
            }
            let aspectRatio = bodyRect.width / bodyRect.height
            guard aspectRatio >= minimumBodyAspectRatio,
                  aspectRatio <= maximumBodyAspectRatio else {
                continue
            }

            guard let bars = surroundingBars(for: bodyRect, image: image) else { continue }
            let topDark = darkCoverage(in: bars.title, image: image, stride: stride)
            let bottomDark = darkCoverage(in: bars.instruction, image: image, stride: stride)
            guard topDark >= minimumDarkBarCoverage,
                  bottomDark >= minimumDarkBarCoverage else {
                continue
            }

            let titleGlyphRect = CGRect(
                x: bars.title.minX + bars.title.width * 0.28,
                y: bars.title.minY,
                width: bars.title.width * 0.44,
                height: bars.title.height
            ).integral
            let titleGlyphs = brightNeutralCoverage(
                in: titleGlyphRect,
                image: image,
                stride: max(1, stride / 2)
            )
            guard titleGlyphs >= minimumTitleGlyphCoverage else { continue }

            let brightTarget = brightNeutralCoverage(
                in: bodyRect,
                image: image,
                stride: stride
            )
            let confidence = confidence(
                goldCoverage: component.coverage,
                titleBarDarkCoverage: topDark,
                instructionBarDarkCoverage: bottomDark,
                titleGlyphCoverage: titleGlyphs,
                brightTargetCoverage: brightTarget
            )
            let wholeRect = bars.title.union(bodyRect).union(bars.instruction).integral
            let candidate = MouseFollowVerificationDetection(
                rect: wholeRect,
                bodyRect: bodyRect,
                goldCoverage: component.coverage,
                titleBarDarkCoverage: topDark,
                instructionBarDarkCoverage: bottomDark,
                titleGlyphCoverage: titleGlyphs,
                brightTargetCoverage: brightTarget,
                confidence: confidence
            )
            if best == nil || candidate.confidence > best!.confidence {
                best = candidate
            }
        }
        return best
    }

    static func confidence(
        goldCoverage: Double,
        titleBarDarkCoverage: Double,
        instructionBarDarkCoverage: Double,
        titleGlyphCoverage: Double,
        brightTargetCoverage: Double
    ) -> Double {
        let gold = normalize(
            goldCoverage,
            lowerBound: minimumGoldCoverage,
            upperBound: strongGoldCoverage
        )
        let title = normalize(
            titleBarDarkCoverage,
            lowerBound: minimumDarkBarCoverage,
            upperBound: strongDarkBarCoverage
        )
        let instruction = normalize(
            instructionBarDarkCoverage,
            lowerBound: minimumDarkBarCoverage,
            upperBound: strongDarkBarCoverage
        )
        let glyphs = normalize(
            titleGlyphCoverage,
            lowerBound: minimumTitleGlyphCoverage,
            upperBound: strongTitleGlyphCoverage
        )
        // 白色目标会很快消失，只能少量加分，绝不能成为成立条件。
        let targetBonus = min(0.05, max(0, brightTargetCoverage - 0.01) * 0.5)
        return min(1, 0.35 * gold + 0.22 * title + 0.22 * instruction + 0.21 * glyphs + targetBonus)
    }

    static func isGoldPixel(b: Int, g: Int, r: Int) -> Bool {
        r >= 105
            && g >= 65
            && r >= g + 10
            && g >= b + 12
            && r >= b + 42
            && b <= 175
    }

    static func isDarkNeutralPixel(b: Int, g: Int, r: Int) -> Bool {
        let maximum = max(r, max(g, b))
        let minimum = min(r, min(g, b))
        return maximum <= 92 && maximum - minimum <= 30
    }

    static func isBrightNeutralPixel(b: Int, g: Int, r: Int) -> Bool {
        let maximum = max(r, max(g, b))
        let minimum = min(r, min(g, b))
        return minimum >= 125 && maximum - minimum <= 45
    }

    private static func samplingStride(width: Int, height: Int) -> Int {
        max(2, min(6, min(width, height) / 300))
    }

    private static func makeGoldMask(
        image: ImageBuffer,
        stride: Int,
        gridWidth: Int,
        gridHeight: Int
    ) -> [Bool] {
        var mask = [Bool](repeating: false, count: gridWidth * gridHeight)
        image.bgr.withUnsafeBufferPointer { pixels in
            for gridY in 0..<gridHeight {
                let y = min(image.height - 1, gridY * stride)
                for gridX in 0..<gridWidth {
                    let x = min(image.width - 1, gridX * stride)
                    let index = (y * image.width + x) * 3
                    guard index + 2 < pixels.count else { continue }
                    mask[gridY * gridWidth + gridX] = isGoldPixel(
                        b: Int(pixels[index]),
                        g: Int(pixels[index + 1]),
                        r: Int(pixels[index + 2])
                    )
                }
            }
        }
        return mask
    }

    private static func connectedComponents(
        mask: [Bool],
        width: Int,
        height: Int
    ) -> [Component] {
        guard width > 0, height > 0, mask.count == width * height else { return [] }
        var visited = [Bool](repeating: false, count: mask.count)
        var result: [Component] = []
        var queue: [Int] = []

        for start in mask.indices where mask[start] && !visited[start] {
            queue.removeAll(keepingCapacity: true)
            queue.append(start)
            visited[start] = true
            var cursor = 0
            var area = 0
            var minX = width
            var minY = height
            var maxX = 0
            var maxY = 0

            while cursor < queue.count {
                let index = queue[cursor]
                cursor += 1
                let x = index % width
                let y = index / width
                area += 1
                minX = min(minX, x)
                minY = min(minY, y)
                maxX = max(maxX, x)
                maxY = max(maxY, y)

                for dy in -1...1 {
                    for dx in -1...1 where dx != 0 || dy != 0 {
                        let nextX = x + dx
                        let nextY = y + dy
                        guard nextX >= 0, nextY >= 0,
                              nextX < width, nextY < height else { continue }
                        let next = nextY * width + nextX
                        guard mask[next], !visited[next] else { continue }
                        visited[next] = true
                        queue.append(next)
                    }
                }
            }

            result.append(
                Component(
                    area: area,
                    minX: minX,
                    minY: minY,
                    maxX: maxX,
                    maxY: maxY
                )
            )
        }
        return result
    }

    private static func pixelRect(
        for component: Component,
        stride: Int,
        imageWidth: Int,
        imageHeight: Int
    ) -> CGRect {
        let x = component.minX * stride
        let y = component.minY * stride
        let maxX = min(imageWidth, (component.maxX + 1) * stride)
        let maxY = min(imageHeight, (component.maxY + 1) * stride)
        return CGRect(x: x, y: y, width: maxX - x, height: maxY - y)
    }

    private static func surroundingBars(
        for body: CGRect,
        image: ImageBuffer
    ) -> (title: CGRect, instruction: CGRect)? {
        // 内部比例来自弹窗自身，不受整个游戏窗口分辨率和占比影响。
        let horizontalExpansion = body.width * 0.025
        let titleHeight = body.height * 0.18
        let instructionHeight = body.height * 0.22
        let x = max(0, body.minX - horizontalExpansion)
        let maxX = min(Double(image.width), body.maxX + horizontalExpansion)
        let titleY = body.minY - titleHeight
        let instructionMaxY = body.maxY + instructionHeight
        guard titleY >= 0, instructionMaxY <= Double(image.height), maxX > x else { return nil }
        return (
            CGRect(x: x, y: titleY, width: maxX - x, height: titleHeight).integral,
            CGRect(x: x, y: body.maxY, width: maxX - x, height: instructionHeight).integral
        )
    }

    private static func darkCoverage(in rect: CGRect, image: ImageBuffer, stride: Int) -> Double {
        coverage(in: rect, image: image, stride: stride, predicate: isDarkNeutralPixel)
    }

    private static func brightNeutralCoverage(
        in rect: CGRect,
        image: ImageBuffer,
        stride: Int
    ) -> Double {
        coverage(in: rect, image: image, stride: stride, predicate: isBrightNeutralPixel)
    }

    private static func coverage(
        in rect: CGRect,
        image: ImageBuffer,
        stride: Int,
        predicate: (_ b: Int, _ g: Int, _ r: Int) -> Bool
    ) -> Double {
        let minX = max(0, Int(rect.minX.rounded(.down)))
        let minY = max(0, Int(rect.minY.rounded(.down)))
        let maxX = min(image.width, Int(rect.maxX.rounded(.up)))
        let maxY = min(image.height, Int(rect.maxY.rounded(.up)))
        guard minX < maxX, minY < maxY else { return 0 }

        var total = 0
        var hits = 0
        image.bgr.withUnsafeBufferPointer { pixels in
            var y = minY
            while y < maxY {
                var x = minX
                while x < maxX {
                    let index = (y * image.width + x) * 3
                    if index + 2 < pixels.count {
                        total += 1
                        if predicate(
                            Int(pixels[index]),
                            Int(pixels[index + 1]),
                            Int(pixels[index + 2])
                        ) {
                            hits += 1
                        }
                    }
                    x += max(1, stride)
                }
                y += max(1, stride)
            }
        }
        return total > 0 ? Double(hits) / Double(total) : 0
    }

    private static func normalize(_ value: Double, lowerBound: Double, upperBound: Double) -> Double {
        guard upperBound > lowerBound else { return 0 }
        return min(1, max(0, (value - lowerBound) / (upperBound - lowerBound)))
    }
}

/// 验证弹窗告警防抖：结构非常强时单帧立即触发；边缘样本要求连续两帧。
struct MouseFollowVerificationStabilizer {
    static let immediateConfidence = 0.72
    static let requiredConsecutiveDetections = 2
    static let requiredConsecutiveMisses = 2

    private(set) var isPresent = false
    private(set) var consecutiveDetections = 0
    private(set) var consecutiveMisses = 0
    private(set) var latestDetection: MouseFollowVerificationDetection?

    @discardableResult
    mutating func update(_ detection: MouseFollowVerificationDetection?) -> Bool {
        if let detection {
            consecutiveMisses = 0
            consecutiveDetections += 1
            latestDetection = detection
            guard !isPresent,
                  detection.confidence >= Self.immediateConfidence
                    || consecutiveDetections >= Self.requiredConsecutiveDetections else {
                return false
            }
            isPresent = true
            return true
        }

        consecutiveDetections = 0
        consecutiveMisses += 1
        guard isPresent, consecutiveMisses >= Self.requiredConsecutiveMisses else { return false }
        isPresent = false
        latestDetection = nil
        return true
    }

    mutating func reset() {
        isPresent = false
        consecutiveDetections = 0
        consecutiveMisses = 0
        latestDetection = nil
    }
}
