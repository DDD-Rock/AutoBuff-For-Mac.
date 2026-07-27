import CoreGraphics
import Foundation
import Testing
@testable import AutoBuff

struct MonitorSafeZoneTests {
    // MARK: - 几何

    @Test func centersTheRectangleOnTheAnchor() {
        let zone = MonitorSafeZone(
            center: NormalizedMapPoint(x: 0.5, y: 0.5),
            width: 0.4,
            height: 0.2
        )

        let rect = zone.normalizedRect
        #expect(abs(rect.minX - 0.3) < 1e-9)
        #expect(abs(rect.maxX - 0.7) < 1e-9)
        #expect(abs(rect.minY - 0.4) < 1e-9)
        #expect(abs(rect.maxY - 0.6) < 1e-9)
    }

    @Test func clipsTheRectangleToTheMinimapWhenTheAnchorIsNearAnEdge() {
        let zone = MonitorSafeZone(
            center: NormalizedMapPoint(x: 0.05, y: 0.95),
            width: 0.4,
            height: 0.4
        )

        let rect = zone.normalizedRect
        // 服务端要求上报的矩形不能越出 0~1，贴边时必须被裁掉而不是溢出。
        #expect(rect.minX == 0)
        #expect(rect.maxY == 1)
        #expect(rect.maxX <= 1)
        #expect(rect.minY >= 0)
        #expect(abs(rect.maxX - 0.25) < 1e-9)
        #expect(abs(rect.minY - 0.75) < 1e-9)
    }

    @Test func keepsAFullMapZoneWithinBounds() {
        let zone = MonitorSafeZone(
            center: NormalizedMapPoint(x: 0.5, y: 0.5),
            width: 1,
            height: 1
        )

        let rect = zone.normalizedRect
        #expect(rect.minX == 0)
        #expect(rect.minY == 0)
        #expect(rect.maxX == 1)
        #expect(rect.maxY == 1)
    }

    @Test func clampsUnusableSideLengths() {
        let tooSmall = MonitorSafeZone(
            center: NormalizedMapPoint(x: 0.5, y: 0.5),
            width: 0,
            height: -3
        )
        // 边长为 0 的矩形会让黄点永远在外面，等于持续误报。
        #expect(tooSmall.width == MonitorSafeZone.minimumSideRatio)
        #expect(tooSmall.height == MonitorSafeZone.minimumSideRatio)

        let tooLarge = MonitorSafeZone(
            center: NormalizedMapPoint(x: 0.5, y: 0.5),
            width: 4,
            height: 2
        )
        #expect(tooLarge.width == 1)
        #expect(tooLarge.height == 1)
    }

    // MARK: - 越界判定

    @Test func treatsPointsInsideAndOnTheBoundaryAsSafe() {
        let zone = MonitorSafeZone(
            center: NormalizedMapPoint(x: 0.5, y: 0.5),
            width: 0.4,
            height: 0.4
        )
        let contentSize = CGSize(width: 200, height: 100)

        #expect(zone.contains(CGPoint(x: 100, y: 50), in: contentSize))
        // 恰好落在边界上算「在内」，避免站在线上反复报警又取消。
        #expect(zone.contains(CGPoint(x: 60, y: 50), in: contentSize))
        #expect(zone.contains(CGPoint(x: 140, y: 50), in: contentSize))
        #expect(!zone.contains(CGPoint(x: 59, y: 50), in: contentSize))
        #expect(!zone.contains(CGPoint(x: 100, y: 20), in: contentSize))
    }

    @Test func judgesTheSameRelativePositionIdenticallyAcrossResolutions() {
        let zone = MonitorSafeZone(
            center: NormalizedMapPoint(x: 0.5, y: 0.5),
            width: 0.3,
            height: 0.3
        )

        // 归一化存储的意义：换分辨率后同一个相对位置的判定结果必须一致。
        for size in [
            CGSize(width: 200, height: 100),
            CGSize(width: 421, height: 263),
            CGSize(width: 1024, height: 300)
        ] {
            let inside = CGPoint(x: size.width * 0.52, y: size.height * 0.48)
            let outside = CGPoint(x: size.width * 0.9, y: size.height * 0.5)
            #expect(zone.contains(inside, in: size), "\(size) 的区内点判定错误")
            #expect(!zone.contains(outside, in: size), "\(size) 的区外点判定错误")
        }
    }

    @Test func treatsAnUnknownContentSizeAsSafe() {
        let zone = MonitorSafeZone(
            center: NormalizedMapPoint(x: 0.5, y: 0.5),
            width: 0.3,
            height: 0.3
        )
        // 还没拿到画面尺寸时不能报警，否则监控刚启动就会误触发。
        #expect(zone.contains(CGPoint(x: 10, y: 10), in: .zero))
    }

    @Test func buildsAZoneFromPixelInput() {
        let contentSize = CGSize(width: 400, height: 200)
        let zone = MonitorSafeZone(
            centerPixel: CGPoint(x: 200, y: 100),
            widthPixels: 100,
            heightPixels: 40,
            in: contentSize
        )

        #expect(abs(zone.center.x - 0.5) < 1e-9)
        #expect(abs(zone.width - 0.25) < 1e-9)
        #expect(abs(zone.height - 0.2) < 1e-9)

        let pixels = zone.pixelSize(in: contentSize)
        #expect(abs(pixels.width - 100) < 1e-6)
        #expect(abs(pixels.height - 40) < 1e-6)
    }

    @Test func scalesTheDrawnRectangleToTheCanvas() {
        let zone = MonitorSafeZone(
            center: NormalizedMapPoint(x: 0.5, y: 0.5),
            width: 0.5,
            height: 0.5
        )

        let rect = zone.rect(in: CGSize(width: 400, height: 200))
        #expect(abs(rect.minX - 100) < 1e-6)
        #expect(abs(rect.width - 200) < 1e-6)
        #expect(abs(rect.minY - 50) < 1e-6)
        #expect(abs(rect.height - 100) < 1e-6)
    }

    // MARK: - 防抖

    @Test func requiresSustainedAbsenceBeforeReportingABreach() {
        var stabilizer = SafeZoneStabilizer()
        let start = ContinuousClock.now

        let first = stabilizer.update(observedOutside: true, now: start)
        #expect(first == .none)
        #expect(!stabilizer.isOutside)

        // 还没满足持续时长，仍然不算越界。
        let tooEarly = stabilizer.update(
            observedOutside: true,
            now: start.advanced(by: .milliseconds(500))
        )
        #expect(tooEarly == .none)
        #expect(!stabilizer.isOutside)

        let confirmed = stabilizer.update(
            observedOutside: true,
            now: start.advanced(by: SafeZoneStabilizer.requiredOutsideDuration)
        )
        #expect(confirmed == .breached)
        #expect(stabilizer.isOutside)
    }

    @Test func cancelsAPendingBreachWhenThePlayerComesBack() {
        var stabilizer = SafeZoneStabilizer()
        let start = ContinuousClock.now

        _ = stabilizer.update(observedOutside: true, now: start)
        // 中途回到区内，之前累积的时长必须清零。
        _ = stabilizer.update(
            observedOutside: false,
            now: start.advanced(by: .milliseconds(800))
        )
        #expect(!stabilizer.isOutside)

        _ = stabilizer.update(
            observedOutside: true,
            now: start.advanced(by: .milliseconds(900))
        )
        let restarted = stabilizer.update(
            observedOutside: true,
            now: start.advanced(by: .milliseconds(1600))
        )
        #expect(restarted == .none, "计时应从重新离开的那一刻起算")
        #expect(!stabilizer.isOutside)
    }

    // MARK: - 黄点丢失

    @Test func neverAlarmsFromLostMarkerAlone() {
        var stabilizer = SafeZoneStabilizer()
        let start = ContinuousClock.now

        for second in 0..<60 {
            let change = stabilizer.update(
                observedOutside: nil,
                now: start.advanced(by: .seconds(second))
            )
            #expect(change == .none)
        }
        // 找不到角色不能报警，否则遮挡或切场景时会一直响。
        #expect(!stabilizer.isOutside)
    }

    @Test func discardsAPartialBreachCountdownWhenTheMarkerDisappears() {
        var stabilizer = SafeZoneStabilizer()
        let start = ContinuousClock.now

        // 刚出框 1 秒（还没到阈值）黄点就丢了，这一次不能被"补上"。
        _ = stabilizer.update(observedOutside: true, now: start)
        _ = stabilizer.update(
            observedOutside: nil,
            now: start.advanced(by: .seconds(1))
        )
        let resumed = stabilizer.update(
            observedOutside: true,
            now: start.advanced(by: .milliseconds(1600))
        )
        #expect(resumed == .none, "计时必须从重新看到黄点那刻起算")
        #expect(!stabilizer.isOutside)
    }

    @Test func keepsAlarmingWhileTheMarkerIsOnlyBrieflyLost() {
        var stabilizer = SafeZoneStabilizer()
        let breachedAt = breach(&stabilizer)

        // 宽限期内的短暂丢失不该中断报警，否则检测抖一下就漏报。
        let change = stabilizer.update(
            observedOutside: nil,
            now: breachedAt.advanced(by: SafeZoneStabilizer.lostMarkerGracePeriod - .seconds(1))
        )
        #expect(change == .none)
        #expect(stabilizer.isOutside)
    }

    @Test func stopsAlarmingAfterTheMarkerStaysLostTooLong() {
        var stabilizer = SafeZoneStabilizer()
        let breachedAt = breach(&stabilizer)

        _ = stabilizer.update(observedOutside: nil, now: breachedAt)
        let change = stabilizer.update(
            observedOutside: nil,
            now: breachedAt.advanced(by: SafeZoneStabilizer.lostMarkerGracePeriod)
        )
        // 角色死亡或被传送后黄点会消失，此时继续报警已经没有依据。
        #expect(change == .lostTrack)
        #expect(!stabilizer.isOutside)
    }

    @Test func reAlarmsAfterTheCharacterIsSeenOutsideAgain() {
        var stabilizer = SafeZoneStabilizer()
        let breachedAt = breach(&stabilizer)

        _ = stabilizer.update(observedOutside: nil, now: breachedAt)
        _ = stabilizer.update(
            observedOutside: nil,
            now: breachedAt.advanced(by: SafeZoneStabilizer.lostMarkerGracePeriod)
        )
        #expect(!stabilizer.isOutside)

        // 重新看到角色后要重新判定，而不是沿用之前收回的判断。
        let seenAgain = breachedAt.advanced(by: .seconds(20))
        _ = stabilizer.update(observedOutside: true, now: seenAgain)
        let change = stabilizer.update(
            observedOutside: true,
            now: seenAgain.advanced(by: SafeZoneStabilizer.requiredOutsideDuration)
        )
        #expect(change == .breached)
        #expect(stabilizer.isOutside)
    }

    @Test func doesNotReportLostTrackWhenTheCharacterComesBackFirst() {
        var stabilizer = SafeZoneStabilizer()
        let breachedAt = breach(&stabilizer)

        _ = stabilizer.update(observedOutside: nil, now: breachedAt)
        // 丢了几秒后重新看到角色在区内，应当是「已回到安全区」而不是「跟丢了」。
        let seenInside = breachedAt.advanced(by: .seconds(3))
        _ = stabilizer.update(observedOutside: false, now: seenInside)
        let change = stabilizer.update(
            observedOutside: false,
            now: seenInside.advanced(by: SafeZoneStabilizer.requiredInsideDuration)
        )
        #expect(change == .returned)
        #expect(!stabilizer.isOutside)
    }

    @Test func restartsTheLostMarkerGraceAfterTheMarkerReappears() {
        var stabilizer = SafeZoneStabilizer()
        let breachedAt = breach(&stabilizer)

        // 丢 8 秒 → 看到一帧 → 再丢 8 秒，累计 16 秒但都没连续满 10 秒，
        // 报警必须继续，宽限期只对「连续」丢失生效。
        _ = stabilizer.update(observedOutside: nil, now: breachedAt)
        _ = stabilizer.update(
            observedOutside: nil,
            now: breachedAt.advanced(by: .seconds(8))
        )
        _ = stabilizer.update(
            observedOutside: true,
            now: breachedAt.advanced(by: .seconds(8))
        )
        _ = stabilizer.update(
            observedOutside: nil,
            now: breachedAt.advanced(by: .seconds(9))
        )
        let change = stabilizer.update(
            observedOutside: nil,
            now: breachedAt.advanced(by: .seconds(16))
        )
        #expect(change == .none)
        #expect(stabilizer.isOutside)
    }

    // MARK: - 回归与复位

    @Test func requiresSustainedPresenceBeforeClearingABreach() {
        var stabilizer = SafeZoneStabilizer()
        let breachedAt = breach(&stabilizer)

        let tooEarly = stabilizer.update(observedOutside: false, now: breachedAt)
        #expect(tooEarly == .none)
        #expect(stabilizer.isOutside)

        let cleared = stabilizer.update(
            observedOutside: false,
            now: breachedAt.advanced(by: SafeZoneStabilizer.requiredInsideDuration)
        )
        #expect(cleared == .returned)
        #expect(!stabilizer.isOutside)
    }

    @Test func resetClearsTheBreachState() {
        var stabilizer = SafeZoneStabilizer()
        _ = breach(&stabilizer)
        #expect(stabilizer.isOutside)

        stabilizer.reset()
        #expect(!stabilizer.isOutside)
    }

    @Test func confirmsBreachesFasterThanTheServerPushInterval() {
        // 服务端每 5 秒推一次；防抖必须明显快于它，否则第一次报警会被推迟一整轮。
        #expect(SafeZoneStabilizer.requiredOutsideDuration < .seconds(5))
        // 心跳每 3 秒一次，判定时长不能长到让状态在心跳之间反复翻转。
        #expect(
            SafeZoneStabilizer.requiredOutsideDuration
                < MonitorStatePublishPolicy.heartbeatInterval
        )
    }

    @Test func stopsAlarmingBeforeTheServerFreshnessWindowExpires() {
        // 客户端每 3 秒心跳，服务端数据永远不会自己过期，所以必须由客户端
        // 主动收回判断；宽限期要短于服务端 12 秒的新鲜度窗口。
        #expect(SafeZoneStabilizer.lostMarkerGracePeriod < .seconds(12))
        // 也必须明显长于越界确认时长，否则刚报警就容易被一次丢帧撤销。
        #expect(
            SafeZoneStabilizer.lostMarkerGracePeriod
                > SafeZoneStabilizer.requiredOutsideDuration
        )
    }

    /// 把防抖器推进到「已确认越界」状态，返回确认发生的时刻。
    private func breach(_ stabilizer: inout SafeZoneStabilizer) -> ContinuousClock.Instant {
        let start = ContinuousClock.now
        let breachedAt = start.advanced(by: SafeZoneStabilizer.requiredOutsideDuration)
        _ = stabilizer.update(observedOutside: true, now: start)
        _ = stabilizer.update(observedOutside: true, now: breachedAt)
        return breachedAt
    }

    // MARK: - 持久化

    @Test func roundTripsThroughSettingsJSON() throws {
        var settings = AppSettings.default
        settings.monitorSafeZone = MonitorSafeZone(
            center: NormalizedMapPoint(x: 0.42, y: 0.61),
            width: 0.3,
            height: 0.25
        )

        let data = try JSONEncoder().encode(settings)
        let restored = try JSONDecoder().decode(AppSettings.self, from: data)

        #expect(restored.monitorSafeZone == settings.monitorSafeZone)
    }

    @Test func defaultsToNoSafeZoneForOlderSettingsFiles() throws {
        // 旧版本的 settings.json 里没有这个字段，解码不能失败。
        let legacy = Data(#"{"schemaVersion":2,"mode":"monitor"}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: legacy)

        #expect(settings.monitorSafeZone == nil)
    }
}
