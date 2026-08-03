import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import AutoBuff

struct EXPFixedFontRecognizerTests {
    @Test func recognizesDigitFiveAndPercentageFromFixedTemplates() throws {
        let panel = try makePanel(currentEXP: "6528", percentage: "0.01")

        let reading = try #require(EXPFixedFontRecognizer.recognize(in: panel))

        #expect(reading.currentEXP == 6_528)
        #expect(reading.percent == 0.01)
        #expect(reading.confidence > 0.90)
    }

    @Test func locatesPanelInsideLowerCenterOfGameFrame() throws {
        let panel = try makePanel(currentEXP: "6528", percentage: "0.01")
        var frame = ImageBuffer(
            width: 900,
            height: 500,
            bgr: [UInt8](repeating: 18, count: 900 * 500 * 3)
        )
        paste(panel, into: &frame, x: 358, y: 440)

        let reading = try #require(EXPFixedFontRecognizer.recognize(in: frame))

        #expect(reading.currentEXP == 6_528)
        #expect(reading.percent == 0.01)
    }

    @Test func recognizesFilledBarAtMultipleWindowResolutions() throws {
        let reading = try recognizeScaledPanel(
            frameWidth: 960,
            frameHeight: 628,
            scale: 0.80,
            percentage: "12.09"
        )

        #expect(reading.currentEXP == 7_192_723)
        #expect(reading.percent == 12.09)
    }

    @Test func recognizesMostlyFilledBarAtHighResolution() throws {
        let reading = try recognizeScaledPanel(
            frameWidth: 1_600,
            frameHeight: 900,
            scale: 1.25,
            percentage: "90.01"
        )

        #expect(reading.currentEXP == 7_192_723)
        #expect(reading.percent == 90.01)
    }

    @Test func recognizesNativeLayoutInsideWideGameCapture() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent(
                "Fixtures/EXP/exp_1355x882_78660262_11_99.png"
            )
        let crop = try #require(loadImage(fixtureURL))
        var frame = ImageBuffer(
            width: 1_355,
            height: 882,
            bgr: [UInt8](repeating: 18, count: 1_355 * 882 * 3)
        )
        pasteAllPixels(crop, into: &frame, x: 710, y: 820)

        let reading = try #require(EXPFixedFontRecognizer.recognize(in: frame))

        #expect(reading.currentEXP == 78_660_262)
        #expect(reading.percent == 11.99)
    }

    @Test func productionPPOCRRecognizesNativeLayoutScreenshot() throws {
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent(
                "Fixtures/EXP/exp_1355x882_78660262_11_99.png"
            )
        let crop = try #require(loadImage(fixtureURL))
        var frame = ImageBuffer(
            width: 1_355,
            height: 882,
            bgr: [UInt8](repeating: 18, count: 1_355 * 882 * 3)
        )
        pasteAllPixels(crop, into: &frame, x: 710, y: 820)

        #expect(EXPPaddleOCRRecognizer.isAvailable)
        let reading = try #require(EXPHybridRecognizer.recognize(in: frame))

        #expect(reading.currentEXP == 78_660_262)
        #expect(reading.percent == 11.99)
        #expect(reading.confidence >= 0.55)
        #expect(reading.recognitionMethod == .ppOCRv4)
    }

    @Test func productionPPOCRAllowsZeroEXP() throws {
        let panel = try makePanel(currentEXP: "0", percentage: "0.0")
        var frame = ImageBuffer(
            width: 900,
            height: 500,
            bgr: [UInt8](repeating: 18, count: 900 * 500 * 3)
        )
        paste(panel, into: &frame, x: 358, y: 440)

        let reading = try #require(EXPHybridRecognizer.recognize(in: frame))

        #expect(reading.currentEXP == 0)
        #expect(reading.percent == 0)
        #expect(reading.recognitionMethod == .ppOCRv4)
    }

    @Test func includesNativeLayoutWhenAnchorSuggestsLargerScale() {
        let candidates = EXPLayoutScaleSearch.candidates(anchorScale: 1.15)

        #expect(candidates.contains(1.0))
        #expect(candidates.contains(1.15))
        #expect(EXPLayoutScaleSearch.horizontalOffsets(layoutScale: 1.0).contains(4))
    }

    @Test func stabilizesTwoFramesAndToleratesShortOcclusion() throws {
        let reading = EXPRecognitionResult(
            currentEXP: 6_528,
            percent: 0.01,
            confidence: 0.98
        )
        var stabilizer = EXPRecognitionStabilizer(
            requiredMatches: 2,
            toleratedMisses: 2
        )

        #expect(stabilizer.update(reading) == nil)
        #expect(stabilizer.update(reading) == reading)
        #expect(stabilizer.update(nil) == reading)
        #expect(stabilizer.update(nil) == reading)
        #expect(stabilizer.update(nil) == nil)
    }

    @Test func productionStabilizerRequiresThreeMatchingOCRFrames() {
        let reading = EXPRecognitionResult(
            currentEXP: 6_528,
            percent: 0.01,
            confidence: 0.98,
            recognitionMethod: .ppOCRv4
        )
        var stabilizer = EXPRecognitionStabilizer()

        #expect(stabilizer.update(reading) == nil)
        #expect(stabilizer.update(reading) == nil)
        #expect(stabilizer.update(reading) == reading)
    }

    @Test func stabilizerTracksRecognitionMethodChanges() {
        let template = EXPRecognitionResult(
            currentEXP: 6_528,
            percent: 0.01,
            confidence: 0.92
        )
        let ocr = EXPRecognitionResult(
            currentEXP: 6_528,
            percent: 0.01,
            confidence: 0.92,
            recognitionMethod: .ppOCRv4
        )
        var stabilizer = EXPRecognitionStabilizer(requiredMatches: 2, toleratedMisses: 1)

        #expect(stabilizer.update(template) == nil)
        #expect(stabilizer.update(template)?.recognitionMethod == .fixedTemplate)
        #expect(stabilizer.update(ocr)?.recognitionMethod == .fixedTemplate)
        #expect(stabilizer.update(ocr)?.recognitionMethod == .ppOCRv4)
    }

    @Test func exposesTemplateLocatedPanelForOCR() throws {
        let panel = try makePanel(currentEXP: "6528", percentage: "0.01")
        var frame = ImageBuffer(
            width: 900,
            height: 500,
            bgr: [UInt8](repeating: 18, count: 900 * 500 * 3)
        )
        paste(panel, into: &frame, x: 358, y: 440)

        let located = try #require(EXPFixedFontRecognizer.locatePanel(in: frame))

        #expect(abs(located.width - panel.width) <= 2)
        #expect(abs(located.height - panel.height) <= 2)
    }

    @Test func cachedAnchorIsReusedUntilWindowSizeChanges() throws {
        let panel = try makePanel(currentEXP: "6528", percentage: "0.01")
        let cache = EXPPanelLocationCache()
        var first = ImageBuffer(
            width: 900,
            height: 500,
            bgr: [UInt8](repeating: 18, count: 900 * 500 * 3)
        )
        paste(panel, into: &first, x: 358, y: 440)

        _ = try #require(cache.locatePanelWithConfidence(in: first))
        #expect(cache.fullSearchCount == 1)
        _ = try #require(cache.locatePanelWithConfidence(in: first))
        #expect(cache.fullSearchCount == 1)

        var resized = ImageBuffer(
            width: 1_000,
            height: 600,
            bgr: [UInt8](repeating: 18, count: 1_000 * 600 * 3)
        )
        paste(panel, into: &resized, x: 408, y: 540)
        _ = try #require(cache.locatePanelWithConfidence(in: resized))
        #expect(cache.fullSearchCount == 2)
    }

    @Test func lineEndExpandsCropBeyondCanonicalWidth() throws {
        let rightBracketX = 205
        let panel = try makeLineEndPanel(width: 230, rightBracketX: rightBracketX)
        var frame = ImageBuffer(
            width: 900,
            height: 500,
            bgr: [UInt8](repeating: 18, count: 900 * 500 * 3)
        )
        paste(panel, into: &frame, x: 335, y: 440)

        let located = try #require(
            EXPPanelLocationCache().locatePanelWithConfidence(in: frame)
        )

        #expect(located.image.width > EXPFixedFontRecognizer.canonicalWidth)
        #expect(located.image.width >= rightBracketX + 3 + 8)
    }

    @Test func missingLineEndUsesConservativeMaximumWidth() throws {
        var frame = ImageBuffer(
            width: 900,
            height: 500,
            bgr: [UInt8](repeating: 18, count: 900 * 500 * 3)
        )
        let anchor = try #require(TemplatePaths.load(TemplatePaths.expAnchor))
        paste(anchor, into: &frame, x: 358, y: 443)

        let located = try #require(
            EXPPanelLocationCache().locatePanelWithConfidence(in: frame)
        )

        #expect(located.image.width >= 260)
    }

    @Test func productionRecognizerDoesNotFallBackToFixedTemplates() throws {
        let panel = try makePanel(currentEXP: "6528", percentage: "0.01")
        var frame = ImageBuffer(
            width: 900,
            height: 500,
            bgr: [UInt8](repeating: 18, count: 900 * 500 * 3)
        )
        paste(panel, into: &frame, x: 358, y: 440)
        let recognizer = EXPProductionRecognizer { _ in nil }

        #expect(EXPFixedFontRecognizer.recognize(in: frame) != nil)
        #expect(recognizer.recognize(in: frame) == nil)
    }

    @Test func replaysLocalCollectedSamplesWhenAvailable() throws {
        let root = EXPDatasetStore.defaultDirectoryURL
        let manifest = root.appendingPathComponent("manifest.jsonl")
        guard let contents = try? String(contentsOf: manifest, encoding: .utf8) else {
            return
        }

        var replayed = 0
        for line in contents.split(separator: "\n") {
            guard let data = line.data(using: .utf8),
                  let entry = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let relativePath = entry["context"] as? String,
                  let rawText = (entry["raw_text"] as? String)
                    ?? (entry["suspected_text"] as? String),
                  let expected = EXPTextParser.parse(rawText),
                  let panel = loadImage(root.appendingPathComponent(relativePath)),
                  panel.width == EXPFixedFontRecognizer.canonicalWidth,
                  panel.height == EXPFixedFontRecognizer.canonicalHeight else {
                continue
            }

            let reading = try #require(EXPFixedFontRecognizer.recognize(in: panel))
            #expect(reading.currentEXP == expected.currentEXP)
            #expect(reading.percent == expected.percent)
            replayed += 1
        }
        #expect(replayed > 0)
    }

    @Test func replaysDiagnosticScreenshotWhenProvided() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["EXP_TEST_SCREENSHOT"],
              let expectedEXP = environment["EXP_TEST_CURRENT"].flatMap(Int.init),
              let expectedPercent = environment["EXP_TEST_PERCENT"].flatMap(Double.init),
              let screenshot = loadImage(URL(fileURLWithPath: path)) else {
            return
        }

        let reading = try #require(
            EXPFixedFontRecognizer.recognize(in: screenshot)
        )
        #expect(reading.currentEXP == expectedEXP)
        #expect(reading.percent == expectedPercent)
    }

    private func makePanel(currentEXP: String, percentage: String) throws -> ImageBuffer {
        var panel = ImageBuffer(
            width: EXPFixedFontRecognizer.canonicalWidth,
            height: EXPFixedFontRecognizer.canonicalHeight,
            bgr: [UInt8](repeating: 12, count: 185 * 44 * 3)
        )
        try pasteTemplate(TemplatePaths.expAnchor, into: &panel, x: 8, y: 3)

        for (index, character) in currentEXP.enumerated() {
            let digit = try #require(character.wholeNumberValue)
            try pasteTemplate(
                TemplatePaths.expDigit(digit),
                into: &panel,
                x: 41 + index * 7,
                y: 3
            )
        }
        let leftParenthesisX = 41 + currentEXP.count * 7
        try pasteTemplate(
            TemplatePaths.expLeftParenthesis,
            into: &panel,
            x: leftParenthesisX,
            y: 3
        )

        let parts = percentage.split(separator: ".", omittingEmptySubsequences: false)
        let integer = try #require(parts.first.map(String.init))
        let fraction = try #require(parts.count == 2 ? String(parts[1]) : nil)
        let percentageX = leftParenthesisX + 4
        for (index, character) in integer.enumerated() {
            let digit = try #require(character.wholeNumberValue)
            try pasteTemplate(
                TemplatePaths.expDigit(digit),
                into: &panel,
                x: percentageX + index * 7,
                y: 3
            )
        }
        let dotX = percentageX + integer.count * 7
        try pasteTemplate(TemplatePaths.expDot, into: &panel, x: dotX, y: 3)
        let fractionX = dotX + 3
        for (index, character) in fraction.enumerated() {
            let digit = try #require(character.wholeNumberValue)
            try pasteTemplate(
                TemplatePaths.expDigit(digit),
                into: &panel,
                x: fractionX + index * 7,
                y: 3
            )
        }
        let percentX = fractionX + fraction.count * 7
        try pasteTemplate(TemplatePaths.expPercent, into: &panel, x: percentX, y: 3)
        try pasteTemplate(
            TemplatePaths.expRightParenthesis,
            into: &panel,
            x: percentX + 16,
            y: 3
        )

        for y in 19...31 {
            drawBrightRun(in: &panel, x: 8, y: y, width: 155)
        }
        drawBrightRun(in: &panel, x: 8, y: 38, width: 155)
        return panel
    }

    private func makeLineEndPanel(
        width: Int,
        rightBracketX: Int
    ) throws -> ImageBuffer {
        var panel = ImageBuffer(
            width: width,
            height: EXPFixedFontRecognizer.canonicalHeight,
            bgr: [UInt8](
                repeating: 12,
                count: width * EXPFixedFontRecognizer.canonicalHeight * 3
            )
        )
        try pasteTemplate(TemplatePaths.expAnchor, into: &panel, x: 8, y: 3)
        try pasteTemplate(
            TemplatePaths.expPercent,
            into: &panel,
            x: rightBracketX - 16,
            y: 3
        )
        try pasteTemplate(
            TemplatePaths.expRightParenthesis,
            into: &panel,
            x: rightBracketX,
            y: 3
        )
        for y in 19...31 {
            drawBrightRun(in: &panel, x: 8, y: y, width: 155)
        }
        drawBrightRun(in: &panel, x: 8, y: 38, width: 155)
        return panel
    }

    private func pasteTemplate(
        _ path: String,
        into destination: inout ImageBuffer,
        x: Int,
        y: Int
    ) throws {
        let template = try #require(TemplatePaths.load(path))
        paste(template, into: &destination, x: x, y: y)
    }

    private func paste(
        _ source: ImageBuffer,
        into destination: inout ImageBuffer,
        x: Int,
        y: Int
    ) {
        var pixels = destination.bgr
        for row in 0..<source.height {
            for column in 0..<source.width {
                let sourceIndex = (row * source.width + column) * 3
                guard source.bgr[sourceIndex] >= 128 else { continue }
                let destinationIndex = ((y + row) * destination.width + x + column) * 3
                pixels[destinationIndex] = 255
                pixels[destinationIndex + 1] = 255
                pixels[destinationIndex + 2] = 255
            }
        }
        destination = ImageBuffer(
            width: destination.width,
            height: destination.height,
            bgr: pixels
        )
    }

    private func pasteAllPixels(
        _ source: ImageBuffer,
        into destination: inout ImageBuffer,
        x: Int,
        y: Int
    ) {
        var pixels = destination.bgr
        for row in 0..<source.height {
            let sourceStart = row * source.width * 3
            let destinationStart = ((y + row) * destination.width + x) * 3
            pixels.replaceSubrange(
                destinationStart..<(destinationStart + source.width * 3),
                with: source.bgr[sourceStart..<(sourceStart + source.width * 3)]
            )
        }
        destination = ImageBuffer(
            width: destination.width,
            height: destination.height,
            bgr: pixels
        )
    }

    private func drawBrightRun(
        in image: inout ImageBuffer,
        x: Int,
        y: Int,
        width: Int
    ) {
        var pixels = image.bgr
        for column in x..<(x + width) {
            let index = (y * image.width + column) * 3
            pixels[index] = 225
            pixels[index + 1] = 225
            pixels[index + 2] = 225
        }
        image = ImageBuffer(width: image.width, height: image.height, bgr: pixels)
    }

    private func fillExperienceBar(
        in image: inout ImageBuffer,
        fraction: Double
    ) {
        var pixels = image.bgr
        let filledWidth = max(1, Int((155 * min(1, max(0, fraction))).rounded()))
        for y in 19...38 {
            for x in 8..<(8 + filledWidth) {
                let index = (y * image.width + x) * 3
                pixels[index] = 25
                pixels[index + 1] = 225
                pixels[index + 2] = 235
            }
        }
        image = ImageBuffer(width: image.width, height: image.height, bgr: pixels)
    }

    private func recognizeScaledPanel(
        frameWidth: Int,
        frameHeight: Int,
        scale: Double,
        percentage: String
    ) throws -> EXPRecognitionResult {
        var panel = try makePanel(
            currentEXP: "7192723",
            percentage: percentage
        )
        fillExperienceBar(
            in: &panel,
            fraction: (Double(percentage) ?? 0) / 100
        )
        let scaledPanel = bilinearScaled(panel, scale: scale)
        var frame = ImageBuffer(
            width: frameWidth,
            height: frameHeight,
            bgr: [UInt8](repeating: 18, count: frameWidth * frameHeight * 3)
        )
        paste(
            scaledPanel,
            into: &frame,
            x: (frameWidth - scaledPanel.width) / 2,
            y: frameHeight - scaledPanel.height
        )
        return try #require(EXPFixedFontRecognizer.recognize(in: frame))
    }

    private func bilinearScaled(
        _ image: ImageBuffer,
        scale: Double
    ) -> ImageBuffer {
        let width = max(1, Int(Double(image.width) * scale))
        let height = max(1, Int(Double(image.height) * scale))
        var pixels = [UInt8](repeating: 0, count: width * height * 3)
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
                for channel in 0..<3 {
                    let top = Double(image.bgr[(y0 * image.width + x0) * 3 + channel])
                            * (1 - xWeight)
                        + Double(image.bgr[(y0 * image.width + x1) * 3 + channel])
                            * xWeight
                    let bottom = Double(image.bgr[(y1 * image.width + x0) * 3 + channel])
                            * (1 - xWeight)
                        + Double(image.bgr[(y1 * image.width + x1) * 3 + channel])
                            * xWeight
                    pixels[(y * width + x) * 3 + channel] = UInt8(
                        max(0, min(255, (top * (1 - yWeight) + bottom * yWeight).rounded()))
                    )
                }
            }
        }
        return ImageBuffer(width: width, height: height, bgr: pixels)
    }

    private func loadImage(_ url: URL) -> ImageBuffer? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        return ImagePipeline.cgImageToBGRBuffer(image)
    }
}
