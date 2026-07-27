import CoreGraphics
import Foundation
import Testing
@testable import AutoBuff

struct EXPDataCollectorTests {
    @Test func parsesExpectedEXPFormats() throws {
        let standard = try #require(EXPTextParser.parse("EXP 72384 (0.12%)"))
        #expect(standard.currentEXP == 72_384)
        #expect(standard.percent == 0.12)
        #expect(standard.displayText == "72384 (0.12%)")

        let compact = try #require(EXPTextParser.parse("exp72384(12,50%)"))
        #expect(compact.currentEXP == 72_384)
        #expect(compact.percent == 12.5)
        #expect(compact.displayText == "72384 (12.5%)")

        let pixelFontOCR = try #require(
            EXPTextParser.parse("ĐXP72384[0.12% ]")
        )
        #expect(pixelFontOCR.currentEXP == 72_384)
        #expect(pixelFontOCR.percent == 0.12)
    }

    @Test func rejectsMissingAnchorAndOutOfRangePercentage() {
        #expect(EXPTextParser.parse("72384 (0.12%)") == nil)
        #expect(EXPTextParser.parse("EXP 72384 (101%)") == nil)
        #expect(EXPTextParser.parse("EXP ABC (0.12%)") == nil)
    }

    @Test func requiresConsecutiveMatchingReadings() {
        var stabilizer = EXPReadingStabilizer(requiredMatches: 3)
        let first = reading(exp: 72_384, percent: 0.12)
        let changed = reading(exp: 72_500, percent: 0.2)

        let firstAttempt = stabilizer.update(first)
        let secondAttempt = stabilizer.update(first)
        let thirdAttempt = stabilizer.update(first)
        let changedAttempt = stabilizer.update(changed)
        let missingAttempt = stabilizer.update(nil)

        #expect(!firstAttempt)
        #expect(!secondAttempt)
        #expect(thirdAttempt)
        #expect(!changedAttempt)
        #expect(!missingAttempt)
        #expect(stabilizer.consecutiveMatches == 0)
    }

    @Test func cropsLowerCentralSearchRegion() {
        let rect = EXPFrameRegionExtractor.searchRect(
            frameWidth: 1_000,
            frameHeight: 500
        )

        #expect(rect == CGRect(x: 200, y: 360, width: 600, height: 140))
    }

    @Test func localizesPanelUsingExperienceBarEdges() throws {
        let width = 300
        let height = 100
        var pixels = [UInt8](repeating: 20, count: width * height * 3)
        for y in [55, 72] {
            for x in 70..<222 {
                let index = (y * width + x) * 3
                pixels[index] = 230
                pixels[index + 1] = 230
                pixels[index + 2] = 230
            }
        }
        let source = ImageBuffer(width: width, height: height, bgr: pixels)

        let localized = try #require(
            EXPFrameRegionExtractor.localizedPanelAroundBar(in: source)
        )

        #expect(localized.width < source.width)
        #expect(localized.width >= 165)
        #expect(localized.height >= 35)
    }

    @Test func storesRowsGlyphsManifestAndDeduplicates() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = EXPDatasetStore(rootURL: root)
        let image = ImageBuffer(
            width: 100,
            height: 40,
            bgr: [UInt8](repeating: 180, count: 100 * 40 * 3)
        )
        let reading = EXPTextReading(
            currentEXP: 72_384,
            percent: 0.12,
            rawText: "EXP 72384 (0.12%)",
            confidence: 0.95,
            normalizedLineBox: CGRect(x: 0.1, y: 0.25, width: 0.8, height: 0.5),
            glyphBoxes: [
                EXPGlyphBox(
                    label: "7",
                    normalizedBox: CGRect(x: 0.2, y: 0.35, width: 0.06, height: 0.3)
                ),
                EXPGlyphBox(
                    label: "2",
                    normalizedBox: CGRect(x: 0.27, y: 0.35, width: 0.06, height: 0.3)
                ),
            ],
            preprocessingAgreement: true
        )

        let first = try store.saveAutomatic(
            searchRegion: image,
            reading: reading
        )
        let second = try store.saveAutomatic(
            searchRegion: image,
            reading: reading
        )

        #expect(first.rowURL != nil)
        #expect(first.savedGlyphCount == 2)
        #expect(!first.wasDuplicate)
        #expect(second.wasDuplicate)
        #expect(
            FileManager.default.fileExists(
                atPath: root.appendingPathComponent("manifest.jsonl").path
            )
        )
        #expect(
            try FileManager.default.contentsOfDirectory(
                at: root.appendingPathComponent("chars/auto/7"),
                includingPropertiesForKeys: nil
            ).count == 1
        )
    }

    private func reading(exp: Int, percent: Double) -> EXPTextReading {
        EXPTextReading(
            currentEXP: exp,
            percent: percent,
            rawText: "EXP \(exp) (\(percent)%)",
            confidence: 0.95,
            normalizedLineBox: CGRect(x: 0, y: 0, width: 1, height: 1),
            glyphBoxes: []
        )
    }
}
