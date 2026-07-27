import CoreGraphics
import Foundation

struct HumanizedDropTiming: Equatable, Sendable {
    var preparationMilliseconds: ClosedRange<Int> = 90...240
    var downLeadMilliseconds: ClosedRange<Int> = 45...110
    var jumpHoldMilliseconds: ClosedRange<Int> = 65...125
    var releaseGapMilliseconds: ClosedRange<Int> = 25...75
    var observationMilliseconds: ClosedRange<Int> = 55...115
    var landingSettleMilliseconds: ClosedRange<Int> = 140...320

    func sample(_ range: ClosedRange<Int>) -> Int { .random(in: range) }
}

@available(macOS 14.0, *)
final class MapDropExecutor {
    enum ExecutionError: LocalizedError {
        case invalidDrop
        case notAtStart
        case playerNotFound
        case timeout

        var errorDescription: String? {
            switch self {
            case .invalidDrop: return "当前路径第一步不是可执行的下落"
            case .notAtStart: return "角色尚未到达下落起点，请先执行步行"
            case .playerNotFound: return "连续多帧未识别到角色黄点"
            case .timeout: return "未在时限内确认落到目标平台"
            }
        }
    }

    private let human: HumanInput
    private let timing: HumanizedDropTiming

    init(human: HumanInput = HumanInput(), timing: HumanizedDropTiming = HumanizedDropTiming()) {
        self.human = human
        self.timing = timing
    }

    func execute(
        edge: NavigationEdge,
        graph: MapNavigationGraph,
        topology: MapTopology,
        jumpKey: String,
        windowID: CGWindowID,
        minimapRegion: CGRect,
        onFrame: @MainActor @escaping (ImageBuffer, CGPoint?) -> Void,
        onUpdate: @MainActor @escaping (String) -> Void
    ) async throws {
        guard edge.kind == .drop,
              let start = edge.actionStartPoint,
              let targetNode = graph.nodes.first(where: { $0.id == edge.to }) else {
            throw ExecutionError.invalidDrop
        }
        let monitor = MinimapMonitor()
        monitor.setWindow(windowID)
        monitor.setMinimapRegion(minimapRegion)
        _ = WindowSelector().bringWindowToFront(windowID: windowID)
        do {
            var missing = 0
            let current = try await detectPlayer(monitor: monitor, missing: &missing, onFrame: onFrame)
            guard abs(current.x - start.x) <= 0.035 else { throw ExecutionError.notAtStart }
            let preparation = timing.sample(timing.preparationMilliseconds)
            await onUpdate("下落前停顿 \(preparation)ms")
            try await Task.sleep(for: .milliseconds(preparation))

            if edge.direction == .neutral {
                let lead = timing.sample(timing.downLeadMilliseconds)
                let hold = timing.sample(timing.jumpHoldMilliseconds)
                var downRelease = timing.sample(timing.releaseGapMilliseconds)
                if downRelease >= hold { downRelease = max(1, hold - 1) }
                await onUpdate("原地下跳：下键提前 \(lead)ms，跳后 \(downRelease)ms 先松下键，再松跳跃键")
                try await human.performDownJump(
                    jumpKey: jumpKey,
                    downLeadMS: lead,
                    jumpHoldMS: hold,
                    downReleaseAfterJumpMS: downRelease
                )
            } else {
                await onUpdate("持续向\(edge.direction == .left ? "左" : "右")走出平台边缘")
                if edge.direction == .left { await human.moveLeft() } else { await human.moveRight() }
                try await waitUntilLeavingPlatform(
                    startY: start.y,
                    monitor: monitor,
                    missing: &missing,
                    onFrame: onFrame
                )
                await human.stopMove()
            }

            try await waitForLanding(
                platformID: targetNode.sourceID,
                topology: topology,
                monitor: monitor,
                missing: &missing,
                onFrame: onFrame
            )
            let settle = timing.sample(timing.landingSettleMilliseconds)
            await onUpdate("已落到目标平台，稳定等待 \(settle)ms")
            try await Task.sleep(for: .milliseconds(settle))
            await human.releaseAll()
        } catch {
            await human.releaseAll()
            throw error
        }
    }

    func stop() async { await human.releaseAll() }

    private func waitUntilLeavingPlatform(
        startY: Double,
        monitor: MinimapMonitor,
        missing: inout Int,
        onFrame: @MainActor @escaping (ImageBuffer, CGPoint?) -> Void
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !Task.isCancelled, ContinuousClock.now < deadline {
            let point = try await detectPlayer(monitor: monitor, missing: &missing, onFrame: onFrame)
            if point.y > startY + 0.035 { return }
            try await Task.sleep(for: .milliseconds(timing.sample(timing.observationMilliseconds)))
        }
        if Task.isCancelled { throw CancellationError() }
        throw ExecutionError.timeout
    }

    private func waitForLanding(
        platformID: UUID,
        topology: MapTopology,
        monitor: MinimapMonitor,
        missing: inout Int,
        onFrame: @MainActor @escaping (ImageBuffer, CGPoint?) -> Void
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !Task.isCancelled, ContinuousClock.now < deadline {
            let point = try await detectPlayer(monitor: monitor, missing: &missing, onFrame: onFrame)
            if isNearPlatform(point, platformID: platformID, topology: topology) { return }
            try await Task.sleep(for: .milliseconds(timing.sample(timing.observationMilliseconds)))
        }
        if Task.isCancelled { throw CancellationError() }
        throw ExecutionError.timeout
    }

    private func detectPlayer(
        monitor: MinimapMonitor,
        missing: inout Int,
        onFrame: @MainActor @escaping (ImageBuffer, CGPoint?) -> Void
    ) async throws -> NormalizedMapPoint {
        while !Task.isCancelled {
            let frame = try await monitor.captureMinimap()
            let detection = await Task.detached(priority: .userInitiated) {
                ColorDetector.detectPlayerMarker(in: frame)
            }.value
            await onFrame(frame, detection.point)
            if let player = detection.point {
                missing = 0
                return NormalizedMapPoint(player, in: CGSize(width: frame.width, height: frame.height))
            }
            missing += 1
            if missing >= 8 { throw ExecutionError.playerNotFound }
            try await Task.sleep(for: .milliseconds(Int.random(in: 70...145)))
        }
        throw CancellationError()
    }

    private func isNearPlatform(_ point: NormalizedMapPoint, platformID: UUID, topology: MapTopology) -> Bool {
        guard let platform = topology.platforms.first(where: { $0.id == platformID }) else { return false }
        return zip(platform.points, platform.points.dropFirst()).contains { start, end in
            guard point.x >= min(start.x, end.x) - 0.05, point.x <= max(start.x, end.x) + 0.05 else { return false }
            let t = abs(end.x - start.x) > 0.000001 ? min(max((point.x - start.x) / (end.x - start.x), 0), 1) : 0
            let y = start.y + (end.y - start.y) * t
            return abs(point.y - y) <= 0.075
        }
    }
}
