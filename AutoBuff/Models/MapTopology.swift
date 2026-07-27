import CoreGraphics
import Foundation

struct NormalizedMapPoint: Codable, Equatable, Sendable {
    var x: Double
    var y: Double

    init(x: Double, y: Double) {
        self.x = min(max(x, 0), 1)
        self.y = min(max(y, 0), 1)
    }

    init(_ point: CGPoint, in size: CGSize) {
        self.init(
            x: size.width > 0 ? point.x / size.width : 0,
            y: size.height > 0 ? point.y / size.height : 0
        )
    }

    func point(in size: CGSize) -> CGPoint {
        CGPoint(x: x * size.width, y: y * size.height)
    }
}

struct MapPlatform: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var points: [NormalizedMapPoint]

    init(id: UUID = UUID(), points: [NormalizedMapPoint]) {
        self.id = id
        self.points = points
    }
}

struct MapRope: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var x: Double
    var topY: Double
    var bottomY: Double

    init(id: UUID = UUID(), x: Double, topY: Double, bottomY: Double) {
        self.id = id
        self.x = min(max(x, 0), 1)
        self.topY = min(max(min(topY, bottomY), 0), 1)
        self.bottomY = min(max(max(topY, bottomY), 0), 1)
    }
}

enum MapPortalType: String, Codable, CaseIterable, Sendable {
    case normal
    case mapExit
    case specialEntrance
    case intraMap

    var title: String {
        switch self {
        case .normal: return "普通传送门"
        case .mapExit: return "地图出口"
        case .specialEntrance: return "特殊入口"
        case .intraMap: return "当前地图传送"
        }
    }
}

struct MapPortal: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var point: NormalizedMapPoint
    var type: MapPortalType
    var destinationMapName: String?
    var destinationPortalID: UUID?

    init(
        id: UUID = UUID(),
        point: NormalizedMapPoint,
        type: MapPortalType = .normal,
        destinationMapName: String? = nil,
        destinationPortalID: UUID? = nil
    ) {
        self.id = id
        self.point = point
        self.type = type
        self.destinationMapName = destinationMapName
        self.destinationPortalID = destinationPortalID
    }
}

enum MapTraversalKind: String, Codable, CaseIterable, Sendable {
    case jump
    case drop

    var title: String { self == .jump ? "跳跃" : "下落" }
}

enum MapMovementDirection: String, Codable, Sendable {
    case left
    case right
    case neutral
}

struct MapTraversalConnection: Codable, Equatable, Identifiable, Sendable {
    var id: UUID
    var kind: MapTraversalKind
    var fromPlatformID: UUID
    var toPlatformID: UUID
    var startPoint: NormalizedMapPoint
    var landingPoint: NormalizedMapPoint
    var direction: MapMovementDirection
    var keyHoldMilliseconds: Int
    var landingTolerance: Double
    var isEnabled: Bool
    var isVerified: Bool
    var successCount: Int
    var failureCount: Int

    init(
        id: UUID = UUID(),
        kind: MapTraversalKind,
        fromPlatformID: UUID,
        toPlatformID: UUID,
        startPoint: NormalizedMapPoint,
        landingPoint: NormalizedMapPoint,
        direction: MapMovementDirection,
        keyHoldMilliseconds: Int = 300,
        landingTolerance: Double = 0.06,
        isEnabled: Bool = true,
        isVerified: Bool = false,
        successCount: Int = 0,
        failureCount: Int = 0
    ) {
        self.id = id
        self.kind = kind
        self.fromPlatformID = fromPlatformID
        self.toPlatformID = toPlatformID
        self.startPoint = startPoint
        self.landingPoint = landingPoint
        self.direction = direction
        self.keyHoldMilliseconds = min(max(keyHoldMilliseconds, 50), 2000)
        self.landingTolerance = min(max(landingTolerance, 0.01), 0.2)
        self.isEnabled = isEnabled
        self.isVerified = isVerified
        self.successCount = max(0, successCount)
        self.failureCount = max(0, failureCount)
    }
}

struct MapTopology: Codable, Equatable, Sendable {
    static let currentVersion = 4

    var version: Int
    var mapName: String
    var referenceWidth: Int
    var referenceHeight: Int
    var visualSignature: [UInt8]?
    var referenceBGR: Data?
    var platforms: [MapPlatform]
    var ropes: [MapRope]
    var portals: [MapPortal]
    var traversalConnections: [MapTraversalConnection]

    init(
        version: Int = currentVersion,
        mapName: String = "",
        referenceWidth: Int,
        referenceHeight: Int,
        visualSignature: [UInt8]? = nil,
        referenceBGR: Data? = nil,
        platforms: [MapPlatform] = [],
        ropes: [MapRope] = [],
        portals: [MapPortal] = [],
        traversalConnections: [MapTraversalConnection] = []
    ) {
        self.version = version
        self.mapName = mapName
        self.referenceWidth = referenceWidth
        self.referenceHeight = referenceHeight
        self.visualSignature = visualSignature
        self.referenceBGR = referenceBGR
        self.platforms = platforms
        self.ropes = ropes
        self.portals = portals
        self.traversalConnections = traversalConnections
    }

    var isEmpty: Bool { platforms.isEmpty && ropes.isEmpty && portals.isEmpty && traversalConnections.isEmpty }

    private enum CodingKeys: String, CodingKey {
        case version, mapName, referenceWidth, referenceHeight
        case visualSignature, referenceBGR, platforms, ropes, portals, traversalConnections
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        _ = try container.decodeIfPresent(Int.self, forKey: .version)
        version = Self.currentVersion
        mapName = try container.decodeIfPresent(String.self, forKey: .mapName) ?? ""
        referenceWidth = try container.decode(Int.self, forKey: .referenceWidth)
        referenceHeight = try container.decode(Int.self, forKey: .referenceHeight)
        visualSignature = try container.decodeIfPresent([UInt8].self, forKey: .visualSignature)
        referenceBGR = try container.decodeIfPresent(Data.self, forKey: .referenceBGR)
        platforms = try container.decodeIfPresent([MapPlatform].self, forKey: .platforms) ?? []
        ropes = try container.decodeIfPresent([MapRope].self, forKey: .ropes) ?? []
        portals = try container.decodeIfPresent([MapPortal].self, forKey: .portals) ?? []
        traversalConnections = try container.decodeIfPresent([MapTraversalConnection].self, forKey: .traversalConnections) ?? []
    }
}

enum MinimapVisualMatcher {
    static let columns = 24
    static let rows = 16
    static let minimumMatchPercentage = 60.0

    struct Comparison: Equatable, Sendable {
        let similarityPercentage: Double
        let isMatch: Bool
        let appearanceDistance: Double
        let structuralMismatch: Double
        let usesScaleTolerance: Bool
    }

    static func signature(for image: ImageBuffer) -> [UInt8] {
        guard image.width > 0, image.height > 0 else { return [] }
        return (0..<rows).flatMap { row in
            (0..<columns).map { column in
                let x0 = column * image.width / columns
                let x1 = max(x0 + 1, (column + 1) * image.width / columns)
                let y0 = row * image.height / rows
                let y1 = max(y0 + 1, (row + 1) * image.height / rows)
                var values: [Int] = []
                for y in y0..<min(y1, image.height) {
                    for x in x0..<min(x1, image.width) {
                        guard let pixel = image.pixelBGR(x: x, y: y) else { continue }
                        // Ignore highly saturated moving markers (player/portals).
                        let channels = [Int(pixel.b), Int(pixel.g), Int(pixel.r)]
                        if (channels.max() ?? 0) - (channels.min() ?? 0) > 90 { continue }
                        values.append((29 * Int(pixel.b) + 150 * Int(pixel.g) + 77 * Int(pixel.r)) >> 8)
                    }
                }
                return UInt8(values.max() ?? 0)
            }
        }
    }

    static func distance(_ lhs: [UInt8], _ rhs: [UInt8]) -> Double {
        guard lhs.count == columns * rows, rhs.count == lhs.count else { return .infinity }
        var differences = zip(lhs, rhs).map { abs(Int($0) - Int($1)) }.sorted()
        // Player and portal markers move between captures. They only occupy a
        // handful of cells, so exclude the largest local changes and compare
        // the stable minimap geometry instead.
        differences.removeLast(differences.count * 6 / 100)
        return Double(differences.reduce(0, +)) / Double(differences.count)
    }

    static func matches(_ lhs: [UInt8], _ rhs: [UInt8]) -> Bool {
        comparison(lhs, rhs).isMatch
    }

    static func comparison(_ lhs: [UInt8], _ rhs: [UInt8]) -> Comparison {
        guard lhs.count == columns * rows, rhs.count == lhs.count else {
            return Comparison(
                similarityPercentage: 0,
                isMatch: false,
                appearanceDistance: .infinity,
                structuralMismatch: 1,
                usesScaleTolerance: false
            )
        }

        let exactDistance = distance(lhs, rhs)
        let exactStructure = structuralMismatch(lhs, rhs, searchRadius: 0)
        let scaledDistance = spatiallyTolerantDistance(lhs, rhs)
        let scaledStructure = structuralMismatch(lhs, rhs, searchRadius: 1)
        let exactPenalty = similarityPenalty(
            appearanceDistance: exactDistance,
            structuralMismatch: exactStructure
        )
        let scaledPenalty = similarityPenalty(
            appearanceDistance: scaledDistance,
            structuralMismatch: scaledStructure
        )
        let usesScaleTolerance = scaledPenalty < exactPenalty
        let selectedDistance = usesScaleTolerance ? scaledDistance : exactDistance
        let selectedStructure = usesScaleTolerance ? scaledStructure : exactStructure
        let selectedPenalty = min(exactPenalty, scaledPenalty)
        let rawSimilarityPercentage = max(0, min(100, (1 - selectedPenalty) * 100))
        let similarityPercentage = (rawSimilarityPercentage * 10).rounded() / 10
        let isMatch = similarityPercentage >= minimumMatchPercentage

        return Comparison(
            similarityPercentage: similarityPercentage,
            isMatch: isMatch,
            appearanceDistance: selectedDistance,
            structuralMismatch: selectedStructure,
            usesScaleTolerance: usesScaleTolerance
        )
    }

    private static func similarityPenalty(
        appearanceDistance: Double,
        structuralMismatch: Double
    ) -> Double {
        let normalizedAppearance = min(1, max(0, appearanceDistance / 32))
        let normalizedStructure = min(1, max(0, structuralMismatch))
        return normalizedAppearance * 0.45 + normalizedStructure * 0.55
    }

    /// Measures whether bright minimap geometry exists in both signatures.
    /// The distance score intentionally discards a few outlier cells to ignore
    /// moving markers, which can also hide a newly added thin platform or rope.
    /// This second check keeps those structural changes significant.
    static func structuralMismatch(
        _ lhs: [UInt8],
        _ rhs: [UInt8],
        searchRadius: Int
    ) -> Double {
        guard lhs.count == columns * rows, rhs.count == lhs.count else { return 1 }
        let geometryThreshold: UInt8 = 35

        func directedMismatch(_ source: [UInt8], _ target: [UInt8]) -> (unmatched: Int, total: Int) {
            var unmatched = 0
            var total = 0
            for row in 0..<rows {
                for column in 0..<columns {
                    guard source[row * columns + column] >= geometryThreshold else { continue }
                    total += 1
                    var found = false
                    let minRow = max(0, row - searchRadius)
                    let maxRow = min(rows - 1, row + searchRadius)
                    let minColumn = max(0, column - searchRadius)
                    let maxColumn = min(columns - 1, column + searchRadius)
                    for neighborRow in minRow...maxRow where !found {
                        for neighborColumn in minColumn...maxColumn {
                            if target[neighborRow * columns + neighborColumn] >= geometryThreshold {
                                found = true
                                break
                            }
                        }
                    }
                    if !found { unmatched += 1 }
                }
            }
            return (unmatched, total)
        }

        let forward = directedMismatch(lhs, rhs)
        let backward = directedMismatch(rhs, lhs)
        let total = forward.total + backward.total
        guard total > 0 else { return 0 }
        return Double(forward.unmatched + backward.unmatched) / Double(total)
    }

    /// A window resize can move thin platform lines by one signature cell.
    /// Compare against the closest value in the neighboring 3×3 cells and do
    /// it in both directions so genuinely added or removed geometry remains a
    /// mismatch.
    static func spatiallyTolerantDistance(_ lhs: [UInt8], _ rhs: [UInt8]) -> Double {
        guard lhs.count == columns * rows, rhs.count == lhs.count else { return .infinity }

        func directedDistance(_ source: [UInt8], _ target: [UInt8]) -> Double {
            var total = 0
            for row in 0..<rows {
                for column in 0..<columns {
                    let sourceValue = Int(source[row * columns + column])
                    var best = Int.max
                    for neighborRow in max(0, row - 1)...min(rows - 1, row + 1) {
                        for neighborColumn in max(0, column - 1)...min(columns - 1, column + 1) {
                            let targetValue = Int(target[neighborRow * columns + neighborColumn])
                            best = min(best, abs(sourceValue - targetValue))
                        }
                    }
                    total += best
                }
            }
            return Double(total) / Double(source.count)
        }

        return (directedDistance(lhs, rhs) + directedDistance(rhs, lhs)) / 2
    }
}

enum MapTopologyValidator {
    static func messages(for topology: MapTopology) -> [String] {
        var messages: [String] = []
        if topology.platforms.isEmpty {
            messages.append("还没有标注平台")
        }
        if topology.ropes.isEmpty {
            messages.append("还没有标注绳索")
        }

        for (index, platform) in topology.platforms.enumerated() {
            guard platform.points.count >= 2 else {
                messages.append("平台 P\(index + 1) 至少需要两个端点")
                continue
            }
            let hasLength = zip(platform.points, platform.points.dropFirst()).contains { lhs, rhs in
                hypot(lhs.x - rhs.x, lhs.y - rhs.y) >= 0.015
            }
            if !hasLength {
                messages.append("平台 P\(index + 1) 长度太短")
            }
        }

        for (index, rope) in topology.ropes.enumerated() {
            if rope.bottomY - rope.topY < 0.025 {
                messages.append("绳索 R\(index + 1) 长度太短")
            }
            if !topology.platforms.contains(where: { platformIntersects($0, rope: rope) }) {
                messages.append("绳索 R\(index + 1) 没有连接任何平台")
            }
        }
        for (index, portal) in topology.portals.enumerated() {
            let nearPlatform = topology.platforms.contains { platform in
                zip(platform.points, platform.points.dropFirst()).contains { start, end in
                    pointToSegmentDistance(portal.point, start: start, end: end) <= 0.07
                }
            }
            let nearRope = topology.ropes.contains { rope in
                abs(portal.point.x - rope.x) <= 0.05
                    && portal.point.y >= rope.topY - 0.05
                    && portal.point.y <= rope.bottomY + 0.05
            }
            if !nearPlatform && !nearRope {
                messages.append("传送点 T\(index + 1) 不在平台或绳索可到达范围内")
            }
        }
        let platformIDs = Set(topology.platforms.map(\.id))
        for (index, connection) in topology.traversalConnections.enumerated() {
            if !platformIDs.contains(connection.fromPlatformID) || !platformIDs.contains(connection.toPlatformID) {
                messages.append("连接 \(connection.kind == .jump ? "J" : "D")\(index + 1) 引用的平台已不存在")
            }
            if connection.fromPlatformID == connection.toPlatformID {
                messages.append("连接 \(connection.kind == .jump ? "J" : "D")\(index + 1) 的起点和落点不能是同一平台")
            }
            if connection.kind == .drop, connection.landingPoint.y <= connection.startPoint.y + 0.02 {
                messages.append("下落连接 D\(index + 1) 的落点必须在起点下方")
            }
        }
        return messages
    }

    private static func pointToSegmentDistance(
        _ point: NormalizedMapPoint,
        start: NormalizedMapPoint,
        end: NormalizedMapPoint
    ) -> Double {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0.000001 else { return hypot(point.x - start.x, point.y - start.y) }
        let t = min(max(((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared, 0), 1)
        return hypot(point.x - (start.x + t * dx), point.y - (start.y + t * dy))
    }

    private static func platformIntersects(_ platform: MapPlatform, rope: MapRope) -> Bool {
        // Automatic platform traces follow the center of the yellow player marker,
        // which sits a few minimap pixels above the visual platform line.
        let tolerance = 0.05
        for (start, end) in zip(platform.points, platform.points.dropFirst()) {
            let minX = min(start.x, end.x) - tolerance
            let maxX = max(start.x, end.x) + tolerance
            guard rope.x >= minX, rope.x <= maxX else { continue }

            let segmentY: Double
            if abs(end.x - start.x) < 0.0001 {
                segmentY = (start.y + end.y) / 2
            } else {
                let t = min(max((rope.x - start.x) / (end.x - start.x), 0), 1)
                segmentY = start.y + (end.y - start.y) * t
            }
            if segmentY >= rope.topY - tolerance, segmentY <= rope.bottomY + tolerance {
                return true
            }
        }
        return false
    }
}

enum PlatformTraceBuilder {
    static func buildPolyline(
        from samples: [CGPoint],
        canvasSize: CGSize,
        bucketWidth: CGFloat = 1,
        simplifyTolerance: CGFloat = 1.2
    ) -> [NormalizedMapPoint] {
        guard canvasSize.width > 0, canvasSize.height > 0 else { return [] }
        let valid = samples.filter {
            $0.x.isFinite && $0.y.isFinite
                && $0.x >= 0 && $0.y >= 0
                && $0.x < canvasSize.width && $0.y < canvasSize.height
        }
        guard valid.count >= 5 else { return [] }

        let width = max(bucketWidth, 0.5)
        var buckets: [Int: [CGPoint]] = [:]
        for point in valid {
            buckets[Int((point.x / width).rounded()), default: []].append(point)
        }

        var merged = buckets.keys.sorted().compactMap { key -> CGPoint? in
            guard let points = buckets[key], !points.isEmpty else { return nil }
            let xs = points.map(\.x).sorted()
            let ys = points.map(\.y).sorted()
            return CGPoint(x: median(xs), y: median(ys))
        }
        guard merged.count >= 3 else { return [] }

        let runs = connectedRuns(from: merged)
        guard var best = runs.max(by: { runScore($0) < runScore($1) }), best.count >= 3 else { return [] }
        best = medianSmooth(best)
        merged = simplify(best, tolerance: simplifyTolerance)
        guard merged.count >= 2 else { return [] }
        return merged.map { NormalizedMapPoint($0, in: canvasSize) }
    }

    private static func connectedRuns(from points: [CGPoint]) -> [[CGPoint]] {
        guard let first = points.first else { return [] }
        var result: [[CGPoint]] = []
        var current = [first]
        for point in points.dropFirst() {
            guard let previous = current.last else { continue }
            if point.x - previous.x <= 5, abs(point.y - previous.y) <= 6 {
                current.append(point)
            } else {
                result.append(current)
                current = [point]
            }
        }
        result.append(current)
        return result
    }

    private static func runScore(_ points: [CGPoint]) -> CGFloat {
        guard let first = points.first, let last = points.last else { return 0 }
        return last.x - first.x + CGFloat(points.count) * 0.25
    }

    private static func medianSmooth(_ points: [CGPoint]) -> [CGPoint] {
        guard points.count >= 3 else { return points }
        return points.indices.map { index in
            let lower = max(0, index - 1)
            let upper = min(points.count - 1, index + 1)
            let ys = points[lower...upper].map(\.y).sorted()
            return CGPoint(x: points[index].x, y: median(ys))
        }
    }

    private static func simplify(_ points: [CGPoint], tolerance: CGFloat) -> [CGPoint] {
        guard points.count > 2 else { return points }
        let first = points[0]
        let last = points[points.count - 1]
        var maximumDistance: CGFloat = 0
        var splitIndex = 0
        for index in 1..<(points.count - 1) {
            let distance = perpendicularDistance(points[index], lineStart: first, lineEnd: last)
            if distance > maximumDistance {
                maximumDistance = distance
                splitIndex = index
            }
        }
        guard maximumDistance > tolerance else { return [first, last] }
        let left = simplify(Array(points[0...splitIndex]), tolerance: tolerance)
        let right = simplify(Array(points[splitIndex...]), tolerance: tolerance)
        return Array(left.dropLast()) + right
    }

    private static func perpendicularDistance(
        _ point: CGPoint,
        lineStart: CGPoint,
        lineEnd: CGPoint
    ) -> CGFloat {
        let dx = lineEnd.x - lineStart.x
        let dy = lineEnd.y - lineStart.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0.0001 else {
            return hypot(point.x - lineStart.x, point.y - lineStart.y)
        }
        let t = min(max(((point.x - lineStart.x) * dx + (point.y - lineStart.y) * dy) / lengthSquared, 0), 1)
        let projection = CGPoint(x: lineStart.x + t * dx, y: lineStart.y + t * dy)
        return hypot(point.x - projection.x, point.y - projection.y)
    }

    private static func median(_ values: [CGFloat]) -> CGFloat {
        guard !values.isEmpty else { return 0 }
        let middle = values.count / 2
        if values.count.isMultiple(of: 2) {
            return (values[middle - 1] + values[middle]) / 2
        }
        return values[middle]
    }
}

enum RopeTraceBuilder {
    static func buildRope(from samples: [CGPoint], canvasSize: CGSize) -> MapRope? {
        guard canvasSize.width > 0, canvasSize.height > 0 else { return nil }
        let valid = samples.filter {
            $0.x.isFinite && $0.y.isFinite && $0.x >= 0 && $0.y >= 0
                && $0.x < canvasSize.width && $0.y < canvasSize.height
        }
        guard valid.count >= 5 else { return nil }
        let xs = valid.map(\.x).sorted()
        let ys = valid.map(\.y).sorted()
        let x = xs[xs.count / 2]
        let low = ys[max(0, ys.count / 20)]
        let high = ys[min(ys.count - 1, ys.count - 1 - ys.count / 20)]
        guard high - low >= max(5, canvasSize.height * 0.025) else { return nil }
        return MapRope(
            x: Double(x / canvasSize.width),
            topY: Double(low / canvasSize.height),
            bottomY: Double(high / canvasSize.height)
        )
    }
}
