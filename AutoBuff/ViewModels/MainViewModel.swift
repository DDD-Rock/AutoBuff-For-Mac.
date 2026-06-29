import AppKit
import CoreGraphics
import Foundation
import SwiftUI

@available(macOS 14.0, *)
@MainActor
final class MainViewModel: ObservableObject {
    @Published var settings: AppSettings
    @Published var mode: AppMode = .deadFlower
    @Published var selectedWindow: GameWindowInfo?
    @Published var windowStatusText = "未识别"
    @Published var logs: [String] = []
    @Published var countdowns: [Int: Int] = [:]
    @Published var isRunning = false
    @Published var accessibilityGranted = false
    @Published var accessibilityUsesAdHocSignature = false
    @Published var screenRecordingGranted = false
    @Published var showWindowPicker = false
    @Published var showVirtualKeyboard = false
    @Published var showPortalMarker = false
    @Published var showFollowHealMarker = false
    @Published var isCheckingPortalMarker = false
    @Published var portalMarkerAlert: PortalMarkerAlert?
    @Published var keyboardTarget: KeyboardTarget = .buff(0)
    @Published var debugExpanded = false
    @Published var previewImage: NSImage?
    @Published var previewInfo = ""

    private let settingsManager = SettingsManager()
    private let windowSelector = WindowSelector()
    private let liveWorker = LiveFlowerWorker()
    private let deadWorker = DeadFlowerWorker()
    private let followHealWorker = FollowHealWorker()

    enum KeyboardTarget: Equatable {
        case buff(Int)
        case jumpKey
        case chairKey
        case healSkillKey
    }

    struct PortalMarkerAlert: Identifiable {
        let id = UUID()
        let message: String
    }

    init() {
        settings = settingsManager.load()
        mode = settings.mode
        wireWorkers()
        refreshPermissions()
        if accessibilityUsesAdHocSignature {
            appendLog("⚠️ 当前使用临时代码签名；重新构建后辅助功能授权可能失效")
        }
        autoIdentifyWindow()
    }

    func refreshPermissions() {
        accessibilityGranted = PermissionManager.requestAccessibility(prompt: false)
        accessibilityUsesAdHocSignature = PermissionManager.isAdHocSigned
        screenRecordingGranted = PermissionManager.screenRecordingGranted
    }

    func requestAccessibility() {
        _ = PermissionManager.requestAccessibility(prompt: true)
        PermissionManager.openAccessibilitySettings()
        refreshPermissions()
    }

    func repairAccessibility() {
        stopWorker()
        let accessibilityReset = PermissionManager.resetAccessibilityConsent()
        let screenRecordingReset = PermissionManager.resetScreenRecordingConsent()
        if accessibilityReset && screenRecordingReset {
            appendLog("已清除旧权限记录，请为当前 AutoBuff 重新授权辅助功能和屏幕录制")
        } else {
            appendLog("无法完整清除旧权限，请在系统设置中删除旧 AutoBuff 后重新添加")
        }
        _ = PermissionManager.requestAccessibility(prompt: true)
        _ = PermissionManager.requestScreenRecording()
        PermissionManager.openAccessibilitySettings()
        refreshPermissions()
    }

    func requestScreenRecording() {
        screenRecordingGranted = PermissionManager.requestScreenRecording()
        if !screenRecordingGranted {
            appendLog("请在“系统设置 → 隐私与安全性 → 屏幕与系统音频录制”中允许 AutoBuff，然后重新打开应用")
        }
    }

    func setMode(_ newMode: AppMode) {
        guard !isRunning else { return }
        mode = newMode
        settings.mode = newMode
        settings.returnToMarket = newMode == .deadFlower
        saveSettings()
    }

    func saveSettings() {
        settingsManager.save(settings)
    }

    func autoIdentifyWindow() {
        if let window = windowSelector.autoDetectGameWindow() {
            selectWindow(window)
        }
    }

    func identifyWindow() {
        if let window = windowSelector.autoDetectGameWindow() {
            selectWindow(window)
            appendLog("自动识别成功: \(window.title)")
        } else {
            showWindowPicker = true
        }
    }

    func selectWindow(_ window: GameWindowInfo) {
        selectedWindow = window
        windowStatusText = "\(window.title) (\(Int(window.size.width))×\(Int(window.size.height)))"
    }

    func toggleWorker() {
        isRunning ? stopWorker() : startWorker()
    }

    func startWorker() {
        refreshPermissions()
        guard let window = selectedWindow else {
            appendLog("请先识别游戏窗口")
            return
        }
        guard windowSelector.isWindowValid(windowID: window.windowID) else {
            appendLog("游戏窗口已失效，请重新识别")
            selectedWindow = nil
            windowStatusText = "未识别"
            return
        }
        guard accessibilityGranted else {
            appendLog("请先授予辅助功能权限")
            requestAccessibility()
            return
        }
        if (mode == .deadFlower || mode == .followHeal) && !screenRecordingGranted {
            appendLog("\(mode.title)需要屏幕录制权限")
            requestScreenRecording()
            return
        }
        let validationErrors = validateEnabledBuffs()
        guard validationErrors.isEmpty else {
            validationErrors.forEach(appendLog)
            return
        }
        settings.mode = mode
        settings.returnToMarket = mode == .deadFlower
        saveSettings()
        isRunning = true
        countdowns = [:]
        switch mode {
        case .liveFlower:
            let skills = buildLiveSkills()
            liveWorker.start(
                skills: skills,
                windowID: window.windowID,
                movementMode: settings.movementMode,
                sitChairEnabled: settings.sitChairEnabled,
                chairKey: settings.chairKey
            )
            appendLog("活花模式已启动")
        case .deadFlower:
            deadWorker.start(settings: settings, windowID: window.windowID)
            appendLog("死花模式已启动")
        case .followHeal:
            followHealWorker.start(settings: settings, windowID: window.windowID)
            appendLog("跟补模式已启动")
        }
    }

    func stopWorker() {
        liveWorker.stop()
        deadWorker.stop()
        followHealWorker.stop()
        isRunning = false
        countdowns = [:]
        appendLog("已停止")
    }

    func buildLiveSkills() -> [SkillConfig] {
        let randomDelay = settings.randomBehaviorEnabled ? Double(settings.randomBehaviorValue) : 0
        return settings.buffs
            .filter { $0.enabled && !$0.key.isEmpty && $0.duration > 0 }
            .map { SkillConfig(id: $0.id, key: $0.key, interval: $0.duration, randomDelay: randomDelay) }
    }

    func appendLog(_ message: String) {
        let timestamp = DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)
        logs.append("[\(timestamp)] \(message)")
        if logs.count > 500 { logs.removeFirst(logs.count - 500) }
    }

    func clearLogs() {
        logs.removeAll()
    }

    func applySelectedKey(_ key: String) {
        switch keyboardTarget {
        case .buff(let index):
            guard settings.buffs.indices.contains(index) else { return }
            settings.buffs[index].key = key
        case .jumpKey:
            settings.jumpKey = key
        case .chairKey:
            settings.chairKey = key
        case .healSkillKey:
            settings.healSkillKey = key
        }
        saveSettings()
    }

    func openKeyboard(for target: KeyboardTarget) {
        keyboardTarget = target
        showVirtualKeyboard = true
    }

    func requestPortalMarker() async {
        guard !isRunning, !isCheckingPortalMarker else { return }
        guard let window = selectedWindow else {
            portalMarkerAlert = PortalMarkerAlert(message: "请先识别游戏窗口。")
            return
        }
        guard windowSelector.isWindowValid(windowID: window.windowID) else {
            selectedWindow = nil
            windowStatusText = "未识别"
            portalMarkerAlert = PortalMarkerAlert(message: "游戏窗口已失效，请重新识别。")
            return
        }

        isCheckingPortalMarker = true
        defer { isCheckingPortalMarker = false }

        let detector = MarketButtonDetector()
        detector.setWindow(window.windowID)
        do {
            guard try await detector.isInMarket() else {
                appendLog("传送门标记已取消：当前未检测到自由市场")
                portalMarkerAlert = PortalMarkerAlert(
                    message: "当前未检测到自由市场，请先进入自由市场后再标记传送门。"
                )
                return
            }
            showPortalMarker = true
        } catch {
            appendLog("传送门标记前置检测失败: \(error.localizedDescription)")
            portalMarkerAlert = PortalMarkerAlert(
                message: "无法确认当前地图，请检查屏幕录制权限和游戏窗口后重试。"
            )
        }
    }

    func requestFollowHealMarker() {
        guard !isRunning else { return }
        guard let window = selectedWindow else {
            portalMarkerAlert = PortalMarkerAlert(message: "请先识别游戏窗口。")
            return
        }
        guard windowSelector.isWindowValid(windowID: window.windowID) else {
            selectedWindow = nil
            windowStatusText = "未识别"
            portalMarkerAlert = PortalMarkerAlert(message: "游戏窗口已失效，请重新识别。")
            return
        }
        showFollowHealMarker = true
    }

    func addBuff() {
        guard !isRunning, settings.buffs.count < AppConstants.maxBuffSlotCount else { return }
        settings.buffs.append(BuffConfig(id: settings.buffs.count + 1))
        saveSettings()
    }

    func removeBuff(at index: Int) {
        guard !isRunning,
              settings.buffs.count > AppConstants.defaultBuffSlotCount,
              settings.buffs.indices.contains(index) else { return }
        settings.buffs.remove(at: index)
        for index in settings.buffs.indices {
            settings.buffs[index].id = index + 1
        }
        saveSettings()
    }

    func capturePreview() async {
        guard let window = selectedWindow else {
            appendLog("请先识别游戏窗口")
            return
        }
        let capture = GameCaptureService()
        do {
            let result = try await capture.captureBGR(windowID: window.windowID)
            previewImage = result.buffer.toNSImage()
            previewInfo = "\(result.buffer.width)×\(result.buffer.height) px"
            appendLog("截图成功 \(previewInfo)")
        } catch {
            appendLog("截图失败: \(error.localizedDescription)")
        }
    }

    func shutdown() {
        stopWorker()
        saveSettings()
    }

    private func wireWorkers() {
        liveWorker.onLog = { [weak self] msg in self?.appendLog(msg) }
        liveWorker.onCountdown = { [weak self] info in self?.countdowns = info }
        liveWorker.onError = { [weak self] msg in self?.appendLog("错误: \(msg)") }
        liveWorker.onStopped = { [weak self] in
            self?.isRunning = false
            self?.countdowns = [:]
        }

        deadWorker.onLog = { [weak self] msg in self?.appendLog(msg) }
        deadWorker.onCountdown = { [weak self] info in self?.countdowns = info }
        deadWorker.onError = { [weak self] msg in self?.appendLog("错误: \(msg)") }
        deadWorker.onStopped = { [weak self] in
            self?.isRunning = false
            self?.countdowns = [:]
        }

        followHealWorker.onLog = { [weak self] msg in self?.appendLog(msg) }
        followHealWorker.onCountdown = { [weak self] info in self?.countdowns = info }
        followHealWorker.onError = { [weak self] msg in self?.appendLog("错误: \(msg)") }
        followHealWorker.onStopped = { [weak self] in
            self?.isRunning = false
            self?.countdowns = [:]
        }
    }

    private func validateEnabledBuffs() -> [String] {
        let enabled = settings.buffs.filter(\.enabled)
        guard !enabled.isEmpty else { return ["请至少启用一个 Buff"] }
        var errors: [String] = []
        for buff in enabled {
            if buff.key.isEmpty {
                errors.append("Buff #\(buff.id) 尚未设置按键")
            } else if KeyCodeMap.virtualKeyCode(for: buff.key) == nil {
                errors.append("Buff #\(buff.id) 的按键“\(buff.key)”不受支持")
            }
            if buff.duration < AppConstants.minInterval || buff.duration > AppConstants.maxInterval {
                errors.append("Buff #\(buff.id) 的持续时间需为 \(AppConstants.minInterval)～\(Int(AppConstants.maxInterval)) 秒")
            }
        }
        if settings.sitChairEnabled && KeyCodeMap.virtualKeyCode(for: settings.chairKey) == nil {
            errors.append("椅子键“\(settings.chairKey)”不受支持")
        }
        if mode == .deadFlower && KeyCodeMap.virtualKeyCode(for: settings.jumpKey) == nil {
            errors.append("跳跃键“\(settings.jumpKey)”不受支持")
        }
        if mode == .followHeal {
            if settings.healSkillKey.isEmpty {
                errors.append("请设置加血技能键")
            } else if KeyCodeMap.virtualKeyCode(for: settings.healSkillKey) == nil {
                errors.append("加血技能键“\(settings.healSkillKey)”不受支持")
            }
            if settings.healAnchorX == nil {
                errors.append("请先标记跟补基准点")
            }
        }
        return errors
    }
}

private extension ImageBuffer {
    func toNSImage() -> NSImage? {
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        var dst = 0
        for i in stride(from: 0, to: bgr.count, by: 3) {
            rgba[dst] = bgr[i + 2]
            rgba[dst + 1] = bgr[i + 1]
            rgba[dst + 2] = bgr[i]
            rgba[dst + 3] = 255
            dst += 4
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let cg = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: width, height: height))
    }
}
