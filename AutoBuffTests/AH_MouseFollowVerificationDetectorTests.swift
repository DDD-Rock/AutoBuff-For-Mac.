import CoreGraphics
import Testing
@testable import AutoBuff

struct MouseFollowVerificationDetectorTests {
    @Test func detectsPopupWithoutDependingOnItsWindowRatioOrPosition() throws {
        let cases = [
            (canvas: (800, 600), popup: CGRect(x: 180, y: 120, width: 420, height: 260)),
            // 相同弹窗放进更大的游戏分辨率后，占整窗比例明显变小。
            (canvas: (1_920, 1_080), popup: CGRect(x: 760, y: 360, width: 420, height: 260)),
            (canvas: (1_280, 1_000), popup: CGRect(x: 90, y: 410, width: 520, height: 300)),
            (canvas: (640, 480), popup: CGRect(x: 80, y: 80, width: 480, height: 290)),
        ]

        for item in cases {
            let frame = syntheticFrame(
                width: item.canvas.0,
                height: item.canvas.1,
                bodyRect: item.popup,
                includesBrightTarget: false
            )
            let detection = MouseFollowVerificationDetector.detect(in: frame)
            #expect(detection != nil, "\(item.canvas) 中任意位置和占比的验证弹窗都应命中")
            #expect(try #require(detection).confidence >= 0.65)
        }
    }

    @Test func doesNotRequireTheCentralWhiteShape() {
        let withTarget = syntheticFrame(
            width: 1_000,
            height: 700,
            bodyRect: CGRect(x: 250, y: 180, width: 500, height: 300),
            includesBrightTarget: true
        )
        let fadedTarget = syntheticFrame(
            width: 1_000,
            height: 700,
            bodyRect: CGRect(x: 250, y: 180, width: 500, height: 300),
            includesBrightTarget: false
        )

        let bright = MouseFollowVerificationDetector.detect(in: withTarget)
        let faded = MouseFollowVerificationDetector.detect(in: fadedTarget)
        #expect(bright != nil)
        #expect(faded != nil)
        #expect((bright?.confidence ?? 0) >= (faded?.confidence ?? 0))
    }

    @Test func acceptsModeratelyStretchedInternalBody() {
        for size in [(360, 300), (620, 240), (700, 360)] {
            let frame = syntheticFrame(
                width: 1_200,
                height: 800,
                bodyRect: CGRect(x: 200, y: 180, width: size.0, height: size.1),
                includesBrightTarget: false
            )
            #expect(
                MouseFollowVerificationDetector.detect(in: frame) != nil,
                "弹窗主体 \(size.0)×\(size.1) 被拉伸后仍应命中"
            )
        }
    }

    @Test func rejectsLargeGoldRegionWithoutAlignedDarkBars() {
        var frame = syntheticFrame(
            width: 1_000,
            height: 700,
            bodyRect: CGRect(x: 220, y: 180, width: 560, height: 320),
            includesBrightTarget: false
        )
        paint(
            &frame,
            rect: CGRect(x: 200, y: 100, width: 600, height: 80),
            bgr: (150, 80, 30)
        )
        paint(
            &frame,
            rect: CGRect(x: 200, y: 500, width: 600, height: 90),
            bgr: (150, 80, 30)
        )
        #expect(MouseFollowVerificationDetector.detect(in: frame) == nil)
    }

    @Test func rejectsDarkFramedPanelWithoutCenteredTitleGlyphs() {
        let frame = syntheticFrame(
            width: 1_000,
            height: 700,
            bodyRect: CGRect(x: 220, y: 180, width: 560, height: 320),
            includesBrightTarget: false,
            includesTitleGlyphs: false
        )
        #expect(MouseFollowVerificationDetector.detect(in: frame) == nil)
    }

    @Test func rejectsSmallGoldUIElement() {
        let frame = syntheticFrame(
            width: 1_000,
            height: 700,
            bodyRect: CGRect(x: 450, y: 300, width: 120, height: 80),
            includesBrightTarget: true
        )
        #expect(MouseFollowVerificationDetector.detect(in: frame) == nil)
    }

    @Test func strongStructureTriggersImmediatelyButWeakStructureNeedsTwoFrames() {
        let strong = detection(confidence: 0.90)
        var immediate = MouseFollowVerificationStabilizer()
        let immediateChange = immediate.update(strong)
        #expect(immediateChange)
        #expect(immediate.isPresent)

        let weak = detection(confidence: 0.60)
        var cautious = MouseFollowVerificationStabilizer()
        let firstWeakChange = cautious.update(weak)
        let secondWeakChange = cautious.update(weak)
        #expect(!firstWeakChange)
        #expect(secondWeakChange)
        #expect(cautious.isPresent)
    }

    @Test func requiresTwoMissesBeforeClearing() {
        var stabilizer = MouseFollowVerificationStabilizer()
        stabilizer.update(detection(confidence: 0.90))
        let firstMissChange = stabilizer.update(nil)
        #expect(!firstMissChange)
        #expect(stabilizer.isPresent)
        let secondMissChange = stabilizer.update(nil)
        #expect(secondMissChange)
        #expect(!stabilizer.isPresent)
    }

    private func detection(confidence: Double) -> MouseFollowVerificationDetection {
        MouseFollowVerificationDetection(
            rect: CGRect(x: 10, y: 10, width: 300, height: 260),
            bodyRect: CGRect(x: 10, y: 50, width: 300, height: 180),
            goldCoverage: 0.82,
            titleBarDarkCoverage: 0.68,
            instructionBarDarkCoverage: 0.68,
            titleGlyphCoverage: 0.06,
            brightTargetCoverage: 0,
            confidence: confidence
        )
    }

    private func syntheticFrame(
        width: Int,
        height: Int,
        bodyRect: CGRect,
        includesBrightTarget: Bool,
        includesTitleGlyphs: Bool = true
    ) -> ImageBuffer {
        var pixels = [UInt8](repeating: 0, count: width * height * 3)
        paint(
            &pixels,
            width: width,
            height: height,
            rect: CGRect(x: 0, y: 0, width: width, height: height),
            bgr: (155, 86, 38)
        )

        let titleHeight = bodyRect.height * 0.18
        let instructionHeight = bodyRect.height * 0.22
        let expandedX = bodyRect.minX - bodyRect.width * 0.025
        let expandedWidth = bodyRect.width * 1.05
        let titleRect = CGRect(
            x: expandedX,
            y: bodyRect.minY - titleHeight,
            width: expandedWidth,
            height: titleHeight
        )
        let instructionRect = CGRect(
            x: expandedX,
            y: bodyRect.maxY,
            width: expandedWidth,
            height: instructionHeight
        )
        paint(&pixels, width: width, height: height, rect: titleRect, bgr: (48, 48, 48))
        paint(&pixels, width: width, height: height, rect: instructionRect, bgr: (48, 48, 48))
        paint(&pixels, width: width, height: height, rect: bodyRect, bgr: (82, 154, 205))

        // 少量深色裂缝模拟金色石块纹理，但保持主体为高覆盖率连通域。
        var x = Int(bodyRect.minX) + 18
        while x < Int(bodyRect.maxX) {
            paint(
                &pixels,
                width: width,
                height: height,
                rect: CGRect(
                    x: CGFloat(x),
                    y: bodyRect.minY + 8,
                    width: 2,
                    height: bodyRect.height - 16
                ),
                bgr: (55, 95, 130)
            )
            x += 31
        }

        if includesTitleGlyphs {
            let glyphY = titleRect.midY - titleRect.height * 0.16
            let glyphHeight = max(4, titleRect.height * 0.32)
            for offset in stride(from: -0.16, through: 0.16, by: 0.08) {
                paint(
                    &pixels,
                    width: width,
                    height: height,
                    rect: CGRect(
                        x: titleRect.midX + titleRect.width * offset,
                        y: glyphY,
                        width: max(3, titleRect.width * 0.025),
                        height: glyphHeight
                    ),
                    bgr: (215, 215, 215)
                )
            }
        }

        if includesBrightTarget {
            paint(
                &pixels,
                width: width,
                height: height,
                rect: CGRect(
                    x: bodyRect.midX - bodyRect.width * 0.06,
                    y: bodyRect.midY - bodyRect.height * 0.08,
                    width: bodyRect.width * 0.12,
                    height: bodyRect.height * 0.16
                ),
                bgr: (255, 255, 255)
            )
        }
        return ImageBuffer(width: width, height: height, bgr: pixels)
    }

    private func paint(
        _ image: inout ImageBuffer,
        rect: CGRect,
        bgr: (UInt8, UInt8, UInt8)
    ) {
        var pixels = image.bgr
        paint(&pixels, width: image.width, height: image.height, rect: rect, bgr: bgr)
        image = ImageBuffer(width: image.width, height: image.height, bgr: pixels)
    }

    private func paint(
        _ pixels: inout [UInt8],
        width: Int,
        height: Int,
        rect: CGRect,
        bgr: (UInt8, UInt8, UInt8)
    ) {
        let minX = max(0, Int(rect.minX.rounded(.down)))
        let minY = max(0, Int(rect.minY.rounded(.down)))
        let maxX = min(width, Int(rect.maxX.rounded(.up)))
        let maxY = min(height, Int(rect.maxY.rounded(.up)))
        guard minX < maxX, minY < maxY else { return }
        for y in minY..<maxY {
            for x in minX..<maxX {
                let index = (y * width + x) * 3
                pixels[index] = bgr.0
                pixels[index + 1] = bgr.1
                pixels[index + 2] = bgr.2
            }
        }
    }
}
