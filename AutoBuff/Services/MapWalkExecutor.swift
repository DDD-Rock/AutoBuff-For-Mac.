import CoreGraphics
import Foundation

struct HumanizedWalkTiming: Equatable, Sendable {
    var reactionMilliseconds: ClosedRange<Int> = 80...220
    var observationMilliseconds: ClosedRange<Int> = 55...115
    var settleMilliseconds: ClosedRange<Int> = 90...190
    var correctionPauseMilliseconds: ClosedRange<Int> = 120...320

    func sampleReactionMilliseconds() -> Int { .random(in: reactionMilliseconds) }
    func sampleObservationMilliseconds() -> Int { .random(in: observationMilliseconds) }
    func sampleSettleMilliseconds() -> Int { .random(in: settleMilliseconds) }
    func sampleCorrectionPauseMilliseconds() -> Int { .random(in: correctionPauseMilliseconds) }
}

@available(macOS 14.0, *)
final class MapWalkExecutor {
    enum ExecutionError: LocalizedError {
        case noWalkSteps
        case playerNotFound
        case leftExpectedPlatform
        case timeout

        var errorDescription: String? {
            switch self {
            case .noWalkSteps: return "当前路径开头没有可执行的步行步骤"
            case .playerNotFound: return "连续多帧未识别到角色黄点"
            case .leftExpectedPlatform: return "角色已偏离预期平台，执行已停止"
            case .timeout: return "步行超时，执行已停止"
            }
        }
    }

    private let human: HumanInput
    private let timing: HumanizedWalkTiming

    init(human: HumanInput = HumanInput(), timing: HumanizedWalkTiming = HumanizedWalkTiming()) {
        self.human = human
        self.timing = timing
    }

    func executeWalkPrefix(
        path: PlannedMapPath,
        graph: MapNavigationGraph,
        topology: MapTopology,
        windowID: CGWindowID,
        minimapRegion: CGRect,
        onFrame: @MainActor @escaping (_ frame: ImageBuffer, _ player: CGPoint?) -> Void,
        onUpdate: @MainActor @escaping (String) -> Void
    ) async throws {
        let walkEdges = Array(path.edges.prefix { $0.kind == .walk })
        guard !walkEdges.isEmpty else { throw ExecutionError.noWalkSteps }
        let nodes = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0) })
        let monitor = MinimapMonitor()
        monitor.setWindow(windowID)
        monitor.setMinimapRegion(minimapRegion)
        _ = WindowSelector().bringWindowToFront(windowID: windowID)

        do {
            guard let finalEdge = walkEdges.last, let target = nodes[finalEdge.to] else {
                throw ExecutionError.noWalkSteps
            }
            try await executeSingleWalk(
                target: target.point,
                expectedSourceID: target.sourceID,
                topology: topology,
                monitor: monitor,
                onFrame: onFrame,
                onUpdate: onUpdate
            )
            await human.releaseAll()
        } catch {
            await human.releaseAll()
            throw error
        }
    }

    func stop() async { await human.releaseAll() }

    private func executeSingleWalk(
        target: NormalizedMapPoint,
        expectedSourceID: UUID,
        topology: MapTopology,
        monitor: MinimapMonitor,
        onFrame: @MainActor @escaping (_ frame: ImageBuffer, _ player: CGPoint?) -> Void,
        onUpdate: @MainActor @escaping (String) -> Void
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(8)
        var missingFrames = 0
        var point = try await detectPlayer(monitor: monitor, missingFrames: &missingFrames, onFrame: onFrame)
        let tolerance = 0.012
        for correction in 0...2 {
            if abs(point.x - target.x) <= tolerance {
                await human.releaseAll()
                await onUpdate("连续步行已到达")
                return
            }
            let direction: HumanInput.Direction = point.x < target.x ? .right : .left
            let pauseMS = correction == 0
                ? timing.sampleReactionMilliseconds()
                : timing.sampleCorrectionPauseMilliseconds()
            await onUpdate(correction == 0
                ? "\(direction == .left ? "向左" : "向右")持续行走，起步反应 \(pauseMS)ms"
                : "走过目标，停顿 \(pauseMS)ms 后向\(direction == .left ? "左" : "右")微调")
            try await Task.sleep(for: .milliseconds(pauseMS))
            guard !Task.isCancelled else { throw CancellationError() }
            if direction == .left { await human.moveLeft() } else { await human.moveRight() }

            while !Task.isCancelled, ContinuousClock.now < deadline {
                point = try await detectPlayer(monitor: monitor, missingFrames: &missingFrames, onFrame: onFrame)
                guard isNearPlatform(point, platformID: expectedSourceID, topology: topology) else {
                    throw ExecutionError.leftExpectedPlatform
                }
                let reached = direction == .right
                    ? point.x >= target.x - tolerance
                    : point.x <= target.x + tolerance
                if reached {
                    await human.stopMove()
                    let settleMS = timing.sampleSettleMilliseconds()
                    await onUpdate("已松开方向键，等待 \(settleMS)ms 确认位置")
                    try await Task.sleep(for: .milliseconds(settleMS))
                    point = try await detectPlayer(monitor: monitor, missingFrames: &missingFrames, onFrame: onFrame)
                    if abs(point.x - target.x) <= tolerance * 1.5 {
                        await onUpdate("连续步行已到达")
                        return
                    }
                    break
                }
                try await Task.sleep(for: .milliseconds(timing.sampleObservationMilliseconds()))
            }
        }
        if Task.isCancelled { throw CancellationError() }
        throw ExecutionError.timeout
    }

    private func detectPlayer(
        monitor: MinimapMonitor,
        missingFrames: inout Int,
        onFrame: @MainActor @escaping (_ frame: ImageBuffer, _ player: CGPoint?) -> Void
    ) async throws -> NormalizedMapPoint {
        while !Task.isCancelled {
            let frame = try await monitor.captureMinimap()
            let detection = await Task.detached(priority: .userInitiated) {
                ColorDetector.detectPlayerMarker(in: frame)
            }.value
            await onFrame(frame, detection.point)
            if let player = detection.point {
                missingFrames = 0
                return NormalizedMapPoint(player, in: CGSize(width: frame.width, height: frame.height))
            } else {
                missingFrames += 1
                if missingFrames >= 8 { throw ExecutionError.playerNotFound }
                try await Task.sleep(for: .milliseconds(Int.random(in: 70...145)))
            }
        }
        throw CancellationError()
    }

    private func isNearPlatform(_ point: NormalizedMapPoint, platformID: UUID, topology: MapTopology) -> Bool {
        guard let platform = topology.platforms.first(where: { $0.id == platformID }) else { return false }
        return zip(platform.points, platform.points.dropFirst()).contains { start, end in
            let minX = min(start.x, end.x) - 0.04
            let maxX = max(start.x, end.x) + 0.04
            guard point.x >= minX, point.x <= maxX else { return false }
            let t = abs(end.x - start.x) > 0.000001
                ? min(max((point.x - start.x) / (end.x - start.x), 0), 1) : 0
            let y = start.y + (end.y - start.y) * t
            return abs(point.y - y) <= 0.08
        }
    }
}
