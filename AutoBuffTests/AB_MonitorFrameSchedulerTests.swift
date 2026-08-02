import CoreGraphics
import CoreVideo
import Testing
@testable import AutoBuff

struct MonitorFrameSchedulerTests {
    @Test func targetsThirtyFramesPerSecond() {
        #expect(MonitorFrameScheduler.targetFramesPerSecond == 30)
        #expect(
            abs(
                MonitorFrameScheduler.targetFrameInterval
                    - (1.0 / 30.0)
            ) < 0.000_001
        )
    }

    @Test func schedulesLowFrequencyWorkWithoutSlowingFrames() {
        #expect(MonitorFrameScheduler.shouldValidateWindow(frameIndex: 0))
        #expect(!MonitorFrameScheduler.shouldValidateWindow(frameIndex: 1))
        #expect(!MonitorFrameScheduler.shouldValidateWindow(frameIndex: 29))
        #expect(MonitorFrameScheduler.shouldValidateWindow(frameIndex: 30))

        #expect(MonitorFrameScheduler.shouldRefreshMapMatch(frameIndex: 0))
        #expect(!MonitorFrameScheduler.shouldRefreshMapMatch(frameIndex: 1))
        #expect(!MonitorFrameScheduler.shouldRefreshMapMatch(frameIndex: 5))
        #expect(MonitorFrameScheduler.shouldRefreshMapMatch(frameIndex: 6))
        #expect(MonitorFrameScheduler.shouldRefreshMapMatch(frameIndex: 12))
    }

    @Test func checksMouseFollowVerificationOnEveryWindowFrame() {
        for frameIndex in 0..<20 {
            #expect(
                MonitorFrameScheduler.shouldDetectMouseFollowVerification(
                    windowFrameIndex: frameIndex
                )
            )
        }
    }

    @Test func latestFrameStreamDropsBufferedOldFrames() async throws {
        let first = ImageBuffer(width: 1, height: 1, bgr: [1, 1, 1])
        let second = ImageBuffer(width: 1, height: 1, bgr: [2, 2, 2])
        let latest = ImageBuffer(width: 1, height: 1, bgr: [3, 3, 3])
        let channel = LatestMinimapFrameStream.make()

        channel.continuation.yield(first)
        channel.continuation.yield(second)
        channel.continuation.yield(latest)

        var iterator = channel.frames.makeAsyncIterator()
        let received = try await iterator.next()
        #expect(received == latest)
        channel.continuation.finish()
    }

    @Test func streamConfigurationCapturesOnlyTheMinimapAtThirtyFPS() {
        let configuration = MonitorStreamConfiguration.make(
            region: CGRect(x: 12.2, y: 30.4, width: 201.2, height: 126.3),
            targetFramesPerSecond: 30
        )

        #expect(configuration.sourceRect == CGRect(x: 12, y: 30, width: 202, height: 127))
        #expect(configuration.width == 202)
        #expect(configuration.height == 127)
        #expect(configuration.queueDepth == 3)
        #expect(configuration.minimumFrameInterval.value == 1)
        #expect(configuration.minimumFrameInterval.timescale == 30)
    }

    @Test func convertsPaddedBGRAPixelBufferWithoutMixingRows() throws {
        var optionalPixelBuffer: CVPixelBuffer?
        let result = CVPixelBufferCreate(
            kCFAllocatorDefault,
            2,
            2,
            kCVPixelFormatType_32BGRA,
            nil,
            &optionalPixelBuffer
        )
        #expect(result == kCVReturnSuccess)
        let pixelBuffer = try #require(optionalPixelBuffer)
        #expect(CVPixelBufferLockBaseAddress(pixelBuffer, []) == kCVReturnSuccess)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let baseAddress = try #require(
            CVPixelBufferGetBaseAddress(pixelBuffer)?.assumingMemoryBound(to: UInt8.self)
        )
        let expected: [[UInt8]] = [
            [10, 20, 30, 255, 40, 50, 60, 255],
            [70, 80, 90, 255, 100, 110, 120, 255],
        ]
        for row in 0..<2 {
            let destination = baseAddress.advanced(by: row * bytesPerRow)
            for (index, value) in expected[row].enumerated() {
                destination[index] = value
            }
        }
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])

        let converted = try #require(ImagePipeline.pixelBufferToBGRBuffer(pixelBuffer))
        #expect(converted.width == 2)
        #expect(converted.height == 2)
        #expect(
            converted.bgr
                == [10, 20, 30, 40, 50, 60, 70, 80, 90, 100, 110, 120]
        )
    }

    @Test func formatsPlayerCoordinatesAndAvailableRange() {
        #expect(
            MonitorCoordinateReadout.positionText(
                CGPoint(x: 128.44, y: 63.26)
            ) == "X 128.4 · Y 63.3"
        )
        #expect(
            MonitorCoordinateReadout.positionText(nil)
                == "X -- · Y --"
        )
        #expect(
            MonitorCoordinateReadout.rangeText(
                contentSize: CGSize(width: 202, height: 127)
            ) == "范围 X 0–201 · Y 0–126"
        )
        #expect(
            MonitorCoordinateReadout.rangeText(contentSize: .zero)
                == "范围 X -- · Y --"
        )
    }

    @Test func transientMapMatchMissesKeepTheCurrentMapUntilTheFifthMiss() {
        let topology = MapTopology(
            mapName: "跳跃测试地图",
            referenceWidth: 202,
            referenceHeight: 127
        )
        var stabilizer = MonitorMapMatchStabilizer()

        #expect(stabilizer.update(candidate: topology)?.mapName == topology.mapName)
        for expectedMisses in 1..<MonitorMapMatchStabilizer.requiredConsecutiveMisses {
            #expect(stabilizer.update(candidate: nil)?.mapName == topology.mapName)
            #expect(stabilizer.consecutiveMisses == expectedMisses)
        }
        #expect(stabilizer.update(candidate: nil) == nil)
        #expect(stabilizer.currentTopology == nil)
        #expect(stabilizer.consecutiveMisses == 0)
    }

    @Test func successfulMatchResetsMissesAndAnotherMapSwitchesImmediately() {
        let first = MapTopology(
            mapName: "第一张地图",
            referenceWidth: 202,
            referenceHeight: 127
        )
        let second = MapTopology(
            mapName: "第二张地图",
            referenceWidth: 180,
            referenceHeight: 110
        )
        var stabilizer = MonitorMapMatchStabilizer()

        _ = stabilizer.update(candidate: first)
        _ = stabilizer.update(candidate: nil)
        _ = stabilizer.update(candidate: nil)
        #expect(stabilizer.consecutiveMisses == 2)

        #expect(stabilizer.update(candidate: first)?.mapName == first.mapName)
        #expect(stabilizer.consecutiveMisses == 0)
        #expect(stabilizer.update(candidate: second)?.mapName == second.mapName)
        #expect(stabilizer.currentTopology?.mapName == second.mapName)
    }

    @Test func playerMarkerUsesACompactDownArrowAboveTheDot() {
        #expect(MapTopologyOverlayRenderer.playerMarkerDiameter == 16)
        #expect(MapTopologyOverlayRenderer.teammateMarkerDiameter == 12)
        #expect(MapTopologyOverlayRenderer.otherPlayerMarkerDiameter == 12)
        let normalPoints = MapTopologyOverlayRenderer.playerArrowPoints(
            for: CGPoint(x: 80, y: 60),
            canvasSize: CGSize(width: 202, height: 127)
        )
        #expect(
            normalPoints
                == [
                    CGPoint(x: 75, y: 42),
                    CGPoint(x: 85, y: 42),
                    CGPoint(x: 80, y: 50),
                ]
        )
        #expect(normalPoints[2].y < 60 - MapTopologyOverlayRenderer.playerMarkerDiameter / 2)

        let edgePoints = MapTopologyOverlayRenderer.playerArrowPoints(
            for: CGPoint(x: 198, y: 4),
            canvasSize: CGSize(width: 202, height: 127)
        )
        #expect(edgePoints.allSatisfy { $0.x >= 0 && $0.x <= 202 })
        #expect(edgePoints.allSatisfy { $0.y >= 0 })
        #expect(edgePoints[2].y < 4)
    }

    @Test func separatesYellowOrangeAndRedPlayerMarkersAndRejectsNoise() {
        let width = 56
        let height = 28
        var pixels = [UInt8](repeating: 20, count: width * height * 3)
        func paint(
            x: Int,
            y: Int,
            width paintWidth: Int,
            height paintHeight: Int,
            b: UInt8,
            g: UInt8,
            r: UInt8
        ) {
            for row in y..<(y + paintHeight) {
                for column in x..<(x + paintWidth) {
                    let index = (row * width + column) * 3
                    pixels[index] = b
                    pixels[index + 1] = g
                    pixels[index + 2] = r
                }
            }
        }

        paint(x: 4, y: 5, width: 4, height: 3, b: 30, g: 45, r: 230)
        paint(x: 28, y: 15, width: 3, height: 4, b: 40, g: 50, r: 210)
        paint(x: 17, y: 2, width: 1, height: 12, b: 25, g: 35, r: 235)
        paint(x: 37, y: 2, width: 18, height: 18, b: 20, g: 30, r: 220)
        paint(x: 20, y: 21, width: 3, height: 3, b: 65, g: 70, r: 105)
        paint(x: 9, y: 18, width: 3, height: 3, b: 20, g: 225, r: 235)
        paint(x: 14, y: 18, width: 3, height: 3, b: 20, g: 130, r: 240)
        paint(x: 24, y: 1, width: 1, height: 10, b: 20, g: 130, r: 240)

        let image = ImageBuffer(width: width, height: height, bgr: pixels)
        let player = ColorDetector.detectPlayerMarker(in: image)
        let teammates = ColorDetector.detectTeammateMarkers(in: image)
        let otherPlayers = ColorDetector.detectOtherPlayerMarkers(in: image)

        #expect(player.point == CGPoint(x: 10, y: 19))
        #expect(teammates.candidateCount == 1)
        #expect(
            teammates.points
                == [
                    CGPoint(x: 15, y: 19),
                ]
        )
        #expect(otherPlayers.candidateCount == 2)
        #expect(
            otherPlayers.points
                == [
                    CGPoint(x: 5.5, y: 6),
                    CGPoint(x: 29, y: 16.5),
                ]
        )
    }
}
