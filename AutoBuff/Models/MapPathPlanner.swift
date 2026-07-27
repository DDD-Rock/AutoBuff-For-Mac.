import Foundation

struct PlannedMapPath: Equatable, Sendable {
    var startNodeID: String
    var targetNodeID: String
    var edges: [NavigationEdge]
    var totalCost: Double
}

enum MapPathPlanner {
    static func locateCurrentNode(
        point: NormalizedMapPoint,
        topology: MapTopology,
        graph: MapNavigationGraph
    ) -> NavigationNode? {
        var platformCandidates: [(UUID, Double)] = []
        for platform in topology.platforms {
            let distance = platform.points.dropLast().enumerated().map { index, start in
                pointToSegmentDistance(point, start: start, end: platform.points[index + 1])
            }.min() ?? .infinity
            if distance <= 0.065 { platformCandidates.append((platform.id, distance)) }
        }
        // The player marker often overlaps a rope while the character is still
        // standing on the platform. Prefer a close platform before classifying
        // the same point as climbing the rope.
        let nearestPlatform = platformCandidates.min(by: { $0.1 < $1.1 })
        let ropeCandidates = topology.ropes.compactMap { rope -> (MapRope, Double)? in
            let xDistance = abs(point.x - rope.x)
            guard xDistance <= 0.045,
                  point.y >= rope.topY - 0.04,
                  point.y <= rope.bottomY + 0.04 else { return nil }
            return (rope, xDistance)
        }
        let nearestRope = ropeCandidates.min(by: { $0.1 < $1.1 })
        let candidates: [(UUID, Double)]
        if let nearestRope, nearestRope.1 <= 0.028 {
            let endpointDistance = min(
                abs(point.y - nearestRope.0.topY),
                abs(point.y - nearestRope.0.bottomY)
            )
            let isStandingAtJunction = endpointDistance <= 0.045
                && (nearestPlatform?.1 ?? .infinity) <= 0.018
            candidates = isStandingAtJunction
                ? [(nearestPlatform!.0, nearestPlatform!.1)]
                : [(nearestRope.0.id, nearestRope.1)]
        } else if let nearestPlatform, nearestPlatform.1 <= 0.045 {
            candidates = [nearestPlatform]
        } else {
            var combined = platformCandidates
            combined += ropeCandidates.map { ($0.0.id, $0.1) }
            candidates = combined
        }
        guard let sourceID = candidates.min(by: { $0.1 < $1.1 })?.0 else { return nil }
        return graph.nodes
            .filter { $0.mapName == topology.mapName && $0.sourceID == sourceID }
            .min { distance(point, $0.point) < distance(point, $1.point) }
    }

    static func shortestPath(
        graph: MapNavigationGraph,
        from startNodeID: String,
        targetSourceID: UUID,
        targetMapName: String
    ) -> PlannedMapPath? {
        let targets = Set(graph.nodes.filter {
            $0.mapName == targetMapName && $0.sourceID == targetSourceID
        }.map(\.id))
        guard !targets.isEmpty else { return nil }

        var distances: [String: Double] = [startNodeID: 0]
        var previous: [String: NavigationEdge] = [:]
        var pending = Set(graph.nodes.map(\.id))
        while let current = pending.min(by: {
            distances[$0, default: .infinity] < distances[$1, default: .infinity]
        }) {
            pending.remove(current)
            let currentDistance = distances[current, default: .infinity]
            guard currentDistance.isFinite else { break }
            if targets.contains(current) {
                var path: [NavigationEdge] = []
                var cursor = current
                while cursor != startNodeID, let edge = previous[cursor] {
                    path.append(edge)
                    cursor = edge.from
                }
                guard cursor == startNodeID else { return nil }
                return PlannedMapPath(
                    startNodeID: startNodeID,
                    targetNodeID: current,
                    edges: path.reversed(),
                    totalCost: currentDistance
                )
            }
            for edge in graph.outgoingEdges(from: current) where pending.contains(edge.to) {
                let candidate = currentDistance + edge.cost
                if candidate < distances[edge.to, default: .infinity] {
                    distances[edge.to] = candidate
                    previous[edge.to] = edge
                }
            }
        }
        return nil
    }

    static func isolatedSourceIDs(in graph: MapNavigationGraph, mapName: String) -> Set<UUID> {
        let mapNodes = graph.nodes.filter { $0.mapName == mapName }
        let nodeIDs = Set(mapNodes.map(\.id))
        var adjacency: [String: Set<String>] = [:]
        for edge in graph.edges where nodeIDs.contains(edge.from) && nodeIDs.contains(edge.to) {
            adjacency[edge.from, default: []].insert(edge.to)
            adjacency[edge.to, default: []].insert(edge.from)
        }
        var remaining = nodeIDs
        var components: [Set<String>] = []
        while let seed = remaining.first {
            var component: Set<String> = []
            var stack = [seed]
            remaining.remove(seed)
            while let current = stack.popLast() {
                component.insert(current)
                for neighbor in adjacency[current, default: []] where remaining.remove(neighbor) != nil {
                    stack.append(neighbor)
                }
            }
            components.append(component)
        }
        guard let primary = components.max(by: { $0.count < $1.count }) else { return [] }
        return Set(mapNodes.filter { !primary.contains($0.id) }.map(\.sourceID))
    }

    private static func pointToSegmentDistance(
        _ point: NormalizedMapPoint,
        start: NormalizedMapPoint,
        end: NormalizedMapPoint
    ) -> Double {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0.000001 else { return distance(point, start) }
        let t = min(max(((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared, 0), 1)
        return hypot(point.x - (start.x + t * dx), point.y - (start.y + t * dy))
    }

    private static func distance(_ lhs: NormalizedMapPoint, _ rhs: NormalizedMapPoint) -> Double {
        hypot(lhs.x - rhs.x, lhs.y - rhs.y)
    }
}
