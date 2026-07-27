import CoreGraphics
import Foundation

/// 监控模式的「安全区」：以基准点为中心的矩形。
///
/// 全部用归一化坐标（0~1）存储，而不是像素。小地图内容区的尺寸会随游戏窗口
/// 变化，跟补模式的 `healAnchorX/Y` 存的是绝对像素，换分辨率就失效了；这里
/// 沿用地图标注和远程推送已经在用的 `NormalizedMapPoint` 做法，避免重复那个坑。
struct MonitorSafeZone: Codable, Equatable, Sendable {
    /// 矩形中心，也就是用户在小地图上点的那个基准点。
    var center: NormalizedMapPoint
    /// 矩形的总宽和总高（不是半宽半高），归一化到 0~1。
    var width: Double
    var height: Double

    /// 边长下限。太小的矩形黄点几乎必然在外面，等于持续误报。
    static let minimumSideRatio = 0.02

    init(center: NormalizedMapPoint, width: Double, height: Double) {
        self.center = center
        self.width = Self.clampSide(width)
        self.height = Self.clampSide(height)
    }

    private static func clampSide(_ value: Double) -> Double {
        guard value.isFinite else { return minimumSideRatio }
        return min(max(value, minimumSideRatio), 1)
    }

    /// 归一化后的实际生效矩形：以中心向四周各扩一半，再裁进小地图范围内。
    ///
    /// 基准点贴边时矩形会被截断，这是正确的——小地图到那里就结束了，
    /// 而且服务端要求上报的矩形不能越出 0~1。
    var normalizedRect: CGRect {
        let minX = max(0, center.x - width / 2)
        let minY = max(0, center.y - height / 2)
        let maxX = min(1, center.x + width / 2)
        let maxY = min(1, center.y + height / 2)
        return CGRect(
            x: minX,
            y: minY,
            width: max(0, maxX - minX),
            height: max(0, maxY - minY)
        )
    }

    /// 换算到某个尺寸下的矩形，用于在画布或小地图上绘制。
    func rect(in size: CGSize) -> CGRect {
        let normalized = normalizedRect
        return CGRect(
            x: normalized.minX * size.width,
            y: normalized.minY * size.height,
            width: normalized.width * size.width,
            height: normalized.height * size.height
        )
    }

    /// 判断一个内容区像素坐标是否还在安全区内。
    ///
    /// 先把像素换算成归一化坐标再比，这样和绘制、上报用的是同一套判据。
    /// 边界上算「在内」，避免站在线上时反复报警又取消。
    func contains(_ point: CGPoint, in contentSize: CGSize) -> Bool {
        guard contentSize.width > 0, contentSize.height > 0 else { return true }
        let normalized = NormalizedMapPoint(point, in: contentSize)
        let rect = normalizedRect
        guard rect.width > 0, rect.height > 0 else { return true }
        return normalized.x >= rect.minX
            && normalized.x <= rect.maxX
            && normalized.y >= rect.minY
            && normalized.y <= rect.maxY
    }
}

extension MonitorSafeZone {
    /// 用当前画面的像素尺寸构造安全区，供「点击取基准点 + 输入长宽」的界面使用。
    init(centerPixel: CGPoint, widthPixels: Double, heightPixels: Double, in contentSize: CGSize) {
        self.init(
            center: NormalizedMapPoint(centerPixel, in: contentSize),
            width: contentSize.width > 0 ? widthPixels / contentSize.width : Self.minimumSideRatio,
            height: contentSize.height > 0 ? heightPixels / contentSize.height : Self.minimumSideRatio
        )
    }

    /// 换算回像素长宽，用于把已保存的配置显示回输入框。
    func pixelSize(in contentSize: CGSize) -> CGSize {
        CGSize(width: width * contentSize.width, height: height * contentSize.height)
    }
}

/// 安全区状态的变化原因。
///
/// 区分「回到区内」和「跟丢了」很重要：两者都会停止报警，但前者是角色真的
/// 回来了，后者只是我们不再有依据，日志和文案不能混为一谈。
enum SafeZoneStateChange: Equatable, Sendable {
    case none
    case breached
    case returned
    case lostTrack
}

/// 越界判定防抖。
///
/// 黄点检测会偶尔丢帧或质心抖动，单帧结果不足以改变状态。这里用「持续时间」
/// 而不是帧数，因为位置帧的帧率会随窗口和负载变化，按帧计数在掉帧时会
/// 被拉长成十几秒。
struct SafeZoneStabilizer {
    /// 连续在区外这么久才算真的越界。
    static let requiredOutsideDuration: Duration = .milliseconds(1500)
    /// 连续回到区内这么久才算解除。
    static let requiredInsideDuration: Duration = .milliseconds(1000)
    /// 已经在报警时，黄点连续丢失这么久就停止报警。
    ///
    /// 报警必须始终有「明确看到角色在框外」作依据。角色死亡、被传送或小地图
    /// 重新识别都会让黄点消失，此时继续按最后一次判断无限报警是没有依据的。
    /// 必须短于服务端 12 秒的新鲜度窗口，这样是我们主动停推而不是靠数据过期。
    static let lostMarkerGracePeriod: Duration = .seconds(10)

    private(set) var isOutside = false
    private var pendingOutside: Bool?
    private var pendingSince: ContinuousClock.Instant?
    private var lostSince: ContinuousClock.Instant?

    /// - Parameter observedOutside: 本帧判定结果。`nil` 表示没识别到黄点，
    ///   此时不会据此报警——找不到角色不等于角色跑了。
    /// - Returns: 稳定后的状态变化原因。
    @discardableResult
    mutating func update(
        observedOutside: Bool?,
        now: ContinuousClock.Instant = .now
    ) -> SafeZoneStateChange {
        guard let observedOutside else {
            return handleLostMarker(now: now)
        }
        lostSince = nil
        guard observedOutside != isOutside else {
            clearPending()
            return .none
        }

        let required = observedOutside
            ? Self.requiredOutsideDuration
            : Self.requiredInsideDuration

        guard pendingOutside == observedOutside, let pendingSince else {
            pendingOutside = observedOutside
            self.pendingSince = now
            return .none
        }
        guard pendingSince.duration(to: now) >= required else { return .none }

        isOutside = observedOutside
        clearPending()
        return observedOutside ? .breached : .returned
    }

    /// 黄点丢失：先清掉未完成的越界计时，避免"补上"一次没看全的报警；
    /// 若已经在报警，则等宽限期结束后收回判断。
    private mutating func handleLostMarker(now: ContinuousClock.Instant) -> SafeZoneStateChange {
        clearPending()
        guard isOutside else {
            lostSince = nil
            return .none
        }
        guard let lostSince else {
            self.lostSince = now
            return .none
        }
        guard lostSince.duration(to: now) >= Self.lostMarkerGracePeriod else { return .none }
        isOutside = false
        self.lostSince = nil
        return .lostTrack
    }

    mutating func reset() {
        isOutside = false
        lostSince = nil
        clearPending()
    }

    private mutating func clearPending() {
        pendingOutside = nil
        pendingSince = nil
    }
}
