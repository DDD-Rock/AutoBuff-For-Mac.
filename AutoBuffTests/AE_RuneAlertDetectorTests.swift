import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import AutoBuff

struct RuneAlertDetectorTests {
    // MARK: - 真实截图回归

    @Test func detectsRuneAlertInEveryCollectedScreenshot() throws {
        let samples = try fixtureImages()
        #expect(samples.count == 9)

        for sample in samples {
            let detection = RuneAlertDetector.detect(in: sample.buffer)
            #expect(detection != nil, "\(sample.name) 应识别出符文提示")
            guard let detection else { continue }
            #expect(detection.confidence > 0.5, "\(sample.name) 置信度过低")

            // 横幅位于画面上半部，垂直高度约占窗口的 12%。
            let height = Double(sample.buffer.height)
            let spanRatio = Double(detection.rect.height) / height
            #expect(spanRatio > 0.08 && spanRatio < 0.20, "\(sample.name) 横幅高度比例异常")
            #expect(Double(detection.rect.minY) / height < 0.45, "\(sample.name) 横幅位置异常")
        }
    }

    @Test func detectsRuneAlertAfterArbitraryWindowStretching() throws {
        let stretchTargets = [
            (width: 640, height: 360),
            (width: 800, height: 600),
            (width: 1_600, height: 600),
            (width: 900, height: 900),
            (width: 1_920, height: 1_080),
            (width: 480, height: 270),
        ]

        for sample in try fixtureImages() {
            for target in stretchTargets {
                let stretched = try #require(
                    resized(sample.cgImage, width: target.width, height: target.height),
                    "\(sample.name) 缩放到 \(target.width)×\(target.height) 失败"
                )
                #expect(
                    RuneAlertDetector.detect(in: stretched) != nil,
                    "\(sample.name) 拉伸到 \(target.width)×\(target.height) 后漏检"
                )
            }
        }
    }

    @Test func ignoresScreenshotsWithoutTheRuneBanner() throws {
        // 用横幅上方的画面覆盖横幅本身，得到「同一张地图但没有符文提示」的负样本。
        for sample in try fixtureImages() {
            let detection = try #require(RuneAlertDetector.detect(in: sample.buffer))
            let cleaned = bannerRemoved(from: sample.buffer, banner: detection.rect)
            #expect(
                RuneAlertDetector.detect(in: cleaned) == nil,
                "\(sample.name) 去掉横幅后不应再识别出符文提示"
            )
        }
    }

    @Test func ignoresDesaturatedAndChannelSwappedFrames() throws {
        for sample in try fixtureImages() {
            #expect(
                RuneAlertDetector.detect(in: desaturated(sample.buffer)) == nil,
                "\(sample.name) 灰度化后不应识别出符文提示"
            )
            #expect(
                RuneAlertDetector.detect(in: redBlueSwapped(sample.buffer)) == nil,
                "\(sample.name) 红蓝通道互换后不应识别出符文提示"
            )
        }
    }

    // MARK: - 结构判据

    @Test func rejectsBannerWhenBorderLinesAreTooShort() {
        let full = syntheticFrame(width: 800, height: 600, bannerWidthRatio: 0.55)
        #expect(RuneAlertDetector.detect(in: full) != nil)

        // 边框线只有窗口宽度的 20%，低于 30% 门槛，应被当作文字或装饰排除。
        let narrow = syntheticFrame(width: 800, height: 600, bannerWidthRatio: 0.20)
        #expect(RuneAlertDetector.detect(in: narrow) == nil)
    }

    @Test func rejectsBorderPairsOutsideTheExpectedVerticalSpan() {
        // 间距只占窗口高度的 3%，远低于真实横幅的 12%。
        let tooClose = syntheticFrame(width: 800, height: 600, spanRatio: 0.03)
        #expect(RuneAlertDetector.detect(in: tooClose) == nil)

        // 间距占 40%，远超真实横幅。
        let tooFar = syntheticFrame(width: 800, height: 600, spanRatio: 0.40)
        #expect(RuneAlertDetector.detect(in: tooFar) == nil)
    }

    @Test func rejectsBorderPairsThatDoNotOverlapHorizontally() {
        // 上下两条线各占一半宽度且左右错开，不构成一个矩形框。
        let frame = syntheticFrame(
            width: 800,
            height: 600,
            bannerWidthRatio: 0.45,
            bottomLineOffsetRatio: 0.50
        )
        #expect(RuneAlertDetector.detect(in: frame) == nil)
    }

    @Test func rejectsBorderPairsWithoutPurpleInterior() {
        let frame = syntheticFrame(width: 800, height: 600, interiorIsPurple: false)
        #expect(RuneAlertDetector.detect(in: frame) == nil)
    }

    @Test func scalesThresholdsWithWindowSizeInsteadOfPixelCounts() {
        for (width, height) in [(400, 300), (1_024, 575), (2_560, 1_440)] {
            let frame = syntheticFrame(width: width, height: height)
            #expect(
                RuneAlertDetector.detect(in: frame) != nil,
                "\(width)×\(height) 合成横幅应被识别"
            )
        }
    }

    @Test func reportsHigherConfidenceForStrongerBanners() {
        let weak = RuneAlertDetector.confidence(lineCoverage: 0.33, interiorTint: 0.26)
        let strong = RuneAlertDetector.confidence(lineCoverage: 0.55, interiorTint: 0.45)
        #expect(weak < 0.15)
        #expect(strong > 0.99)
        #expect(RuneAlertDetector.confidence(lineCoverage: 0.90, interiorTint: 0.90) <= 1.0)
    }

    // MARK: - 防抖

    @Test func requiresTwoConsecutiveFramesBeforeReportingRuneAlert() {
        let detection = RuneAlertDetection(
            rect: CGRect(x: 0, y: 0, width: 10, height: 10),
            lineCoverage: 0.5,
            interiorTint: 0.4,
            confidence: 0.8
        )
        var stabilizer = RuneAlertStabilizer()

        #expect(stabilizer.update(detection) == false)
        #expect(stabilizer.isPresent == false)
        #expect(stabilizer.update(detection) == true)
        #expect(stabilizer.isPresent == true)
        // 状态已稳定后继续命中不再重复上报状态变化。
        #expect(stabilizer.update(detection) == false)
        #expect(stabilizer.isPresent == true)
    }

    @Test func toleratesSingleMissedFrameBeforeClearingRuneAlert() {
        let detection = RuneAlertDetection(
            rect: CGRect(x: 0, y: 0, width: 10, height: 10),
            lineCoverage: 0.5,
            interiorTint: 0.4,
            confidence: 0.8
        )
        var stabilizer = RuneAlertStabilizer()
        _ = stabilizer.update(detection)
        _ = stabilizer.update(detection)
        #expect(stabilizer.isPresent)

        #expect(stabilizer.update(nil) == false)
        #expect(stabilizer.isPresent, "单帧漏检不应立刻清除符文状态")
        #expect(stabilizer.update(nil) == true)
        #expect(stabilizer.isPresent == false)
        #expect(stabilizer.latestDetection == nil)
    }

    @Test func resetClearsStabilizerState() {
        let detection = RuneAlertDetection(
            rect: CGRect(x: 0, y: 0, width: 10, height: 10),
            lineCoverage: 0.5,
            interiorTint: 0.4,
            confidence: 0.8
        )
        var stabilizer = RuneAlertStabilizer()
        _ = stabilizer.update(detection)
        _ = stabilizer.update(detection)
        stabilizer.reset()

        #expect(stabilizer.isPresent == false)
        #expect(stabilizer.latestDetection == nil)
        #expect(stabilizer.update(detection) == false)
    }

    // MARK: - 上报节奏

    @Test func reportsRuneStateChangeImmediately() {
        // 首次上报没有历史状态，必须发送。
        #expect(
            RuneAlertPublishPolicy.shouldSend(
                isPresent: false,
                lastSentState: nil,
                sinceLastSend: .zero
            )
        )
        // 状态刚变化，不等心跳间隔立刻发送。
        #expect(
            RuneAlertPublishPolicy.shouldSend(
                isPresent: true,
                lastSentState: false,
                sinceLastSend: .milliseconds(1)
            )
        )
    }

    @Test func throttlesUnchangedRuneStateToHeartbeatInterval() {
        #expect(
            !RuneAlertPublishPolicy.shouldSend(
                isPresent: true,
                lastSentState: true,
                sinceLastSend: .seconds(1)
            )
        )
        #expect(
            RuneAlertPublishPolicy.shouldSend(
                isPresent: true,
                lastSentState: true,
                sinceLastSend: RuneAlertPublishPolicy.heartbeatInterval
            )
        )
    }

    @Test func heartbeatIsFasterThanServerStaleWindow() {
        // 服务端把超过 12 秒没更新的符文状态视为过期，心跳必须明显更快。
        #expect(RuneAlertPublishPolicy.heartbeatInterval < .seconds(12))
    }

    // MARK: - 识别节奏

    @Test func runsRuneRecognitionAboutOncePerSecond() {
        // EXP 任务每 500ms 抓取一次整窗画面，符文识别复用其中每两帧的一帧。
        #expect(MonitorFrameScheduler.shouldDetectRuneAlert(windowFrameIndex: 0))
        #expect(!MonitorFrameScheduler.shouldDetectRuneAlert(windowFrameIndex: 1))
        #expect(MonitorFrameScheduler.shouldDetectRuneAlert(windowFrameIndex: 2))
        #expect(!MonitorFrameScheduler.shouldDetectRuneAlert(windowFrameIndex: 3))
        #expect(MonitorFrameScheduler.shouldDetectRuneAlert(windowFrameIndex: 4))
    }

    // MARK: - 辅助

    private struct Fixture {
        let name: String
        let cgImage: CGImage
        let buffer: ImageBuffer
    }

    private func fixtureImages() throws -> [Fixture] {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/RuneAlert", isDirectory: true)
        let urls = try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "png" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        return try urls.map { url in
            let source = try #require(
                CGImageSourceCreateWithURL(url as CFURL, nil),
                "无法读取 \(url.lastPathComponent)"
            )
            let cgImage = try #require(
                CGImageSourceCreateImageAtIndex(source, 0, nil),
                "无法解码 \(url.lastPathComponent)"
            )
            let buffer = try #require(
                ImagePipeline.cgImageToBGRBuffer(cgImage),
                "无法转换 \(url.lastPathComponent)"
            )
            return Fixture(name: url.lastPathComponent, cgImage: cgImage, buffer: buffer)
        }
    }

    private func resized(_ image: CGImage, width: Int, height: Int) -> ImageBuffer? {
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return nil
        }
        context.interpolationQuality = .default
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let scaled = context.makeImage() else { return nil }
        return ImagePipeline.cgImageToBGRBuffer(scaled)
    }

    /// 用横幅上方等高的画面内容覆盖横幅，模拟没有符文提示的同一张地图。
    private func bannerRemoved(from image: ImageBuffer, banner: CGRect) -> ImageBuffer {
        let top = max(0, Int(banner.minY))
        let bannerHeight = max(1, Int(banner.height))
        let sourceTop = max(0, top - bannerHeight - 10)
        var pixels = image.bgr
        for row in 0..<bannerHeight {
            let destination = top + row
            let source = sourceTop + row
            guard destination < image.height, source < image.height else { break }
            let destinationStart = destination * image.width * 3
            let sourceStart = source * image.width * 3
            let length = image.width * 3
            pixels.replaceSubrange(
                destinationStart..<(destinationStart + length),
                with: image.bgr[sourceStart..<(sourceStart + length)]
            )
        }
        return ImageBuffer(width: image.width, height: image.height, bgr: pixels)
    }

    private func desaturated(_ image: ImageBuffer) -> ImageBuffer {
        var pixels = image.bgr
        for index in stride(from: 0, to: pixels.count, by: 3) {
            let luminance = UInt8(
                min(
                    255,
                    (Int(pixels[index]) * 29 + Int(pixels[index + 1]) * 150 + Int(pixels[index + 2]) * 77) >> 8
                )
            )
            pixels[index] = luminance
            pixels[index + 1] = luminance
            pixels[index + 2] = luminance
        }
        return ImageBuffer(width: image.width, height: image.height, bgr: pixels)
    }

    private func redBlueSwapped(_ image: ImageBuffer) -> ImageBuffer {
        var pixels = image.bgr
        for index in stride(from: 0, to: pixels.count, by: 3) {
            pixels.swapAt(index, index + 2)
        }
        return ImageBuffer(width: image.width, height: image.height, bgr: pixels)
    }

    /// 合成一张只含结构特征的画面，用来单独验证各项几何判据。
    private func syntheticFrame(
        width: Int,
        height: Int,
        bannerWidthRatio: Double = 0.55,
        spanRatio: Double = 0.12,
        bottomLineOffsetRatio: Double = 0,
        interiorIsPurple: Bool = true
    ) -> ImageBuffer {
        var pixels = [UInt8](repeating: 0, count: width * height * 3)
        // 中性深灰背景，既不满足边框判据也不满足蒙版判据。
        for index in stride(from: 0, to: pixels.count, by: 3) {
            pixels[index] = 40
            pixels[index + 1] = 40
            pixels[index + 2] = 40
        }

        // 边框是高饱和亮紫；框内是半透明紫，只满足蒙版判据、不满足边框判据，
        // 否则整条横幅会被并成一条线而不是上下两条边框。
        let borderBGR: (UInt8, UInt8, UInt8) = (210, 60, 150)
        let interiorBGR: (UInt8, UInt8, UInt8) = interiorIsPurple ? (120, 80, 95) : (60, 60, 60)

        let bannerWidth = Int(Double(width) * bannerWidthRatio)
        let left = (width - bannerWidth) / 2
        let bottomLeft = left + Int(Double(width) * bottomLineOffsetRatio)
        let top = Int(Double(height) * 0.24)
        let bottom = top + max(6, Int(Double(height) * spanRatio))
        let lineThickness = max(2, height / 160)

        func fill(x range: Range<Int>, y rows: Range<Int>, color: (UInt8, UInt8, UInt8)) {
            for y in rows where y >= 0 && y < height {
                for x in range where x >= 0 && x < width {
                    let index = (y * width + x) * 3
                    pixels[index] = color.0
                    pixels[index + 1] = color.1
                    pixels[index + 2] = color.2
                }
            }
        }

        fill(
            x: max(0, left)..<min(width, left + bannerWidth),
            y: (top + lineThickness)..<bottom,
            color: interiorBGR
        )
        fill(
            x: max(0, left)..<min(width, left + bannerWidth),
            y: top..<(top + lineThickness),
            color: borderBGR
        )
        fill(
            x: max(0, bottomLeft)..<min(width, bottomLeft + bannerWidth),
            y: bottom..<(bottom + lineThickness),
            color: borderBGR
        )
        return ImageBuffer(width: width, height: height, bgr: pixels)
    }
}
