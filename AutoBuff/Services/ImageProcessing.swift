import Accelerate
import CoreGraphics
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
        
        var summary: String {
            if let point {
                return "玩家黄点 x=\(String(format: "%.1f", point.x)), y=\(String(format: "%.1f", point.y))，面积=\(selectedArea ?? 0)，候选数=\(candidateCount)"
            }
            return "未检测到玩家黄点，候选数=\(candidateCount)"
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
            if let bestCandidate {
                return "未找到合格区域；候选数=\(candidateCount)，最佳候选 x=\(Int(bestCandidate.minX)), y=\(Int(bestCandidate.minY)), w=\(Int(bestCandidate.width)), h=\(Int(bestCandidate.height))，矩形度=\(String(format: "%.2f", bestRectangularity))"
            }
            return "未找到深色连通区域；候选数=\(candidateCount)"
        }
    }
    
    static func findYellowCentroid(in image: ImageBuffer, minArea: Int = 5) -> CGPoint? {
        detectPlayerMarker(in: image, minArea: minArea).point
    }
    
    static func detectPlayerMarker(
        in image: ImageBuffer,
        minArea: Int = 2,
        maxArea: Int = 180
    ) -> PlayerMarkerDetectionResult {
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
        
        let candidates = blobs.filter {
            guard $0.area >= minArea,
                  $0.area <= maxArea,
                  $0.width <= 20,
                  $0.height <= 20,
                  $0.width > 0,
                  $0.height > 0 else { return false }
            let aspect = Double($0.width) / Double($0.height)
            return aspect >= 0.35 && aspect <= 2.8
        }
        
        // Match the Windows/OpenCV behavior: use the largest valid yellow
        // contour. The size bounds above keep unrelated large UI elements out.
        let best = candidates.max { $0.area < $1.area }
        return PlayerMarkerDetectionResult(
            point: best?.centroid,
            candidateCount: candidates.count,
            selectedArea: best?.area
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
    
    static func autoDetectDarkRegion(
        in image: ImageBuffer,
        searchWidth: Int = 480,
        searchHeight: Int = 360,
        darkThreshold: Int = 100,
        minArea: Int = 2_000
    ) -> CGRect? {
        detectDarkRegion(
            in: image,
            searchWidth: searchWidth,
            searchHeight: searchHeight,
            thresholds: [darkThreshold, 120, 140],
            minArea: minArea
        ).rect
    }
    
    static func detectDarkRegion(
        in image: ImageBuffer,
        searchWidth: Int = 480,
        searchHeight: Int = 360,
        thresholds: [Int] = [100, 120, 140],
        minArea: Int = 2_000
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
                minArea: minArea
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
        minArea: Int
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
