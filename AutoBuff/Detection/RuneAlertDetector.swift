import CoreGraphics
import Foundation

/// 一次「符文诅咒提示横幅」识别的结果。
///
/// 横幅是游戏在角色被符文诅咒期间常驻显示的紫色半透明长条，内容为
/// 「必須解放符文才能解除詛咒!!」。它的视觉结构非常稳定：
/// 上下各有一条贯穿的亮紫色边框线，中间是半透明紫色蒙版和两行文字。
struct RuneAlertDetection: Equatable, Sendable {
    /// 横幅在整窗画面中的像素范围。
    let rect: CGRect
    /// 上下两条边框线中较弱那条的水平覆盖率。
    let lineCoverage: Double
    /// 框内半透明紫色蒙版的像素占比。
    let interiorTint: Double
    /// 综合置信度，0–1。
    let confidence: Double

    var summary: String {
        "符文提示 x=\(Int(rect.minX)) y=\(Int(rect.minY))"
            + " w=\(Int(rect.width)) h=\(Int(rect.height))"
            + "，边线覆盖=\(String(format: "%.2f", lineCoverage))"
            + "，蒙版=\(String(format: "%.2f", interiorTint))"
            + "，置信度=\(String(format: "%.2f", confidence))"
    }
}

/// 符文提示横幅检测器。
///
/// 所有判据都用「相对窗口宽高的比例」表达，因此与游戏分辨率无关，
/// 窗口被任意拉伸（包括改变宽高比）后依然成立。
enum RuneAlertDetector {
    /// 一行要被当作边框线，紫色像素至少要覆盖这么大比例的宽度。
    static let minimumLineCoverage = 0.32
    /// 边框线自身的最长连续段至少要有这么宽，用来排除文字造成的短横线。
    static let minimumLineWidthRatio = 0.30
    /// 上下边框线的垂直间距占窗口高度的合法区间。
    static let minimumSpanRatio = 0.06
    static let maximumSpanRatio = 0.22
    /// 上下边框线的水平重叠，至少要覆盖较窄那条线的这个比例。
    static let minimumHorizontalOverlap = 0.80
    /// 框内半透明紫色蒙版的最低占比。
    static let minimumInteriorTint = 0.25
    /// 隔列采样，识别成本减半；边框线宽达数百像素，不会因此漏检。
    static let columnStride = 2

    /// 置信度归一化用的上界，取自实测样本的典型值。
    private static let strongLineCoverage = 0.55
    private static let strongInteriorTint = 0.45

    private struct BorderLine {
        let topRow: Int
        let bottomRow: Int
        /// 采样列坐标，乘以 `columnStride` 才是真实像素列。
        let left: Int
        let right: Int
        let coverage: Double

        var width: Int { right - left + 1 }
    }

    static func detect(in image: ImageBuffer) -> RuneAlertDetection? {
        guard !image.isEmpty, image.width >= 64, image.height >= 64 else { return nil }

        let sampledColumns = (image.width + columnStride - 1) / columnStride
        guard sampledColumns >= 16 else { return nil }

        let coverage = borderCoveragePerRow(in: image, sampledColumns: sampledColumns)
        let rowGroups = mergeHotRows(coverage: coverage)
        guard rowGroups.count >= 2 else { return nil }

        let gapTolerance = max(2, sampledColumns / 128)
        let minimumLineWidth = Double(sampledColumns) * minimumLineWidthRatio
        let lines = rowGroups.compactMap { group -> BorderLine? in
            let hits = columnHits(in: image, rows: group, sampledColumns: sampledColumns)
            guard let run = longestRun(in: hits, gapTolerance: gapTolerance),
                  Double(run.count) >= minimumLineWidth else { return nil }
            let peak = group.map { coverage[$0] }.max() ?? 0
            return BorderLine(
                topRow: group.lowerBound,
                bottomRow: group.upperBound - 1,
                left: run.lowerBound,
                right: run.upperBound - 1,
                coverage: peak
            )
        }
        guard lines.count >= 2 else { return nil }

        let minimumSpan = Double(image.height) * minimumSpanRatio
        let maximumSpan = Double(image.height) * maximumSpanRatio

        var best: RuneAlertDetection?
        for topIndex in lines.indices {
            let top = lines[topIndex]
            for bottom in lines[(topIndex + 1)...] {
                let span = Double(bottom.bottomRow - top.topRow)
                guard span >= minimumSpan, span <= maximumSpan else { continue }

                let overlapLeft = max(top.left, bottom.left)
                let overlapRight = min(top.right, bottom.right)
                let overlap = overlapRight - overlapLeft + 1
                let narrower = min(top.width, bottom.width)
                guard narrower > 0,
                      Double(overlap) / Double(narrower) >= minimumHorizontalOverlap else {
                    continue
                }

                let interiorRows = (top.bottomRow + 1)..<bottom.topRow
                guard interiorRows.count >= 4 else { continue }
                let tint = interiorTint(
                    in: image,
                    rows: interiorRows,
                    sampledLeft: overlapLeft,
                    sampledRight: overlapRight
                )
                guard tint >= minimumInteriorTint else { continue }

                let lineCoverage = min(top.coverage, bottom.coverage)
                let candidate = RuneAlertDetection(
                    rect: CGRect(
                        x: overlapLeft * columnStride,
                        y: top.topRow,
                        width: overlap * columnStride,
                        height: bottom.bottomRow - top.topRow + 1
                    ),
                    lineCoverage: lineCoverage,
                    interiorTint: tint,
                    confidence: confidence(lineCoverage: lineCoverage, interiorTint: tint)
                )
                if best == nil || candidate.confidence > best!.confidence {
                    best = candidate
                }
            }
        }
        return best
    }

    static func confidence(lineCoverage: Double, interiorTint: Double) -> Double {
        let lineScore = normalize(
            lineCoverage,
            lowerBound: minimumLineCoverage,
            upperBound: strongLineCoverage
        )
        let tintScore = normalize(
            interiorTint,
            lowerBound: minimumInteriorTint,
            upperBound: strongInteriorTint
        )
        return 0.5 * lineScore + 0.5 * tintScore
    }

    /// 边框线像素：明亮的紫/品红，蓝通道明显高于绿，红通道居中。
    static func isBorderPixel(b: Int, g: Int, r: Int) -> Bool {
        b >= 90 && b >= g + 45 && r >= g + 20 && b >= r + 5 && r >= 40
    }

    /// 半透明紫色蒙版覆盖后的像素：蓝高于绿，红略高于绿。
    static func isTintPixel(b: Int, g: Int, r: Int) -> Bool {
        b >= g + 25 && r >= g + 8 && b >= 40
    }

    private static func normalize(_ value: Double, lowerBound: Double, upperBound: Double) -> Double {
        guard upperBound > lowerBound else { return 0 }
        return min(1, max(0, (value - lowerBound) / (upperBound - lowerBound)))
    }

    private static func borderCoveragePerRow(
        in image: ImageBuffer,
        sampledColumns: Int
    ) -> [Double] {
        var coverage = [Double](repeating: 0, count: image.height)
        image.bgr.withUnsafeBufferPointer { pixels in
            for y in 0..<image.height {
                let rowStart = y * image.width
                var hits = 0
                var column = 0
                while column < sampledColumns {
                    let index = (rowStart + column * columnStride) * 3
                    guard index + 2 < pixels.count else { break }
                    if isBorderPixel(
                        b: Int(pixels[index]),
                        g: Int(pixels[index + 1]),
                        r: Int(pixels[index + 2])
                    ) {
                        hits += 1
                    }
                    column += 1
                }
                coverage[y] = Double(hits) / Double(sampledColumns)
            }
        }
        return coverage
    }

    /// 把覆盖率达标的行合并成线段；允许 2 行以内的断裂，容忍抗锯齿。
    private static func mergeHotRows(coverage: [Double]) -> [Range<Int>] {
        var groups: [Range<Int>] = []
        for (row, value) in coverage.enumerated() where value >= minimumLineCoverage {
            if let last = groups.last, row - (last.upperBound - 1) <= 2 {
                groups[groups.count - 1] = last.lowerBound..<(row + 1)
            } else {
                groups.append(row..<(row + 1))
            }
        }
        return groups
    }

    /// 线段内任意一行命中即算该列命中，避免边框被文字或场景压暗时断开。
    private static func columnHits(
        in image: ImageBuffer,
        rows: Range<Int>,
        sampledColumns: Int
    ) -> [Bool] {
        var hits = [Bool](repeating: false, count: sampledColumns)
        image.bgr.withUnsafeBufferPointer { pixels in
            for y in rows {
                let rowStart = y * image.width
                var column = 0
                while column < sampledColumns {
                    if !hits[column] {
                        let index = (rowStart + column * columnStride) * 3
                        guard index + 2 < pixels.count else { break }
                        if isBorderPixel(
                            b: Int(pixels[index]),
                            g: Int(pixels[index + 1]),
                            r: Int(pixels[index + 2])
                        ) {
                            hits[column] = true
                        }
                    }
                    column += 1
                }
            }
        }
        return hits
    }

    /// 找出命中列中最长的一段，允许 `gapTolerance` 以内的空隙。
    private static func longestRun(in hits: [Bool], gapTolerance: Int) -> Range<Int>? {
        var best: Range<Int>?
        var start: Int?
        var lastHit: Int?
        for (column, isHit) in hits.enumerated() {
            guard isHit else { continue }
            if let previous = lastHit, column - previous > gapTolerance {
                if let runStart = start {
                    best = longer(best, runStart..<(previous + 1))
                }
                start = column
            } else if start == nil {
                start = column
            }
            lastHit = column
        }
        if let runStart = start, let previous = lastHit {
            best = longer(best, runStart..<(previous + 1))
        }
        return best
    }

    private static func longer(_ lhs: Range<Int>?, _ rhs: Range<Int>) -> Range<Int> {
        guard let lhs, lhs.count >= rhs.count else { return rhs }
        return lhs
    }

    private static func interiorTint(
        in image: ImageBuffer,
        rows: Range<Int>,
        sampledLeft: Int,
        sampledRight: Int
    ) -> Double {
        var total = 0
        var hits = 0
        image.bgr.withUnsafeBufferPointer { pixels in
            for y in rows {
                let rowStart = y * image.width
                var column = sampledLeft
                while column <= sampledRight {
                    let index = (rowStart + column * columnStride) * 3
                    guard index + 2 < pixels.count else { break }
                    total += 1
                    if isTintPixel(
                        b: Int(pixels[index]),
                        g: Int(pixels[index + 1]),
                        r: Int(pixels[index + 2])
                    ) {
                        hits += 1
                    }
                    column += 1
                }
            }
        }
        return total > 0 ? Double(hits) / Double(total) : 0
    }
}

/// 符文提示状态防抖。
///
/// 单帧误检或单帧漏检都不应该立刻改变对外状态：出现和消失都要求连续
/// 命中若干帧。识别节奏为每秒一帧，因此确认延迟约 1 秒。
struct RuneAlertStabilizer {
    static let requiredConsecutiveDetections = 2
    static let requiredConsecutiveMisses = 2

    private(set) var isPresent = false
    private(set) var consecutiveDetections = 0
    private(set) var consecutiveMisses = 0
    private(set) var latestDetection: RuneAlertDetection?

    /// 返回值表示稳定后的状态是否发生了变化。
    @discardableResult
    mutating func update(_ detection: RuneAlertDetection?) -> Bool {
        if let detection {
            consecutiveMisses = 0
            consecutiveDetections += 1
            latestDetection = detection
            guard !isPresent,
                  consecutiveDetections >= Self.requiredConsecutiveDetections else {
                return false
            }
            isPresent = true
            return true
        }

        consecutiveDetections = 0
        consecutiveMisses += 1
        guard isPresent, consecutiveMisses >= Self.requiredConsecutiveMisses else {
            return false
        }
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
