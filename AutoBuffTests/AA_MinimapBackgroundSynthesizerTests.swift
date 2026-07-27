import Foundation
import Testing
@testable import AutoBuff

struct MinimapBackgroundSynthesizerTests {
    @Test func removesMovingYellowOrangeAndRedMarkers() throws {
        let width = 32
        let height = 18
        var basePixels = [UInt8](repeating: 12, count: width * height * 3)
        for x in 2..<(width - 2) {
            let index = (10 * width + x) * 3
            basePixels[index] = 205
            basePixels[index + 1] = 205
            basePixels[index + 2] = 205
        }
        for y in 3..<6 {
            for x in 25..<28 {
                let index = (y * width + x) * 3
                basePixels[index] = 235
                basePixels[index + 1] = 115
                basePixels[index + 2] = 20
            }
        }
        let base = ImageBuffer(width: width, height: height, bgr: basePixels)
        let markers: [(center: (Int, Int), color: (UInt8, UInt8, UInt8))] = [
            ((5, 9), (0, 245, 255)),
            ((12, 10), (0, 140, 255)),
            ((19, 9), (28, 45, 235)),
        ]
        var frames: [ImageBuffer] = []
        for frameIndex in 0..<12 {
            var pixels = basePixels
            let marker = markers[frameIndex % markers.count]
            let shiftedX = marker.center.0 + frameIndex / markers.count
            for y in (marker.center.1 - 1)...(marker.center.1 + 1) {
                for x in (shiftedX - 1)...(shiftedX + 1) {
                    let index = (y * width + x) * 3
                    pixels[index] = marker.color.0
                    pixels[index + 1] = marker.color.1
                    pixels[index + 2] = marker.color.2
                }
            }
            frames.append(ImageBuffer(width: width, height: height, bgr: pixels))
        }

        let result = try MinimapBackgroundSynthesizer.synthesize(frames: frames)

        #expect(result.buffer == base)
        #expect(result.sampledFrameCount == 12)
        #expect(result.cleanedPixelCount > 0)
        #expect(result.spatiallyRepairedPixelCount == 0)
        #expect(MinimapBackgroundSynthesizer.isMovingMarkerPixel(b: 0, g: 245, r: 255))
        #expect(MinimapBackgroundSynthesizer.isMovingMarkerPixel(b: 0, g: 140, r: 255))
        #expect(MinimapBackgroundSynthesizer.isMovingMarkerPixel(b: 28, g: 45, r: 235))
        #expect(!MinimapBackgroundSynthesizer.isMovingMarkerPixel(b: 235, g: 115, r: 20))
    }

    @Test func repairsPersistentlyCoveredPlatform() throws {
        let width = 25
        let height = 15
        var basePixels = [UInt8](repeating: 10, count: width * height * 3)
        for x in 2..<(width - 2) {
            let index = (7 * width + x) * 3
            basePixels[index] = 220
            basePixels[index + 1] = 220
            basePixels[index + 2] = 220
        }
        var coveredPixels = basePixels
        for y in 5...9 {
            for x in 10...14 {
                let index = (y * width + x) * 3
                coveredPixels[index] = 0
                coveredPixels[index + 1] = 235
                coveredPixels[index + 2] = 255
            }
        }
        let covered = ImageBuffer(width: width, height: height, bgr: coveredPixels)

        let result = try MinimapBackgroundSynthesizer.synthesize(
            frames: [ImageBuffer](repeating: covered, count: 12)
        )
        let repairedCenter = try #require(result.buffer.pixelBGR(x: 12, y: 7))
        let repairedBackground = try #require(result.buffer.pixelBGR(x: 12, y: 5))

        #expect(result.spatiallyRepairedPixelCount > 0)
        #expect(repairedCenter.b > 190)
        #expect(repairedCenter.g > 190)
        #expect(repairedCenter.r > 190)
        #expect(repairedBackground.b < 40)
        #expect(repairedBackground.g < 40)
        #expect(repairedBackground.r < 40)
    }

    @Test func rejectsInconsistentFrames() {
        let first = ImageBuffer(width: 10, height: 8, bgr: [UInt8](repeating: 0, count: 10 * 8 * 3))
        let second = ImageBuffer(width: 11, height: 8, bgr: [UInt8](repeating: 0, count: 11 * 8 * 3))

        do {
            _ = try MinimapBackgroundSynthesizer.synthesize(frames: [first, second])
            Issue.record("尺寸不一致的小地图帧不应允许合成")
        } catch let error as MinimapBackgroundSynthesisError {
            #expect(error == .inconsistentFrameSize)
        } catch {
            Issue.record("收到非预期错误：\(error)")
        }
    }
}
