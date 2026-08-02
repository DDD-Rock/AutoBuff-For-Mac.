import Foundation

struct MinimapBackgroundSynthesisResult: Equatable, Sendable {
    let buffer: ImageBuffer
    let sampledFrameCount: Int
    let cleanedPixelCount: Int
    let spatiallyRepairedPixelCount: Int
}

struct MinimapReferenceMergeResult: Equatable, Sendable {
    let buffer: ImageBuffer
    let replacedPixelCount: Int
    let stillCoveredPixelCount: Int
}

enum MinimapBackgroundSynthesisError: LocalizedError, Equatable {
    case notEnoughFrames
    case inconsistentFrameSize

    var errorDescription: String? {
        switch self {
        case .notEnoughFrames:
            return "纯净小地图合成至少需要 2 帧有效截图"
        case .inconsistentFrameSize:
            return "采样期间小地图尺寸发生变化，请重新抓取"
        }
    }
}

enum MinimapBackgroundSynthesizer {
    private struct PixelValue {
        let b: Double
        let g: Double
        let r: Double

        var luminance: Double {
            0.114 * b + 0.587 * g + 0.299 * r
        }
    }

    static func synthesize(frames: [ImageBuffer]) throws -> MinimapBackgroundSynthesisResult {
        guard frames.count >= 2 else {
            throw MinimapBackgroundSynthesisError.notEnoughFrames
        }
        guard let first = frames.first,
              first.width > 0,
              first.height > 0,
              first.bgr.count == first.width * first.height * 3,
              frames.allSatisfy({
                  $0.width == first.width
                      && $0.height == first.height
                      && $0.bgr.count == first.bgr.count
              }) else {
            throw MinimapBackgroundSynthesisError.inconsistentFrameSize
        }

        let pixelCount = first.width * first.height
        let masks = frames.map {
            movingMarkerMask(in: $0, radius: 1)
        }
        var output = [UInt8](repeating: 0, count: first.bgr.count)
        var unresolved = [Bool](repeating: false, count: pixelCount)
        var cleanedPixelCount = 0

        for pixelIndex in 0..<pixelCount {
            var blueSamples: [UInt8] = []
            var greenSamples: [UInt8] = []
            var redSamples: [UInt8] = []
            blueSamples.reserveCapacity(frames.count)
            greenSamples.reserveCapacity(frames.count)
            redSamples.reserveCapacity(frames.count)
            var wasMasked = false

            for frameIndex in frames.indices {
                if masks[frameIndex][pixelIndex] {
                    wasMasked = true
                    continue
                }
                let source = pixelIndex * 3
                blueSamples.append(frames[frameIndex].bgr[source])
                greenSamples.append(frames[frameIndex].bgr[source + 1])
                redSamples.append(frames[frameIndex].bgr[source + 2])
            }

            if wasMasked {
                cleanedPixelCount += 1
            }
            guard !blueSamples.isEmpty else {
                unresolved[pixelIndex] = true
                continue
            }
            let destination = pixelIndex * 3
            output[destination] = median(blueSamples)
            output[destination + 1] = median(greenSamples)
            output[destination + 2] = median(redSamples)
        }

        let spatiallyRepairedPixelCount = unresolved.reduce(0) { $0 + ($1 ? 1 : 0) }
        if spatiallyRepairedPixelCount > 0 {
            repairUnresolvedPixels(
                in: &output,
                unresolved: unresolved,
                width: first.width,
                height: first.height
            )
        }

        return MinimapBackgroundSynthesisResult(
            buffer: ImageBuffer(width: first.width, height: first.height, bgr: output),
            sampledFrameCount: frames.count,
            cleanedPixelCount: cleanedPixelCount,
            spatiallyRepairedPixelCount: spatiallyRepairedPixelCount
        )
    }

    /// Repairs only marker-covered pixels in the stored reference. Pixels that
    /// are already clean are kept byte-for-byte, so repeated merges cannot blur
    /// the reference image.
    static func mergeReference(
        stored: ImageBuffer,
        current: ImageBuffer
    ) throws -> MinimapReferenceMergeResult {
        guard stored.width > 0,
              stored.height > 0,
              stored.width == current.width,
              stored.height == current.height,
              stored.bgr.count == stored.width * stored.height * 3,
              current.bgr.count == stored.bgr.count else {
            throw MinimapBackgroundSynthesisError.inconsistentFrameSize
        }

        let storedMask = movingMarkerMask(in: stored, radius: 1)
        let currentMask = movingMarkerMask(in: current, radius: 1)
        var output = stored.bgr
        var replacedPixelCount = 0
        var stillCoveredPixelCount = 0

        for pixelIndex in storedMask.indices where storedMask[pixelIndex] {
            guard !currentMask[pixelIndex] else {
                stillCoveredPixelCount += 1
                continue
            }
            let offset = pixelIndex * 3
            output[offset] = current.bgr[offset]
            output[offset + 1] = current.bgr[offset + 1]
            output[offset + 2] = current.bgr[offset + 2]
            replacedPixelCount += 1
        }

        return MinimapReferenceMergeResult(
            buffer: ImageBuffer(width: stored.width, height: stored.height, bgr: output),
            replacedPixelCount: replacedPixelCount,
            stillCoveredPixelCount: stillCoveredPixelCount
        )
    }

    static func isMovingMarkerPixel(b: UInt8, g: UInt8, r: UInt8) -> Bool {
        let hsv = openCVHSV(r: r, g: g, b: b)
        let isWarmHue = hsv.h <= 45 || hsv.h >= 170
        return isWarmHue
            && hsv.s >= 70
            && hsv.v >= 90
            && r >= 90
            && Int(r) >= Int(b) + 20
    }

    private static func movingMarkerMask(
        in image: ImageBuffer,
        radius: Int
    ) -> [Bool] {
        let pixelCount = image.width * image.height
        var raw = [Bool](repeating: false, count: pixelCount)
        for pixelIndex in 0..<pixelCount {
            let source = pixelIndex * 3
            raw[pixelIndex] = isMovingMarkerPixel(
                b: image.bgr[source],
                g: image.bgr[source + 1],
                r: image.bgr[source + 2]
            )
        }
        guard radius > 0 else { return raw }

        var dilated = raw
        for y in 0..<image.height {
            for x in 0..<image.width where raw[y * image.width + x] {
                for offsetY in -radius...radius {
                    let neighborY = y + offsetY
                    guard neighborY >= 0, neighborY < image.height else { continue }
                    for offsetX in -radius...radius {
                        let neighborX = x + offsetX
                        guard neighborX >= 0, neighborX < image.width else { continue }
                        dilated[neighborY * image.width + neighborX] = true
                    }
                }
            }
        }
        return dilated
    }

    private static func median(_ values: [UInt8]) -> UInt8 {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return UInt8((Int(sorted[middle - 1]) + Int(sorted[middle])) / 2)
        }
        return sorted[middle]
    }

    private static func repairUnresolvedPixels(
        in pixels: inout [UInt8],
        unresolved: [Bool],
        width: Int,
        height: Int
    ) {
        let maxSearchRadius = min(max(width, height), 24)
        for y in 0..<height {
            for x in 0..<width {
                let pixelIndex = y * width + x
                guard unresolved[pixelIndex] else { continue }

                var candidates: [PixelValue] = []
                if let horizontal = opposingPairValue(
                    negativeX: x - 1,
                    negativeY: y,
                    positiveX: x + 1,
                    positiveY: y,
                    negativeStepX: -1,
                    negativeStepY: 0,
                    positiveStepX: 1,
                    positiveStepY: 0,
                    pixels: pixels,
                    unresolved: unresolved,
                    width: width,
                    height: height,
                    maxRadius: maxSearchRadius
                ) {
                    candidates.append(horizontal)
                }
                if let vertical = opposingPairValue(
                    negativeX: x,
                    negativeY: y - 1,
                    positiveX: x,
                    positiveY: y + 1,
                    negativeStepX: 0,
                    negativeStepY: -1,
                    positiveStepX: 0,
                    positiveStepY: 1,
                    pixels: pixels,
                    unresolved: unresolved,
                    width: width,
                    height: height,
                    maxRadius: maxSearchRadius
                ) {
                    candidates.append(vertical)
                }

                let replacement = candidates.max(by: { $0.luminance < $1.luminance })
                    ?? nearestKnownValue(
                        x: x,
                        y: y,
                        pixels: pixels,
                        unresolved: unresolved,
                        width: width,
                        height: height,
                        maxRadius: maxSearchRadius
                    )
                    ?? PixelValue(b: 0, g: 0, r: 0)
                setPixel(replacement, at: pixelIndex, pixels: &pixels)
            }
        }
    }

    private static func opposingPairValue(
        negativeX: Int,
        negativeY: Int,
        positiveX: Int,
        positiveY: Int,
        negativeStepX: Int,
        negativeStepY: Int,
        positiveStepX: Int,
        positiveStepY: Int,
        pixels: [UInt8],
        unresolved: [Bool],
        width: Int,
        height: Int,
        maxRadius: Int
    ) -> PixelValue? {
        var negativePoint = (x: negativeX, y: negativeY)
        var positivePoint = (x: positiveX, y: positiveY)
        var negative: (value: PixelValue, distance: Int)?
        var positive: (value: PixelValue, distance: Int)?

        for distance in 1...maxRadius {
            if negative == nil,
               isInside(negativePoint, width: width, height: height) {
                let index = negativePoint.y * width + negativePoint.x
                if !unresolved[index] {
                    negative = (pixelValue(at: index, pixels: pixels), distance)
                }
            }
            if positive == nil,
               isInside(positivePoint, width: width, height: height) {
                let index = positivePoint.y * width + positivePoint.x
                if !unresolved[index] {
                    positive = (pixelValue(at: index, pixels: pixels), distance)
                }
            }
            if let negative, let positive {
                let total = Double(negative.distance + positive.distance)
                return PixelValue(
                    b: (
                        negative.value.b * Double(positive.distance)
                            + positive.value.b * Double(negative.distance)
                    ) / total,
                    g: (
                        negative.value.g * Double(positive.distance)
                            + positive.value.g * Double(negative.distance)
                    ) / total,
                    r: (
                        negative.value.r * Double(positive.distance)
                            + positive.value.r * Double(negative.distance)
                    ) / total
                )
            }
            negativePoint.x += negativeStepX
            negativePoint.y += negativeStepY
            positivePoint.x += positiveStepX
            positivePoint.y += positiveStepY
        }
        return nil
    }

    private static func nearestKnownValue(
        x: Int,
        y: Int,
        pixels: [UInt8],
        unresolved: [Bool],
        width: Int,
        height: Int,
        maxRadius: Int
    ) -> PixelValue? {
        for radius in 1...maxRadius {
            var values: [PixelValue] = []
            for offsetY in -radius...radius {
                for offsetX in -radius...radius
                where abs(offsetX) == radius || abs(offsetY) == radius {
                    let neighborX = x + offsetX
                    let neighborY = y + offsetY
                    guard neighborX >= 0,
                          neighborX < width,
                          neighborY >= 0,
                          neighborY < height else { continue }
                    let index = neighborY * width + neighborX
                    if !unresolved[index] {
                        values.append(pixelValue(at: index, pixels: pixels))
                    }
                }
            }
            if !values.isEmpty {
                return values.max(by: { $0.luminance < $1.luminance })
            }
        }
        return nil
    }

    private static func isInside(
        _ point: (x: Int, y: Int),
        width: Int,
        height: Int
    ) -> Bool {
        point.x >= 0 && point.x < width && point.y >= 0 && point.y < height
    }

    private static func pixelValue(at pixelIndex: Int, pixels: [UInt8]) -> PixelValue {
        let source = pixelIndex * 3
        return PixelValue(
            b: Double(pixels[source]),
            g: Double(pixels[source + 1]),
            r: Double(pixels[source + 2])
        )
    }

    private static func setPixel(
        _ value: PixelValue,
        at pixelIndex: Int,
        pixels: inout [UInt8]
    ) {
        let destination = pixelIndex * 3
        pixels[destination] = UInt8(clamping: Int(value.b.rounded()))
        pixels[destination + 1] = UInt8(clamping: Int(value.g.rounded()))
        pixels[destination + 2] = UInt8(clamping: Int(value.r.rounded()))
    }

    private static func openCVHSV(
        r: UInt8,
        g: UInt8,
        b: UInt8
    ) -> (h: Double, s: Double, v: Double) {
        let red = Double(r) / 255
        let green = Double(g) / 255
        let blue = Double(b) / 255
        let maximum = max(red, green, blue)
        let minimum = min(red, green, blue)
        let difference = maximum - minimum

        let hueDegrees: Double
        if difference == 0 {
            hueDegrees = 0
        } else if maximum == red {
            hueDegrees = 60 * ((green - blue) / difference).truncatingRemainder(dividingBy: 6)
        } else if maximum == green {
            hueDegrees = 60 * ((blue - red) / difference + 2)
        } else {
            hueDegrees = 60 * ((red - green) / difference + 4)
        }
        let normalizedHue = hueDegrees < 0 ? hueDegrees + 360 : hueDegrees
        let saturation = maximum == 0 ? 0 : difference / maximum
        return (
            h: normalizedHue / 2,
            s: saturation * 255,
            v: maximum * 255
        )
    }
}
