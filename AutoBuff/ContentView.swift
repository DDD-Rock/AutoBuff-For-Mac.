import AppKit
import SwiftUI

@available(macOS 14.0, *)
struct ContentView: View {
    @StateObject private var viewModel = MainViewModel()
    @State private var workspaceTab: WorkspaceTab = .configuration
    private let windowSelector = WindowSelector()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                sidebar
                Divider().overlay(AppTheme.border)
                workspace
            }
            Divider().overlay(AppTheme.border)
            actionBar
        }
        .frame(
            minWidth: MainWindowLayout.minimumContentWidth,
            idealWidth: MainWindowLayout.preferredContentWidth,
            minHeight: 560,
            idealHeight: 740
        )
        .tint(AppTheme.accent)
        .background {
            LinearGradient(
                colors: [AppTheme.background, Color.white],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        }
        .preferredColorScheme(.light)
        .onChange(of: viewModel.mode) { _, mode in
            if mode == .monitor && workspaceTab == .tools {
                workspaceTab = .configuration
            }
        }
        .onDisappear { viewModel.shutdown() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willBecomeActiveNotification)) { _ in
            viewModel.refreshPermissions()
        }
        .task {
            while !Task.isCancelled {
                viewModel.refreshPermissions()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .sheet(isPresented: $viewModel.showWindowPicker) {
            WindowPickerView(windows: windowSelector.getAllWindows()) { window in
                viewModel.selectWindow(window)
                viewModel.appendLog("已选择窗口: \(window.title)")
            }
        }
        .sheet(isPresented: $viewModel.showVirtualKeyboard) {
            VirtualKeyboardView { key in
                viewModel.applySelectedKey(key)
            }
        }
        .sheet(isPresented: $viewModel.showPortalMarker) {
            if let window = viewModel.selectedWindow {
                PortalMarkerView(
                    windowID: window.windowID,
                    existingX: viewModel.settings.manualPortalX,
                    existingY: viewModel.settings.manualPortalY
                ) { x, y, _ in
                    viewModel.settings.manualPortalX = x
                    viewModel.settings.manualPortalY = y
                    viewModel.saveSettings()
                    if let x, let y {
                        viewModel.appendLog("传送门已标记: \(x), \(y)")
                    } else {
                        viewModel.appendLog("已清除手动传送门标记")
                    }
                }
            }
        }
        .sheet(isPresented: $viewModel.showFollowHealMarker) {
            if let window = viewModel.selectedWindow {
                PortalMarkerView(
                    windowID: window.windowID,
                    existingX: viewModel.settings.healAnchorX,
                    existingY: viewModel.settings.healAnchorY,
                    title: "标记跟补基准点",
                    showAutoPortal: false,
                    clearButtonTitle: "清除基准点",
                    loadedStatusText: "红点=跟补基准点，运行时只使用该点的 X 坐标"
                ) { x, y, region in
                    viewModel.settings.healAnchorX = x
                    viewModel.settings.healAnchorY = y
                    viewModel.settings.healMinimapRegion = (x != nil && y != nil) ? region : nil
                    viewModel.saveSettings()
                    if let x, let y {
                        viewModel.appendLog("跟补基准点已标记: \(x), \(y)")
                    } else {
                        viewModel.appendLog("已清除跟补基准点")
                    }
                }
            }
        }
        .sheet(isPresented: $viewModel.showMonitorZoneMarker) {
            if let window = viewModel.selectedWindow {
                // 安全区存的是归一化坐标，而这个弹窗按像素预填；标记时监控已停止，
                // 拿不到当前内容区尺寸，所以不预填，每次重新点一次中心点。
                PortalMarkerView(
                    windowID: window.windowID,
                    existingX: nil,
                    existingY: nil,
                    title: "标记安全区基准点",
                    showAutoPortal: false,
                    clearButtonTitle: "清除安全区",
                    loadedStatusText: "点击小地图设置安全区中心，长宽在监控面板里按百分比调整"
                ) { x, y, region in
                    viewModel.applyMonitorZoneAnchor(x: x, y: y, region: region)
                }
            }
        }
        .sheet(isPresented: $viewModel.showMapTopologyEditor) {
            if let window = viewModel.selectedWindow {
                MapTopologyLibraryView(
                    windowID: window.windowID,
                    maps: viewModel.settings.mapTopologies,
                    jumpKey: viewModel.settings.jumpKey,
                    allowsInputActions: viewModel.mode != .monitor,
                    cloudAccess: viewModel.remoteMonitorIsSuperAdmin
                ) { maps in
                    viewModel.settings.mapTopologies = maps
                    viewModel.saveSettings()
                    viewModel.appendLog("地图库已保存：共 \(maps.count) 张地图")
                } listCloudMaps: {
                    try await viewModel.listCloudMaps()
                } uploadCloudMaps: { maps in
                    try await viewModel.uploadCloudMaps(maps)
                } downloadCloudMap: { id in
                    try await viewModel.downloadCloudMap(id: id)
                }
            }
        }
        .alert(item: $viewModel.portalMarkerAlert) { alert in
            Alert(
                title: Text("无法打开标注"),
                message: Text(alert.message),
                dismissButton: .default(Text("知道了"))
            )
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 8)
                .padding(.top, 16)
                .padding(.bottom, 18)

            modeSelector
                .padding(.horizontal, 6)

            Divider()
                .overlay(AppTheme.border)
                .padding(.horizontal, 8)
                .padding(.vertical, 14)

            sidebarStatus
                .padding(.horizontal, 8)

            Spacer(minLength: 12)

            sidebarFooter
                .padding(6)
        }
        .frame(width: MainWindowLayout.sidebarWidth)
        .background(AppTheme.panel.opacity(0.82))
        .contentShape(Rectangle())
        .onTapGesture { dismissInputFocus() }
    }

    private var workspace: some View {
        VStack(spacing: 0) {
            workspaceHeader
            Divider().overlay(AppTheme.border)
            Group {
                switch workspaceTab {
                case .configuration:
                    ScrollView {
                        Group {
                            if viewModel.mode == .monitor {
                                MonitoringPanelView(viewModel: viewModel)
                            } else {
                                SettingsSectionView(viewModel: viewModel)
                            }
                        }
                        .padding(18)
                    }
                    .scrollIndicators(.hidden)
                case .logs:
                    logWorkspace
                case .tools:
                    ScrollView {
                        DebugPanelView(viewModel: viewModel)
                            .padding(18)
                            .onAppear { viewModel.debugExpanded = true }
                    }
                    .scrollIndicators(.hidden)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .contentShape(Rectangle())
        .onTapGesture { dismissInputFocus() }
    }

    private var workspaceHeader: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(viewModel.mode.title)
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.textPrimary)
                Text(modeDescription)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(AppTheme.textSecondary)
                if viewModel.remoteMonitorAuthenticated {
                    Label(viewModel.remoteClientName, systemImage: "desktopcomputer")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(AppTheme.accent)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 16)

            Picker("工作区", selection: $workspaceTab) {
                Label("配置", systemImage: "slider.horizontal.3")
                    .tag(WorkspaceTab.configuration)
                Label("日志", systemImage: "text.alignleft")
                    .tag(WorkspaceTab.logs)
                if viewModel.mode != .monitor {
                    Label("工具", systemImage: "hammer")
                        .tag(WorkspaceTab.tools)
                }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: viewModel.mode == .monitor ? 170 : 240)
            .accessibilityIdentifier("workspace.tabs")
        }
        .padding(.horizontal, 18)
        .frame(height: 68)
        .background(.ultraThinMaterial)
    }

    private var logWorkspace: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("运行日志")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(AppTheme.textPrimary)
                    Text("共 \(viewModel.logs.count) 条记录")
                        .font(.system(size: 10))
                        .foregroundStyle(AppTheme.textSecondary)
                }
                Spacer()
                Button("清空", action: viewModel.clearLogs)
                    .controlSize(.small)
                    .disabled(viewModel.logs.isEmpty)
            }
            .padding(.horizontal, 18)
            .padding(.vertical, 13)

            Divider().overlay(AppTheme.border)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 7) {
                        if viewModel.logs.isEmpty {
                            ContentUnavailableView(
                                "暂无运行日志",
                                systemImage: "text.alignleft",
                                description: Text("开始运行后，状态和检测结果会显示在这里")
                            )
                            .frame(maxWidth: .infinity, minHeight: 320)
                        } else {
                            ForEach(Array(viewModel.logs.enumerated()), id: \.offset) { index, line in
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Text(String(format: "%03d", index + 1))
                                        .foregroundStyle(AppTheme.textSecondary.opacity(0.65))
                                    Text(line)
                                        .foregroundStyle(AppTheme.textPrimary)
                                        .textSelection(.enabled)
                                }
                                .font(.system(size: 11, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                            }
                        }
                    }
                    .padding(18)
                }
                .onChange(of: viewModel.logs.count) { _, _ in
                    if let last = viewModel.logs.indices.last {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
        }
        .background(AppTheme.panel.opacity(0.56))
    }

    private var actionBar: some View {
        HStack(spacing: 14) {
            HStack(spacing: 8) {
                Circle()
                    .fill(viewModel.isRunning ? AppTheme.success : AppTheme.textSecondary.opacity(0.55))
                    .frame(width: 7, height: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(viewModel.isRunning ? "正在运行" : "准备就绪")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                    Text(viewModel.mode.title)
                        .font(.system(size: 9))
                        .foregroundStyle(AppTheme.textSecondary)
                }
            }

            Spacer()

            primaryAction
                .frame(minWidth: 220, idealWidth: 320, maxWidth: 360)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private var header: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [AppTheme.accent, Color(red: 0.27, green: 0.62, blue: 1)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            Image(systemName: "bolt.fill")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.white)
        }
        .frame(width: 38, height: 38)
        .shadow(color: AppTheme.accent.opacity(0.25), radius: 10, y: 5)
        .help("Auto Buff · v\(AppConstants.appVersion)")
        .accessibilityLabel("Auto Buff")
        .accessibilityIdentifier("app.title")
    }

    private func dismissInputFocus() {
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    private var sidebarStatus: some View {
        VStack(alignment: .leading, spacing: 8) {
            if viewModel.mode != .monitor {
                statusRow(
                    title: "辅助功能",
                    icon: "accessibility",
                    granted: viewModel.accessibilityGranted,
                    action: viewModel.requestAccessibility
                )
            }
            statusRow(
                title: "屏幕录制",
                icon: "rectangle.inset.filled",
                granted: viewModel.screenRecordingGranted,
                action: viewModel.requestScreenRecording
            )
            statusRow(
                title: "游戏窗口",
                icon: "macwindow",
                granted: viewModel.selectedWindow != nil,
                action: viewModel.identifyWindow
            )
        }
    }

    private func statusRow(
        title: String,
        icon: String,
        granted: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            ZStack(alignment: .bottomTrailing) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(AppTheme.textSecondary)
                    .frame(width: 38, height: 32)
                Circle()
                    .fill(granted ? AppTheme.success : AppTheme.warning)
                    .frame(width: 7, height: 7)
                    .overlay { Circle().stroke(AppTheme.panel, lineWidth: 2) }
                    .offset(x: -4, y: -3)
            }
        }
        .buttonStyle(.plain)
        .help("\(title)：\(granted ? "已就绪" : "需设置")")
        .accessibilityIdentifier(title == "游戏窗口" ? "window.identify" : "permission.\(title)")
    }

    private var modeSelector: some View {
        VStack(spacing: 5) {
            modeButton(
                .deadFlower,
                icon: "arrow.uturn.backward.circle.fill",
                subtitle: "释放后进入自由市场"
            )
            modeButton(
                .liveFlower,
                icon: "repeat.circle.fill",
                subtitle: "在当前地图循环释放"
            )
            modeButton(
                .followHeal,
                icon: "heart.circle.fill",
                subtitle: "自动补血并回位"
            )
            modeButton(
                .monitor,
                icon: "map.circle.fill",
                subtitle: "只读显示实时地图"
            )
        }
    }

    private func modeButton(
        _ mode: AppMode,
        icon: String,
        subtitle: String
    ) -> some View {
        let selected = viewModel.mode == mode
        return Button {
            guard !viewModel.isRunning else { return }
            viewModel.setMode(mode)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 19))
                    .foregroundStyle(selected ? AppTheme.accent : AppTheme.textSecondary)
            }
            .frame(maxWidth: .infinity, minHeight: 42)
            .background(selected ? AppTheme.accentSoft : AppTheme.panel)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(selected ? AppTheme.accent.opacity(0.55) : AppTheme.border)
            }
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isRunning)
        .help("\(mode.title)：\(subtitle)")
        .accessibilityIdentifier("mode.\(mode.rawValue)")
    }

    private var sidebarFooter: some View {
        VStack(alignment: .center, spacing: 9) {
            Button {
                viewModel.requestMapTopologyEditor()
            } label: {
                Image(systemName: "map")
                    .frame(width: 40, height: 28)
            }
            .disabled(viewModel.isRunning)
            .help("地图")

            if viewModel.mode == .deadFlower {
                Button {
                    Task { await viewModel.requestPortalMarker() }
                } label: {
                    if viewModel.isCheckingPortalMarker {
                        ProgressView().controlSize(.mini)
                            .frame(width: 40, height: 28)
                    } else {
                        Image(systemName: "mappin.and.ellipse")
                            .frame(width: 40, height: 28)
                    }
                }
                .disabled(viewModel.isRunning || viewModel.isCheckingPortalMarker)
                .help("传送门")
            }

            if !viewModel.screenRecordingGranted
                || (viewModel.mode != .monitor && !viewModel.accessibilityGranted) {
                Button {
                    if viewModel.mode == .monitor {
                        viewModel.requestScreenRecording()
                    } else {
                        viewModel.repairAccessibility()
                    }
                } label: {
                    Image(systemName: "wrench.and.screwdriver")
                        .frame(width: 40, height: 28)
                }
                .help("修复系统权限")
            }
        }
        .font(.system(size: 10, weight: .medium))
        .buttonStyle(.borderless)
        .foregroundStyle(AppTheme.accent)
    }

    private var modeDescription: String {
        switch viewModel.mode {
        case .deadFlower: return "释放 Buff 后自动进入自由市场"
        case .liveFlower: return "在当前地图循环释放 Buff"
        case .followHeal: return "自动补血、位置修正并回到基准点"
        case .monitor: return "只读取游戏画面并显示实时地图"
        }
    }

    private var primaryAction: some View {
        Button {
            viewModel.toggleWorker()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: viewModel.isRunning ? "stop.fill" : "play.fill")
                Text(primaryActionTitle)
                    .fontWeight(.semibold)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 11)
            .foregroundStyle(.white)
            .background(viewModel.isRunning ? AppTheme.danger : AppTheme.accent)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .buttonStyle(.plain)
        .shadow(
            color: (viewModel.isRunning ? AppTheme.danger : AppTheme.accent).opacity(0.22),
            radius: 10,
            y: 4
        )
        .keyboardShortcut(.return, modifiers: [])
        .accessibilityIdentifier("worker.toggle")
    }

    private var primaryActionTitle: String {
        if viewModel.mode == .monitor {
            return viewModel.isRunning ? "停止监控" : "开始监控"
        }
        return viewModel.isRunning ? "停止运行" : "开始运行"
    }
}

private enum WorkspaceTab: Hashable {
    case configuration
    case logs
    case tools
}
