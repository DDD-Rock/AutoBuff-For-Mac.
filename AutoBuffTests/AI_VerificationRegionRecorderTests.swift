import CoreGraphics
import Foundation
import Testing
@testable import AutoBuff

struct VerificationRegionRecorderTests {
    @Test @MainActor func outputNameContainsTimestampAndAvoidsCollision() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let date = Date(timeIntervalSince1970: 1_786_092_309)
        let first = VerificationRegionRecorder.availableOutputURL(in: directory, at: date)
        try Data().write(to: first)
        let second = VerificationRegionRecorder.availableOutputURL(in: directory, at: date)

        #expect(first.lastPathComponent.hasPrefix("鼠标跟随验证_"))
        #expect(first.pathExtension == "mp4")
        #expect(second.deletingPathExtension().lastPathComponent.hasSuffix("_2"))
    }

    @Test @MainActor func regionIsClippedAndMadeEncoderSafe() {
        let frame = ImageBuffer(
            width: 121,
            height: 101,
            bgr: [UInt8](repeating: 0, count: 121 * 101 * 3)
        )
        let result = VerificationRegionRecorder.normalized(
            rect: CGRect(x: -3, y: 5, width: 124, height: 97),
            in: frame
        )

        #expect(result == CGRect(x: 0, y: 5, width: 120, height: 96))
    }

    @Test @MainActor func invalidRegionIsRejected() {
        let frame = ImageBuffer(width: 20, height: 20, bgr: [UInt8](repeating: 0, count: 1_200))
        #expect(
            VerificationRegionRecorder.normalized(
                rect: CGRect(x: 30, y: 30, width: 10, height: 10),
                in: frame
            ) == nil
        )
    }
}
