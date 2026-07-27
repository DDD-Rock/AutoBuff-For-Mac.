import CoreGraphics
import Foundation

@available(macOS 14.0, *)
final class MapSpecialActionExecutor {
    enum ExecutionError: LocalizedError {
        case unsupported
        case playerNotFound
        case invalidRopeStaging
        case timeout(String)

        var errorDescription: String? {
            switch self {
            case .unsupported: return "当前路径动作尚不支持执行"
            case .playerNotFound: return "连续多帧未识别到角色黄点"
            case .invalidRopeStaging: return "角色未到达绳索侧下方的有效起跳位置"
            case .timeout(let action): return "\(action)超时，未确认到达目标"
            }
        }
    }

    private let human: HumanInput

    init(human: HumanInput) { self.human = human }

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
        guard let from = graph.nodes.first(where: { $0.id == edge.from }),
              let to = graph.nodes.first(where: { $0.id == edge.to }) else { throw ExecutionError.unsupported }
        let monitor = MinimapMonitor()
        monitor.setWindow(windowID)
        monitor.setMinimapRegion(minimapRegion)
        _ = WindowSelector().bringWindowToFront(windowID: windowID)
        try await Task.sleep(for: .milliseconds(Int.random(in: 120...260)))
        guard !Task.isCancelled else { throw CancellationError() }
        switch edge.kind {
        case .jumpGrabRope:
            try await jumpGrabRope(edge: edge, to: to, topology: topology, jumpKey: jumpKey, monitor: monitor, onFrame: onFrame, onUpdate: onUpdate)
        case .climb:
            try await climb(from: from, to: to, monitor: monitor, onFrame: onFrame, onUpdate: onUpdate)
        case .approach:
            try await approach(from: from, to: to, topology: topology, jumpKey: jumpKey, monitor: monitor, onFrame: onFrame, onUpdate: onUpdate)
        case .teleport:
            try await teleport(to: to, monitor: monitor, onFrame: onFrame, onUpdate: onUpdate)
        default:
            throw ExecutionError.unsupported
        }
    }

    func stop() async { await human.releaseAll() }

    private func jumpGrabRope(
        edge: NavigationEdge,
        to node: NavigationNode,
        topology: MapTopology,
        jumpKey: String,
        monitor: MinimapMonitor,
        onFrame: @MainActor @escaping (ImageBuffer, CGPoint?) -> Void,
        onUpdate: @MainActor @escaping (String) -> Void
    ) async throws {
        guard let rope = topology.ropes.first(where: { $0.id == node.sourceID }) else { throw ExecutionError.unsupported }
        var missing = 0
        let current = try await detect(monitor, missing: &missing, onFrame: onFrame)
        let horizontalOffset = abs(current.x - rope.x)
        guard horizontalOffset >= 0.012,
              horizontalOffset <= 0.12,
              abs(current.y - rope.bottomY) <= 0.13 else {
            throw ExecutionError.invalidRopeStaging
        }
        let direction: HumanInput.Direction
        if edge.direction == .right {
            guard current.x < rope.x else { throw ExecutionError.invalidRopeStaging }
            direction = .right
        } else if edge.direction == .left {
            guard current.x > rope.x else { throw ExecutionError.invalidRopeStaging }
            direction = .left
        } else {
            direction = current.x < rope.x ? .right : .left
        }
        let directionLead = Int.random(in: 35...90)
        let upLead = Int.random(in: 20...55)
        let jumpHold = Int.random(in: (upLead + 45)...175)
        let releaseGap = Int.random(in: 25...80)
        let upHold = Int.random(in: 180...340)
        await onUpdate("起跳点距绳索 X \(String(format: "%.3f", horizontalOffset))；先按方向 \(directionLead)ms，再按跳跃键“\(jumpKey)”，\(upLead)ms 后按上")
        try await human.performJumpGrabRope(
            jumpKey: jumpKey,
            direction: direction,
            directionLeadMS: directionLead,
            upLeadMS: upLead,
            jumpHoldMS: jumpHold,
            directionReleaseGapMS: releaseGap,
            upHoldMS: upHold
        )
        try await waitFor(timeout: 3.5, action: "跳抓绳（未检测到有效起跳）", monitor: monitor, missing: &missing, onFrame: onFrame) { point in
            abs(point.x - rope.x) <= 0.05
                && point.y <= current.y - 0.012
                && point.y >= rope.topY - 0.04
                && point.y <= rope.bottomY + 0.04
        }
    }

    private func climb(
        from: NavigationNode,
        to node: NavigationNode,
        monitor: MinimapMonitor,
        onFrame: @MainActor @escaping (ImageBuffer, CGPoint?) -> Void,
        onUpdate: @MainActor @escaping (String) -> Void
    ) async throws {
        let direction: HumanInput.Direction = node.point.y < from.point.y ? .up : .down
        await onUpdate("持续按住\(direction == .up ? "上" : "下")爬绳")
        await human.holdDirection(direction)
        var missing = 0
        do {
            try await waitFor(timeout: 7, action: "爬绳", monitor: monitor, missing: &missing, onFrame: onFrame) { point in
                direction == .up ? point.y <= node.point.y + 0.025 : point.y >= node.point.y - 0.025
            }
            await human.releaseAll()
            try await Task.sleep(for: .milliseconds(Int.random(in: 100...240)))
        } catch {
            await human.releaseAll()
            throw error
        }
    }

    private func approach(
        from: NavigationNode,
        to: NavigationNode,
        topology: MapTopology,
        jumpKey: String,
        monitor: MinimapMonitor,
        onFrame: @MainActor @escaping (ImageBuffer, CGPoint?) -> Void,
        onUpdate: @MainActor @escaping (String) -> Void
    ) async throws {
        if from.kind == .ropeTop || from.kind == .ropeBottom {
            let direction: HumanInput.Direction = to.point.x < from.point.x ? .left : .right
            let lead = Int.random(in: 45...115)
            let hold = Int.random(in: 70...140)
            let gap = Int.random(in: 25...80)
            await onUpdate("从绳索向\(direction == .left ? "左" : "右")跳离")
            try await human.performRopeDismount(
                jumpKey: jumpKey,
                direction: direction,
                directionLeadMS: lead,
                jumpHoldMS: hold,
                directionReleaseGapMS: gap
            )
            var missing = 0
            try await waitFor(timeout: 4, action: "绳索离开", monitor: monitor, missing: &missing, onFrame: onFrame) { point in
                self.isNearPlatform(point, platformID: to.sourceID, topology: topology)
            }
            return
        }
        if to.kind == .ropeTop {
            await onUpdate("按住下进入绳索")
            await human.holdDirection(.down)
            var missing = 0
            do {
                try await waitFor(timeout: 3, action: "进入绳索", monitor: monitor, missing: &missing, onFrame: onFrame) { point in
                    abs(point.x - to.point.x) <= 0.05 && point.y >= to.point.y + 0.01
                }
                await human.releaseAll()
            } catch {
                await human.releaseAll()
                throw error
            }
            return
        }
        // Platform/portal approach: hold one direction until the target X.
        var missing = 0
        let current = try await detect(monitor, missing: &missing, onFrame: onFrame)
        guard abs(current.x - to.point.x) > 0.015 else { return }
        let direction: HumanInput.Direction = current.x < to.point.x ? .right : .left
        await human.holdDirection(direction)
        do {
            try await waitFor(timeout: 5, action: "接近目标", monitor: monitor, missing: &missing, onFrame: onFrame) { point in
                direction == .right ? point.x >= to.point.x - 0.015 : point.x <= to.point.x + 0.015
            }
            await human.releaseAll()
        } catch {
            await human.releaseAll()
            throw error
        }
    }

    private func teleport(
        to node: NavigationNode,
        monitor: MinimapMonitor,
        onFrame: @MainActor @escaping (ImageBuffer, CGPoint?) -> Void,
        onUpdate: @MainActor @escaping (String) -> Void
    ) async throws {
        await onUpdate("进入传送点")
        await human.tapDirection(.up, holdMS: 180...520, intervalMS: 70...190)
        var missing = 0
        try await waitFor(timeout: 5, action: "传送", monitor: monitor, missing: &missing, onFrame: onFrame) { point in
            hypot(point.x - node.point.x, point.y - node.point.y) <= 0.09
        }
    }

    private func waitFor(
        timeout: Double,
        action: String,
        monitor: MinimapMonitor,
        missing: inout Int,
        onFrame: @MainActor @escaping (ImageBuffer, CGPoint?) -> Void,
        predicate: (NormalizedMapPoint) -> Bool
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while !Task.isCancelled, ContinuousClock.now < deadline {
            let point = try await detect(monitor, missing: &missing, onFrame: onFrame)
            if predicate(point) { return }
            try await Task.sleep(for: .milliseconds(Int.random(in: 55...120)))
        }
        if Task.isCancelled { throw CancellationError() }
        throw ExecutionError.timeout(action)
    }

    private func detect(
        _ monitor: MinimapMonitor,
        missing: inout Int,
        onFrame: @MainActor @escaping (ImageBuffer, CGPoint?) -> Void
    ) async throws -> NormalizedMapPoint {
        while !Task.isCancelled {
            let frame = try await monitor.captureMinimap()
            let result = await Task.detached(priority: .userInitiated) { ColorDetector.detectPlayerMarker(in: frame) }.value
            await onFrame(frame, result.point)
            if let player = result.point {
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
            return abs(point.y - (start.y + (end.y - start.y) * t)) <= 0.08
        }
    }
}
