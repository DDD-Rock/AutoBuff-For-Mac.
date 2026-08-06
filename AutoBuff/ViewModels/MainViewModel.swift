import AppKit
import CoreGraphics
import Foundation
import SwiftUI

private struct MonitorFramePresentation {
    var image: NSImage?
    var contentSize: CGSize
    var playerPoint: CGPoint?
    var teammatePoints: [CGPoint]
    var otherPlayerPoints: [CGPoint]
    var matchedTopology: MapTopology?
    var framesPerSecond: Double

    static let empty = MonitorFramePresentation(
        image: nil,
        contentSize: .zero,
        playerPoint: nil,
        teammatePoints: [],
        otherPlayerPoints: [],
        matchedTopology: nil,
        framesPerSecond: 0
    )
}

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
    private var ropePartyFirstCreation = false
    @Published var accessibilityGranted = false
    @Published var accessibilityUsesAdHocSignature = false
    @Published var screenRecordingGranted = false
    @Published var showWindowPicker = false
    @Published var showVirtualKeyboard = false
    @Published var showPortalMarker = false
    @Published var showFollowHealMarker = false
    @Published var showMonitorZoneMarker = false
    @Published var showMapTopologyEditor = false
    @Published var isCheckingPortalMarker = false
    @Published var portalMarkerAlert: PortalMarkerAlert?
    @Published var keyboardTarget: KeyboardTarget = .buff(0)
    @Published var debugExpanded = false
    @Published var previewImage: NSImage?
    @Published var previewInfo = ""
    @Published var expDataCollection = EXPDataCollectionSnapshot()
    @Published var isPartyInviteWorkerActive = false
    @Published private var monitorFramePresentation = MonitorFramePresentation.empty
    @Published var monitorStatusText = "尚未开始监控"
    @Published var monitorEXPReading: EXPRecognitionResult?
    @Published var monitorEXPStatus = "尚未开始识别 EXP"
    @Published var monitorRuneAlertPresent = false
    @Published var monitorRuneAlertDetection: RuneAlertDetection?
    @Published var monitorMouseFollowVerificationPresent = false
    @Published var monitorMouseFollowVerificationDetection: MouseFollowVerificationDetection?
    @Published var monitorRuneTestBusy = false
    @Published var monitorRuneTestSummary = ""
    @Published var monitorZoneOutside = false
    @Published var remoteMonitorAuthenticated = false
    @Published var remoteMonitorIsSuperAdmin = false
    @Published var remoteMonitorAuthStatus = "未登录远程监控账号"
    @Published var remoteClientName = "正在分配客户端名称"
    @Published var remoteMonitorLinkCopied = false

    var monitorImage: NSImage? { monitorFramePresentation.image }
    var monitorContentSize: CGSize { monitorFramePresentation.contentSize }
    var monitorPlayerPoint: CGPoint? { monitorFramePresentation.playerPoint }
    var monitorTeammatePoints: [CGPoint] { monitorFramePresentation.teammatePoints }
    var monitorOtherPlayerPoints: [CGPoint] { monitorFramePresentation.otherPlayerPoints }
    var monitorMatchedTopology: MapTopology? { monitorFramePresentation.matchedTopology }
    var monitorFPS: Double { monitorFramePresentation.framesPerSecond }

    private let settingsManager = SettingsManager()
    private let windowSelector = WindowSelector()
    private let liveWorker = LiveFlowerWorker()
    private let deadWorker = DeadFlowerWorker()
    private let loungeWorker = LoungeWorker()
    private let ropePartyWorker = RopePartyWorker()
    private let followHealWorker = FollowHealWorker()
    private let partyInviteWorker = PartyInviteWorker()
    private let monitoringSession = MonitoringSession()
    private let remoteMonitorClient = RemoteMonitorClient()
    private let expDataCollectionSession = EXPDataCollectionSession()
    private var screenRecordingRequestIssued = false
    private var reportedPersistenceErrors: Set<String> = []
    /// 图片回放测试期间为 true，此时忽略实时识别结果，避免注入的状态被覆盖。
    private var isRuneTestHolding = false
    private var runeTestHoldTask: Task<Void, Never>?
    private var isMouseFollowVerificationTestHolding = false
    private var mouseFollowVerificationTestHoldTask: Task<Void, Never>?
    private var safeZoneStabilizer = SafeZoneStabilizer()

    enum KeyboardTarget: Equatable {
        case buff(Int)
        case jumpKey
        case chairKey
        case healSkillKey
        case teleportSkillKey
    }

    struct PortalMarkerAlert: Identifiable {
        let id = UUID()
        let message: String
    }

    init() {
        settings = settingsManager.load()
        mode = settings.mode
        wireWorkers()
        wireRemoteMonitor()
        wireEXPDataCollector()
        settingsManager.protectionWarnings.forEach {
            appendLog("⚠️ \($0)")
        }
        refreshPermissions()
        if accessibilityUsesAdHocSignature {
            appendLog("⚠️ 当前使用临时代码签名；重新构建后辅助功能授权可能失效")
        }
        autoIdentifyWindow()
        syncPartyInviteWorker(logMissingRequirements: false)
        Task { [weak self] in
            await self?.restoreRemoteMonitorAccount()
        }
    }

    func refreshPermissions() {
        accessibilityGranted = PermissionManager.requestAccessibility(prompt: false)
        accessibilityUsesAdHocSignature = PermissionManager.isAdHocSigned
        screenRecordingGranted = PermissionManager.screenRecordingGranted
        syncPartyInviteWorker(logMissingRequirements: false)
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
        if PermissionManager.screenRecordingGranted {
            screenRecordingGranted = true
            screenRecordingRequestIssued = false
            return
        }
        guard !screenRecordingRequestIssued else {
            appendLog("屏幕录制授权变更后需要退出并重新从 Xcode 运行 AutoBuff")
            PermissionManager.openScreenRecordingSettings()
            return
        }
        screenRecordingRequestIssued = true
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
        clearMonitorState(status: "尚未开始监控")
        saveSettings()
        publishRemoteClientState()
        syncPartyInviteWorker(logMissingRequirements: false)
    }

    func saveSettings() {
        let result = settingsManager.save(settings)
        for error in result.errors where reportedPersistenceErrors.insert(error).inserted {
            appendLog("⚠️ \(error)")
        }
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
        if isRunning {
            stopWorker()
        }
        if expDataCollectionSession.isRunning {
            expDataCollectionSession.stop()
            appendLog("游戏窗口已切换，EXP 样本采集已停止")
        }
        selectedWindow = window
        windowStatusText = "\(window.title) (\(Int(window.size.width))×\(Int(window.size.height)))"
        syncPartyInviteWorker(logMissingRequirements: false)
    }

    func setAutoAcceptPartyInviteEnabled(_ enabled: Bool) {
        settings.autoAcceptPartyInviteEnabled = enabled
        saveSettings()
        if enabled {
            syncPartyInviteWorker(logMissingRequirements: true)
        } else {
            partyInviteWorker.stop()
            isPartyInviteWorkerActive = false
            appendLog("自动同意组队已关闭")
        }
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
        if ModeRequirements.requiresAccessibility(mode), !accessibilityGranted {
            appendLog("请先授予辅助功能权限")
            requestAccessibility()
            return
        }
        if ModeRequirements.requiresScreenRecording(mode), !screenRecordingGranted {
            appendLog("\(mode.title)需要屏幕录制权限")
            requestScreenRecording()
            return
        }
        let validationErrors = WorkerConfigurationValidator.validationErrors(
            settings: settings,
            mode: mode
        )
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
        case .temple:
            switch settings.templeFunction {
            case .freeEntry:
                // “进出自由”与死花的运行流程一致；其余神殿功能在各自配置明确后
                // 再接入独立 Worker，避免三套行为耦合在 DeadFlowerWorker 中。
                deadWorker.start(
                    settings: settings,
                    windowID: window.windowID,
                    displayName: "神殿模式 · 进出自由"
                )
                appendLog("神殿模式 · 进出自由已启动")
            case .lounge:
                loungeWorker.start(settings: settings, windowID: window.windowID)
                appendLog("神殿模式 · 休息室已启动")
            case .ropeParty:
                let launchSettings = settings
                ropePartyWorker.start(
                    settings: launchSettings,
                    windowID: window.windowID,
                    firstCreation: ropePartyFirstCreation
                )
                ropePartyFirstCreation = false
                if !settings.ropePartyInviteRoleNames.isEmpty {
                    settings.ropePartyInviteRoleNames = []
                    saveSettings()
                }
                appendLog("神殿模式 · 挂绳组队已启动")
            }
        case .followHeal:
            followHealWorker.start(settings: settings, windowID: window.windowID)
            appendLog("跟补模式已启动")
        case .monitor:
            partyInviteWorker.stop()
            if !remoteMonitorAuthenticated {
                appendLog("未登录远程账号，仅使用软件内本地预览")
            }
            monitoringSession.start(
                windowID: window.windowID,
                maps: settings.mapTopologies
            )
            appendLog("监控模式已启动（只读，不发送输入）")
        }
        publishRemoteClientState()
    }

    func stopWorker(resumePartyInvite: Bool = true) {
        liveWorker.stop()
        deadWorker.stop()
        loungeWorker.stop()
        ropePartyWorker.stop()
        followHealWorker.stop()
        monitoringSession.stop()
        isRunning = false
        countdowns = [:]
        clearMonitorState(status: "监控已停止")
        if resumePartyInvite {
            syncPartyInviteWorker(logMissingRequirements: false)
        }
        appendLog("已停止")
        publishRemoteClientState()
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
        case .teleportSkillKey:
            settings.teleportSkillKey = key
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
        guard screenRecordingGranted else {
            portalMarkerAlert = PortalMarkerAlert(message: "标记跟补基准点需要屏幕录制权限。")
            requestScreenRecording()
            return
        }
        showFollowHealMarker = true
    }

    /// 打开「监控安全区基准点」标记弹窗。
    ///
    /// 和跟补基准点共用 `PortalMarkerView` 的点击取点交互，但两者互不影响：
    /// 跟补存的是绝对像素的 healAnchorX/Y，这里存的是归一化的 monitorSafeZone。
    func requestMonitorZoneMarker() {
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
        guard screenRecordingGranted else {
            portalMarkerAlert = PortalMarkerAlert(message: "标记安全区基准点需要屏幕录制权限。")
            requestScreenRecording()
            return
        }
        showMonitorZoneMarker = true
    }

    /// 保存标记结果。`region` 的宽高就是当时小地图内容区的尺寸，用它做归一化。
    func applyMonitorZoneAnchor(x: Int?, y: Int?, region: CGRect?) {
        guard let x, let y, let region, region.width > 0, region.height > 0 else {
            clearMonitorSafeZone()
            return
        }
        let previous = settings.monitorSafeZone
        settings.monitorSafeZone = MonitorSafeZone(
            center: NormalizedMapPoint(
                CGPoint(x: CGFloat(x), y: CGFloat(y)),
                in: region.size
            ),
            width: previous?.width ?? Self.defaultZoneSideRatio,
            height: previous?.height ?? Self.defaultZoneSideRatio
        )
        saveSettings()
        safeZoneStabilizer.reset()
        monitorZoneOutside = false
        appendLog("安全区基准点已设置")
    }

    func clearMonitorSafeZone() {
        guard settings.monitorSafeZone != nil else { return }
        settings.monitorSafeZone = nil
        saveSettings()
        safeZoneStabilizer.reset()
        monitorZoneOutside = false
        appendLog("安全区已清除")
    }

    static let defaultZoneSideRatio = 0.35

    /// 安全区宽度占小地图的百分比。用百分比而不是像素，是因为没开始监控时
    /// 拿不到当前内容区尺寸，而百分比本身就是存储用的归一化值。
    var monitorZoneWidthPercent: Double {
        get { (settings.monitorSafeZone?.width ?? Self.defaultZoneSideRatio) * 100 }
        set { updateMonitorSafeZone(width: newValue / 100, height: nil) }
    }

    var monitorZoneHeightPercent: Double {
        get { (settings.monitorSafeZone?.height ?? Self.defaultZoneSideRatio) * 100 }
        set { updateMonitorSafeZone(width: nil, height: newValue / 100) }
    }

    private func updateMonitorSafeZone(width: Double?, height: Double?) {
        guard let zone = settings.monitorSafeZone else { return }
        settings.monitorSafeZone = MonitorSafeZone(
            center: zone.center,
            width: width ?? zone.width,
            height: height ?? zone.height
        )
        saveSettings()
    }

    func requestMapTopologyEditor() {
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
        guard screenRecordingGranted else {
            portalMarkerAlert = PortalMarkerAlert(message: "地图标注需要屏幕录制权限。")
            requestScreenRecording()
            return
        }
        showMapTopologyEditor = true
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

    func toggleEXPDataCollection() {
        if expDataCollectionSession.isRunning {
            expDataCollectionSession.stop()
            appendLog("EXP 样本采集已停止")
            return
        }
        refreshPermissions()
        guard let window = selectedWindow else {
            appendLog("请先识别游戏窗口")
            return
        }
        guard windowSelector.isWindowValid(windowID: window.windowID) else {
            selectedWindow = nil
            windowStatusText = "未识别"
            appendLog("游戏窗口已失效，请重新识别")
            return
        }
        guard screenRecordingGranted else {
            appendLog("EXP 样本采集需要屏幕录制权限")
            requestScreenRecording()
            return
        }
        expDataCollectionSession.start(windowID: window.windowID)
    }

    func revealEXPDataCollectionDirectory() {
        expDataCollectionSession.revealDatasetDirectory()
    }

    func shutdown() {
        expDataCollectionSession.stop()
        partyInviteWorker.stop()
        stopWorker(resumePartyInvite: false)
        remoteMonitorClient.disconnectPublisher(sendOffline: false)
        saveSettings()
    }

    func logoutRemoteMonitor(message: String = "已退出远程监控账号") {
        if isRunning {
            stopWorker()
        }
        remoteMonitorClient.logout()
        remoteMonitorAuthenticated = false
        remoteMonitorIsSuperAdmin = false
        remoteMonitorAuthStatus = message
        NotificationCenter.default.post(
            name: .autoBuffAccountDidLogout,
            object: nil,
            userInfo: ["message": message]
        )
    }

    func openRemoteMonitorPage() {
        guard let url = remoteMonitorPageURL() else {
            remoteMonitorAuthStatus = "监控网页地址无效"
            return
        }
        NSWorkspace.shared.open(url)
        remoteMonitorAuthStatus = "已打开监控网页，请登录同一账号"
    }

    func copyRemoteMonitorPageLink() {
        guard let url = remoteMonitorPageURL() else {
            remoteMonitorAuthStatus = "监控网页地址无效"
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(url.absoluteString, forType: .string) else {
            remoteMonitorAuthStatus = "复制监控网页链接失败"
            return
        }
        remoteMonitorLinkCopied = true
        remoteMonitorAuthStatus = "监控网页链接已复制"
        Task {
            try? await Task.sleep(for: .seconds(2))
            remoteMonitorLinkCopied = false
        }
    }

    func openClientManagementPage() {
        guard let url = clientManagementPageURL() else {
            remoteMonitorAuthStatus = "客户端管理网页地址无效"
            return
        }
        NSWorkspace.shared.open(url)
        remoteMonitorAuthStatus = "已打开客户端管理网页"
    }

    func copyClientManagementPageLink() {
        guard let url = clientManagementPageURL() else {
            remoteMonitorAuthStatus = "客户端管理网页地址无效"
            return
        }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(url.absoluteString, forType: .string) else {
            remoteMonitorAuthStatus = "复制客户端管理链接失败"
            return
        }
        remoteMonitorLinkCopied = true
        remoteMonitorAuthStatus = "客户端管理链接已复制"
        Task {
            try? await Task.sleep(for: .seconds(2))
            remoteMonitorLinkCopied = false
        }
    }

    func saveCharacterName() async {
        let roleName = settings.characterName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !roleName.isEmpty, roleName.count <= 24 else {
            appendLog("角色名称须为 1～24 个字符")
            return
        }
        guard remoteMonitorAuthenticated else {
            appendLog("请先登录远程账号再保存角色名称")
            return
        }
        do {
            settings.characterName = try await remoteMonitorClient.saveRoleName(roleName)
            saveSettings()
            appendLog("角色名称已保存：\(settings.characterName)")
        } catch {
            appendLog("角色名称保存失败：\(error.localizedDescription)")
        }
    }

    private func remoteMonitorPageURL() -> URL? {
        let baseURL = settings.monitorServerBaseURL
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: "\(baseURL)/dashboard")
    }

    private func clientManagementPageURL() -> URL? {
        let baseURL = settings.monitorServerBaseURL
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return URL(string: "\(baseURL)/clients")
    }

    private func restoreRemoteMonitorAccount() async {
        guard let storedToken = await remoteMonitorClient.loadStoredAccessToken() else {
            return
        }
        remoteMonitorAuthStatus = "正在恢复登录..."
        do {
            let account = try await remoteMonitorClient.restore(
                baseURL: settings.monitorServerBaseURL,
                storedToken: storedToken
            )
            settings.monitorAccountUsername = account
            settings.monitorAccountNickname = remoteMonitorClient.nickname ?? "未设置昵称"
            remoteMonitorAuthenticated = true
            remoteMonitorIsSuperAdmin = remoteMonitorClient.isSuperAdmin
            try remoteMonitorClient.connectPublisher()
            publishRemoteClientState()
            remoteMonitorAuthStatus = "已登录 · 客户端管理通道已连接"
        } catch {
            remoteMonitorAuthenticated = false
            remoteMonitorIsSuperAdmin = false
            remoteMonitorAuthStatus = "登录已失效，请重新登录"
            NotificationCenter.default.post(name: .autoBuffAccountDidLogout, object: nil)
        }
    }

    func listCloudMaps() async throws -> [CloudMapSummary] {
        try await remoteMonitorClient.listCloudMaps()
    }

    func uploadCloudMaps(_ maps: [MapTopology]) async throws -> Int {
        try await remoteMonitorClient.uploadCloudMaps(maps)
    }

    func downloadCloudMap(id: Int64) async throws -> [MapTopology] {
        try await remoteMonitorClient.downloadCloudMap(id: id)
    }

    private func wireRemoteMonitor() {
        remoteMonitorClient.onIdentity = { [weak self] name in
            self?.remoteClientName = name
        }
        remoteMonitorClient.onRoleName = { [weak self] roleName in
            guard let self else { return }
            settings.characterName = roleName
            saveSettings()
        }
        remoteMonitorClient.onCommand = { [weak self] command in
            guard let self else { return }
            switch command.action {
            case "start":
                if !isRunning {
                    appendLog("收到网页远程开始指令")
                    startWorker()
                }
            case "stop":
                if isRunning {
                    if command.reason == "monitor_conflict" {
                        appendLog("同一账号已有另一个客户端在运行监控模式，本机已自动停止")
                    } else {
                        appendLog("收到网页远程停止指令")
                    }
                    stopWorker()
                }
            case "unbind":
                appendLog("当前客户端已解绑，正在停止功能并退出登录")
                logoutRemoteMonitor(message: command.reason ?? "当前客户端已解绑，请重新登录")
                return
            case "configure_rope_party":
                guard let teamID = command.teamId else {
                    appendLog("收到的挂绳组队配置缺少队伍编号")
                    return
                }
                appendLog("收到网页挂绳组队配置，正在停止当前模式")
                if isRunning { stopWorker() }
                mode = .temple
                settings.mode = .temple
                settings.returnToMarket = false
                settings.templeFunction = .ropeParty
                settings.autoAcceptPartyInviteEnabled = true
                if let roleName = command.roleName, !roleName.isEmpty {
                    settings.characterName = roleName
                }
                settings.ropePartyTeamID = teamID
                settings.ropePartyIsLeader = command.isLeader
                ropePartyFirstCreation = command.firstCreation
                settings.ropePartyInviteRoleNames = command.firstCreation
                    ? command.inviteRoleNames
                    : []
                saveSettings()
                syncPartyInviteWorker(logMissingRequirements: true)
                appendLog("已切换为神殿模式 · 挂绳组队，并开启自动同意组队")
                startWorker()
            case "disband_rope_party":
                guard let teamID = command.teamId else {
                    appendLog("收到的解散队伍指令缺少队伍编号")
                    return
                }
                appendLog("收到网页解散队伍指令，正在停止当前模式")
                stopWorker(resumePartyInvite: false)
                settings.autoAcceptPartyInviteEnabled = false
                settings.ropePartyTeamID = nil
                settings.ropePartyIsLeader = false
                ropePartyFirstCreation = false
                settings.ropePartyInviteRoleNames = []
                saveSettings()
                guard let window = selectedWindow,
                      windowSelector.isWindowValid(windowID: window.windowID) else {
                    appendLog("游戏窗口未识别，无法发送 /退出隊伍")
                    return
                }
                ropePartyWorker.disbandParty(teamID: teamID, windowID: window.windowID)
            case "remove_rope_party_member":
                guard let roleName = command.targetRoleName?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !roleName.isEmpty else {
                    appendLog("收到的移除成员指令缺少角色名称")
                    return
                }
                guard let window = selectedWindow,
                      windowSelector.isWindowValid(windowID: window.windowID) else {
                    appendLog("游戏窗口未识别，无法发送 /踢出隊伍 \(roleName)")
                    return
                }
                appendLog("收到网页移除成员指令：\(roleName)")
                ropePartyWorker.removeMember(roleName: roleName, windowID: window.windowID)
            case "start_boss_invite_cycle":
                guard let cycleID = command.cycleId,
                      let roleName = command.targetRoleName?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !roleName.isEmpty else {
                    appendLog("收到的老板邀请周期缺少周期编号或角色名称")
                    return
                }
                ropePartyWorker.startBossInviteCycle(cycleID: cycleID, roleName: roleName)
            case "cast_boss_buffs":
                guard let cycleID = command.cycleId else {
                    appendLog("收到的强制 BUFF 指令缺少周期编号")
                    return
                }
                ropePartyWorker.castBossBuffs(cycleID: cycleID)
            case "kick_boss_from_party":
                guard let cycleID = command.cycleId,
                      let roleName = command.targetRoleName?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !roleName.isEmpty else {
                    appendLog("收到的踢出老板指令缺少周期编号或角色名称")
                    return
                }
                ropePartyWorker.kickBoss(cycleID: cycleID, roleName: roleName)
            default:
                break
            }
            publishRemoteClientState()
        }
    }

    private func publishRemoteClientState() {
        guard remoteMonitorAuthenticated else { return }
        remoteMonitorClient.publishClientState(mode: mode.rawValue, running: isRunning)
    }

    private func wireWorkers() {
        liveWorker.onLog = { [weak self] msg in self?.appendLog(msg) }
        liveWorker.onCountdown = { [weak self] info in self?.countdowns = info }
        liveWorker.onError = { [weak self] msg in self?.appendLog("错误: \(msg)") }
        liveWorker.onStopped = { [weak self] in
            self?.isRunning = false
            self?.countdowns = [:]
            self?.publishRemoteClientState()
        }

        deadWorker.onLog = { [weak self] msg in self?.appendLog(msg) }
        deadWorker.onCountdown = { [weak self] info in self?.countdowns = info }
        deadWorker.onError = { [weak self] msg in self?.appendLog("错误: \(msg)") }
        deadWorker.onStopped = { [weak self] in
            self?.isRunning = false
            self?.countdowns = [:]
            self?.publishRemoteClientState()
        }

        loungeWorker.onLog = { [weak self] msg in self?.appendLog(msg) }
        loungeWorker.onError = { [weak self] msg in self?.appendLog("错误: \(msg)") }
        loungeWorker.onStopped = { [weak self] in
            self?.isRunning = false
            self?.countdowns = [:]
            self?.publishRemoteClientState()
        }

        ropePartyWorker.onLog = { [weak self] msg in self?.appendLog(msg) }
        ropePartyWorker.onError = { [weak self] msg in self?.appendLog("错误: \(msg)") }
        ropePartyWorker.onTeamCreated = { [weak self] in
            guard let self, let teamID = settings.ropePartyTeamID else { return }
            remoteMonitorClient.publishRopePartyProgress(
                teamID: teamID,
                event: "team_created"
            )
            appendLog("已向服务器上报游戏队伍创建成功")
        }
        ropePartyWorker.onInvitationSent = { [weak self] roleName in
            guard let self, let teamID = settings.ropePartyTeamID else { return }
            remoteMonitorClient.publishRopePartyProgress(
                teamID: teamID,
                event: "invitation_sent",
                roleName: roleName
            )
            appendLog("已向服务器上报邀请发送成功：\(roleName)")
        }
        ropePartyWorker.onTeamDisbanded = { [weak self] teamID in
            guard let self else { return }
            remoteMonitorClient.publishRopePartyProgress(
                teamID: teamID,
                event: "team_disbanded"
            )
            appendLog("已向服务器上报游戏队伍解散成功")
        }
        ropePartyWorker.onBuffDue = { [weak self] in
            guard let self, let teamID = settings.ropePartyTeamID else { return }
            remoteMonitorClient.publishRopePartyProgress(teamID: teamID, event: "buff_due")
            appendLog("BUFF 即将到期，已请求老板邀请周期")
        }
        ropePartyWorker.onBossJoined = { [weak self] cycleID in
            guard let self, let teamID = settings.ropePartyTeamID else { return }
            remoteMonitorClient.publishRopePartyProgress(
                teamID: teamID,
                cycleID: cycleID,
                event: "boss_joined"
            )
            appendLog("已向服务器上报老板进队")
        }
        ropePartyWorker.onBossBuffsCompleted = { [weak self] cycleID in
            guard let self, let teamID = settings.ropePartyTeamID else { return }
            remoteMonitorClient.publishRopePartyProgress(
                teamID: teamID,
                cycleID: cycleID,
                event: "buff_completed"
            )
            appendLog("本客户端老板 BUFF 已释放完毕并上报")
        }
        ropePartyWorker.onBossKicked = { [weak self] cycleID in
            guard let self, let teamID = settings.ropePartyTeamID else { return }
            remoteMonitorClient.publishRopePartyProgress(
                teamID: teamID,
                cycleID: cycleID,
                event: "boss_kicked"
            )
            appendLog("已向服务器上报老板踢出成功")
        }
        ropePartyWorker.onStopped = { [weak self] in
            self?.isRunning = false
            self?.publishRemoteClientState()
        }

        followHealWorker.onLog = { [weak self] msg in self?.appendLog(msg) }
        followHealWorker.onCountdown = { [weak self] info in self?.countdowns = info }
        followHealWorker.onError = { [weak self] msg in self?.appendLog("错误: \(msg)") }
        followHealWorker.onStopped = { [weak self] in
            self?.isRunning = false
            self?.countdowns = [:]
            self?.publishRemoteClientState()
        }

        partyInviteWorker.onLog = { [weak self] msg in self?.appendLog(msg) }
        partyInviteWorker.onError = { [weak self] msg in self?.appendLog("错误: \(msg)") }
        partyInviteWorker.onStateChanged = { [weak self] active in
            self?.isPartyInviteWorkerActive = active
        }
        partyInviteWorker.onInviteAccepted = { [weak self] in
            guard let self else { return }
            loungeWorker.partyInviteAccepted()
            if isRunning,
               mode == .temple,
               settings.templeFunction == .ropeParty,
               let teamID = settings.ropePartyTeamID,
               !settings.characterName.isEmpty {
                remoteMonitorClient.publishTeamJoined(
                    teamID: teamID,
                    roleName: settings.characterName
                )
                appendLog("已向服务器上报入队成功")
            }
        }

        monitoringSession.onFrame = { [weak self] frame in
            guard let self else { return }
            monitorFramePresentation = MonitorFramePresentation(
                image: frame.buffer.mapEditorImage(),
                contentSize: CGSize(width: frame.buffer.width, height: frame.buffer.height),
                playerPoint: frame.playerPoint,
                teammatePoints: frame.teammatePoints,
                otherPlayerPoints: frame.otherPlayerPoints,
                matchedTopology: frame.matchedTopology,
                framesPerSecond: frame.framesPerSecond
            )
            remoteMonitorClient.publish(frame: frame)
            evaluateSafeZone(
                playerPoint: frame.playerPoint,
                contentSize: CGSize(width: frame.buffer.width, height: frame.buffer.height)
            )
        }
        monitoringSession.onStatus = { [weak self] status in
            guard let self, monitorStatusText != status else { return }
            monitorStatusText = status
        }
        monitoringSession.onEXPReading = { [weak self] reading in
            guard let self, monitorEXPReading != reading else { return }
            monitorEXPReading = reading
        }
        monitoringSession.onEXPStatus = { [weak self] status in
            guard let self else { return }
            if monitorEXPStatus != status {
                monitorEXPStatus = status
            }
            remoteMonitorClient.publishEXP(
                reading: monitorEXPReading,
                status: status
            )
        }
        monitoringSession.onRuneAlert = { [weak self] isPresent, detection in
            guard let self else { return }
            guard !isRuneTestHolding else { return }
            if isPresent != monitorRuneAlertPresent {
                appendLog(isPresent ? "⚠️ 检测到符文诅咒提示" : "符文诅咒提示已消失")
            }
            monitorRuneAlertPresent = isPresent
            monitorRuneAlertDetection = detection
            remoteMonitorClient.publishRuneAlert(isPresent: isPresent, detection: detection)
        }
        monitoringSession.onMouseFollowVerification = { [weak self] isPresent, detection in
            guard let self else { return }
            guard !isMouseFollowVerificationTestHolding else { return }
            if isPresent != monitorMouseFollowVerificationPresent {
                appendLog(
                    isPresent
                        ? "🚨 检测到鼠标跟随验证，请立即人工处理"
                        : "鼠标跟随验证弹窗已消失"
                )
            }
            monitorMouseFollowVerificationPresent = isPresent
            monitorMouseFollowVerificationDetection = detection
            remoteMonitorClient.publishMouseFollowVerification(
                isPresent: isPresent,
                detection: detection
            )
        }
        monitoringSession.onStopped = { [weak self] reason in
            guard let self else { return }
            isRunning = false
            clearMonitorState(status: reason)
            appendLog(reason)
            syncPartyInviteWorker(logMissingRequirements: false)
            publishRemoteClientState()
        }
    }

    private func wireEXPDataCollector() {
        expDataCollectionSession.onSnapshot = { [weak self] snapshot in
            self?.expDataCollection = snapshot
        }
        expDataCollectionSession.onLog = { [weak self] message in
            self?.appendLog(message)
        }
    }

    private func syncPartyInviteWorker(logMissingRequirements: Bool) {
        if isRunning && mode == .monitor {
            partyInviteWorker.stop()
            isPartyInviteWorkerActive = false
            return
        }
        guard settings.autoAcceptPartyInviteEnabled else {
            partyInviteWorker.stop()
            isPartyInviteWorkerActive = false
            return
        }
        guard let window = selectedWindow else {
            partyInviteWorker.stop()
            isPartyInviteWorkerActive = false
            if logMissingRequirements { appendLog("请先识别游戏窗口后再开启自动同意组队") }
            return
        }
        guard windowSelector.isWindowValid(windowID: window.windowID) else {
            selectedWindow = nil
            windowStatusText = "未识别"
            partyInviteWorker.stop()
            isPartyInviteWorkerActive = false
            if logMissingRequirements { appendLog("游戏窗口已失效，请重新识别") }
            return
        }
        guard accessibilityGranted else {
            partyInviteWorker.stop()
            isPartyInviteWorkerActive = false
            if logMissingRequirements {
                appendLog("自动同意组队需要辅助功能权限")
                requestAccessibility()
            }
            return
        }
        guard screenRecordingGranted else {
            partyInviteWorker.stop()
            isPartyInviteWorkerActive = false
            if logMissingRequirements {
                appendLog("自动同意组队需要屏幕录制权限")
                requestScreenRecording()
            }
            return
        }

        let wasRunning = partyInviteWorker.isRunning
        let previousWindowID = partyInviteWorker.currentWindowID
        partyInviteWorker.start(windowID: window.windowID)
        if !wasRunning || previousWindowID != window.windowID {
            appendLog("自动同意组队已开启")
        }
    }

    /// 每帧判断角色是否还在安全区内，防抖后上报。
    ///
    /// 没配置安全区时也要上报一次「未越界且无矩形」，让网页停止画框；
    /// 之后由发布策略的心跳节流兜住，不会每帧都发。
    private func evaluateSafeZone(playerPoint: CGPoint?, contentSize: CGSize) {
        guard let zone = settings.monitorSafeZone else {
            if safeZoneStabilizer.isOutside || monitorZoneOutside {
                safeZoneStabilizer.reset()
                monitorZoneOutside = false
            }
            remoteMonitorClient.publishZone(isOutside: false, zone: nil)
            return
        }

        // 黄点没识别到时传 nil：找不到角色不等于角色跑了，不能据此报警。
        let observation = playerPoint.map { !zone.contains($0, in: contentSize) }
        switch safeZoneStabilizer.update(observedOutside: observation) {
        case .none:
            break
        case .breached:
            appendLog("⚠️ 角色已离开安全区")
        case .returned:
            appendLog("角色已回到安全区")
        case .lostTrack:
            let seconds = SafeZoneStabilizer.lostMarkerGracePeriod.components.seconds
            appendLog("已连续 \(seconds) 秒识别不到角色，暂停安全区报警")
        }
        monitorZoneOutside = safeZoneStabilizer.isOutside
        remoteMonitorClient.publishZone(isOutside: safeZoneStabilizer.isOutside, zone: zone)
    }

    /// 用本地图片回放所选告警链路：识别 → 面板提示 → 上报 → 服务端推送。
    ///
    /// 只在监控运行中可用，避免把离线图片结果混入正常状态。
    func runMonitorImageTest(kind: MonitorImageTestKind, urls: [URL]) {
        guard !monitorRuneTestBusy else { return }
        guard !urls.isEmpty else {
            monitorRuneTestSummary = "没有选择图片"
            return
        }
        guard isRunning else {
            monitorRuneTestSummary = "请先开始监控，再用图片测试"
            return
        }

        monitorRuneTestBusy = true
        monitorRuneTestSummary = "正在识别 \(urls.count) 张图片..."
        Task { [weak self] in
            switch kind {
            case .rune:
                let report = await Task.detached(priority: .userInitiated) {
                    RuneAlertImageTestRunner.run(urls: urls)
                }.value
                self?.applyRuneAlertImageTestReport(report)
            case .mouseFollowVerification:
                let report = await Task.detached(priority: .userInitiated) {
                    MouseFollowVerificationImageTestRunner.run(urls: urls)
                }.value
                self?.applyMouseFollowVerificationImageTestReport(report)
            }
        }
    }

    func reportMonitorImageTestFailure(_ error: Error) {
        monitorRuneTestSummary = "选择图片失败：\(error.localizedDescription)"
        appendLog(monitorRuneTestSummary)
    }

    private func applyRuneAlertImageTestReport(_ report: RuneAlertImageTestReport) {
        monitorRuneTestBusy = false
        monitorRuneTestSummary = report.summary
        appendLog("符文图片测试：\(report.summary)")

        guard let strongest = report.strongest, let detection = strongest.detection else {
            appendLog("没有识别到符文，未触发上报和推送")
            return
        }
        holdRuneAlertForTest(detection: detection, fileName: strongest.fileName)
    }

    private func applyMouseFollowVerificationImageTestReport(
        _ report: MouseFollowVerificationImageTestReport
    ) {
        monitorRuneTestBusy = false
        monitorRuneTestSummary = report.summary
        appendLog("测谎图片测试：\(report.summary)")

        guard let strongest = report.strongest, let detection = strongest.detection else {
            appendLog("没有识别到测谎弹窗，未触发上报和推送")
            return
        }
        holdMouseFollowVerificationForTest(detection: detection, fileName: strongest.fileName)
    }

    /// 注入「有符文」状态并保持一段时间，让服务端那一轮扫描能看到它。
    private func holdRuneAlertForTest(detection: RuneAlertDetection, fileName: String) {
        runeTestHoldTask?.cancel()
        isRuneTestHolding = true
        monitorRuneAlertPresent = true
        monitorRuneAlertDetection = detection
        remoteMonitorClient.publishRuneAlert(isPresent: true, detection: detection)

        let seconds = RuneAlertImageTestPolicy.stateHoldDuration.components.seconds
        appendLog("已按 \(fileName) 上报符文状态，保持 \(seconds) 秒等待推送")

        runeTestHoldTask = Task { [weak self] in
            try? await Task.sleep(for: RuneAlertImageTestPolicy.stateHoldDuration)
            guard !Task.isCancelled else { return }
            self?.releaseRuneAlertTestHold(restoreState: true)
        }
    }

    private func releaseRuneAlertTestHold(restoreState: Bool) {
        runeTestHoldTask?.cancel()
        runeTestHoldTask = nil
        guard isRuneTestHolding else { return }
        isRuneTestHolding = false
        guard restoreState else { return }
        monitorRuneAlertPresent = false
        monitorRuneAlertDetection = nil
        remoteMonitorClient.publishRuneAlert(isPresent: false, detection: nil)
        appendLog("符文测试状态已恢复，实时识别继续接管")
    }

    private func holdMouseFollowVerificationForTest(
        detection: MouseFollowVerificationDetection,
        fileName: String
    ) {
        mouseFollowVerificationTestHoldTask?.cancel()
        isMouseFollowVerificationTestHolding = true
        monitorMouseFollowVerificationPresent = true
        monitorMouseFollowVerificationDetection = detection
        remoteMonitorClient.publishMouseFollowVerification(isPresent: true, detection: detection)

        let seconds = RuneAlertImageTestPolicy.stateHoldDuration.components.seconds
        appendLog("已按 \(fileName) 上报测谎状态，保持 \(seconds) 秒等待推送")

        mouseFollowVerificationTestHoldTask = Task { [weak self] in
            try? await Task.sleep(for: RuneAlertImageTestPolicy.stateHoldDuration)
            guard !Task.isCancelled else { return }
            self?.releaseMouseFollowVerificationTestHold(restoreState: true)
        }
    }

    private func releaseMouseFollowVerificationTestHold(restoreState: Bool) {
        mouseFollowVerificationTestHoldTask?.cancel()
        mouseFollowVerificationTestHoldTask = nil
        guard isMouseFollowVerificationTestHolding else { return }
        isMouseFollowVerificationTestHolding = false
        guard restoreState else { return }
        monitorMouseFollowVerificationPresent = false
        monitorMouseFollowVerificationDetection = nil
        remoteMonitorClient.publishMouseFollowVerification(isPresent: false, detection: nil)
        appendLog("测谎测试状态已恢复，实时识别继续接管")
    }

    private func clearMonitorState(status: String) {
        // 监控停止时发布通道已经断开，再上报「无符文」没有意义，只复位本地状态。
        releaseRuneAlertTestHold(restoreState: false)
        releaseMouseFollowVerificationTestHold(restoreState: false)
        monitorFramePresentation = .empty
        monitorEXPReading = nil
        monitorEXPStatus = "尚未开始识别 EXP"
        monitorRuneAlertPresent = false
        monitorRuneAlertDetection = nil
        monitorMouseFollowVerificationPresent = false
        monitorMouseFollowVerificationDetection = nil
        safeZoneStabilizer.reset()
        monitorZoneOutside = false
        monitorStatusText = status
    }

}

enum WorkerConfigurationValidator {
    static func validationErrors(settings: AppSettings, mode: AppMode) -> [String] {
        if mode == .monitor {
            return []
        }
        let enabled = settings.buffs.filter(\.enabled)
        var errors: [String] = []
        let ropePartyMode = mode == .temple && settings.templeFunction == .ropeParty
        if enabled.isEmpty && mode != .followHeal && !ropePartyMode {
            errors.append("请至少启用一个 Buff")
        }
        for buff in enabled {
            if buff.key.isEmpty {
                errors.append("Buff #\(buff.id) 尚未设置按键")
            } else if KeyCodeMap.virtualKeyCode(for: buff.key) == nil {
                errors.append("Buff #\(buff.id) 的按键“\(buff.key)”不受支持")
            }
            let loungeIgnoresDuration = mode == .temple && settings.templeFunction == .lounge
            if !loungeIgnoresDuration,
               (buff.duration < AppConstants.minInterval || buff.duration > AppConstants.maxInterval) {
                errors.append("Buff #\(buff.id) 的持续时间需为 \(AppConstants.minInterval)～\(Int(AppConstants.maxInterval)) 秒")
            }
        }
        if settings.sitChairEnabled && KeyCodeMap.virtualKeyCode(for: settings.chairKey) == nil {
            errors.append("椅子键“\(settings.chairKey)”不受支持")
        }
        if mode == .deadFlower && KeyCodeMap.virtualKeyCode(for: settings.jumpKey) == nil {
            errors.append("跳跃键“\(settings.jumpKey)”不受支持")
        }
        if mode == .temple {
            switch settings.templeFunction {
            case .freeEntry:
                if KeyCodeMap.virtualKeyCode(for: settings.jumpKey) == nil {
                    errors.append("跳跃键“\(settings.jumpKey)”不受支持")
                }
            case .lounge:
                if settings.loungeMoveMinMinutes < 1 || settings.loungeMoveMinMinutes > 24 * 60 {
                    errors.append("休息室防卡最短间隔需为 1～1440 分钟")
                }
                if settings.loungeMoveMaxMinutes < 1 || settings.loungeMoveMaxMinutes > 24 * 60 {
                    errors.append("休息室防卡最长间隔需为 1～1440 分钟")
                }
                if settings.loungeMoveMinMinutes > settings.loungeMoveMaxMinutes {
                    errors.append("休息室防卡最短间隔不能大于最长间隔")
                }
            case .ropeParty:
                if settings.characterName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    errors.append("挂绳组队需要先填写并保存角色名称")
                }
            }
        }
        if mode == .followHeal {
            if settings.healSkillKey.isEmpty {
                errors.append("请设置加血技能键")
            } else if KeyCodeMap.virtualKeyCode(for: settings.healSkillKey) == nil {
                errors.append("加血技能键“\(settings.healSkillKey)”不受支持")
            }
            if settings.teleportSkillKey.isEmpty {
                errors.append("请设置瞬移技能键")
            } else if KeyCodeMap.virtualKeyCode(for: settings.teleportSkillKey) == nil {
                errors.append("瞬移技能键“\(settings.teleportSkillKey)”不受支持")
            } else if settings.teleportSkillKey == settings.healSkillKey {
                errors.append("瞬移技能键不能与加血技能键相同")
            }
            if settings.healAnchorX == nil {
                errors.append("请先标记跟补基准点")
            }
            if settings.followHealBoundaryTolerance < 1 || settings.followHealBoundaryTolerance > 50 {
                errors.append("跟补左右界限值需为 1～50")
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
