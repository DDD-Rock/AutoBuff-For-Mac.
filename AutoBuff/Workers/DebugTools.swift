import CoreGraphics
import Foundation

@available(macOS 14.0, *)
@MainActor
enum DebugTools {
    static func testLeaveMarket(windowID: CGWindowID?, log: @MainActor @escaping (String) -> Void) async {
        guard let windowID else { log("请先识别游戏窗口"); return }
        log("调试: 测试离开市场...")
        let minimap = MinimapMonitor()
        minimap.setWindow(windowID)
        let region = try? await minimap.autoDetectDarkRegion()
        if let region {
            log("小地图区域: x=\(Int(region.minX)), y=\(Int(region.minY)), w=\(Int(region.width)), h=\(Int(region.height))")
        } else {
            log("小地图区域检测失败: \(minimap.lastDetectionSummary)")
        }
        if let portal = try? await minimap.findBluePortal(leftmost: true) {
            log("检测到传送门: \(Int(portal.x)), \(Int(portal.y))")
        } else {
            log("未检测到传送门")
        }
        if let player = try? await minimap.findPlayerPosition() {
            log("检测到玩家: \(String(format: "%.1f", player.x)), \(String(format: "%.1f", player.y))")
        } else {
            log(minimap.lastPlayerDetectionSummary)
        }
        let market = MarketButtonDetector()
        market.setWindow(windowID)
        let inMarket = (try? await market.isInMarket()) ?? false
        log("当前在市场: \(inMarket)")
    }
    
    static func testReturnToMarket(windowID: CGWindowID?, log: @MainActor @escaping (String) -> Void) async {
        guard let windowID else { log("请先识别游戏窗口"); return }
        log("调试: 测试回到市场...")
        let market = MarketButtonDetector()
        market.setWindow(windowID)
        if let pos = try? await market.findMarketButtonScreenPoint() {
            log("市场按钮屏幕坐标: \(Int(pos.x)), \(Int(pos.y))")
        } else {
            log("未找到市场按钮")
        }
    }
    
    static func testDismissDialog(windowID: CGWindowID?, log: @MainActor @escaping (String) -> Void) async {
        guard let windowID else { log("请先识别游戏窗口"); return }
        log("调试: 测试弹窗检测...")
        let dialog = DialogDetector()
        dialog.setWindow(windowID)
        guard var pos = try? await dialog.findConfirmButtonScreenPoint() else {
            log("未检测到弹窗")
            return
        }

        log("确定按钮: \(Int(pos.x)), \(Int(pos.y))，正在点击...")
        let windowSelector = WindowSelector()
        let human = HumanInput()
        if !windowSelector.bringWindowToFront(windowID: windowID) {
            log("⚠️ 无法将游戏窗口置于前台，仍会尝试点击")
        }
        try? await Task.sleep(nanoseconds: 200_000_000)

        for attempt in 1...2 {
            if attempt > 1,
               let refreshedPos = try? await dialog.findConfirmButtonScreenPoint() {
                pos = refreshedPos
            }
            await human.clickAt(screenPoint: pos, offsetRange: 3)
            try? await Task.sleep(nanoseconds: 250_000_000)
            if (try? await dialog.findConfirmButtonScreenPoint()) == nil {
                log("弹窗已关闭")
                return
            }
            if attempt == 1 {
                log("弹窗仍在，准备再次点击")
            }
        }
        log("⚠️ 已点击确定，但弹窗仍被检测到")
    }

    static func testPartyInvite(windowID: CGWindowID?, log: @MainActor @escaping (String) -> Void) async {
        guard let windowID else { log("请先识别游戏窗口"); return }
        log("调试: 测试队伍邀请检测...")
        let detector = PartyInviteDetector()
        detector.setWindow(windowID)
        guard let pos = try? await detector.findAcceptButtonScreenPoint() else {
            log("未检测到队伍邀请")
            return
        }

        log("队伍邀请同意按钮: \(Int(pos.x)), \(Int(pos.y))，正在点击...")
        let windowSelector = WindowSelector()
        let human = HumanInput()
        if !windowSelector.bringWindowToFront(windowID: windowID) {
            log("⚠️ 无法将游戏窗口置于前台，仍会尝试点击")
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
        await human.clickAt(screenPoint: pos, offsetRange: 2)
        log("已点击队伍邀请同意按钮")
    }
}
