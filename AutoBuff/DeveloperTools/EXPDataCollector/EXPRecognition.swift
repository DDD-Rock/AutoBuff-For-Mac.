import CoreGraphics
import Foundation
import Vision

struct EXPParsedText: Equatable {
    let currentEXP: Int
    let percent: Double
    let matchRange: Range<String.Index>

    var displayText: String {
        "\(currentEXP) (\(EXPTextParser.format(percent: percent))%)"
    }
}

enum EXPTextParser {
    private static let expression = try! NSRegularExpression(
        pattern: #"(?:E|D|Đ|F)XP[\s\.:_-]*([0-9]+)\s*[\(\[\{]\s*([0-9]+(?:[\.,，][0-9]+)?)\s*%\s*[\)\]\}]?"#,
        options: [.caseInsensitive]
    )

    static func parse(_ text: String) -> EXPParsedText? {
        let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = expression.firstMatch(in: text, range: fullRange),
              let expRange = Range(match.range(at: 1), in: text),
              let percentRange = Range(match.range(at: 2), in: text),
              let matchRange = Range(match.range(at: 0), in: text),
              let currentEXP = Int(text[expRange]),
              let percent = Double(
                text[percentRange]
                    .replacingOccurrences(of: "，", with: ".")
                    .replacingOccurrences(of: ",", with: ".")
              ),
              (0...100).contains(percent) else {
            return nil
        }
        return EXPParsedText(
            currentEXP: currentEXP,
            percent: percent,
            matchRange: matchRange
        )
    }

    static func format(percent: Double) -> String {
        let formatted = String(
            format: "%.4f",
            locale: Locale(identifier: "en_US_POSIX"),
            percent
        )
        return formatted
            .replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\.$"#, with: "", options: .regularExpression)
    }
}

struct EXPGlyphBox: Equatable, Sendable {
    let label: String
    let normalizedBox: CGRect
}

struct EXPTextReading: Equatable, Sendable {
    let currentEXP: Int
    let percent: Double
    let rawText: String
    let confidence: Float
    let normalizedLineBox: CGRect
    let glyphBoxes: [EXPGlyphBox]
    var preprocessingAgreement = false

    var key: String {
        "\(currentEXP)|\(EXPTextParser.format(percent: percent))"
    }

    var displayText: String {
        "\(currentEXP) (\(EXPTextParser.format(percent: percent))%)"
    }
}

struct EXPRecognitionAttempt: Sendable {
    var reading: EXPTextReading?
    var suspectedText: String?
    var suspectedConfidence: Float = 0
}

struct EXPReadingStabilizer {
    let requiredMatches: Int
    private(set) var lastKey: String?
    private(set) var consecutiveMatches = 0

    init(requiredMatches: Int = 3) {
        self.requiredMatches = max(1, requiredMatches)
    }

    mutating func update(_ reading: EXPTextReading?) -> Bool {
        guard let reading else {
            reset()
            return false
        }
        if reading.key == lastKey {
            consecutiveMatches += 1
        } else {
            lastKey = reading.key
            consecutiveMatches = 1
        }
        return consecutiveMatches >= requiredMatches
    }

    mutating func reset() {
        lastKey = nil
        consecutiveMatches = 0
    }
}

enum EXPFrameRegionExtractor {
    static func searchRect(frameWidth: Int, frameHeight: Int) -> CGRect {
        guard frameWidth > 0, frameHeight > 0 else { return .zero }
        let x = Int((Double(frameWidth) * 0.20).rounded(.down))
        let y = Int((Double(frameHeight) * 0.72).rounded(.down))
        let width = max(1, Int((Double(frameWidth) * 0.60).rounded(.down)))
        let height = max(1, frameHeight - y)
        return CGRect(
            x: max(0, min(x, frameWidth - 1)),
            y: max(0, min(y, frameHeight - 1)),
            width: min(width, frameWidth - x),
            height: min(height, frameHeight - y)
        ).integral
    }

    static func extract(from frame: ImageBuffer) -> ImageBuffer? {
        let rect = searchRect(frameWidth: frame.width, frameHeight: frame.height)
        guard let broadRegion = frame.cropped(
            x: Int(rect.minX),
            y: Int(rect.minY),
            width: Int(rect.width),
            height: Int(rect.height)
        ) else {
            return nil
        }
        return localizedPanelAroundBar(in: broadRegion) ?? broadRegion
    }

    static func localizedPanelAroundBar(in image: ImageBuffer) -> ImageBuffer? {
        struct BrightRun {
            let x: Int
            let y: Int
            let width: Int
        }

        let minimumWidth = max(60, image.width / 20)
        let maximumWidth = min(420, max(minimumWidth, image.width * 9 / 10))
        var runs: [BrightRun] = []

        for y in 0..<image.height {
            var start: Int?
            for x in 0...image.width {
                let isBright = x < image.width && isBrightNeutralPixel(
                    image,
                    x: x,
                    y: y
                )
                if isBright, start == nil {
                    start = x
                } else if !isBright, let runStart = start {
                    let width = x - runStart
                    if (minimumWidth...maximumWidth).contains(width) {
                        runs.append(BrightRun(x: runStart, y: y, width: width))
                    }
                    start = nil
                }
            }
        }

        var bestPair: (top: BrightRun, score: Double)?
        for topIndex in runs.indices {
            let top = runs[topIndex]
            let scale = max(0.5, min(2.5, Double(top.width) / 152))
            for bottom in runs.dropFirst(topIndex + 1) {
                let verticalGap = bottom.y - top.y
                if verticalGap > Int((25 * scale).rounded(.up)) {
                    break
                }
                guard verticalGap >= Int((10 * scale).rounded(.down)),
                      abs(bottom.x - top.x) <= Int((5 * scale).rounded(.up)),
                      abs(bottom.width - top.width) <= Int((10 * scale).rounded(.up)) else {
                    continue
                }
                let expectedGap = 17 * scale
                let score = Double(top.width)
                    - abs(Double(verticalGap) - expectedGap) * 3
                    + Double(top.y) * 0.05
                if bestPair == nil || score > bestPair!.score {
                    bestPair = (top, score)
                }
            }
        }

        guard let bar = bestPair?.top else { return nil }
        let scale = max(0.5, min(2.5, Double(bar.width) / 152))
        let x = max(0, bar.x - Int((7 * scale).rounded(.up)))
        let y = max(0, bar.y - Int((20 * scale).rounded(.up)))
        let maxX = min(
            image.width,
            bar.x + bar.width + Int((20 * scale).rounded(.up))
        )
        let maxY = min(
            image.height,
            bar.y + Int((22 * scale).rounded(.up))
        )
        return image.cropped(
            x: x,
            y: y,
            width: maxX - x,
            height: maxY - y
        )
    }

    private static func isBrightNeutralPixel(
        _ image: ImageBuffer,
        x: Int,
        y: Int
    ) -> Bool {
        guard let pixel = image.pixelBGR(x: x, y: y) else { return false }
        let minimum = min(pixel.b, pixel.g, pixel.r)
        let maximum = max(pixel.b, pixel.g, pixel.r)
        return minimum >= 165 && Int(maximum) - Int(minimum) <= 55
    }
}

enum EXPVisionRecognizer {
    private enum Variant {
        case original
        case highContrast
    }

    static func recognize(in image: ImageBuffer) -> EXPRecognitionAttempt {
        let attempts = [
            recognize(in: image, variant: .original),
            recognize(in: image, variant: .highContrast),
        ]
        var validReadings = attempts.compactMap(\.reading)
        if !validReadings.isEmpty {
            validReadings.sort { $0.confidence > $1.confidence }
            var best = validReadings[0]
            best.preprocessingAgreement = validReadings.contains {
                $0.key == best.key && $0.rawText != best.rawText
            } || (
                validReadings.count >= 2
                    && validReadings[0].key == validReadings[1].key
            )
            return EXPRecognitionAttempt(
                reading: best,
                suspectedText: best.rawText,
                suspectedConfidence: best.confidence
            )
        }
        return attempts.max { lhs, rhs in
            lhs.suspectedConfidence < rhs.suspectedConfidence
        } ?? EXPRecognitionAttempt()
    }

    private static func recognize(
        in image: ImageBuffer,
        variant: Variant
    ) -> EXPRecognitionAttempt {
        let prepared: ImageBuffer
        switch variant {
        case .original:
            prepared = image
        case .highContrast:
            prepared = highContrast(image)
        }
        let scale: Int
        if max(prepared.width, prepared.height) <= 420 {
            scale = 8
        } else if max(prepared.width, prepared.height) <= 900 {
            scale = 4
        } else {
            scale = 2
        }
        guard let cgImage = EXPImageCodec.cgImage(from: prepared),
              let enlarged = EXPImageCodec.scaledImage(cgImage, scale: scale) else {
            return EXPRecognitionAttempt()
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.customWords = ["EXP"]
        request.minimumTextHeight = 0.015

        do {
            try VNImageRequestHandler(
                cgImage: enlarged,
                orientation: .up,
                options: [:]
            ).perform([request])
        } catch {
            return EXPRecognitionAttempt()
        }

        var attempt = EXPRecognitionAttempt()
        for observation in request.results ?? [] {
            for candidate in observation.topCandidates(3) {
                let rawText = candidate.string
                if looksLikeEXPAnchor(rawText),
                   candidate.confidence > attempt.suspectedConfidence {
                    attempt.suspectedText = rawText
                    attempt.suspectedConfidence = candidate.confidence
                }
                guard let parsed = EXPTextParser.parse(rawText) else { continue }
                let glyphBoxes = glyphBoxes(
                    candidate: candidate,
                    parsed: parsed,
                    source: rawText
                )
                let reading = EXPTextReading(
                    currentEXP: parsed.currentEXP,
                    percent: parsed.percent,
                    rawText: rawText,
                    confidence: candidate.confidence,
                    normalizedLineBox: observation.boundingBox,
                    glyphBoxes: glyphBoxes
                )
                if attempt.reading == nil
                    || candidate.confidence > attempt.reading!.confidence {
                    attempt.reading = reading
                }
            }
        }
        return attempt
    }

    private static func glyphBoxes(
        candidate: VNRecognizedText,
        parsed: EXPParsedText,
        source: String
    ) -> [EXPGlyphBox] {
        var boxes: [EXPGlyphBox] = []
        var index = parsed.matchRange.lowerBound
        while index < parsed.matchRange.upperBound {
            let next = source.index(after: index)
            let value = String(source[index..<next])
            if let label = datasetLabel(for: value),
               let observation = try? candidate.boundingBox(for: index..<next) {
                boxes.append(
                    EXPGlyphBox(
                        label: label,
                        normalizedBox: observation.boundingBox
                    )
                )
            }
            index = next
        }
        return boxes
    }

    private static func datasetLabel(for value: String) -> String? {
        if value.count == 1, value.first?.isNumber == true {
            return value
        }
        switch value {
        case ".": return "dot"
        case "%": return "percent"
        case "(": return "left_paren"
        case ")": return "right_paren"
        default: return nil
        }
    }

    private static func looksLikeEXPAnchor(_ text: String) -> Bool {
        let uppercase = text.uppercased()
        return ["EXP", "DXP", "ĐXP", "FXP"].contains {
            uppercase.contains($0)
        }
    }

    private static func highContrast(_ image: ImageBuffer) -> ImageBuffer {
        var pixels = image.bgr
        for index in stride(from: 0, to: pixels.count, by: 3) {
            let blue = Int(pixels[index])
            let green = Int(pixels[index + 1])
            let red = Int(pixels[index + 2])
            let luminance = (blue * 29 + green * 150 + red * 77) >> 8
            let value: UInt8 = luminance >= 165 ? 0 : 255
            pixels[index] = value
            pixels[index + 1] = value
            pixels[index + 2] = value
        }
        return ImageBuffer(width: image.width, height: image.height, bgr: pixels)
    }
}
