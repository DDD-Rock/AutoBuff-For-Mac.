import CoreGraphics
import Foundation

struct EXPRecognitionResult: Equatable, Sendable {
    let currentEXP: Int
    let percent: Double
    let confidence: Double

    var percentText: String {
        EXPValueFormatter.percent(percent)
    }

    var displayText: String {
        "\(currentEXP) (\(percentText)%)"
    }

    var key: String {
        "\(currentEXP)|\(percentText)"
    }
}

enum EXPValueFormatter {
    static func percent(_ value: Double) -> String {
        String(format: "%.4f", locale: Locale(identifier: "en_US_POSIX"), value)
            .replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\.$"#, with: "", options: .regularExpression)
    }
}

enum EXPLayoutScaleSearch {
    static func candidates(anchorScale: Double) -> [Double] {
        let roundedAnchor = (anchorScale / 0.05).rounded() * 0.05
        let rawCandidates = [
            anchorScale,
            roundedAnchor,
            1.0,
            roundedAnchor - 0.10,
            roundedAnchor - 0.05,
            roundedAnchor + 0.05,
            roundedAnchor + 0.10,
        ]
        var seen = Set<Int>()
        return rawCandidates.compactMap { rawScale in
            let scale = max(0.5, min(2.0, rawScale))
            let key = Int((scale * 100).rounded())
            guard seen.insert(key).inserted else { return nil }
            return Double(key) / 100
        }
    }

    static func horizontalOffsets(layoutScale: Double) -> ClosedRange<Int> {
        -4...4
    }
}

struct EXPRecognitionStabilizer {
    let requiredMatches: Int
    let toleratedMisses: Int

    private(set) var candidateKey: String?
    private(set) var consecutiveMatches = 0
    private(set) var misses = 0
    private(set) var stableReading: EXPRecognitionResult?

    init(requiredMatches: Int = 2, toleratedMisses: Int = 3) {
        self.requiredMatches = max(1, requiredMatches)
        self.toleratedMisses = max(0, toleratedMisses)
    }

    mutating func update(_ reading: EXPRecognitionResult?) -> EXPRecognitionResult? {
        guard let reading else {
            misses += 1
            candidateKey = nil
            consecutiveMatches = 0
            if misses > toleratedMisses {
                stableReading = nil
            }
            return stableReading
        }

        misses = 0
        if reading.key == candidateKey {
            consecutiveMatches += 1
        } else {
            candidateKey = reading.key
            consecutiveMatches = 1
        }
        if consecutiveMatches >= requiredMatches {
            stableReading = reading
        }
        return stableReading
    }

    mutating func reset() {
        candidateKey = nil
        consecutiveMatches = 0
        misses = 0
        stableReading = nil
    }
}

enum EXPFixedFontRecognizer {
    static let canonicalWidth = 185
    static let canonicalHeight = 44

    static func recognize(in frame: ImageBuffer) -> EXPRecognitionResult? {
        guard let templates = EXPFixedFontTemplateLibrary.shared else {
            return nil
        }
        if frame.width == canonicalWidth, frame.height == canonicalHeight {
            return recognizeCanonical(panel: frame, templates: templates)
        }
        let pixels = EXPLuminanceImage(image: frame)
        if let anchor = EXPPanelLocator.locateNearbyAnchor(
            in: frame,
            template: templates.anchorImage
        ), let reading = recognizeScaled(
            anchor: anchor,
            pixels: pixels,
            templates: templates
        ) {
            return reading
        }
        guard let fallbackAnchor = EXPPanelLocator.locateFallbackAnchor(
            in: frame,
            template: templates.anchorImage
        ) else {
            return nil
        }
        return recognizeScaled(
            anchor: fallbackAnchor,
            pixels: pixels,
            templates: templates
        )
    }

    private static func recognizeCanonical(
        panel: ImageBuffer,
        templates: EXPFixedFontTemplateLibrary
    ) -> EXPRecognitionResult? {
        let pixels = EXPBinaryMask(image: panel)
        guard let anchor = bestMatch(
            template: templates.anchor,
            in: pixels,
            xRange: 0...20,
            yRange: 0...8
        ), anchor.score >= 0.72 else {
            return nil
        }

        let digitStartX = anchor.x + 33
        let textY = anchor.y
        guard let currentLength = bestSlot(
            template: templates.leftParenthesis,
            counts: 1...10,
            x: { digitStartX + $0 * 7 },
            y: textY,
            in: pixels
        ), currentLength.score >= 0.65 else {
            return nil
        }

        guard let current = readDigits(
            count: currentLength.count,
            startX: digitStartX,
            y: textY,
            pixels: pixels,
            templates: templates
        ) else {
            return nil
        }

        let leftParenthesisX = digitStartX + currentLength.count * 7
        let percentStartX = leftParenthesisX + 4
        guard let integerLength = bestSlot(
            template: templates.dot,
            counts: 1...3,
            x: { percentStartX + $0 * 7 },
            y: textY,
            in: pixels
        ), integerLength.score >= 0.65,
              let percentageInteger = readDigits(
                count: integerLength.count,
                startX: percentStartX,
                y: textY,
                pixels: pixels,
                templates: templates
              ) else {
            return nil
        }

        let dotX = percentStartX + integerLength.count * 7
        let fractionStartX = dotX + 3
        guard let fractionLength = bestSlot(
            template: templates.percent,
            counts: 2...2,
            x: { fractionStartX + $0 * 7 },
            y: textY,
            in: pixels
        ), fractionLength.score >= 0.65,
              let percentageFraction = readDigits(
                count: fractionLength.count,
                startX: fractionStartX,
                y: textY,
                pixels: pixels,
                templates: templates
              ) else {
            return nil
        }

        let percentX = fractionStartX + fractionLength.count * 7
        let rightParenthesisScore = templates.rightParenthesis.score(
            in: pixels,
            x: percentX + 16,
            y: textY
        )
        guard rightParenthesisScore >= 0.60,
              let currentEXP = Int(current.text),
              let percent = Double("\(percentageInteger.text).\(percentageFraction.text)"),
              (0...100).contains(percent) else {
            return nil
        }

        let scores = [
            anchor.score,
            currentLength.score,
            current.minimumScore,
            integerLength.score,
            percentageInteger.minimumScore,
            fractionLength.score,
            percentageFraction.minimumScore,
            rightParenthesisScore,
        ]
        let confidence = scores.reduce(0, +) / Double(scores.count)
        guard scores.min() ?? 0 >= 0.55 else { return nil }
        return EXPRecognitionResult(
            currentEXP: currentEXP,
            percent: percent,
            confidence: confidence
        )
    }

    private static func recognizeScaled(
        anchor: EXPAnchorMatch,
        pixels: EXPLuminanceImage,
        templates: EXPFixedFontTemplateLibrary
    ) -> EXPRecognitionResult? {
        let anchorScaledTemplates = EXPScaledTemplateLibrary(
            source: templates,
            scale: anchor.scale
        )
        if let originalLayoutReading = recognizeScaledLayout(
            anchor: anchor,
            layoutScale: anchor.scale,
            horizontalOffset: 0,
            pixels: pixels,
            templates: anchorScaledTemplates
        ) {
            return originalLayoutReading
        }

        var best: (
            reading: EXPRecognitionResult,
            selectionScore: Double
        )?
        for layoutScale in EXPLayoutScaleSearch.candidates(anchorScale: anchor.scale) {
            let scaled = EXPScaledTemplateLibrary(
                source: templates,
                scale: layoutScale
            )
            for horizontalOffset in EXPLayoutScaleSearch.horizontalOffsets(
                layoutScale: layoutScale
            ) {
                guard let reading = recognizeScaledLayout(
                    anchor: anchor,
                    layoutScale: layoutScale,
                    horizontalOffset: horizontalOffset,
                    pixels: pixels,
                    templates: scaled
                ) else {
                    continue
                }
                let selectionScore = reading.confidence
                    - abs(layoutScale - anchor.scale) * 0.30
                    - Double(abs(horizontalOffset)) * 0.012
                if best == nil || selectionScore > best!.selectionScore {
                    best = (
                        reading,
                        selectionScore
                    )
                }
            }
        }
        return best?.reading
    }

    private static func recognizeScaledLayout(
        anchor: EXPAnchorMatch,
        layoutScale: Double,
        horizontalOffset: Int,
        pixels: EXPLuminanceImage,
        templates scaled: EXPScaledTemplateLibrary
    ) -> EXPRecognitionResult? {
        let textY = anchor.y
        let digitStartX = anchor.x
            + Int((33 * layoutScale).rounded())
            + horizontalOffset

        guard let currentLength = bestScaledSlot(
            template: scaled.leftParenthesis,
            counts: 1...10,
            x: { digitStartX + Int((Double($0 * 7) * layoutScale).rounded()) },
            y: textY,
            in: pixels
        ), currentLength.score >= 0.48 else {
            return nil
        }

        let leftParenthesisX = digitStartX
            + Int((Double(currentLength.count * 7) * layoutScale).rounded())
        let percentStartX = leftParenthesisX + Int((4 * layoutScale).rounded())
        guard let integerLength = bestScaledSlot(
            template: scaled.dot,
            counts: 1...3,
            x: { percentStartX + Int((Double($0 * 7) * layoutScale).rounded()) },
            y: textY,
            in: pixels
        ), integerLength.score >= 0.45 else {
            return nil
        }

        let dotX = percentStartX
            + Int((Double(integerLength.count * 7) * layoutScale).rounded())
        let fractionStartX = dotX + Int((3 * layoutScale).rounded())
        guard let fractionLength = bestScaledSlot(
            template: scaled.percent,
            counts: 2...2,
            x: { fractionStartX + Int((Double($0 * 7) * layoutScale).rounded()) },
            y: textY,
            in: pixels
        ), fractionLength.score >= 0.45 else {
            return nil
        }

        let percentX = fractionStartX
            + Int((Double(fractionLength.count * 7) * layoutScale).rounded())
        let rightParenthesisScore = pixels.bestScore(
            template: scaled.rightParenthesis,
            x: percentX + Int((16 * layoutScale).rounded()),
            y: textY
        )
        guard rightParenthesisScore >= 0.42,
              let current = readScaledDigits(
                count: currentLength.count,
                startX: digitStartX,
                y: textY,
                scale: layoutScale,
                pixels: pixels,
                templates: scaled
              ),
              let percentageInteger = readScaledDigits(
                count: integerLength.count,
                startX: percentStartX,
                y: textY,
                scale: layoutScale,
                pixels: pixels,
                templates: scaled
              ),
              let percentageFraction = readScaledDigits(
                count: fractionLength.count,
                startX: fractionStartX,
                y: textY,
                scale: layoutScale,
                pixels: pixels,
                templates: scaled
              ),
              let currentEXP = Int(current.text),
              let percent = Double("\(percentageInteger.text).\(percentageFraction.text)"),
              (0...100).contains(percent) else {
            return nil
        }

        let scores = [
            anchor.confidence,
            currentLength.score,
            current.minimumScore,
            integerLength.score,
            percentageInteger.minimumScore,
            fractionLength.score,
            percentageFraction.minimumScore,
            rightParenthesisScore,
        ]
        guard scores.min() ?? 0 >= 0.40 else { return nil }
        return EXPRecognitionResult(
            currentEXP: currentEXP,
            percent: percent,
            confidence: scores.reduce(0, +) / Double(scores.count)
        )
    }

    private static func readScaledDigits(
        count: Int,
        startX: Int,
        y: Int,
        scale: Double,
        pixels: EXPLuminanceImage,
        templates: EXPScaledTemplateLibrary
    ) -> (text: String, minimumScore: Double)? {
        guard count > 0 else { return nil }
        var text = ""
        var minimumScore = 1.0
        for index in 0..<count {
            let x = startX + Int((Double(index * 7) * scale).rounded())
            let candidates = templates.digits.enumerated().map({ digit, template in
                (
                    digit: digit,
                    score: pixels.bestScore(template: template, x: x, y: y)
                )
            })
            guard var best = candidates.max(by: { $0.score < $1.score }) else {
                return nil
            }
            if best.digit == 1 {
                let seven = candidates[7]
                if seven.score >= best.score - 0.03 {
                    best = seven
                }
            }
            guard best.score >= 0.42 else {
                return nil
            }
            text.append(String(best.digit))
            minimumScore = min(minimumScore, best.score)
        }
        return (text, minimumScore)
    }

    private static func bestScaledSlot(
        template: EXPLuminanceTemplate,
        counts: ClosedRange<Int>,
        x: (Int) -> Int,
        y: Int,
        in pixels: EXPLuminanceImage
    ) -> (count: Int, score: Double)? {
        counts.map { count in
            (
                count: count,
                score: pixels.bestScore(template: template, x: x(count), y: y)
            )
        }.max { $0.score < $1.score }
    }

    private static func readDigits(
        count: Int,
        startX: Int,
        y: Int,
        pixels: EXPBinaryMask,
        templates: EXPFixedFontTemplateLibrary
    ) -> (text: String, minimumScore: Double)? {
        guard count > 0 else { return nil }
        var text = ""
        var minimumScore = 1.0
        for index in 0..<count {
            let x = startX + index * 7
            guard let best = templates.digits.enumerated().map({ digit, template in
                (digit: digit, score: template.score(in: pixels, x: x, y: y))
            }).max(by: { $0.score < $1.score }), best.score >= 0.55 else {
                return nil
            }
            text.append(String(best.digit))
            minimumScore = min(minimumScore, best.score)
        }
        return (text, minimumScore)
    }

    private static func bestSlot(
        template: EXPBinaryMask,
        counts: ClosedRange<Int>,
        x: (Int) -> Int,
        y: Int,
        in pixels: EXPBinaryMask
    ) -> (count: Int, score: Double)? {
        counts.map { count in
            (count: count, score: template.score(in: pixels, x: x(count), y: y))
        }.max { $0.score < $1.score }
    }

    private static func bestMatch(
        template: EXPBinaryMask,
        in pixels: EXPBinaryMask,
        xRange: ClosedRange<Int>,
        yRange: ClosedRange<Int>
    ) -> (x: Int, y: Int, score: Double)? {
        var result: (x: Int, y: Int, score: Double)?
        for y in yRange {
            for x in xRange {
                let score = template.score(in: pixels, x: x, y: y)
                if result == nil || score > result!.score {
                    result = (x, y, score)
                }
            }
        }
        return result
    }
}

private struct EXPFixedFontTemplateLibrary {
    let anchorImage: ImageBuffer
    let digitImages: [ImageBuffer]
    let leftParenthesisImage: ImageBuffer
    let dotImage: ImageBuffer
    let percentImage: ImageBuffer
    let rightParenthesisImage: ImageBuffer
    let anchor: EXPBinaryMask
    let digits: [EXPBinaryMask]
    let leftParenthesis: EXPBinaryMask
    let dot: EXPBinaryMask
    let percent: EXPBinaryMask
    let rightParenthesis: EXPBinaryMask

    static let shared: EXPFixedFontTemplateLibrary? = {
        guard let anchor = TemplatePaths.load(TemplatePaths.expAnchor),
              let leftParenthesis = TemplatePaths.load(TemplatePaths.expLeftParenthesis),
              let dot = TemplatePaths.load(TemplatePaths.expDot),
              let percent = TemplatePaths.load(TemplatePaths.expPercent),
              let rightParenthesis = TemplatePaths.load(TemplatePaths.expRightParenthesis) else {
            return nil
        }
        let digitImages = (0...9).compactMap {
            TemplatePaths.load(TemplatePaths.expDigit($0))
        }
        guard digitImages.count == 10 else { return nil }
        return EXPFixedFontTemplateLibrary(
            anchorImage: anchor,
            digitImages: digitImages,
            leftParenthesisImage: leftParenthesis,
            dotImage: dot,
            percentImage: percent,
            rightParenthesisImage: rightParenthesis,
            anchor: EXPBinaryMask(template: anchor),
            digits: digitImages.map(EXPBinaryMask.init(template:)),
            leftParenthesis: EXPBinaryMask(template: leftParenthesis),
            dot: EXPBinaryMask(template: dot),
            percent: EXPBinaryMask(template: percent),
            rightParenthesis: EXPBinaryMask(template: rightParenthesis)
        )
    }()
}

private struct EXPBinaryMask {
    let width: Int
    let height: Int
    let values: [Bool]

    init(image: ImageBuffer) {
        width = image.width
        height = image.height
        values = (0..<(image.width * image.height)).map { pixelIndex in
            let index = pixelIndex * 3
            let b = image.bgr[index]
            let g = image.bgr[index + 1]
            let r = image.bgr[index + 2]
            return min(b, g, r) >= 150
                && Int(max(b, g, r)) - Int(min(b, g, r)) <= 65
        }
    }

    init(template: ImageBuffer) {
        width = template.width
        height = template.height
        values = (0..<(template.width * template.height)).map { pixelIndex in
            let index = pixelIndex * 3
            return max(
                template.bgr[index],
                template.bgr[index + 1],
                template.bgr[index + 2]
            ) >= 128
        }
    }

    func score(in source: EXPBinaryMask, x: Int, y: Int) -> Double {
        guard x >= 0, y >= 0, x + width <= source.width, y + height <= source.height else {
            return 0
        }
        var intersection = 0
        var totalForeground = 0
        for row in 0..<height {
            for column in 0..<width {
                let expected = values[row * width + column]
                let actual = source.values[(y + row) * source.width + x + column]
                if expected { totalForeground += 1 }
                if actual { totalForeground += 1 }
                if expected && actual { intersection += 1 }
            }
        }
        guard totalForeground > 0 else { return 0 }
        return Double(intersection * 2) / Double(totalForeground)
    }
}

private struct EXPAnchorMatch {
    let x: Int
    let y: Int
    let scale: Double
    let confidence: Double
}

private struct EXPScaledTemplateLibrary {
    let digits: [EXPLuminanceTemplate]
    let leftParenthesis: EXPLuminanceTemplate
    let dot: EXPLuminanceTemplate
    let percent: EXPLuminanceTemplate
    let rightParenthesis: EXPLuminanceTemplate

    init(source: EXPFixedFontTemplateLibrary, scale: Double) {
        digits = source.digitImages.map {
            EXPLuminanceTemplate(image: $0, scale: scale)
        }
        leftParenthesis = EXPLuminanceTemplate(
            image: source.leftParenthesisImage,
            scale: scale
        )
        dot = EXPLuminanceTemplate(image: source.dotImage, scale: scale)
        percent = EXPLuminanceTemplate(image: source.percentImage, scale: scale)
        rightParenthesis = EXPLuminanceTemplate(
            image: source.rightParenthesisImage,
            scale: scale
        )
    }
}

private struct EXPLuminanceTemplate {
    let width: Int
    let height: Int
    let centeredValues: [Double]
    let energy: Double

    init(image: ImageBuffer, scale: Double) {
        width = max(1, Int(Double(image.width) * scale))
        height = max(1, Int(Double(image.height) * scale))
        let source = EXPLuminanceImage(image: image)
        var values = [Double](repeating: 0, count: width * height)

        for y in 0..<height {
            let sourceY = (Double(y) + 0.5) / scale - 0.5
            let y0 = max(0, min(image.height - 1, Int(floor(sourceY))))
            let y1 = min(image.height - 1, y0 + 1)
            let yWeight = max(0, min(1, sourceY - Double(y0)))
            for x in 0..<width {
                let sourceX = (Double(x) + 0.5) / scale - 0.5
                let x0 = max(0, min(image.width - 1, Int(floor(sourceX))))
                let x1 = min(image.width - 1, x0 + 1)
                let xWeight = max(0, min(1, sourceX - Double(x0)))
                let top = source.values[y0 * image.width + x0] * (1 - xWeight)
                    + source.values[y0 * image.width + x1] * xWeight
                let bottom = source.values[y1 * image.width + x0] * (1 - xWeight)
                    + source.values[y1 * image.width + x1] * xWeight
                values[y * width + x] = top * (1 - yWeight) + bottom * yWeight
            }
        }

        let mean = values.reduce(0, +) / Double(values.count)
        centeredValues = values.map { $0 - mean }
        energy = centeredValues.reduce(0) { $0 + $1 * $1 }
    }
}

private struct EXPLuminanceImage {
    let width: Int
    let height: Int
    let values: [Double]

    init(image: ImageBuffer) {
        width = image.width
        height = image.height
        values = (0..<(image.width * image.height)).map { pixelIndex in
            let index = pixelIndex * 3
            return 0.114 * Double(image.bgr[index])
                + 0.587 * Double(image.bgr[index + 1])
                + 0.299 * Double(image.bgr[index + 2])
        }
    }

    func bestScore(
        template: EXPLuminanceTemplate,
        x: Int,
        y: Int
    ) -> Double {
        let radius = max(
            1,
            min(4, Int((Double(template.height) / 7.5).rounded()))
        )
        var best = -1.0
        for yOffset in -radius...radius {
            for xOffset in -radius...radius {
                best = max(
                    best,
                    score(
                        template: template,
                        x: x + xOffset,
                        y: y + yOffset
                    )
                )
            }
        }
        return best
    }

    private func score(
        template: EXPLuminanceTemplate,
        x: Int,
        y: Int
    ) -> Double {
        guard x >= 0, y >= 0,
              x + template.width <= width,
              y + template.height <= height,
              template.energy > 0 else {
            return -1
        }

        var sum = 0.0
        var sumSquared = 0.0
        var numerator = 0.0
        for row in 0..<template.height {
            for column in 0..<template.width {
                let actual = values[(y + row) * width + x + column]
                let templateIndex = row * template.width + column
                sum += actual
                sumSquared += actual * actual
                numerator += actual * template.centeredValues[templateIndex]
            }
        }
        let count = Double(template.width * template.height)
        let patchEnergy = max(0, sumSquared - sum * sum / count)
        let denominator = sqrt(template.energy * patchEnergy)
        return denominator > 0 ? numerator / denominator : -1
    }
}

private enum EXPPanelLocator {
    static func locateNearbyAnchor(
        in frame: ImageBuffer,
        template: ImageBuffer
    ) -> EXPAnchorMatch? {
        locateAnchor(
            in: frame,
            template: template,
            scales: nearbyScales(frameWidth: frame.width)
        )
    }

    static func locateFallbackAnchor(
        in frame: ImageBuffer,
        template: ImageBuffer
    ) -> EXPAnchorMatch? {
        locateAnchor(
            in: frame,
            template: template,
            scales: fallbackScales
        )
    }

    private static func locateAnchor(
        in frame: ImageBuffer,
        template: ImageBuffer,
        scales: [Double]
    ) -> EXPAnchorMatch? {
        let searchRect = CGRect(
            x: Double(frame.width) * 0.20,
            y: Double(frame.height) * 0.70,
            width: Double(frame.width) * 0.60,
            height: Double(frame.height) * 0.30
        ).integral
        guard let search = frame.cropped(
            x: Int(searchRect.minX),
            y: Int(searchRect.minY),
            width: min(Int(searchRect.width), frame.width - Int(searchRect.minX)),
            height: min(Int(searchRect.height), frame.height - Int(searchRect.minY))
        ) else {
            return nil
        }

        guard let match = TemplateMatcher.match(
            image: search,
            template: template,
            threshold: 0.55,
            scales: scales
        ) else {
            return nil
        }
        return EXPAnchorMatch(
            x: Int(searchRect.minX) + match.x,
            y: Int(searchRect.minY) + match.y,
            scale: match.scaleX,
            confidence: match.confidence
        )
    }

    private static let fallbackScales: [Double] = [
        0.50, 0.75, 1.00, 1.25, 1.50, 1.75, 2.00,
    ]

    private static func nearbyScales(frameWidth: Int) -> [Double] {
        let expected = max(0.5, min(2.0, Double(frameWidth) / 1_200))
        let roundedExpected = (expected / 0.05).rounded() * 0.05
        return [-0.10, -0.05, 0, 0.05, 0.10].map {
            max(0.5, min(2.0, roundedExpected + $0))
        }
    }
}
