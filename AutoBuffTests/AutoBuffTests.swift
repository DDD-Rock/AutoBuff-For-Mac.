import CoreGraphics
import Foundation
import Testing
@testable import AutoBuff

struct SettingsManagerTests {
    @Test func loadDefaultWhenMissing() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let manager = SettingsManager(settingsDirectory: tempDir)
        let settings = manager.load()
        #expect(settings.buffs.count == AppConstants.defaultBuffSlotCount)
        #expect(settings.buffs[0].enabled == true)
        #expect(settings.buffs[0].key == "1")
        #expect(settings.preSkillMoveMode == .rightOnly)
    }

    @Test func saveAndLoadRoundTrip() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        var settings = AppSettings.default
        settings.manualPortalX = 42
        settings.manualPortalY = 88
        settings.movementMode = .right
        settings.preSkillMoveMode = .rightOnly
        settings.randomBehaviorValue = 15

        let manager = SettingsManager(settingsDirectory: tempDir)
        manager.save(settings)
        let loaded = manager.load()

        #expect(loaded.manualPortalX == 42)
        #expect(loaded.manualPortalY == 88)
        #expect(loaded.movementMode == .right)
        #expect(loaded.preSkillMoveMode == .rightOnly)
        #expect(loaded.randomBehaviorValue == 15)
    }

    @Test func legacyReturnToMarketMigratesToModeWhenModeMissing() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let json = """
        {
          "returnToMarket": false,
          "buffs": [
            { "id": 1, "enabled": true, "key": "1", "duration": 200 },
            { "id": 2, "enabled": true, "key": "2", "duration": 200 },
            { "id": 3, "enabled": false, "key": "", "duration": 0 }
          ]
        }
        """
        try json.data(using: .utf8)?.write(to: tempDir.appendingPathComponent(AppConstants.settingsFileName))

        let manager = SettingsManager(settingsDirectory: tempDir)
        let loaded = manager.load()

        #expect(loaded.mode == .liveFlower)
        #expect(loaded.returnToMarket == false)
    }

    @Test func followHealModeAndHealKeyPersist() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        var settings = AppSettings.default
        settings.mode = .followHeal
        settings.healSkillKey = "Q"
        settings.healAnchorX = 77
        settings.healAnchorY = 12
        settings.healMinimapRegion = CGRect(x: 8, y: 120, width: 164, height: 86)
        settings.followHealAdjustMinMS = 220
        settings.followHealAdjustMaxMS = 330

        let manager = SettingsManager(settingsDirectory: tempDir)
        manager.save(settings)
        let loaded = manager.load()

        #expect(loaded.mode == .followHeal)
        #expect(loaded.returnToMarket == false)
        #expect(loaded.healSkillKey == "Q")
        #expect(loaded.healAnchorX == 77)
        #expect(loaded.healAnchorY == 12)
        #expect(loaded.healMinimapRegion == CGRect(x: 8, y: 120, width: 164, height: 86))
        #expect(loaded.followHealAdjustMinMS == 220)
        #expect(loaded.followHealAdjustMaxMS == 330)
    }

    @Test func legacyEmptyBuffSlotsCollapseToThree() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        var settings = AppSettings.default
        settings.buffs.append(contentsOf: [
            BuffConfig(id: 4),
            BuffConfig(id: 5),
            BuffConfig(id: 6),
        ])

        let manager = SettingsManager(settingsDirectory: tempDir)
        manager.save(settings)
        let loaded = manager.load()

        #expect(loaded.buffs.count == 3)
    }

    @Test func configuredAdditionalBuffSlotsArePreserved() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        var settings = AppSettings.default
        settings.buffs.append(BuffConfig(id: 4, enabled: true, key: "4", duration: 180))

        let manager = SettingsManager(settingsDirectory: tempDir)
        manager.save(settings)
        let loaded = manager.load()

        #expect(loaded.buffs.count == 4)
        #expect(loaded.buffs[3].key == "4")
    }

    @Test func bgrConversionProducesExpectedDimensions() {
        var bgra = [UInt8](repeating: 0, count: 4 * 4 * 4)
        for i in stride(from: 0, to: bgra.count, by: 4) {
            bgra[i] = 255     // R
            bgra[i + 1] = 0   // G
            bgra[i + 2] = 0   // B
            bgra[i + 3] = 255 // A
        }
        guard let provider = CGDataProvider(data: Data(bgra) as CFData),
              let cgImage = CGImage(
                width: 4, height: 4,
                bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 16,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
              ),
              let buffer = ImagePipeline.cgImageToBGRBuffer(cgImage) else {
            Issue.record("Failed to create test image")
            return
        }
        #expect(buffer.width == 4)
        #expect(buffer.height == 4)
        #expect(buffer.bgr.count == 4 * 4 * 3)
        if let pixel = buffer.pixelBGR(x: 0, y: 0) {
            #expect(pixel.r == 255)
            #expect(pixel.g == 0)
            #expect(pixel.b == 0)
        }
    }

    @Test func bgrConversionPreservesRowOrder() {
        let rgba: [UInt8] = [
            255, 0, 0, 255,   0, 255, 0, 255,
            0, 0, 255, 255,   255, 255, 255, 255,
        ]
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let image = CGImage(
                width: 2, height: 2,
                bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
              ),
              let buffer = ImagePipeline.cgImageToBGRBuffer(image) else {
            Issue.record("Failed to create orientation test image")
            return
        }
        #expect(buffer.pixelBGR(x: 0, y: 0)?.r == 255)
        #expect(buffer.pixelBGR(x: 1, y: 0)?.g == 255)
        #expect(buffer.pixelBGR(x: 0, y: 1)?.b == 255)
    }

    @Test func imageCoordinatesMapToQuartzCoordinatesWithoutYFlip() {
        let point = ImagePipeline.imagePointToScreenPoint(
            CGPoint(x: 50, y: 25),
            imageSize: CGSize(width: 200, height: 100),
            windowBounds: CGRect(x: 100, y: 300, width: 400, height: 200)
        )
        #expect(point == CGPoint(x: 200, y: 350))
    }

    @Test func portalArrivalUsesPointResolutionTolerance() {
        #expect(PortalNavigation.hasArrived(playerX: 30, portalX: 32.5))
        #expect(!PortalNavigation.hasArrived(playerX: 30, portalX: 35))
    }

    @Test func followHealNavigationChoosesDirectionToBase() {
        #expect(FollowHealNavigation.directionToBase(currentX: 104, baseX: 100) == .left)
        #expect(FollowHealNavigation.directionToBase(currentX: 96, baseX: 100) == .right)
        #expect(FollowHealNavigation.directionToBase(currentX: 102.5, baseX: 100) == nil)
    }

    @Test func followHealCenterAdjustmentMovesTowardBaseOrRightWhenCentered() {
        #expect(FollowHealNavigation.directionForCenterAdjustment(currentX: 104, baseX: 100) == .left)
        #expect(FollowHealNavigation.directionForCenterAdjustment(currentX: 96, baseX: 100) == .right)
        #expect(FollowHealNavigation.directionForCenterAdjustment(currentX: 102.5, baseX: 100) == .right)
    }

    @Test func followHealAnchorBandAllowsSmallSideSteps() {
        #expect(!FollowHealNavigation.isOutsideAnchorBand(currentX: 106, baseX: 100))
        #expect(!FollowHealNavigation.isOutsideAnchorBand(currentX: 94, baseX: 100))
        #expect(FollowHealNavigation.isOutsideAnchorBand(currentX: 106.5, baseX: 100))
        #expect(FollowHealNavigation.isOutsideAnchorBand(currentX: 93.5, baseX: 100))
    }

    @Test func followHealCenterAdjustIntervalIsFrequent() {
        for _ in 0..<20 {
            let interval = FollowHealNavigation.nextCenterAdjustInterval()
            #expect(interval >= 12)
            #expect(interval <= 15)
        }
    }

    @Test func keyCodeMapUsesRealMacKeyPositions() {
        #expect(KeyCodeMap.virtualKeyCode(for: "A") == 0x00)
        #expect(KeyCodeMap.virtualKeyCode(for: "B") == 0x0B)
        #expect(KeyCodeMap.virtualKeyCode(for: "Y") == 0x10)
        #expect(KeyCodeMap.virtualKeyCode(for: "1") == 0x12)
        #expect(KeyCodeMap.virtualKeyCode(for: "↑") == 0x7E)
    }

    @Test func countdownStartsAtFinalBuffPress() {
        let next = CountdownTiming.nextRelease(
            pressedAt: 1_000,
            interval: 200,
            earlyBy: 7.5
        )
        #expect(next == 1_192.5)
        #expect(CountdownTiming.remainingSeconds(until: next, now: 1_000) == 193)
        #expect(CountdownTiming.remainingSeconds(until: next, now: 1_000.1) == 193)
        #expect(CountdownTiming.remainingSeconds(until: next, now: 1_192.6) == 0)
    }

    @Test @MainActor
    func countdownPublisherContinuesDecreasing() async {
        let publisher = CountdownPublisher()
        var received: [Int] = []
        publisher.start { info in
            if let value = info[1] {
                received.append(value)
            }
        }

        let now = Date().timeIntervalSince1970
        publisher.replaceDeadlines([1: now + 2], now: now)
        try? await Task.sleep(nanoseconds: 1_250_000_000)
        publisher.stop()

        #expect(received.contains(2))
        #expect(received.contains(1))
    }

    @Test func colorDetectionFindsLargestYellowBlobAndBluePortal() {
        var data = [UInt8](repeating: 0, count: 20 * 12 * 3)
        func paint(x: Int, y: Int, width: Int, height: Int, b: UInt8, g: UInt8, r: UInt8) {
            for row in y..<(y + height) {
                for column in x..<(x + width) {
                    let index = (row * 20 + column) * 3
                    data[index] = b
                    data[index + 1] = g
                    data[index + 2] = r
                }
            }
        }
        paint(x: 1, y: 1, width: 2, height: 3, b: 0, g: 250, r: 250)
        paint(x: 10, y: 5, width: 4, height: 3, b: 0, g: 255, r: 255)
        paint(x: 4, y: 3, width: 3, height: 5, b: 255, g: 0, r: 0)
        let image = ImageBuffer(width: 20, height: 12, bgr: data)

        let player = ColorDetector.findYellowCentroid(in: image)
        let portal = ColorDetector.findBluePortal(in: image)
        #expect(player == CGPoint(x: 11.5, y: 6))
        #expect(portal == CGPoint(x: 5, y: 5))
    }

    @Test func playerDetectionAcceptsResampledYellowMarker() {
        let width = 24
        let height = 14
        var data = [UInt8](repeating: 20, count: width * height * 3)
        for y in 5..<8 {
            for x in 15..<19 {
                let index = (y * width + x) * 3
                data[index] = 38
                data[index + 1] = 205
                data[index + 2] = 220
            }
        }
        let image = ImageBuffer(width: width, height: height, bgr: data)

        let result = ColorDetector.detectPlayerMarker(in: image)
        #expect(result.point == CGPoint(x: 16.5, y: 6))
        #expect(result.selectedArea == 12)
    }

    @Test func playerDetectionRejectsThinYellowUiGlyphs() {
        let width = 40
        let height = 20
        var data = [UInt8](repeating: 20, count: width * height * 3)
        func paint(x: Int, y: Int, width: Int, height: Int, b: UInt8, g: UInt8, r: UInt8) {
            for row in y..<(y + height) {
                for column in x..<(x + width) {
                    let index = (row * 40 + column) * 3
                    data[index] = b
                    data[index + 1] = g
                    data[index + 2] = r
                }
            }
        }

        paint(x: 4, y: 7, width: 4, height: 4, b: 0, g: 255, r: 255)
        paint(x: 26, y: 3, width: 2, height: 12, b: 0, g: 255, r: 255)
        let image = ImageBuffer(width: width, height: height, bgr: data)

        let result = ColorDetector.detectPlayerMarker(in: image)
        #expect(result.point == CGPoint(x: 5.5, y: 8.5))
        #expect(result.selectedArea == 16)
    }

    @Test func darkRegionDetectionClosesSmallHolesAndRejectsNoise() {
        let width = 120
        let height = 90
        var data = [UInt8](repeating: 240, count: width * height * 3)
        func setGray(x: Int, y: Int, value: UInt8) {
            let index = (y * width + x) * 3
            data[index] = value
            data[index + 1] = value
            data[index + 2] = value
        }
        for y in 15..<65 {
            for x in 20..<90 {
                setGray(x: x, y: y, value: 30)
            }
        }
        for x in 30..<80 {
            setGray(x: x, y: 40, value: 240)
        }
        for y in 5..<8 {
            for x in 5..<8 {
                setGray(x: x, y: y, value: 20)
            }
        }

        let image = ImageBuffer(width: width, height: height, bgr: data)
        let region = ColorDetector.autoDetectDarkRegion(
            in: image,
            searchWidth: width,
            searchHeight: height,
            minArea: 2_000
        )
        #expect(region == CGRect(x: 20, y: 15, width: 70, height: 50))
    }

    @Test func darkRegionDetectionUsesExternalContourArea() {
        let width = 160
        let height = 100
        var data = [UInt8](repeating: 230, count: width * height * 3)
        func setGray(x: Int, y: Int, value: UInt8) {
            let index = (y * width + x) * 3
            data[index] = value
            data[index + 1] = value
            data[index + 2] = value
        }

        // A dark rectangular frame with a large bright interior has low dark
        // pixel density, but OpenCV RETR_EXTERNAL sees the whole outer contour.
        for y in 20..<80 {
            for x in 25..<135 {
                let isFrame = x < 33 || x >= 127 || y < 28 || y >= 72
                if isFrame {
                    setGray(x: x, y: y, value: 25)
                }
            }
        }

        let image = ImageBuffer(width: width, height: height, bgr: data)
        let result = ColorDetector.detectDarkRegion(
            in: image,
            searchWidth: width,
            searchHeight: height,
            thresholds: [100],
            minArea: 3_000
        )
        #expect(result.rect == CGRect(x: 25, y: 20, width: 110, height: 60))
        #expect(result.bestRectangularity > 0.9)
    }

    @Test func darkRegionDetectionRejectsOversizedGameBackground() {
        let width = 420
        let height = 260
        var data = [UInt8](repeating: 230, count: width * height * 3)
        func setGray(x: Int, y: Int, value: UInt8) {
            let index = (y * width + x) * 3
            data[index] = value
            data[index + 1] = value
            data[index + 2] = value
        }

        for y in 20..<250 {
            for x in 190..<410 {
                setGray(x: x, y: y, value: 35)
            }
        }
        for y in 70..<150 {
            for x in 35..<165 {
                setGray(x: x, y: y, value: 20)
            }
        }

        let image = ImageBuffer(width: width, height: height, bgr: data)
        let result = ColorDetector.detectDarkRegion(
            in: image,
            searchWidth: width,
            searchHeight: height,
            thresholds: [100],
            minArea: 2_000,
            maxCandidateWidth: 180,
            maxCandidateHeight: 120
        )
        #expect(result.rect == CGRect(x: 35, y: 70, width: 130, height: 80))
    }

    @Test func minimapRegionDetectionPrefersMarkedDarkMapOverBackground() {
        let width = 320
        let height = 240
        var data = [UInt8](repeating: 230, count: width * height * 3)
        func setBGR(x: Int, y: Int, b: UInt8, g: UInt8, r: UInt8) {
            let index = (y * width + x) * 3
            data[index] = b
            data[index + 1] = g
            data[index + 2] = r
        }
        func setGray(x: Int, y: Int, value: UInt8) {
            setBGR(x: x, y: y, b: value, g: value, r: value)
        }

        for y in 20..<230 {
            for x in 180..<315 {
                setGray(x: x, y: y, value: 35)
            }
        }
        for y in 95..<185 {
            for x in 40..<170 {
                setGray(x: x, y: y, value: 25)
            }
        }
        for y in 130..<134 {
            for x in 88..<92 {
                setBGR(x: x, y: y, b: 0, g: 235, r: 255)
            }
        }
        for y in 150..<154 {
            for x in 120..<124 {
                setBGR(x: x, y: y, b: 255, g: 80, r: 20)
            }
        }

        let image = ImageBuffer(width: width, height: height, bgr: data)
        let result = ColorDetector.detectMinimapRegion(in: image, searchWidth: width, searchHeight: height)
        #expect(result.rect == CGRect(x: 40, y: 95, width: 130, height: 90))
    }

    @Test func minimapRegionDetectionPrefersWhiteFrame() {
        let width = 360
        let height = 280
        var data = [UInt8](repeating: 230, count: width * height * 3)
        func setBGR(x: Int, y: Int, b: UInt8, g: UInt8, r: UInt8) {
            let index = (y * width + x) * 3
            data[index] = b
            data[index + 1] = g
            data[index + 2] = r
        }
        func setGray(x: Int, y: Int, value: UInt8) {
            setBGR(x: x, y: y, b: value, g: value, r: value)
        }

        for y in 20..<260 {
            for x in 205..<350 {
                setGray(x: x, y: y, value: 35)
            }
        }

        let left = 8
        let top = 78
        let frameWidth = 176
        let frameHeight = 142
        let right = left + frameWidth - 1
        let bottom = top + frameHeight - 1

        let contentLeft = left + 6
        let contentTop = top + 72
        let contentWidth = frameWidth - 12
        let contentHeight = frameHeight - 84
        for y in contentTop..<(contentTop + contentHeight) {
            for x in contentLeft..<(contentLeft + contentWidth) {
                setGray(x: x, y: y, value: 28)
            }
        }
        for x in left...right {
            setGray(x: x, y: top, value: 245)
            setGray(x: x, y: bottom, value: 245)
        }
        for y in top...bottom {
            setGray(x: left, y: y, value: 245)
            setGray(x: right, y: y, value: 245)
        }
        for y in (contentTop + 16)..<(contentTop + 20) {
            for x in (contentLeft + 45)..<(contentLeft + 49) {
                setBGR(x: x, y: y, b: 0, g: 235, r: 255)
            }
        }
        for y in (contentTop + 34)..<(contentTop + 38) {
            for x in (contentLeft + 86)..<(contentLeft + 90) {
                setBGR(x: x, y: y, b: 255, g: 80, r: 20)
            }
        }

        let image = ImageBuffer(width: width, height: height, bgr: data)
        let result = ColorDetector.detectMinimapRegion(in: image, searchWidth: width, searchHeight: height)
        #expect(result.rect != nil)
        if let rect = result.rect {
            #expect(abs(Int(rect.minX) - contentLeft) <= 2)
            #expect(abs(Int(rect.minY) - contentTop) <= 2)
            #expect(abs(Int(rect.width) - contentWidth) <= 4)
            #expect(abs(Int(rect.height) - contentHeight) <= 4)
        }
    }

    @Test func runtimeTemplatesArePackagedAndReadable() {
        #expect(TemplatePaths.load(TemplatePaths.marketButton) != nil)
        #expect(TemplatePaths.load(TemplatePaths.marketLogo) != nil)
        #expect(TemplatePaths.load(TemplatePaths.confirmButton) != nil)
    }

    @Test func acceleratedTemplateMatcherFindsExactLocation() {
        let templateWidth = 7
        let templateHeight = 5
        var templateData = [UInt8](repeating: 0, count: templateWidth * templateHeight * 3)
        for y in 0..<templateHeight {
            for x in 0..<templateWidth {
                let value = UInt8((x * 31 + y * 47 + x * y * 7) % 255)
                let index = (y * templateWidth + x) * 3
                templateData[index] = value
                templateData[index + 1] = value
                templateData[index + 2] = value
            }
        }
        let template = ImageBuffer(width: templateWidth, height: templateHeight, bgr: templateData)

        let imageWidth = 32
        let imageHeight = 20
        var imageData = [UInt8](repeating: 24, count: imageWidth * imageHeight * 3)
        let expectedX = 13
        let expectedY = 8
        for y in 0..<templateHeight {
            for x in 0..<templateWidth {
                let source = (y * templateWidth + x) * 3
                let destination = ((expectedY + y) * imageWidth + expectedX + x) * 3
                imageData[destination] = templateData[source]
                imageData[destination + 1] = templateData[source + 1]
                imageData[destination + 2] = templateData[source + 2]
            }
        }
        let image = ImageBuffer(width: imageWidth, height: imageHeight, bgr: imageData)
        let result = TemplateMatcher.matchSingleScale(
            image: image,
            template: template,
            scaleX: 1,
            scaleY: 1
        )
        #expect(result?.x == expectedX)
        #expect(result?.y == expectedY)
        #expect((result?.confidence ?? 0) > 0.99)
    }
}
