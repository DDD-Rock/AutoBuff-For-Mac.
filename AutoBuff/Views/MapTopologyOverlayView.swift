import CoreGraphics
import SwiftUI

@available(macOS 14.0, *)
struct MapTopologyOverlayView: View {
    let topology: MapTopology?
    let playerPoint: CGPoint?
    let teammatePoints: [CGPoint]
    let otherPlayerPoints: [CGPoint]
    let playerContentSize: CGSize

    var body: some View {
        Canvas { context, size in
            MapTopologyOverlayRenderer.draw(
                topology: topology,
                playerPoint: playerPoint,
                teammatePoints: teammatePoints,
                otherPlayerPoints: otherPlayerPoints,
                playerContentSize: playerContentSize,
                context: &context,
                size: size
            )
        }
        .allowsHitTesting(false)
    }
}

@available(macOS 14.0, *)
enum MapTopologyOverlayRenderer {
    static let playerMarkerDiameter: CGFloat = 16
    static let teammateMarkerDiameter: CGFloat = 12
    static let otherPlayerMarkerDiameter: CGFloat = 12

    static func displayPoint(
        for playerPoint: CGPoint,
        contentSize: CGSize,
        canvasSize: CGSize
    ) -> CGPoint? {
        guard contentSize.width > 0, contentSize.height > 0 else { return nil }
        return CGPoint(
            x: playerPoint.x / contentSize.width * canvasSize.width,
            y: playerPoint.y / contentSize.height * canvasSize.height
        )
    }

    static func playerArrowPoints(
        for playerPoint: CGPoint,
        canvasSize: CGSize
    ) -> [CGPoint] {
        let maximumX = max(0, canvasSize.width)
        let centerX = maximumX >= 10
            ? min(max(playerPoint.x, 5), maximumX - 5)
            : maximumX / 2
        let markerRadius = playerMarkerDiameter / 2
        let tipY = max(1, playerPoint.y - markerRadius - 2)
        let arrowHeight = max(1, min(8, tipY))
        let halfWidth = 5 * arrowHeight / 8
        let baseY = tipY - arrowHeight
        return [
            CGPoint(x: centerX - halfWidth, y: baseY),
            CGPoint(x: centerX + halfWidth, y: baseY),
            CGPoint(x: centerX, y: tipY),
        ]
    }

    static func draw(
        topology: MapTopology?,
        playerPoint: CGPoint? = nil,
        teammatePoints: [CGPoint] = [],
        otherPlayerPoints: [CGPoint] = [],
        playerContentSize: CGSize = .zero,
        context: inout GraphicsContext,
        size: CGSize
    ) {
        if let topology {
            for (index, platform) in topology.platforms.enumerated() where platform.points.count >= 2 {
                var path = Path()
                path.move(to: platform.points[0].point(in: size))
                for point in platform.points.dropFirst() {
                    path.addLine(to: point.point(in: size))
                }
                context.stroke(path, with: .color(.green), lineWidth: 3)
                let labelPoint = platform.points[platform.points.count / 2].point(in: size)
                drawLabel(
                    "P\(index + 1)",
                    at: CGPoint(x: labelPoint.x, y: labelPoint.y - 15),
                    color: .green,
                    context: &context
                )
            }

            for (index, rope) in topology.ropes.enumerated() {
                let x = CGFloat(rope.x) * size.width
                let topY = CGFloat(rope.topY) * size.height
                let bottomY = CGFloat(rope.bottomY) * size.height
                var path = Path()
                path.move(to: CGPoint(x: x, y: topY))
                path.addLine(to: CGPoint(x: x, y: bottomY))
                context.stroke(path, with: .color(.orange), lineWidth: 3)
                drawLabel(
                    "R\(index + 1)",
                    at: CGPoint(x: x + 19, y: (topY + bottomY) / 2),
                    color: .orange,
                    context: &context
                )
            }

            for (index, portal) in topology.portals.enumerated() {
                let point = portal.point.point(in: size)
                context.fill(
                    Path(ellipseIn: CGRect(x: point.x - 6, y: point.y - 6, width: 12, height: 12)),
                    with: .color(.blue)
                )
                context.stroke(
                    Path(ellipseIn: CGRect(x: point.x - 7, y: point.y - 7, width: 14, height: 14)),
                    with: .color(.white),
                    lineWidth: 1.5
                )
                drawLabel(
                    "T\(index + 1)",
                    at: CGPoint(x: point.x + 23, y: point.y),
                    color: .blue,
                    context: &context
                )
            }
        }

        drawCompactPlayerMarkers(
            teammatePoints,
            color: .orange,
            diameter: teammateMarkerDiameter,
            contentSize: playerContentSize,
            context: &context,
            canvasSize: size
        )
        drawCompactPlayerMarkers(
            otherPlayerPoints,
            color: .red,
            diameter: otherPlayerMarkerDiameter,
            contentSize: playerContentSize,
            context: &context,
            canvasSize: size
        )

        if let playerPoint,
           let point = displayPoint(
            for: playerPoint,
            contentSize: playerContentSize,
            canvasSize: size
           ) {
            let markerRect = CGRect(
                x: point.x - playerMarkerDiameter / 2,
                y: point.y - playerMarkerDiameter / 2,
                width: playerMarkerDiameter,
                height: playerMarkerDiameter
            )
            context.fill(
                Path(ellipseIn: markerRect),
                with: .color(.black.opacity(0.9))
            )
            context.stroke(
                Path(ellipseIn: markerRect),
                with: .color(.white),
                lineWidth: 1.5
            )
            context.fill(
                Path(
                    ellipseIn: markerRect.insetBy(dx: 3, dy: 3)
                ),
                with: .color(.yellow)
            )
            let arrowPoints = playerArrowPoints(for: point, canvasSize: size)
            var arrow = Path()
            arrow.move(to: arrowPoints[0])
            arrow.addLine(to: arrowPoints[1])
            arrow.addLine(to: arrowPoints[2])
            arrow.closeSubpath()
            context.fill(arrow, with: .color(.yellow))
            context.stroke(arrow, with: .color(.black), lineWidth: 1.5)
        }
    }

    private static func drawCompactPlayerMarkers(
        _ points: [CGPoint],
        color: Color,
        diameter: CGFloat,
        contentSize: CGSize,
        context: inout GraphicsContext,
        canvasSize: CGSize
    ) {
        for sourcePoint in points {
            guard let point = displayPoint(
                for: sourcePoint,
                contentSize: contentSize,
                canvasSize: canvasSize
            ) else { continue }
            let markerRect = CGRect(
                x: point.x - diameter / 2,
                y: point.y - diameter / 2,
                width: diameter,
                height: diameter
            )
            context.fill(
                Path(ellipseIn: markerRect),
                with: .color(.black.opacity(0.9))
            )
            context.stroke(
                Path(ellipseIn: markerRect),
                with: .color(.white),
                lineWidth: 1
            )
            context.fill(
                Path(ellipseIn: markerRect.insetBy(dx: 2.5, dy: 2.5)),
                with: .color(color)
            )
        }
    }

    private static func drawLabel(
        _ label: String,
        at point: CGPoint,
        color: Color,
        context: inout GraphicsContext
    ) {
        let text = context.resolve(
            Text(label)
                .font(.system(size: 12, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
        )
        let measured = text.measure(in: CGSize(width: 80, height: 24))
        let badgeSize = CGSize(width: max(28, measured.width + 12), height: max(22, measured.height + 6))
        let rect = CGRect(
            x: point.x - badgeSize.width / 2,
            y: point.y - badgeSize.height / 2,
            width: badgeSize.width,
            height: badgeSize.height
        )
        let badge = Path(roundedRect: rect, cornerRadius: 6)
        context.fill(badge, with: .color(color.opacity(0.92)))
        context.stroke(badge, with: .color(.white.opacity(0.95)), lineWidth: 1.5)
        context.draw(text, at: point)
    }
}
