import CoreGraphics
import Foundation

@available(macOS 14.0, *)
final class PlatformTraceRecorder {
    enum TraceError: LocalizedError {
        case insufficientSamples

        var errorDescription: String? {
            "有效黄点轨迹不足，请左右移动更长距离后再结束采集"
        }
    }

    private let windowSelector = WindowSelector()
    private let sampleInterval = Duration.milliseconds(120)

    func recordUntilStopped(
        windowID: CGWindowID,
        minimapRegion: CGRect,
        onFrame: @MainActor @escaping (_ frame: ImageBuffer, _ player: CGPoint?, _ samples: [CGPoint]) -> Void
    ) async throws -> [CGPoint] {
        let minimap = MinimapMonitor()
        minimap.setWindow(windowID)
        minimap.setMinimapRegion(minimapRegion)
        var samples: [CGPoint] = []

        // Starting a capture may move focus to the game for convenience, but this
        // recorder never sends movement keys. The user remains in full control.
        _ = windowSelector.bringWindowToFront(windowID: windowID)

        while !Task.isCancelled {
            do {
                let frame = try await minimap.captureMinimap()
                let detection = await Task.detached(priority: .userInitiated) {
                    ColorDetector.detectPlayerMarker(in: frame)
                }.value
                if let player = detection.point {
                    samples.append(player)
                }
                await onFrame(frame, detection.point, samples)
                try await Task.sleep(for: sampleInterval)
            } catch is CancellationError {
                break
            } catch {
                // A transient capture failure should not discard an otherwise
                // useful manual trace. Keep sampling until the user ends it.
                try? await Task.sleep(for: .milliseconds(250))
            }
        }

        guard samples.count >= 5 else { throw TraceError.insufficientSamples }
        return samples
    }
}
