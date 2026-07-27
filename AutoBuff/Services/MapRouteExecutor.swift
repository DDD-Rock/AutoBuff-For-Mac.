import CoreGraphics
import Foundation

@available(macOS 14.0, *)
final class MapRouteExecutor {
    private let human = HumanInput()

    func execute(
        path: PlannedMapPath,
        graph: MapNavigationGraph,
        topology: MapTopology,
        jumpKey: String,
        windowID: CGWindowID,
        minimapRegion: CGRect,
        onFrame: @MainActor @escaping (ImageBuffer, CGPoint?) -> Void,
        onUpdate: @MainActor @escaping (String) -> Void
    ) async throws {
        let walk = MapWalkExecutor(human: human)
        let drop = MapDropExecutor(human: human)
        let special = MapSpecialActionExecutor(human: human)
        var index = 0
        do {
            while index < path.edges.count, !Task.isCancelled {
                let edge = path.edges[index]
                await onUpdate("执行第 \(index + 1)/\(path.edges.count) 步：\(title(edge.kind))")
                if edge.kind == .walk {
                    let suffix = Array(path.edges[index...])
                    let walkCount = suffix.prefix { $0.kind == .walk }.count
                    let subpath = PlannedMapPath(
                        startNodeID: edge.from,
                        targetNodeID: suffix[walkCount - 1].to,
                        edges: suffix,
                        totalCost: 0
                    )
                    try await walk.executeWalkPrefix(
                        path: subpath,
                        graph: graph,
                        topology: topology,
                        windowID: windowID,
                        minimapRegion: minimapRegion,
                        onFrame: onFrame,
                        onUpdate: onUpdate
                    )
                    index += walkCount
                } else if edge.kind == .drop {
                    try await drop.execute(
                        edge: edge,
                        graph: graph,
                        topology: topology,
                        jumpKey: jumpKey,
                        windowID: windowID,
                        minimapRegion: minimapRegion,
                        onFrame: onFrame,
                        onUpdate: onUpdate
                    )
                    index += 1
                } else {
                    try await special.execute(
                        edge: edge,
                        graph: graph,
                        topology: topology,
                        jumpKey: jumpKey,
                        windowID: windowID,
                        minimapRegion: minimapRegion,
                        onFrame: onFrame,
                        onUpdate: onUpdate
                    )
                    index += 1
                }
                if index < path.edges.count {
                    try await Task.sleep(for: .milliseconds(Int.random(in: 80...230)))
                }
            }
            if Task.isCancelled { throw CancellationError() }
            await human.releaseAll()
        } catch {
            await human.releaseAll()
            throw error
        }
    }

    func stop() async { await human.releaseAll() }

    private func title(_ kind: NavigationEdgeKind) -> String {
        switch kind {
        case .walk: return "步行"
        case .drop: return "下落"
        case .climb: return "爬绳"
        case .jumpGrabRope: return "跳抓绳"
        case .approach: return "接近/离绳"
        case .teleport: return "传送"
        case .jump: return "跳跃"
        }
    }
}
