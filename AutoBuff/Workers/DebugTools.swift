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
        if let pos = try? await dialog.findConfirmButtonScreenPoint() {
            log("确定按钮: \(Int(pos.x)), \(Int(pos.y))")
        } else {
            log("未检测到弹窗")
        }
    }
}
