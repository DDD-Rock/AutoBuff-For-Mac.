import Accelerate
import CoreGraphics
import CoreVideo
import Foundation

struct ImageBuffer: Equatable, Sendable {
    let width: Int
    let height: Int
    let bgr: [UInt8]
    
    var isEmpty: Bool { width <= 0 || height <= 0 || bgr.isEmpty }
    
    func pixelBGR(x: Int, y: Int) -> (b: UInt8, g: UInt8, r: UInt8)? {
        guard x >= 0, y >= 0, x < width, y < height else { return nil }
        let index = (y * width + x) * 3
        guard index + 2 < bgr.count else { return nil }
        return (bgr[index], bgr[index + 1], bgr[index + 2])
    }
    
    func cropped(x: Int, y: Int, width cropW: Int, height cropH: Int) -> ImageBuffer? {
        guard cropW > 0, cropH > 0, x >= 0, y >= 0, x + cropW <= width, y + cropH <= height else { return nil }
        var data = [UInt8](repeating: 0, count: cropW * cropH * 3)
        for row in 0..<cropH {
            let srcStart = ((y + row) * width + x) * 3
            let dstStart = row * cropW * 3
            data.replaceSubrange(dstStart..<(dstStart + cropW * 3), with: bgr[srcStart..<(srcStart + cropW * 3)])
        }
        return ImageBuffer(width: cropW, height: cropH, bgr: data)
    }
    
    func subBuffer(fromY yStart: Int) -> ImageBuffer? {
        cropped(x: 0, y: yStart, width: width, height: height - yStart)
    }
}

struct MatchResult: Equatable, Sendable {
    let x: Int
    let y: Int
    let width: Int
    let height: Int
    let confidence: Double
    let scaleX: Double
    let scaleY: Double
    
    var center: CGPoint {
        CGPoint(x: x + width / 2, y: y + height / 2)
    }
}

enum ImagePipeline {
    static func pixelBufferToBGRBuffer(_ pixelBuffer: CVPixelBuffer) -> ImageBuffer? {
        guard CVPixelBufferGetPixelFormatType(pixelBuffer) == kCVPixelFormatType_32BGRA else {
            return nil
        }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0,
              height > 0,
              CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else {
            return nil
        }
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
        }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return nil
        }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let source = baseAddress.assumingMemoryBound(to: UInt8.self)
        var bgr = [UInt8](repeating: 0, count: width * height * 3)
        bgr.withUnsafeMutableBytes { destinationBytes in
            guard let destination = destinationBytes.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return
            }
            for row in 0..<height {
                let sourceRow = source.advanced(by: row * bytesPerRow)
                let destinationRow = destination.advanced(by: row * width * 3)
                for column in 0..<width {
                    let sourcePixel = sourceRow.advanced(by: column * 4)
                    let destinationPixel = destinationRow.advanced(by: column * 3)
                    destinationPixel[0] = sourcePixel[0]
                    destinationPixel[1] = sourcePixel[1]
                    destinationPixel[2] = sourcePixel[2]
                }
            }
        }
        return ImageBuffer(width: width, height: height, bgr: bgr)
    }

    static func cgImageToBGRBuffer(_ image: CGImage) -> ImageBuffer? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }

        var bgra = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(
            data: &bgra,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        
        var bgr = [UInt8](repeating: 0, count: width * height * 3)
        var dst = 0
        for i in stride(from: 0, to: bgra.count, by: 4) {
            let r = bgra[i]
            let g = bgra[i + 1]
            let b = bgra[i + 2]
            bgr[dst] = b
            bgr[dst + 1] = g
            bgr[dst + 2] = r
            dst += 3
        }
        return ImageBuffer(width: width, height: height, bgr: bgr)
    }
    
    static func loadTemplate(named path: String) -> ImageBuffer? {
        let clean = path.hasSuffix(".png") ? String(path.dropLast(4)) : path
        let name = (clean as NSString).lastPathComponent
        let subdir = (clean as NSString).deletingLastPathComponent
        let candidates: [(String, String?, String?)] = [
            (clean, nil, nil),
            (name, "png", subdir.isEmpty ? nil : subdir),
            (name, "png", nil),
        ]
        for (resource, ext, sub) in candidates {
            guard let url = Bundle.main.url(forResource: resource, withExtension: ext, subdirectory: sub),
                  let data = try? Data(contentsOf: url),
                  let provider = CGDataProvider(data: data as CFData),
                  let image = CGImage(pngDataProviderSource: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
                continue
            }
            return cgImageToBGRBuffer(image)
        }
        return nil
    }
    
    static func imagePointToScreenPoint(_ point: CGPoint, imageSize: CGSize, windowBounds: CGRect) -> CGPoint {
        guard imageSize.width > 0, imageSize.height > 0 else { return windowBounds.origin }
        // Both CGWindow bounds and CGEvent use top-left global display coordinates.
        let screenX = windowBounds.origin.x + point.x * windowBounds.width / imageSize.width
        let screenY = windowBounds.origin.y + point.y * windowBounds.height / imageSize.height
        return CGPoint(x: screenX, y: screenY)
    }
}

enum TemplateMatcher {
    private struct PreparedImage {
        let grayscale: [Float]
        let integral: [Double]
        let squaredIntegral: [Double]
    }
    
    static func match(
        image: ImageBuffer,
        template: ImageBuffer,
        threshold: Double = 0.7,
        scales: [Double] = [0.6, 0.7, 0.8, 0.9, 1.0, 1.1, 1.2, 1.3, 1.4]
    ) -> MatchResult? {
        var best: MatchResult?
        let prepared = prepare(image)
        for scale in scales {
            guard let scaled = resize(template, scaleX: scale, scaleY: scale) else { continue }
            if let result = matchSingleScale(
                image: image,
                template: scaled,
                scaleX: scale,
                scaleY: scale,
                prepared: prepared
            ),
               result.confidence >= threshold,
               (best == nil || result.confidence > best!.confidence) {
                best = result
            }
        }
        return best
    }
    
    static func matchSingleScale(image: ImageBuffer, template: ImageBuffer, scaleX: Double, scaleY: Double) -> MatchResult? {
        matchSingleScale(
            image: image,
            template: template,
            scaleX: scaleX,
            scaleY: scaleY,
            prepared: prepare(image)
        )
    }
    
    private static func matchSingleScale(
        image: ImageBuffer,
        template: ImageBuffer,
        scaleX: Double,
        scaleY: Double,
        prepared: PreparedImage
    ) -> MatchResult? {
        // vImage convolution requires odd kernel dimensions. Removing at most one
        // edge pixel has no material effect on these UI templates.
        let tw = template.width.isMultiple(of: 2) ? template.width - 1 : template.width
        let th = template.height.isMultiple(of: 2) ? template.height - 1 : template.height
        guard tw >= 4, th >= 4, tw <= image.width, th <= image.height else { return nil }
        guard let oddTemplate = template.cropped(x: 0, y: 0, width: tw, height: th) else { return nil }
        
        let templateGray = grayscaleFloats(oddTemplate)
        let count = Float(tw * th)
        let templateMean = templateGray.reduce(0, +) / count
        let kernel = templateGray.map { $0 - templateMean }
        let templateEnergy = kernel.reduce(0) { $0 + $1 * $1 }
        guard templateEnergy > 0.0001 else { return nil }
        
        var correlation = [Float](repeating: 0, count: image.width * image.height)
        let convolutionError: vImage_Error = prepared.grayscale.withUnsafeBytes { srcRaw in
            correlation.withUnsafeMutableBytes { dstRaw in
                kernel.withUnsafeBufferPointer { kernelPointer in
                    var srcBuffer = vImage_Buffer(
                        data: UnsafeMutableRawPointer(mutating: srcRaw.baseAddress!),
                        height: vImagePixelCount(image.height),
                        width: vImagePixelCount(image.width),
                        rowBytes: image.width * MemoryLayout<Float>.stride
                    )
                    var dstBuffer = vImage_Buffer(
                        data: dstRaw.baseAddress!,
                        height: vImagePixelCount(image.height),
                        width: vImagePixelCount(image.width),
                        rowBytes: image.width * MemoryLayout<Float>.stride
                    )
                    return vImageConvolve_PlanarF(
                        &srcBuffer,
                        &dstBuffer,
                        nil,
                        0,
                        0,
                        kernelPointer.baseAddress!,
                        UInt32(th),
                        UInt32(tw),
                        0,
                        vImage_Flags(kvImageEdgeExtend)
                    )
                }
            }
        }
        guard convolutionError == kvImageNoError else { return nil }
        
        let integralWidth = image.width + 1
        let halfW = tw / 2
        let halfH = th / 2
        let maxX = image.width - tw
        let maxY = image.height - th
        var bestValue = -Float.infinity
        var bestX = 0
        var bestY = 0
        
        for y in 0...maxY {
            for x in 0...maxX {
                let sum = rectSum(prepared.integral, stride: integralWidth, x: x, y: y, width: tw, height: th)
                let sumSquared = rectSum(prepared.squaredIntegral, stride: integralWidth, x: x, y: y, width: tw, height: th)
                let patchEnergy = max(0, sumSquared - (sum * sum / Double(tw * th)))
                guard patchEnergy > 0.0001 else { continue }
                let centerIndex = (y + halfH) * image.width + (x + halfW)
                let denominator = sqrt(Double(templateEnergy) * patchEnergy)
                let coefficient = denominator > 0 ? Double(correlation[centerIndex]) / denominator : -1
                if coefficient > Double(bestValue) {
                    bestValue = Float(coefficient)
                    bestX = x
                    bestY = y
                }
            }
        }
        
        guard bestValue > -Float.infinity else { return nil }
        return MatchResult(
            x: bestX,
            y: bestY,
            width: tw,
            height: th,
            confidence: Double(bestValue),
            scaleX: scaleX,
            scaleY: scaleY
        )
    }
    
    private static func resize(_ image: ImageBuffer, scaleX: Double, scaleY: Double) -> ImageBuffer? {
        let newW = max(1, Int(Double(image.width) * scaleX))
        let newH = max(1, Int(Double(image.height) * scaleY))
        var data = [UInt8](repeating: 0, count: newW * newH * 3)
        for y in 0..<newH {
            let srcY = min(image.height - 1, Int(Double(y) / scaleY))
            for x in 0..<newW {
                let srcX = min(image.width - 1, Int(Double(x) / scaleX))
                guard let pixel = image.pixelBGR(x: srcX, y: srcY) else { continue }
                let dst = (y * newW + x) * 3
                data[dst] = pixel.b
                data[dst + 1] = pixel.g
                data[dst + 2] = pixel.r
            }
        }
        return ImageBuffer(width: newW, height: newH, bgr: data)
    }
    
    private static func grayscaleFloats(_ image: ImageBuffer) -> [Float] {
        var result = [Float](repeating: 0, count: image.width * image.height)
        for index in result.indices {
            let source = index * 3
            result[index] =
                0.114 * Float(image.bgr[source])
                + 0.587 * Float(image.bgr[source + 1])
                + 0.299 * Float(image.bgr[source + 2])
        }
        return result
    }
    
    private static func prepare(_ image: ImageBuffer) -> PreparedImage {
        let grayscale = grayscaleFloats(image)
        let (integral, squaredIntegral) = integralImages(
            grayscale,
            width: image.width,
            height: image.height
        )
        return PreparedImage(
            grayscale: grayscale,
            integral: integral,
            squaredIntegral: squaredIntegral
        )
    }
    
    private static func integralImages(_ pixels: [Float], width: Int, height: Int) -> ([Double], [Double]) {
        let stride = width + 1
        var integral = [Double](repeating: 0, count: stride * (height + 1))
        var squared = [Double](repeating: 0, count: stride * (height + 1))
        for y in 0..<height {
            var rowSum = 0.0
            var rowSquared = 0.0
            for x in 0..<width {
                let value = Double(pixels[y * width + x])
                rowSum += value
                rowSquared += value * value
                let destination = (y + 1) * stride + x + 1
                integral[destination] = integral[y * stride + x + 1] + rowSum
                squared[destination] = squared[y * stride + x + 1] + rowSquared
            }
        }
        return (integral, squared)
    }
    
    private static func rectSum(_ integral: [Double], stride: Int, x: Int, y: Int, width: Int, height: Int) -> Double {
        let x2 = x + width
        let y2 = y + height
        return integral[y2 * stride + x2]
            - integral[y * stride + x2]
            - integral[y2 * stride + x]
            + integral[y * stride + x]
    }
}

enum ColorDetector {
    struct PlayerMarkerDetectionResult: Sendable {
        let point: CGPoint?
        let candidateCount: Int
        let selectedArea: Int?
        let selectedSize: CGSize?
        
        var summary: String {
            if let point {
                let sizeText: String
                if let selectedSize {
                    sizeText = "，尺寸=\(Int(selectedSize.width))×\(Int(selectedSize.height))"
                } else {
                    sizeText = ""
                }
                return "玩家黄点 x=\(String(format: "%.1f", point.x)), y=\(String(format: "%.1f", point.y))，面积=\(selectedArea ?? 0)\(sizeText)，候选数=\(candidateCount)"
            }
            return "未检测到玩家黄点，候选数=\(candidateCount)"
        }
    }

    struct OtherPlayerMarkerDetectionResult: Sendable {
        let points: [CGPoint]
        let candidateCount: Int

        var summary: String {
            points.isEmpty
                ? "未检测到其他玩家红点"
                : "检测到其他玩家红点 \(points.count) 个"
        }
    }

    struct TeammateMarkerDetectionResult: Sendable {
        let points: [CGPoint]
        let candidateCount: Int

        var summary: String {
            points.isEmpty
                ? "未检测到队友橙点"
                : "检测到队友橙点 \(points.count) 个"
        }
    }
    
    struct DarkRegionDetectionResult: Sendable {
        let rect: CGRect?
        let threshold: Int?
        let candidateCount: Int
        let bestCandidate: CGRect?
        let bestRectangularity: Double
        
        var summary: String {
            if let rect, let threshold {
                return "小地图区域 x=\(Int(rect.minX)), y=\(Int(rect.minY)), w=\(Int(rect.width)), h=\(Int(rect.height))，灰度阈值=\(threshold)"
            }
            if let rect {
                return "小地图区域 x=\(Int(rect.minX)), y=\(Int(rect.minY)), w=\(Int(rect.width)), h=\(Int(rect.height))"
            }
            if let bestCandidate {
                return "未找到合格区域；候选数=\(candidateCount)，最佳候选 x=\(Int(bestCandidate.minX)), y=\(Int(bestCandidate.minY)), w=\(Int(bestCandidate.width)), h=\(Int(bestCandidate.height))，矩形度=\(String(format: "%.2f", bestRectangularity))"
            }
            return "未找到深色连通区域；候选数=\(candidateCount)"
        }
    }

    struct MinimapContentValidationResult: Sendable {
        let isValid: Bool
        let darkRatio: Double
        let maximumBrightEdgeRatio: Double
        let markerPixelCount: Int
        let summary: String
    }
    
    static func findYellowCentroid(in image: ImageBuffer, minArea: Int = 5) -> CGPoint? {
        detectPlayerMarker(in: image, minArea: minArea).point
    }
    
    static func detectPlayerMarker(
        in image: ImageBuffer,
        minArea: Int = 2,
        maxArea: Int = 120,
        near preferredPoint: CGPoint? = nil
    ) -> PlayerMarkerDetectionResult {
        // The player's marker has a near-neon yellow core. Detect that core
        // first so adjacent gold platforms and decorations cannot merge it into
        // an oversized warm-colored component. Older maps without this pure
        // core continue through the broader resampled-yellow fallback below.
        let vividBlobs = connectedColorBlobs(in: image) { b, g, r in
            r >= 240
                && g >= 235
                && b <= 90
                && abs(Int(r) - Int(g)) <= 25
        }
        let vividCandidates = playerMarkerCandidates(
            from: vividBlobs,
            minArea: minArea,
            maxArea: maxArea
        )
        if let best = bestPlayerMarker(
            in: vividCandidates,
            near: preferredPoint
        ) {
            return PlayerMarkerDetectionResult(
                point: best.centroid,
                candidateCount: vividCandidates.count,
                selectedArea: best.area,
                selectedSize: CGSize(width: best.width, height: best.height)
            )
        }

        let blobs = connectedColorBlobs(in: image) { b, g, r in
            // Native Retina pixels matched the strict Windows BGR threshold.
            // A point-resolution ScreenCaptureKit frame is resampled, so accept
            // anti-aliased yellow while still requiring a saturated warm color.
            let hsv = rgbToOpenCVHSV(r: r, g: g, b: b)
            return hsv.h >= 20 && hsv.h <= 40
                && hsv.s >= 100
                && hsv.v >= 160
                && r >= 165
                && g >= 150
                && Int(r) + Int(g) >= Int(b) * 3
        }
        
        let candidates = playerMarkerCandidates(
            from: blobs,
            minArea: minArea,
            maxArea: maxArea
        )

        // Prefer the compact player marker over thin yellow UI glyphs or
        // oversized minimap decorations that can otherwise stay fixed while the
        // character is moving.
        let best = bestPlayerMarker(in: candidates, near: preferredPoint)
        return PlayerMarkerDetectionResult(
            point: best?.centroid,
            candidateCount: candidates.count,
            selectedArea: best?.area,
            selectedSize: best.map { CGSize(width: $0.width, height: $0.height) }
        )
    }

    private static func playerMarkerCandidates(
        from blobs: [ColorBlob],
        minArea: Int,
        maxArea: Int
    ) -> [ColorBlob] {
        blobs.filter {
            guard $0.area >= minArea,
                  $0.area <= maxArea,
                  $0.width >= 2,
                  $0.height >= 2,
                  $0.width <= 16,
                  $0.height <= 16,
                  $0.width > 0,
                  $0.height > 0 else { return false }
            let aspect = Double($0.width) / Double($0.height)
            let fillRatio = Double($0.area) / Double($0.width * $0.height)
            return aspect >= 0.55
                && aspect <= 1.9
                && fillRatio >= 0.45
        }
    }

    private static func bestPlayerMarker(
        in candidates: [ColorBlob],
        near preferredPoint: CGPoint?
    ) -> ColorBlob? {
        candidates.max { lhs, rhs in
            playerMarkerTrackingScore(lhs, near: preferredPoint)
                < playerMarkerTrackingScore(rhs, near: preferredPoint)
        }
    }

    static func detectOtherPlayerMarkers(
        in image: ImageBuffer,
        minArea: Int = 2,
        maxArea: Int = 120
    ) -> OtherPlayerMarkerDetectionResult {
        let blobs = connectedColorBlobs(in: image) { b, g, r in
            let hsv = rgbToOpenCVHSV(r: r, g: g, b: b)
            let isRedHue = hsv.h <= 12 || hsv.h >= 168
            return isRedHue
                && hsv.s >= 90
                && hsv.v >= 110
                && r >= 130
                && Int(r) >= Int(g) + 40
                && Int(r) >= Int(b) + 40
        }

        let candidates = blobs.filter {
            guard $0.area >= minArea,
                  $0.area <= maxArea,
                  $0.width >= 2,
                  $0.height >= 2,
                  $0.width <= 16,
                  $0.height <= 16 else { return false }
            let aspect = Double($0.width) / Double($0.height)
            let fillRatio = Double($0.area) / Double($0.width * $0.height)
            return aspect >= 0.5
                && aspect <= 2.0
                && fillRatio >= 0.4
        }.sorted {
            if $0.centroid.x == $1.centroid.x {
                return $0.centroid.y < $1.centroid.y
            }
            return $0.centroid.x < $1.centroid.x
        }

        return OtherPlayerMarkerDetectionResult(
            points: candidates.map(\.centroid),
            candidateCount: candidates.count
        )
    }

    static func detectTeammateMarkers(
        in image: ImageBuffer,
        minArea: Int = 2,
        maxArea: Int = 120
    ) -> TeammateMarkerDetectionResult {
        let blobs = connectedColorBlobs(in: image) { b, g, r in
            let hsv = rgbToOpenCVHSV(r: r, g: g, b: b)
            return hsv.h > 12
                && hsv.h < 20
                && hsv.s >= 90
                && hsv.v >= 130
                && r >= 160
                && g >= 80
                && Int(r) >= Int(g) + 30
                && Int(g) >= Int(b) + 30
        }

        let candidates = blobs.filter {
            guard $0.area >= minArea,
                  $0.area <= maxArea,
                  $0.width >= 2,
                  $0.height >= 2,
                  $0.width <= 16,
                  $0.height <= 16 else { return false }
            let aspect = Double($0.width) / Double($0.height)
            let fillRatio = Double($0.area) / Double($0.width * $0.height)
            return aspect >= 0.5
                && aspect <= 2.0
                && fillRatio >= 0.4
        }.sorted {
            if $0.centroid.x == $1.centroid.x {
                return $0.centroid.y < $1.centroid.y
            }
            return $0.centroid.x < $1.centroid.x
        }

        return TeammateMarkerDetectionResult(
            points: candidates.map(\.centroid),
            candidateCount: candidates.count
        )
    }
    
    static func findBluePortal(in image: ImageBuffer, leftmost: Bool = true, minArea: Int = 10) -> CGPoint? {
        let blobs = connectedColorBlobs(in: image) { b, g, r in
            let hsv = rgbToOpenCVHSV(r: r, g: g, b: b)
            return hsv.h >= 90 && hsv.h <= 130 && hsv.s >= 100 && hsv.v >= 100
        }.filter {
            guard $0.area >= minArea, $0.height > 0 else { return false }
            let aspect = Double($0.width) / Double($0.height)
            return aspect > 0.3 && aspect < 3.0
        }
        guard !blobs.isEmpty else { return nil }
        if leftmost {
            return blobs.min(by: { $0.minX < $1.minX })?.centroid
        }
        return blobs.max(by: { $0.area < $1.area })?.centroid
    }

    static func detectMinimapRegion(
        in image: ImageBuffer,
        searchWidth: Int = 480,
        searchHeight: Int = 420
    ) -> DarkRegionDetectionResult {
        // The minimap panel is permanently anchored to the top-left of the
        // game content. Its light frame is considerably more stable than the
        // artwork inside the map: Time Road, for example, contains large white
        // buildings and legitimately fails a "mostly dark" content check.
        //
        // A frame match already proves both location and geometry, so return it
        // directly. Re-validating the cropped content by darkness would reject
        // bright maps and force the very expensive morphology fallback.
        if let frameRegion = detectMinimapByWhiteFrame(
            in: image,
            searchWidth: searchWidth,
            searchHeight: searchHeight
        ) {
            return frameRegion
        }
        if let markerRegion = detectMinimapByDarkComponentsAndMarkers(
            in: image,
            searchWidth: searchWidth,
            searchHeight: searchHeight
        ), let validated = validatedMinimapRegion(markerRegion, in: image) {
            return validated
        }
        let fallback = detectDarkRegion(
            in: image,
            searchWidth: searchWidth,
            searchHeight: searchHeight
        )
        if let validated = validatedMinimapRegion(fallback, in: image) {
            return validated
        }
        return DarkRegionDetectionResult(
            rect: nil,
            threshold: fallback.threshold,
            candidateCount: fallback.candidateCount,
            bestCandidate: fallback.rect ?? fallback.bestCandidate,
            bestRectangularity: fallback.bestRectangularity
        )
    }

    static func validateMinimapContent(in image: ImageBuffer) -> MinimapContentValidationResult {
        guard image.width >= 70, image.height >= 40 else {
            return MinimapContentValidationResult(
                isValid: false,
                darkRatio: 0,
                maximumBrightEdgeRatio: 1,
                markerPixelCount: 0,
                summary: "内容区尺寸过小（\(image.width)×\(image.height)）"
            )
        }

        let aspect = Double(image.width) / Double(max(image.height, 1))
        let darkRatio = darkPixelRatio(
            in: image,
            minX: 0,
            minY: 0,
            maxX: image.width - 1,
            maxY: image.height - 1
        )
        let edgeRatios = [
            brightPixelRatio(in: image, minX: 0, minY: 0, maxX: image.width - 1, maxY: min(1, image.height - 1)),
            brightPixelRatio(in: image, minX: 0, minY: max(0, image.height - 2), maxX: image.width - 1, maxY: image.height - 1),
            brightPixelRatio(in: image, minX: 0, minY: 0, maxX: min(1, image.width - 1), maxY: image.height - 1),
            brightPixelRatio(in: image, minX: max(0, image.width - 2), minY: 0, maxX: image.width - 1, maxY: image.height - 1),
        ]
        let maximumBrightEdgeRatio = edgeRatios.max() ?? 1
        let markerPixelCount = countMinimapMarkerPixels(
            in: image,
            minX: 0,
            minY: 0,
            maxX: image.width - 1,
            maxY: image.height - 1
        )
        let isValid = aspect >= 0.5
            && aspect <= 4.0
            && darkRatio >= 0.12
            && maximumBrightEdgeRatio < 0.25
            && markerPixelCount >= 3
        let summary = "暗色占比=\(String(format: "%.2f", darkRatio))，边缘亮色=\(String(format: "%.2f", maximumBrightEdgeRatio))，标记像素=\(markerPixelCount)"
        return MinimapContentValidationResult(
            isValid: isValid,
            darkRatio: darkRatio,
            maximumBrightEdgeRatio: maximumBrightEdgeRatio,
            markerPixelCount: markerPixelCount,
            summary: summary
        )
    }

    private static func validatedMinimapRegion(
        _ result: DarkRegionDetectionResult,
        in image: ImageBuffer
    ) -> DarkRegionDetectionResult? {
        guard let originalRect = result.rect,
              let refinedRect = trimBrightFrameEdges(in: image, rect: originalRect),
              let content = image.cropped(
                x: Int(refinedRect.minX),
                y: Int(refinedRect.minY),
                width: Int(refinedRect.width),
                height: Int(refinedRect.height)
              ) else { return nil }
        let validation = validateMinimapContent(in: content)
        guard validation.isValid else { return nil }
        return DarkRegionDetectionResult(
            rect: refinedRect,
            threshold: result.threshold,
            candidateCount: result.candidateCount,
            bestCandidate: refinedRect,
            bestRectangularity: result.bestRectangularity
        )
    }

    private static func trimBrightFrameEdges(in image: ImageBuffer, rect: CGRect) -> CGRect? {
        var left = max(0, Int(rect.minX))
        var top = max(0, Int(rect.minY))
        var right = min(image.width - 1, Int(rect.maxX) - 1)
        var bottom = min(image.height - 1, Int(rect.maxY) - 1)
        guard right >= left, bottom >= top else { return nil }

        for _ in 0..<12 {
            var changed = false
            if right - left + 1 > 70,
               brightPixelRatio(
                   in: image,
                   minX: left,
                   minY: top,
                   maxX: left,
                   maxY: bottom
               ) >= 0.35 {
                left += 1
                changed = true
            }
            if right - left + 1 > 70,
               brightPixelRatio(
                   in: image,
                   minX: right,
                   minY: top,
                   maxX: right,
                   maxY: bottom
               ) >= 0.35 {
                right -= 1
                changed = true
            }
            if bottom - top + 1 > 40,
               brightPixelRatio(
                   in: image,
                   minX: left,
                   minY: top,
                   maxX: right,
                   maxY: top
               ) >= 0.35 {
                top += 1
                changed = true
            }
            if bottom - top + 1 > 40,
               brightPixelRatio(
                   in: image,
                   minX: left,
                   minY: bottom,
                   maxX: right,
                   maxY: bottom
               ) >= 0.35 {
                bottom -= 1
                changed = true
            }
            if !changed { break }
        }

        let width = right - left + 1
        let height = bottom - top + 1
        guard width >= 70, height >= 40 else { return nil }
        return CGRect(x: left, y: top, width: width, height: height)
    }

    private struct BrightRun {
        let y: Int
        let startX: Int
        let endX: Int

        var width: Int { endX - startX + 1 }
    }

    private static func detectMinimapByWhiteFrame(
        in image: ImageBuffer,
        searchWidth: Int,
        searchHeight: Int
    ) -> DarkRegionDetectionResult? {
        // ScreenCaptureKit captures the game content without the macOS title
        // bar. The panel therefore begins within a few pixels of (0, 0).
        // Grow the search box for wide windows because the game scales this
        // entire UI panel with window width.
        let dynamicSearchSize = min(640, max(searchWidth, image.width / 4))
        let sw = min(dynamicSearchSize, image.width)
        let sh = min(
            max(searchHeight, dynamicSearchSize),
            image.height
        )
        guard let region = image.cropped(x: 0, y: 0, width: sw, height: sh) else { return nil }

        let runs = brightHorizontalRuns(in: region).filter {
            $0.width >= 100 && $0.width <= 560 && $0.startX <= 24
        }
        var bestRect: CGRect?
        var bestScore = -Double.infinity
        var candidateCount = 0
        // Depending on the ScreenCaptureKit/window-server path, the captured
        // frame may retain the macOS title bar. Keep the panel anchored to the
        // upper-left while allowing that 25–50 point vertical offset.
        let maximumFrameTop = min(64, max(24, region.height / 12))

        for topIndex in runs.indices {
            if Task.isCancelled { return nil }
            let top = runs[topIndex]
            guard top.y <= maximumFrameTop else { continue }
            for bottomIndex in runs.indices.dropFirst(topIndex + 1) {
                if Task.isCancelled { return nil }
                let bottom = runs[bottomIndex]
                let height = bottom.y - top.y + 1
                if height > 600 { break }
                guard height >= 110 else { continue }

                // Use the overlap of the two horizontal frame rows. Nearby
                // bright game artwork can extend either row, while the actual
                // panel width remains their common span.
                let left = max(top.startX, bottom.startX)
                let right = min(top.endX, bottom.endX)
                let width = right - left + 1
                guard width >= 100, width <= 560, left <= 18 else { continue }

                // Ordinary windows keep the panel near one sixth of the
                // content width. Short, ultra-wide windows instead scale the
                // UI from the available height, making the panel less than one
                // tenth of the content width. Accept either stable scale model.
                let widthToWindowWidth = Double(width) / Double(max(image.width, 1))
                let widthToWindowHeight = Double(width) / Double(max(image.height, 1))
                let matchesOrdinaryWidthScale =
                    widthToWindowWidth >= 0.14 && widthToWindowWidth <= 0.21
                let matchesUltraWideHeightScale =
                    widthToWindowHeight >= 0.22 && widthToWindowHeight <= 0.38
                guard matchesOrdinaryWidthScale || matchesUltraWideHeightScale else {
                    continue
                }

                // Across supported resolutions the panel is slightly taller
                // than it is wide. This excludes chat bars and long platform
                // edges which may also be light and touch the left side.
                let panelAspect = Double(height) / Double(width)
                guard panelAspect >= 1.02, panelAspect <= 1.28 else { continue }

                let leftSide = brightVerticalSupport(in: region, x: left, y1: top.y, y2: bottom.y)
                let rightSide = brightVerticalSupport(in: region, x: right, y1: top.y, y2: bottom.y)
                let requiredSideSupport = Int(Double(height) * 0.62)
                guard leftSide >= requiredSideSupport,
                      rightSide >= requiredSideSupport,
                      let contentRect = minimapContentRect(fromPanelFrame: CGRect(
                          x: left,
                          y: top.y,
                          width: width,
                          height: height
                      )) else { continue }
                candidateCount += 1

                let sideSupport = Double(leftSide + rightSide) / Double(height * 2)
                let expectedAspectPenalty = abs(panelAspect - 1.13)
                let score = sideSupport * 10_000
                    + Double(width * height) * 0.02
                    - expectedAspectPenalty * 2_000
                    - Double(top.y + left) * 120

                if score > bestScore {
                    bestScore = score
                    bestRect = contentRect
                }
            }
        }

        guard let bestRect else { return nil }
        return DarkRegionDetectionResult(
            rect: bestRect,
            threshold: nil,
            candidateCount: candidateCount,
            bestCandidate: bestRect,
            bestRectangularity: bestScore
        )
    }

    static func minimapWhiteFrameDiagnostics(
        in image: ImageBuffer,
        searchWidth: Int = 480,
        searchHeight: Int = 420
    ) -> String {
        let dynamicSearchSize = min(640, max(searchWidth, image.width / 4))
        let sw = min(dynamicSearchSize, image.width)
        let sh = min(max(searchHeight, dynamicSearchSize), image.height)
        guard let region = image.cropped(x: 0, y: 0, width: sw, height: sh) else {
            return "白框诊断：截图裁剪失败"
        }

        let runs = brightHorizontalRuns(in: region).filter {
            $0.width >= 100 && $0.width <= 560 && $0.startX <= 24
        }
        let maximumFrameTop = min(64, max(24, region.height / 12))
        let topRuns = runs.filter { $0.y <= maximumFrameTop }
        var geometryCount = 0
        var maximumSideRatio = 0.0

        for top in topRuns {
            for bottom in runs where bottom.y > top.y {
                let height = bottom.y - top.y + 1
                guard height >= 110, height <= 600 else { continue }
                let left = max(top.startX, bottom.startX)
                let right = min(top.endX, bottom.endX)
                let width = right - left + 1
                guard width >= 100, width <= 560, left <= 18 else { continue }
                let widthToWindowWidth = Double(width) / Double(max(image.width, 1))
                let widthToWindowHeight = Double(width) / Double(max(image.height, 1))
                let scaleMatches =
                    (widthToWindowWidth >= 0.14 && widthToWindowWidth <= 0.21)
                    || (widthToWindowHeight >= 0.22 && widthToWindowHeight <= 0.38)
                let panelAspect = Double(height) / Double(width)
                guard scaleMatches, panelAspect >= 1.02, panelAspect <= 1.28 else {
                    continue
                }
                geometryCount += 1
                let leftSide = brightVerticalSupport(
                    in: region,
                    x: left,
                    y1: top.y,
                    y2: bottom.y
                )
                let rightSide = brightVerticalSupport(
                    in: region,
                    x: right,
                    y1: top.y,
                    y2: bottom.y
                )
                let sideRatio = Double(min(leftSide, rightSide)) / Double(height)
                maximumSideRatio = max(maximumSideRatio, sideRatio)
            }
        }

        let topDescription = topRuns.prefix(3).map {
            "y=\($0.y),x=\($0.startX)-\($0.endX)"
        }.joined(separator: ";")
        return "白框诊断：横线=\(runs.count)，顶边=[\(topDescription)]，几何候选=\(geometryCount)，双侧支持=\(String(format: "%.2f", maximumSideRatio))"
    }

    private static func minimapContentRect(fromPanelFrame frame: CGRect) -> CGRect? {
        let panelWidth = Int(frame.width)
        let panelHeight = Int(frame.height)
        guard panelWidth >= 100, panelHeight >= 110 else { return nil }

        // The title/map-name block occupies the upper third of the panel.
        // These proportions were verified across full-screen, 16:9 and wide
        // window captures; the game scales the complete panel uniformly.
        let horizontalInset = max(3, Int((Double(panelWidth) * 0.018).rounded()))
        let contentTopInset = Int((Double(panelHeight) * 0.335).rounded())
        let contentBottomInset = max(5, Int((Double(panelHeight) * 0.052).rounded()))
        let contentWidth = panelWidth - horizontalInset * 2
        let contentHeight = panelHeight - contentTopInset - contentBottomInset
        guard contentWidth >= 70, contentHeight >= 45 else { return nil }

        return CGRect(
            x: Int(frame.minX) + horizontalInset,
            y: Int(frame.minY) + contentTopInset,
            width: contentWidth,
            height: contentHeight
        )
    }
    
    static func autoDetectDarkRegion(
        in image: ImageBuffer,
        searchWidth: Int = 480,
        searchHeight: Int = 360,
        darkThreshold: Int = 100,
        minArea: Int = 2_000,
        maxCandidateWidth: Int = 420,
        maxCandidateHeight: Int = 320
    ) -> CGRect? {
        detectDarkRegion(
            in: image,
            searchWidth: searchWidth,
            searchHeight: searchHeight,
            thresholds: [darkThreshold, 120, 140],
            minArea: minArea,
            maxCandidateWidth: maxCandidateWidth,
            maxCandidateHeight: maxCandidateHeight
        ).rect
    }
    
    static func detectDarkRegion(
        in image: ImageBuffer,
        searchWidth: Int = 480,
        searchHeight: Int = 360,
        thresholds: [Int] = [100, 120, 140],
        minArea: Int = 2_000,
        maxCandidateWidth: Int = 420,
        maxCandidateHeight: Int = 320
    ) -> DarkRegionDetectionResult {
        let sw = min(searchWidth, image.width)
        let sh = min(searchHeight, image.height)
        guard let region = image.cropped(x: 0, y: 0, width: sw, height: sh) else {
            return DarkRegionDetectionResult(
                rect: nil,
                threshold: nil,
                candidateCount: 0,
                bestCandidate: nil,
                bestRectangularity: 0
            )
        }
        
        var totalCandidateCount = 0
        var overallBestCandidate: CGRect?
        var overallBestRectangularity = 0.0
        
        for threshold in Array(Set(thresholds)).sorted() {
            let attempt = detectDarkRegion(
                in: region,
                darkThreshold: threshold,
                minArea: minArea,
                maxCandidateWidth: maxCandidateWidth,
                maxCandidateHeight: maxCandidateHeight
            )
            totalCandidateCount += attempt.candidateCount
            if attempt.bestRectangularity > overallBestRectangularity {
                overallBestRectangularity = attempt.bestRectangularity
                overallBestCandidate = attempt.bestCandidate
            }
            if let rect = attempt.rect {
                return DarkRegionDetectionResult(
                    rect: rect,
                    threshold: threshold,
                    candidateCount: totalCandidateCount,
                    bestCandidate: rect,
                    bestRectangularity: attempt.bestRectangularity
                )
            }
        }
        
        return DarkRegionDetectionResult(
            rect: nil,
            threshold: nil,
            candidateCount: totalCandidateCount,
            bestCandidate: overallBestCandidate,
            bestRectangularity: overallBestRectangularity
        )
    }
    
    private static func detectDarkRegion(
        in region: ImageBuffer,
        darkThreshold: Int,
        minArea: Int,
        maxCandidateWidth: Int,
        maxCandidateHeight: Int
    ) -> DarkRegionDetectionResult {
        
        var darkMask = [Bool](repeating: false, count: region.width * region.height)
        for y in 0..<region.height {
            for x in 0..<region.width {
                guard let pixel = region.pixelBGR(x: x, y: y) else { continue }
                let gray = Int(
                    0.114 * Double(pixel.b)
                    + 0.587 * Double(pixel.g)
                    + 0.299 * Double(pixel.r)
                )
                darkMask[y * region.width + x] = gray < darkThreshold
            }
        }
        // Match the Python/OpenCV pipeline: 5×5 close fills small holes,
        // then 5×5 open removes isolated dark noise.
        darkMask = erode(
            dilate(darkMask, width: region.width, height: region.height, radius: 2),
            width: region.width,
            height: region.height,
            radius: 2
        )
        darkMask = dilate(
            erode(darkMask, width: region.width, height: region.height, radius: 2),
            width: region.width,
            height: region.height,
            radius: 2
        )
        
        var bestRect: CGRect?
        var bestScore = -Double.infinity
        var bestRectangularity = 0.0
        var bestRejectedRect: CGRect?
        var bestRejectedRectangularity = 0.0
        var candidateCount = 0
        var visited = [Bool](repeating: false, count: region.width * region.height)
        
        for y in 0..<region.height {
            for x in 0..<region.width {
                let idx = y * region.width + x
                if visited[idx] { continue }
                visited[idx] = true
                guard darkMask[idx] else { continue }
                var stack = [(x, y)]
                var componentPoints: [(Int, Int)] = []
                var minX = x, maxX = x, minY = y, maxY = y
                while let (cx, cy) = stack.popLast() {
                    componentPoints.append((cx, cy))
                    minX = min(minX, cx); maxX = max(maxX, cx)
                    minY = min(minY, cy); maxY = max(maxY, cy)
                    for (nx, ny) in neighbors(x: cx, y: cy, width: region.width, height: region.height) {
                        let nIdx = ny * region.width + nx
                        if visited[nIdx] { continue }
                        visited[nIdx] = true
                        if darkMask[nIdx] {
                            stack.append((nx, ny))
                        }
                    }
                }
                let w = maxX - minX + 1
                let h = maxY - minY + 1
                let rectArea = w * h
                guard rectArea >= minArea / 2 else { continue }
                candidateCount += 1
                
                // OpenCV RETR_EXTERNAL + contourArea counts holes inside the outer
                // contour as part of the contour. Reproduce that behavior instead
                // of using only the number of dark pixels.
                let exteriorArea = exteriorContourArea(
                    componentPoints,
                    minX: minX,
                    minY: minY,
                    width: w,
                    height: h
                )
                let rectangularity = Double(exteriorArea) / Double(max(rectArea, 1))
                let aspect = Double(w) / Double(max(h, 1))
                let rect = CGRect(x: minX, y: minY, width: w, height: h)
                
                if rectangularity > bestRejectedRectangularity {
                    bestRejectedRectangularity = rectangularity
                    bestRejectedRect = rect
                }
                
                guard rectArea >= minArea,
                      w >= 60,
                      h >= 40,
                      w <= maxCandidateWidth,
                      h <= maxCandidateHeight,
                      rectangularity > 0.55,
                      aspect > 0.5,
                      aspect < 4.0 else { continue }
                
                // Prefer a large rectangular component close to the upper-left.
                let originPenalty = Double(minX + minY) * 2
                let score = Double(exteriorArea) - originPenalty
                if score > bestScore {
                    bestScore = score
                    bestRect = rect
                    bestRectangularity = rectangularity
                }
            }
        }
        
        return DarkRegionDetectionResult(
            rect: bestRect,
            threshold: bestRect == nil ? nil : darkThreshold,
            candidateCount: candidateCount,
            bestCandidate: bestRect ?? bestRejectedRect,
            bestRectangularity: bestRect == nil ? bestRejectedRectangularity : bestRectangularity
        )
    }

    private static func detectMinimapByDarkComponentsAndMarkers(
        in image: ImageBuffer,
        searchWidth: Int,
        searchHeight: Int
    ) -> DarkRegionDetectionResult? {
        let sw = min(searchWidth, image.width)
        let sh = min(searchHeight, image.height)
        guard let region = image.cropped(x: 0, y: 0, width: sw, height: sh) else { return nil }

        var bestRect: CGRect?
        var bestScore = -Double.infinity
        var bestMarkerCount = 0
        var totalCandidateCount = 0

        for threshold in [60, 80, 100, 120, 140] {
            if Task.isCancelled { return nil }
            let components = rawDarkComponents(in: region, darkThreshold: threshold)
            totalCandidateCount += components.count
            for component in components {
                if Task.isCancelled { return nil }
                let w = component.maxX - component.minX + 1
                let h = component.maxY - component.minY + 1
                let rectArea = w * h
                guard rectArea >= 2_000,
                      w >= 70,
                      h >= 45,
                      w <= 220,
                      h <= 180 else { continue }

                let aspect = Double(w) / Double(max(h, 1))
                guard aspect >= 0.75 && aspect <= 2.6 else { continue }

                let markerCount = countMinimapMarkerPixels(
                    in: region,
                    minX: component.minX,
                    minY: component.minY,
                    maxX: component.maxX,
                    maxY: component.maxY
                )
                guard markerCount >= 3 else { continue }

                let originPenalty = Double(component.minX + component.minY) * 1.5
                let score = Double(markerCount * 200 + rectArea) - originPenalty
                if score > bestScore {
                    bestScore = score
                    bestMarkerCount = markerCount
                    bestRect = CGRect(x: component.minX, y: component.minY, width: w, height: h)
                }
            }
        }

        guard let bestRect else { return nil }
        return DarkRegionDetectionResult(
            rect: bestRect,
            threshold: nil,
            candidateCount: totalCandidateCount,
            bestCandidate: bestRect,
            bestRectangularity: Double(bestMarkerCount)
        )
    }

    private struct DarkComponent {
        let minX: Int
        let minY: Int
        let maxX: Int
        let maxY: Int
        let area: Int
    }

    private static func rawDarkComponents(
        in region: ImageBuffer,
        darkThreshold: Int
    ) -> [DarkComponent] {
        var darkMask = [Bool](repeating: false, count: region.width * region.height)
        for y in 0..<region.height {
            for x in 0..<region.width {
                guard let pixel = region.pixelBGR(x: x, y: y) else { continue }
                let gray = Int(
                    0.114 * Double(pixel.b)
                    + 0.587 * Double(pixel.g)
                    + 0.299 * Double(pixel.r)
                )
                darkMask[y * region.width + x] = gray < darkThreshold
            }
        }

        var components: [DarkComponent] = []
        var visited = [Bool](repeating: false, count: region.width * region.height)
        for y in 0..<region.height {
            for x in 0..<region.width {
                let idx = y * region.width + x
                if visited[idx] { continue }
                visited[idx] = true
                guard darkMask[idx] else { continue }

                var stack = [(x, y)]
                var minX = x, maxX = x, minY = y, maxY = y
                var area = 0
                while let (cx, cy) = stack.popLast() {
                    area += 1
                    minX = min(minX, cx); maxX = max(maxX, cx)
                    minY = min(minY, cy); maxY = max(maxY, cy)
                    for (nx, ny) in neighbors(x: cx, y: cy, width: region.width, height: region.height) {
                        let nIdx = ny * region.width + nx
                        if visited[nIdx] { continue }
                        visited[nIdx] = true
                        if darkMask[nIdx] {
                            stack.append((nx, ny))
                        }
                    }
                }

                if area >= 40 {
                    components.append(DarkComponent(minX: minX, minY: minY, maxX: maxX, maxY: maxY, area: area))
                }
            }
        }
        return components
    }

    private static func brightHorizontalRuns(in image: ImageBuffer) -> [BrightRun] {
        var runs: [BrightRun] = []
        for y in 0..<image.height {
            var start: Int?
            var lastBright = -1
            var gap = 0
            for x in 0..<image.width {
                let bright = isBrightFramePixelNear(image, x: x, y: y)
                if bright {
                    if start == nil { start = x }
                    lastBright = x
                    gap = 0
                } else if start != nil {
                    gap += 1
                    if gap > 2 {
                        if let start, lastBright - start + 1 >= 80 {
                            runs.append(BrightRun(y: y, startX: start, endX: lastBright))
                        }
                        start = nil
                        lastBright = -1
                        gap = 0
                    }
                }
            }
            if let start, lastBright - start + 1 >= 80 {
                runs.append(BrightRun(y: y, startX: start, endX: lastBright))
            }
        }
        return runs
    }

    private static func brightVerticalSupport(in image: ImageBuffer, x: Int, y1: Int, y2: Int) -> Int {
        guard y2 >= y1 else { return 0 }
        var count = 0
        for y in y1...y2 {
            if isBrightFramePixelNear(image, x: x, y: y) {
                count += 1
            }
        }
        return count
    }

    private static func minimapContentRect(
        in image: ImageBuffer,
        frameLeft: Int,
        frameTop: Int,
        frameRight: Int,
        frameBottom: Int
    ) -> CGRect? {
        let innerLeft = max(0, frameLeft + 2)
        let innerRight = min(image.width - 1, frameRight - 2)
        let innerTop = max(0, frameTop + 2)
        let innerBottom = min(image.height - 1, frameBottom - 2)
        guard innerRight - innerLeft + 1 >= 70,
              innerBottom - innerTop + 1 >= 45 else { return nil }

        var segments: [(start: Int, end: Int)] = []
        var start: Int?
        var lastDark = -1
        var gap = 0

        for y in innerTop...innerBottom {
            let ratio = darkPixelRatio(
                in: image,
                minX: innerLeft,
                minY: y,
                maxX: innerRight,
                maxY: y
            )
            if ratio >= 0.12 {
                if start == nil { start = y }
                lastDark = y
                gap = 0
            } else if start != nil {
                gap += 1
                if gap > 2 {
                    if let start, lastDark - start + 1 >= 30 {
                        segments.append((start, lastDark))
                    }
                    start = nil
                    lastDark = -1
                    gap = 0
                }
            }
        }
        if let start, lastDark - start + 1 >= 30 {
            segments.append((start, lastDark))
        }

        var bestRect: CGRect?
        var bestScore = -Double.infinity

        for segment in segments {
            var minX: Int?
            var maxX: Int?
            for x in innerLeft...innerRight {
                let ratio = darkPixelRatio(
                    in: image,
                    minX: x,
                    minY: segment.start,
                    maxX: x,
                    maxY: segment.end
                )
                if ratio >= 0.08 {
                    minX = min(minX ?? x, x)
                    maxX = max(maxX ?? x, x)
                }
            }
            guard let minX, let maxX else { continue }

            let width = maxX - minX + 1
            let height = segment.end - segment.start + 1
            guard width >= 70, height >= 40 else { continue }

            let markerCount = countMinimapMarkerPixels(
                in: image,
                minX: minX,
                minY: segment.start,
                maxX: maxX,
                maxY: segment.end
            )
            let ratio = darkPixelRatio(
                in: image,
                minX: minX,
                minY: segment.start,
                maxX: maxX,
                maxY: segment.end
            )
            let score = Double(width * height)
                + Double(markerCount * 120)
                + ratio * 1_000
                + Double(segment.start - frameTop) * 4
            if score > bestScore {
                bestScore = score
                bestRect = CGRect(x: minX, y: segment.start, width: width, height: height)
            }
        }

        return bestRect
    }

    private static func isBrightFramePixelNear(_ image: ImageBuffer, x: Int, y: Int) -> Bool {
        for dy in -1...1 {
            for dx in -1...1 {
                let nx = x + dx
                let ny = y + dy
                guard let pixel = image.pixelBGR(x: nx, y: ny) else { continue }
                if isBrightFramePixel(pixel) {
                    return true
                }
            }
        }
        return false
    }

    private static func isBrightFramePixel(_ pixel: (b: UInt8, g: UInt8, r: UInt8)) -> Bool {
        let maxChannel = max(Int(pixel.r), Int(pixel.g), Int(pixel.b))
        let minChannel = min(Int(pixel.r), Int(pixel.g), Int(pixel.b))
        let brightness = (Int(pixel.r) + Int(pixel.g) + Int(pixel.b)) / 3
        return brightness >= 170 && minChannel >= 145 && maxChannel - minChannel <= 90
    }

    private static func darkPixelRatio(
        in image: ImageBuffer,
        minX: Int,
        minY: Int,
        maxX: Int,
        maxY: Int
    ) -> Double {
        var dark = 0
        var total = 0
        for y in minY...maxY {
            for x in minX...maxX {
                guard let pixel = image.pixelBGR(x: x, y: y) else { continue }
                let gray = Int(
                    0.114 * Double(pixel.b)
                    + 0.587 * Double(pixel.g)
                    + 0.299 * Double(pixel.r)
                )
                if gray < 120 {
                    dark += 1
                }
                total += 1
            }
        }
        guard total > 0 else { return 0 }
        return Double(dark) / Double(total)
    }

    private static func brightPixelRatio(
        in image: ImageBuffer,
        minX: Int,
        minY: Int,
        maxX: Int,
        maxY: Int
    ) -> Double {
        guard minX <= maxX, minY <= maxY else { return 1 }
        var bright = 0
        var total = 0
        for y in minY...maxY {
            for x in minX...maxX {
                guard let pixel = image.pixelBGR(x: x, y: y) else { continue }
                if isBrightFramePixel(pixel) {
                    bright += 1
                }
                total += 1
            }
        }
        guard total > 0 else { return 1 }
        return Double(bright) / Double(total)
    }

    private static func countMinimapMarkerPixels(
        in image: ImageBuffer,
        minX: Int,
        minY: Int,
        maxX: Int,
        maxY: Int
    ) -> Int {
        var count = 0
        for y in minY...maxY {
            for x in minX...maxX {
                guard let pixel = image.pixelBGR(x: x, y: y) else { continue }
                let hsv = rgbToOpenCVHSV(r: pixel.r, g: pixel.g, b: pixel.b)
                let isYellow = hsv.h >= 18 && hsv.h <= 45 && hsv.s >= 100 && hsv.v >= 130
                let isBlue = hsv.h >= 80 && hsv.h <= 135 && hsv.s >= 80 && hsv.v >= 90
                let isRed = (hsv.h <= 12 || hsv.h >= 170) && hsv.s >= 100 && hsv.v >= 120
                if isYellow || isBlue || isRed {
                    count += 1
                }
            }
        }
        return count
    }
    
    private static func exteriorContourArea(
        _ points: [(Int, Int)],
        minX: Int,
        minY: Int,
        width: Int,
        height: Int
    ) -> Int {
        guard width > 0, height > 0 else { return 0 }
        let paddedWidth = width + 2
        let paddedHeight = height + 2
        var componentMask = [Bool](repeating: false, count: paddedWidth * paddedHeight)
        for (x, y) in points {
            let localX = x - minX + 1
            let localY = y - minY + 1
            componentMask[localY * paddedWidth + localX] = true
        }
        
        var outside = [Bool](repeating: false, count: componentMask.count)
        var stack = [(0, 0)]
        outside[0] = true
        var outsideInsideBounds = 0
        
        while let (x, y) = stack.popLast() {
            if x > 0, x <= width, y > 0, y <= height {
                outsideInsideBounds += 1
            }
            for (nextX, nextY) in neighbors(x: x, y: y, width: paddedWidth, height: paddedHeight) {
                let index = nextY * paddedWidth + nextX
                if outside[index] || componentMask[index] { continue }
                outside[index] = true
                stack.append((nextX, nextY))
            }
        }
        
        return max(0, width * height - outsideInsideBounds)
    }
    
    private static func dilate(_ mask: [Bool], width: Int, height: Int, radius: Int) -> [Bool] {
        var output = [Bool](repeating: false, count: mask.count)
        for y in 0..<height {
            for x in 0..<width {
                var found = false
                for dy in -radius...radius where !found {
                    let ny = y + dy
                    guard ny >= 0, ny < height else { continue }
                    for dx in -radius...radius {
                        let nx = x + dx
                        if nx >= 0, nx < width, mask[ny * width + nx] {
                            found = true
                            break
                        }
                    }
                }
                output[y * width + x] = found
            }
        }
        return output
    }
    
    private static func erode(_ mask: [Bool], width: Int, height: Int, radius: Int) -> [Bool] {
        var output = [Bool](repeating: false, count: mask.count)
        for y in 0..<height {
            for x in 0..<width {
                var allSet = true
                for dy in -radius...radius where allSet {
                    let ny = y + dy
                    guard ny >= 0, ny < height else {
                        allSet = false
                        break
                    }
                    for dx in -radius...radius {
                        let nx = x + dx
                        if nx < 0 || nx >= width || !mask[ny * width + nx] {
                            allSet = false
                            break
                        }
                    }
                }
                output[y * width + x] = allSet
            }
        }
        return output
    }
    
    private struct ColorBlob {
        let centroid: CGPoint
        let minX: Int
        let area: Int
        let width: Int
        let height: Int
    }

    private static func playerMarkerScore(_ blob: ColorBlob) -> Double {
        let aspect = Double(blob.width) / Double(blob.height)
        let fillRatio = Double(blob.area) / Double(blob.width * blob.height)
        let squarePenalty = abs(log(aspect))
        let sizePenalty = abs(Double(blob.area) - 24) / 24
        return fillRatio * 8 + Double(blob.area) / 20 - squarePenalty * 3 - sizePenalty
    }

    private static func playerMarkerTrackingScore(
        _ blob: ColorBlob,
        near preferredPoint: CGPoint?
    ) -> Double {
        let appearanceScore = playerMarkerScore(blob)
        guard let preferredPoint else { return appearanceScore }
        let distance = hypot(
            blob.centroid.x - preferredPoint.x,
            blob.centroid.y - preferredPoint.y
        )
        return appearanceScore - min(distance, 200) * 0.18
    }
    
    private static func connectedColorBlobs(
        in image: ImageBuffer,
        predicate: (UInt8, UInt8, UInt8) -> Bool
    ) -> [ColorBlob] {
        var blobs: [ColorBlob] = []
        var visited = [Bool](repeating: false, count: image.width * image.height)
        for y in 0..<image.height {
            for x in 0..<image.width {
                let index = y * image.width + x
                if visited[index] { continue }
                visited[index] = true
                guard let pixel = image.pixelBGR(x: x, y: y),
                      predicate(pixel.b, pixel.g, pixel.r) else { continue }
                
                var stack = [(x, y)]
                var area = 0
                var sumX = 0.0
                var sumY = 0.0
                var minX = x, maxX = x, minY = y, maxY = y
                while let (currentX, currentY) = stack.popLast() {
                    area += 1
                    sumX += Double(currentX)
                    sumY += Double(currentY)
                    minX = min(minX, currentX)
                    maxX = max(maxX, currentX)
                    minY = min(minY, currentY)
                    maxY = max(maxY, currentY)
                    
                    for (nextX, nextY) in neighbors(x: currentX, y: currentY, width: image.width, height: image.height) {
                        let nextIndex = nextY * image.width + nextX
                        if visited[nextIndex] { continue }
                        visited[nextIndex] = true
                        guard let nextPixel = image.pixelBGR(x: nextX, y: nextY),
                              predicate(nextPixel.b, nextPixel.g, nextPixel.r) else { continue }
                        stack.append((nextX, nextY))
                    }
                }
                blobs.append(ColorBlob(
                    centroid: CGPoint(x: sumX / Double(area), y: sumY / Double(area)),
                    minX: minX,
                    area: area,
                    width: maxX - minX + 1,
                    height: maxY - minY + 1
                ))
            }
        }
        return blobs
    }
    
    private static func rgbToOpenCVHSV(r: UInt8, g: UInt8, b: UInt8) -> (h: Double, s: Double, v: Double) {
        let rf = Double(r) / 255.0
        let gf = Double(g) / 255.0
        let bf = Double(b) / 255.0
        let maxV = max(rf, gf, bf)
        let minV = min(rf, gf, bf)
        let delta = maxV - minV
        var h = 0.0
        if delta > 0 {
            if maxV == rf {
                h = 60 * (((gf - bf) / delta).truncatingRemainder(dividingBy: 6))
            } else if maxV == gf {
                h = 60 * (((bf - rf) / delta) + 2)
            } else {
                h = 60 * (((rf - gf) / delta) + 4)
            }
        }
        if h < 0 { h += 360 }
        let s = maxV == 0 ? 0 : (delta / maxV) * 255
        let v = maxV * 255
        // OpenCV stores hue in 0...180, while the standard representation is 0...360.
        return (h / 2, s, v)
    }
    
    private static func neighbors(x: Int, y: Int, width: Int, height: Int) -> [(Int, Int)] {
        var result: [(Int, Int)] = []
        for (dx, dy) in [(-1,0),(1,0),(0,-1),(0,1)] {
            let nx = x + dx
            let ny = y + dy
            if nx >= 0 && ny >= 0 && nx < width && ny < height {
                result.append((nx, ny))
            }
        }
        return result
    }
}
