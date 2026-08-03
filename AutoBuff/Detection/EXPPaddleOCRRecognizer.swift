import Foundation

struct EXPPaddleOCRReading: Equatable, Sendable {
    let currentEXP: Int
    let percent: Double
    let confidence: Double
    let rawText: String
}

/// PP-OCRv4 pipeline shared with the Windows client: DB text detection,
/// cropped-line recognition and CTC decoding with the same model weights.
enum EXPPaddleOCRRecognizer {
    private static let runtime = EXPPaddleOCRRuntime.loadFromBundle()

    static var isAvailable: Bool { runtime != nil }

    static func recognize(in panel: ImageBuffer) -> EXPPaddleOCRReading? {
        runtime?.recognize(in: panel)
    }
}

private final class EXPPaddleOCRRuntime: @unchecked Sendable {
    private let detector: ABONNXModelSession
    private let recognizer: ABONNXModelSession
    private let characters: [String]

    private init(
        detector: ABONNXModelSession,
        recognizer: ABONNXModelSession,
        characters: [String]
    ) {
        self.detector = detector
        self.recognizer = recognizer
        self.characters = characters
    }

    static func loadFromBundle() -> EXPPaddleOCRRuntime? {
        guard let detectorURL = resourceURL(
            name: "ch_PP-OCRv4_det_infer",
            extension: "onnx"
        ), let recognizerURL = resourceURL(
            name: "rec_ch_PP-OCRv4_infer",
            extension: "onnx"
        ), let keysURL = resourceURL(
            name: "ppocr_keys_v1",
            extension: "txt"
        ), let keys = try? String(contentsOf: keysURL, encoding: .utf8) else {
            return nil
        }

        let dictionary = keys
            .split(whereSeparator: \.isNewline)
            .map(String.init)
        guard dictionary.count + 2 == 6_625,
              let detector = ABONNXModelSession(modelURL: detectorURL),
              let recognizer = ABONNXModelSession(modelURL: recognizerURL) else {
            return nil
        }
        return EXPPaddleOCRRuntime(
            detector: detector,
            recognizer: recognizer,
            characters: ["blank"] + dictionary + [" "]
        )
    }

    func recognize(in panel: ImageBuffer) -> EXPPaddleOCRReading? {
        guard !panel.isEmpty,
              let enlarged = EXPOCRImageScaler.nearestNeighbor(panel, scale: 4) else {
            return nil
        }

        // The fixed EXP anchor has already localized a single canonical panel.
        // Its upper 48% is always the text row; sending that row straight to
        // PP-OCRv4 recognition avoids a ~736×3100 DB-detector inference on every
        // frame. Keep DB detection as a compatibility fallback for unusual UI
        // scaling or panel layouts.
        let directLineHeight = max(1, Int((Double(enlarged.height) * 0.48).rounded(.up)))
        let directLine = enlarged.cropped(
            x: 0,
            y: 0,
            width: enlarged.width,
            height: directLineHeight
        )
        if let directLine,
           let decoded = recognizeText(in: directLine),
           decoded.confidence >= 0.80,
           let parsed = EXPTextParser.parse(decoded.text) {
            return EXPPaddleOCRReading(
                currentEXP: parsed.currentEXP,
                percent: parsed.percent,
                confidence: decoded.confidence,
                rawText: decoded.text
            )
        }
        guard let textLine = detectTextLine(in: enlarged),
              let decoded = recognizeText(in: textLine.image),
              decoded.confidence >= 0.80,
              let parsed = EXPTextParser.parse(decoded.text) else { return nil }
        return EXPPaddleOCRReading(
            currentEXP: parsed.currentEXP,
            percent: parsed.percent,
            confidence: min(textLine.confidence, decoded.confidence),
            rawText: decoded.text
        )
    }

    private func detectTextLine(
        in image: ImageBuffer
    ) -> (image: ImageBuffer, confidence: Double)? {
        let minimumSide = min(image.width, image.height)
        guard minimumSide > 0 else { return nil }
        // RapidOCR's 736px default targets full screenshots. This input is
        // already a 4× enlarged, anchor-cropped 185×44 panel, so a 160px
        // minimum side preserves ~48px glyphs while cutting detector pixels
        // by roughly 16× at native scale.
        let detectorMinimumSide = 160.0
        let ratio = minimumSide < Int(detectorMinimumSide)
            ? detectorMinimumSide / Double(minimumSide)
            : 1
        let targetWidth = max(32, Int((Double(image.width) * ratio / 32).rounded()) * 32)
        let targetHeight = max(32, Int((Double(image.height) * ratio / 32).rounded()) * 32)
        let input = EXPOCRImageScaler.normalizedPlanarBGR(
            image,
            resizedWidth: targetWidth,
            resizedHeight: targetHeight,
            paddedWidth: targetWidth
        )
        guard let tensor = detector.run(
            input: input,
            dimensions: [1, 3, Int64(targetHeight), Int64(targetWidth)]
        ), tensor.dimensions.count == 4,
              tensor.dimensions[0] == 1,
              tensor.dimensions[1] == 1 else {
            return nil
        }

        let mapHeight = Int(tensor.dimensions[2])
        let mapWidth = Int(tensor.dimensions[3])
        guard mapWidth > 0,
              mapHeight > 0,
              tensor.values.count == mapWidth * mapHeight else {
            return nil
        }

        var minimumX = mapWidth
        var minimumY = mapHeight
        var maximumX = -1
        var maximumY = -1
        var probabilitySum = 0.0
        var probabilityCount = 0
        for y in 0..<mapHeight {
            let row = y * mapWidth
            for x in 0..<mapWidth {
                let probability = tensor.values[row + x]
                guard probability > 0.30 else { continue }
                minimumX = min(minimumX, x)
                minimumY = min(minimumY, y)
                maximumX = max(maximumX, x)
                maximumY = max(maximumY, y)
                probabilitySum += Double(probability)
                probabilityCount += 1
            }
        }
        guard probabilityCount > 0, maximumX >= minimumX, maximumY >= minimumY else {
            return nil
        }

        // RapidOCR-json dilates with a 2×2 kernel and expands the DB polygon by
        // area * 1.6 / perimeter. The EXP row is horizontal, so an axis-aligned
        // expansion is equivalent while avoiding a general polygon dependency.
        maximumX = min(mapWidth - 1, maximumX + 1)
        maximumY = min(mapHeight - 1, maximumY + 1)
        let componentWidth = Double(maximumX - minimumX + 1)
        let componentHeight = Double(maximumY - minimumY + 1)
        guard componentWidth >= 3, componentHeight >= 3 else { return nil }
        let expansion = componentWidth * componentHeight * 1.6
            / (2 * (componentWidth + componentHeight))

        let left = max(0, Int(
            ((Double(minimumX) - expansion) / Double(mapWidth) * Double(image.width))
                .rounded(.down)
        ))
        let top = max(0, Int(
            ((Double(minimumY) - expansion) / Double(mapHeight) * Double(image.height))
                .rounded(.down)
        ))
        let right = min(image.width, Int(
            ((Double(maximumX + 1) + expansion) / Double(mapWidth) * Double(image.width))
                .rounded(.up)
        ))
        let bottom = min(image.height, Int(
            ((Double(maximumY + 1) + expansion) / Double(mapHeight) * Double(image.height))
                .rounded(.up)
        ))
        guard let crop = image.cropped(
            x: left,
            y: top,
            width: right - left,
            height: bottom - top
        ) else {
            return nil
        }
        return (
            image: crop,
            confidence: probabilitySum / Double(probabilityCount)
        )
    }

    private func recognizeText(
        in image: ImageBuffer
    ) -> (text: String, confidence: Double)? {
        guard image.width > 0, image.height > 0 else { return nil }
        let height = 48
        let widthHeightRatio = Double(image.width) / Double(image.height)
        let maximumRatio = max(320.0 / 48.0, widthHeightRatio)
        let paddedWidth = max(1, Int(Double(height) * maximumRatio))
        let resizedWidth = min(
            paddedWidth,
            max(1, Int((Double(height) * widthHeightRatio).rounded(.up)))
        )
        let input = EXPOCRImageScaler.normalizedPlanarBGR(
            image,
            resizedWidth: resizedWidth,
            resizedHeight: height,
            paddedWidth: paddedWidth
        )
        guard let tensor = recognizer.run(
            input: input,
            dimensions: [1, 3, Int64(height), Int64(paddedWidth)]
        ), tensor.dimensions.count == 3,
              tensor.dimensions[0] == 1,
              tensor.dimensions[2] == Int64(characters.count) else {
            return nil
        }

        let timeSteps = Int(tensor.dimensions[1])
        let classCount = Int(tensor.dimensions[2])
        var previousIndex = -1
        var text = ""
        var confidenceSum = 0.0
        var characterCount = 0
        for timeStep in 0..<timeSteps {
            let offset = timeStep * classCount
            var bestIndex = 0
            var bestProbability = tensor.values[offset]
            for index in 1..<classCount where tensor.values[offset + index] > bestProbability {
                bestIndex = index
                bestProbability = tensor.values[offset + index]
            }
            if bestIndex != 0, bestIndex != previousIndex {
                text += characters[bestIndex]
                confidenceSum += Double(bestProbability)
                characterCount += 1
            }
            previousIndex = bestIndex
        }
        guard characterCount > 0 else { return nil }
        return (text, confidenceSum / Double(characterCount))
    }

    private static func resourceURL(name: String, extension: String) -> URL? {
        let subdirectories = ["RapidOCR/models", "Resources/RapidOCR/models", nil]
        for subdirectory in subdirectories {
            if let url = Bundle.main.url(
                forResource: name,
                withExtension: `extension`,
                subdirectory: subdirectory
            ) {
                return url
            }
        }
        return nil
    }
}

private struct ABONNXTensor {
    let values: [Float]
    let dimensions: [Int64]
}

private final class ABONNXModelSession: @unchecked Sendable {
    private let reference: ABONNXSessionRef
    private let lock = NSLock()

    init?(modelURL: URL) {
        var error = [CChar](repeating: 0, count: 1_024)
        let created = modelURL.path.withCString { path in
            ABONNXCreateSession(path, &error, error.count)
        }
        guard let created else { return nil }
        reference = created
    }

    deinit {
        ABONNXReleaseSession(reference)
    }

    func run(input: [Float], dimensions: [Int64]) -> ABONNXTensor? {
        lock.lock()
        defer { lock.unlock() }

        var mutableInput = input
        let mutableDimensions = dimensions
        var output = ABONNXOutput()
        var error = [CChar](repeating: 0, count: 1_024)
        let succeeded = mutableInput.withUnsafeMutableBufferPointer { inputBuffer in
            mutableDimensions.withUnsafeBufferPointer { dimensionBuffer in
                ABONNXRun(
                    reference,
                    inputBuffer.baseAddress,
                    dimensionBuffer.baseAddress,
                    dimensionBuffer.count,
                    &output,
                    &error,
                    error.count
                )
            }
        }
        guard succeeded != 0,
              let valuePointer = output.values,
              let dimensionPointer = output.dimensions else {
            ABONNXFreeOutput(&output)
            return nil
        }
        let tensor = ABONNXTensor(
            values: Array(UnsafeBufferPointer(
                start: valuePointer,
                count: output.valueCount
            )),
            dimensions: Array(UnsafeBufferPointer(
                start: dimensionPointer,
                count: output.dimensionCount
            ))
        )
        ABONNXFreeOutput(&output)
        return tensor
    }
}

private enum EXPOCRImageScaler {
    static func nearestNeighbor(_ image: ImageBuffer, scale: Int) -> ImageBuffer? {
        guard scale > 0, !image.isEmpty else { return nil }
        let width = image.width * scale
        let height = image.height * scale
        var pixels = [UInt8](repeating: 0, count: width * height * 3)
        for destinationY in 0..<height {
            let sourceY = destinationY / scale
            for destinationX in 0..<width {
                let sourceX = destinationX / scale
                let source = (sourceY * image.width + sourceX) * 3
                let destination = (destinationY * width + destinationX) * 3
                pixels[destination] = image.bgr[source]
                pixels[destination + 1] = image.bgr[source + 1]
                pixels[destination + 2] = image.bgr[source + 2]
            }
        }
        return ImageBuffer(width: width, height: height, bgr: pixels)
    }

    static func normalizedPlanarBGR(
        _ image: ImageBuffer,
        resizedWidth: Int,
        resizedHeight: Int,
        paddedWidth: Int
    ) -> [Float] {
        let planeSize = paddedWidth * resizedHeight
        var output = [Float](repeating: 0, count: planeSize * 3)
        guard resizedWidth > 0,
              resizedHeight > 0,
              paddedWidth >= resizedWidth,
              !image.isEmpty else {
            return output
        }

        let xScale = Double(image.width) / Double(resizedWidth)
        let yScale = Double(image.height) / Double(resizedHeight)
        var xSamples: [(lower: Int, upper: Int, fraction: Double)] = []
        xSamples.reserveCapacity(resizedWidth)
        for x in 0..<resizedWidth {
            let source = max(0, min(
                Double(image.width - 1),
                (Double(x) + 0.5) * xScale - 0.5
            ))
            let lower = Int(source.rounded(.down))
            xSamples.append((lower, min(image.width - 1, lower + 1), source - Double(lower)))
        }

        for y in 0..<resizedHeight {
            let sourceY = max(0, min(
                Double(image.height - 1),
                (Double(y) + 0.5) * yScale - 0.5
            ))
            let top = Int(sourceY.rounded(.down))
            let bottom = min(image.height - 1, top + 1)
            let yFraction = sourceY - Double(top)
            for x in 0..<resizedWidth {
                let sample = xSamples[x]
                let topLeft = (top * image.width + sample.lower) * 3
                let topRight = (top * image.width + sample.upper) * 3
                let bottomLeft = (bottom * image.width + sample.lower) * 3
                let bottomRight = (bottom * image.width + sample.upper) * 3
                let destination = y * paddedWidth + x
                for channel in 0..<3 {
                    let upperValue = Double(image.bgr[topLeft + channel])
                        + (Double(image.bgr[topRight + channel])
                            - Double(image.bgr[topLeft + channel])) * sample.fraction
                    let lowerValue = Double(image.bgr[bottomLeft + channel])
                        + (Double(image.bgr[bottomRight + channel])
                            - Double(image.bgr[bottomLeft + channel])) * sample.fraction
                    let value = upperValue + (lowerValue - upperValue) * yFraction
                    output[channel * planeSize + destination] = Float(value / 127.5 - 1)
                }
            }
        }
        return output
    }
}
