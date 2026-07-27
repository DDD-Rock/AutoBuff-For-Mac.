import Foundation

enum NavigationNodeKind: String, Codable, Sendable {
    case platformPoint
    case ropeTop
    case ropeBottom
    case ropePoint
    case portal
}

enum NavigationEdgeKind: String, Codable, Sendable {
    case walk
    case climb
    case approach
    case jump
    case drop
    case jumpGrabRope
    case teleport
}

struct NavigationNode: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var mapName: String
    var point: NormalizedMapPoint
    var kind: NavigationNodeKind
    var sourceID: UUID
}

struct NavigationEdge: Codable, Equatable, Identifiable, Sendable {
    var id: String { "\(from)>\(to):\(kind.rawValue)" }
    var from: String
    var to: String
    var kind: NavigationEdgeKind
    var cost: Double
    var sourceConnectionID: UUID?
    var direction: MapMovementDirection?
    var keyHoldMilliseconds: Int?
    var landingTolerance: Double?
    var jumpKeyReleaseMilliseconds: Int?
    var directionKeyReleaseMilliseconds: Int?
    var actionStartPoint: NormalizedMapPoint?
    var actionEndPoint: NormalizedMapPoint?
    var isVerified: Bool

    init(
        from: String,
        to: String,
        kind: NavigationEdgeKind,
        cost: Double,
        sourceConnectionID: UUID? = nil,
        direction: MapMovementDirection? = nil,
        keyHoldMilliseconds: Int? = nil,
        landingTolerance: Double? = nil,
        jumpKeyReleaseMilliseconds: Int? = nil,
        directionKeyReleaseMilliseconds: Int? = nil,
        actionStartPoint: NormalizedMapPoint? = nil,
        actionEndPoint: NormalizedMapPoint? = nil,
        isVerified: Bool = true
    ) {
        self.from = from
        self.to = to
        self.kind = kind
        self.cost = cost
        self.sourceConnectionID = sourceConnectionID
        self.direction = direction
        self.keyHoldMilliseconds = keyHoldMilliseconds
        self.landingTolerance = landingTolerance
        self.jumpKeyReleaseMilliseconds = jumpKeyReleaseMilliseconds
        self.directionKeyReleaseMilliseconds = directionKeyReleaseMilliseconds
        self.actionStartPoint = actionStartPoint
        self.actionEndPoint = actionEndPoint
        self.isVerified = isVerified
    }
}

struct MapNavigationGraph: Codable, Equatable, Sendable {
    var nodes: [NavigationNode]
    var edges: [NavigationEdge]

    func outgoingEdges(from nodeID: String) -> [NavigationEdge] {
        edges.filter { $0.from == nodeID }
    }
}

enum MapNavigationGraphBuilder {
    static func build(from maps: [MapTopology]) -> MapNavigationGraph {
        var nodes: [NavigationNode] = []
        var edges: [NavigationEdge] = []
        var portalNodeByID: [UUID: NavigationNode] = [:]

        for map in maps {
            var platformNodes: [NavigationNode] = []
            for platform in map.platforms {
                var previous: NavigationNode?
                var expandedPoints: [NormalizedMapPoint] = []
                for (start, end) in zip(platform.points, platform.points.dropFirst()) {
                    if expandedPoints.isEmpty { expandedPoints.append(start) }
                    let segmentLength = distance(start, end)
                    let steps = max(1, Int(ceil(segmentLength / 0.05)))
                    for step in 1...steps {
                        let t = Double(step) / Double(steps)
                        expandedPoints.append(NormalizedMapPoint(
                            x: start.x + (end.x - start.x) * t,
                            y: start.y + (end.y - start.y) * t
                        ))
                    }
                }
                for (index, point) in expandedPoints.enumerated() {
                    let node = NavigationNode(
                        id: "\(map.mapName):platform:\(platform.id):\(index)",
                        mapName: map.mapName,
                        point: point,
                        kind: .platformPoint,
                        sourceID: platform.id
                    )
                    nodes.append(node)
                    platformNodes.append(node)
                    if let previous {
                        addBidirectionalEdge(previous, node, kind: .walk, edges: &edges)
                    }
                    previous = node
                }
            }

            for rope in map.ropes {
                let steps = max(1, Int(ceil((rope.bottomY - rope.topY) / 0.045)))
                let ropeNodes = (0...steps).map { index in
                    let y = rope.topY + (rope.bottomY - rope.topY) * Double(index) / Double(steps)
                    return NavigationNode(
                        id: "\(map.mapName):rope:\(rope.id):\(index)",
                        mapName: map.mapName,
                        point: NormalizedMapPoint(x: rope.x, y: y),
                        kind: index == 0 ? .ropeTop : index == steps ? .ropeBottom : .ropePoint,
                        sourceID: rope.id
                    )
                }
                nodes += ropeNodes
                for (start, end) in zip(ropeNodes, ropeNodes.dropFirst()) {
                    addBidirectionalEdge(start, end, kind: .climb, edges: &edges)
                }
                guard let top = ropeNodes.first, let bottom = ropeNodes.last else { continue }
                connectToNearestPlatform(top, candidates: platformNodes, edges: &edges)
                connectRopeBottomToNearestPlatform(bottom, candidates: platformNodes, edges: &edges)
                connectPlatformsToRope(ropeNodes, candidates: platformNodes, edges: &edges)
            }

            for portal in map.portals {
                let node = NavigationNode(
                    id: "\(map.mapName):portal:\(portal.id)",
                    mapName: map.mapName,
                    point: portal.point,
                    kind: .portal,
                    sourceID: portal.id
                )
                nodes.append(node)
                portalNodeByID[portal.id] = node
                connectToNearestPlatform(node, candidates: platformNodes, edges: &edges)
            }

            for connection in map.traversalConnections where connection.isEnabled {
                guard let source = nearestNode(
                    to: connection.startPoint,
                    sourceID: connection.fromPlatformID,
                    candidates: platformNodes
                ), let target = nearestNode(
                    to: connection.landingPoint,
                    sourceID: connection.toPlatformID,
                    candidates: platformNodes
                ) else { continue }
                edges.append(NavigationEdge(
                    from: source.id,
                    to: target.id,
                    kind: connection.kind == .jump ? .jump : .drop,
                    cost: connection.kind == .jump ? 2.5 : 1.5,
                    sourceConnectionID: connection.id,
                    direction: connection.direction,
                    keyHoldMilliseconds: connection.keyHoldMilliseconds,
                    landingTolerance: connection.landingTolerance,
                    actionStartPoint: connection.startPoint,
                    actionEndPoint: connection.landingPoint,
                    isVerified: connection.isVerified
                ))
            }
            addAutomaticDropEdges(for: map, platformNodes: platformNodes, edges: &edges)
        }

        for map in maps {
            for portal in map.portals {
                guard let source = portalNodeByID[portal.id],
                      let targetID = portal.destinationPortalID,
                      let target = portalNodeByID[targetID],
                      portal.destinationMapName == target.mapName else { continue }
                edges.append(NavigationEdge(from: source.id, to: target.id, kind: .teleport, cost: 1))
            }
        }
        return MapNavigationGraph(nodes: nodes, edges: edges)
    }

    private static func connectToNearestPlatform(
        _ node: NavigationNode,
        candidates: [NavigationNode],
        edges: inout [NavigationEdge]
    ) {
        guard let nearest = candidates.min(by: { distance(node.point, $0.point) < distance(node.point, $1.point) }),
              distance(node.point, nearest.point) <= 0.09 else { return }
        addBidirectionalEdge(node, nearest, kind: .approach, edges: &edges)
    }

    private static func connectRopeBottomToNearestPlatform(
        _ ropeBottom: NavigationNode,
        candidates: [NavigationNode],
        edges: inout [NavigationEdge]
    ) {
        let nearby = candidates.filter {
            distance(ropeBottom.point, $0.point) <= 0.15
                && abs(ropeBottom.point.x - $0.point.x) >= 0.015
                && abs(ropeBottom.point.x - $0.point.x) <= 0.11
        }
        guard let nearest = nearby.min(by: {
            stagingScore($0.point, rope: ropeBottom.point) < stagingScore($1.point, rope: ropeBottom.point)
        }) else { return }
        edges.append(NavigationEdge(
            from: ropeBottom.id,
            to: nearest.id,
            kind: .approach,
            cost: max(0.001, distance(ropeBottom.point, nearest.point))
        ))
    }

    private static func connectPlatformsToRope(
        _ ropeNodes: [NavigationNode],
        candidates: [NavigationNode],
        edges: inout [NavigationEdge]
    ) {
        let groups = Dictionary(grouping: candidates, by: \.sourceID)
        for (_, platformNodes) in groups {
            let possible = platformNodes.compactMap { platformNode -> (NavigationNode, NavigationNode, Double)? in
                let horizontal = abs(platformNode.point.x - ropeNodes[0].point.x)
                guard horizontal >= 0.015, horizontal <= 0.11 else { return nil }
                guard let ropeNode = ropeNodes.min(by: {
                    abs($0.point.y - platformNode.point.y) < abs($1.point.y - platformNode.point.y)
                }) else { return nil }
                let upwardDistance = platformNode.point.y - ropeNode.point.y
                guard upwardDistance >= -0.025, upwardDistance <= 0.065 else { return nil }
                let sidePenalty = platformNode.point.x < ropeNode.point.x ? 0.0 : 0.02
                let score = abs(horizontal - 0.04) + abs(upwardDistance - 0.02) * 0.7 + sidePenalty
                return (platformNode, ropeNode, score)
            }
            guard let best = possible.min(by: { $0.2 < $1.2 }) else { continue }
            let direction: MapMovementDirection = best.0.point.x < best.1.point.x ? .right : .left
            edges.append(NavigationEdge(
                from: best.0.id,
                to: best.1.id,
                kind: .jumpGrabRope,
                cost: 2,
                direction: direction,
                keyHoldMilliseconds: 190,
                landingTolerance: 0.05,
                jumpKeyReleaseMilliseconds: 135,
                directionKeyReleaseMilliseconds: 175,
                actionStartPoint: best.0.point,
                actionEndPoint: best.1.point,
                isVerified: false
            ))
        }
    }

    private static func stagingScore(_ point: NormalizedMapPoint, rope: NormalizedMapPoint) -> Double {
        abs(abs(point.x - rope.x) - 0.04) + abs(point.y - rope.y) * 0.5
    }

    private static func nearestNode(
        to point: NormalizedMapPoint,
        sourceID: UUID,
        candidates: [NavigationNode]
    ) -> NavigationNode? {
        candidates.filter { $0.sourceID == sourceID }.min {
            distance(point, $0.point) < distance(point, $1.point)
        }
    }

    private static func addAutomaticDropEdges(
        for map: MapTopology,
        platformNodes: [NavigationNode],
        edges: inout [NavigationEdge]
    ) {
        var generated: Set<String> = []
        for source in map.platforms where source.points.count >= 2 {
            let sourceMinX = source.points.map(\.x).min() ?? 0
            let sourceMaxX = source.points.map(\.x).max() ?? 0
            var candidates: [(x: Double, direction: MapMovementDirection)] = [
                ((sourceMinX + sourceMaxX) / 2, .neutral),
                (max(0, sourceMinX - 0.012), .left),
                (min(1, sourceMaxX + 0.012), .right),
            ]
            for target in map.platforms where target.id != source.id {
                let targetMinX = target.points.map(\.x).min() ?? 0
                let targetMaxX = target.points.map(\.x).max() ?? 0
                let overlapMin = max(sourceMinX, targetMinX)
                let overlapMax = min(sourceMaxX, targetMaxX)
                if overlapMax - overlapMin >= 0.015 {
                    candidates.append(((overlapMin + overlapMax) / 2, .neutral))
                }
            }

            for candidate in candidates {
                guard let start = platformPoint(on: source, atX: candidate.x, horizontalTolerance: 0.02) else { continue }
                let targets = map.platforms.compactMap { platform -> (MapPlatform, NormalizedMapPoint)? in
                    guard platform.id != source.id,
                          let point = platformPoint(on: platform, atX: candidate.x, horizontalTolerance: 0.025),
                          point.y > start.y + 0.025 else { return nil }
                    return (platform, point)
                }
                guard let landing = targets.min(by: { $0.1.y < $1.1.y }),
                      let sourceNode = nearestNode(to: start, sourceID: source.id, candidates: platformNodes),
                      let targetNode = nearestNode(to: landing.1, sourceID: landing.0.id, candidates: platformNodes) else { continue }
                if candidate.direction == .neutral,
                   verticalDropIntersectsRope(
                    x: candidate.x,
                    startY: start.y,
                    endY: landing.1.y,
                    ropes: map.ropes
                   ) {
                    continue
                }
                let key = "\(source.id):\(landing.0.id):\(candidate.direction.rawValue)"
                guard generated.insert(key).inserted else { continue }
                edges.append(NavigationEdge(
                    from: sourceNode.id,
                    to: targetNode.id,
                    kind: .drop,
                    cost: 1.5,
                    direction: candidate.direction,
                    keyHoldMilliseconds: candidate.direction == .neutral ? 120 : 250,
                    landingTolerance: 0.07,
                    actionStartPoint: start,
                    actionEndPoint: landing.1,
                    isVerified: false
                ))
            }
        }
    }

    private static func verticalDropIntersectsRope(
        x: Double,
        startY: Double,
        endY: Double,
        ropes: [MapRope]
    ) -> Bool {
        let minY = min(startY, endY)
        let maxY = max(startY, endY)
        return ropes.contains { rope in
            abs(rope.x - x) <= 0.035
                && rope.bottomY >= minY + 0.015
                && rope.topY <= maxY - 0.015
        }
    }

    private static func platformPoint(
        on platform: MapPlatform,
        atX x: Double,
        horizontalTolerance: Double = 0.001
    ) -> NormalizedMapPoint? {
        var best: (point: NormalizedMapPoint, horizontalDistance: Double)?
        for (start, end) in zip(platform.points, platform.points.dropFirst()) {
            let minX = min(start.x, end.x)
            let maxX = max(start.x, end.x)
            let clampedX = min(max(x, minX), maxX)
            let t = abs(end.x - start.x) > 0.000001 ? (clampedX - start.x) / (end.x - start.x) : 0
            let point = NormalizedMapPoint(x: clampedX, y: start.y + (end.y - start.y) * t)
            let horizontalDistance = abs(x - clampedX)
            if best == nil || horizontalDistance < best!.horizontalDistance {
                best = (point, horizontalDistance)
            }
        }
        guard let best, best.horizontalDistance <= horizontalTolerance else { return nil }
        return best.point
    }

    private static func addBidirectionalEdge(
        _ lhs: NavigationNode,
        _ rhs: NavigationNode,
        kind: NavigationEdgeKind,
        edges: inout [NavigationEdge]
    ) {
        let cost = max(0.001, distance(lhs.point, rhs.point))
        edges.append(NavigationEdge(from: lhs.id, to: rhs.id, kind: kind, cost: cost))
        edges.append(NavigationEdge(from: rhs.id, to: lhs.id, kind: kind, cost: cost))
    }

    private static func distance(_ lhs: NormalizedMapPoint, _ rhs: NormalizedMapPoint) -> Double {
        hypot(lhs.x - rhs.x, lhs.y - rhs.y)
    }
}
