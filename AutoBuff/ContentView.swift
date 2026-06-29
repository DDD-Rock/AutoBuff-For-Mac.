import AppKit
import SwiftUI

@available(macOS 14.0, *)
struct ContentView: View {
    @StateObject private var viewModel = MainViewModel()
    private let windowSelector = WindowSelector()

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                header
                    .contentShape(Rectangle())
                    .onTapGesture {
                        dismissInputFocus()
                    }
                permissionBar
                modeSelector
                SettingsSectionView(viewModel: viewModel)
                LogSectionView(logs: viewModel.logs, onClear: viewModel.clearLogs)
                DebugPanelView(viewModel: viewModel)
            }
            .padding(18)
            .contentShape(Rectangle())
            .onTapGesture {
                dismissInputFocus()
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            primaryAction
                .padding(.horizontal, 18)
                .padding(.vertical, 11)
                .background(.ultraThinMaterial)
                .overlay(alignment: .top) {
                    Divider().overlay(AppTheme.border)
                }
        }
        .scrollIndicators(.hidden)
        .frame(minWidth: 480, idealWidth: 520, minHeight: 500, idealHeight: 560)
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
        .alert(item: $viewModel.portalMarkerAlert) { alert in
            Alert(
                title: Text("无法标记传送门"),
                message: Text(alert.message),
                dismissButton: .default(Text("知道了"))
            )
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [AppTheme.accent, Color(red: 0.27, green: 0.62, blue: 1)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                Image(systemName: "bolt.fill")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.white)
            }
            .frame(width: 44, height: 44)
            .shadow(color: AppTheme.accent.opacity(0.25), radius: 10, y: 5)

            VStack(alignment: .leading, spacing: 2) {
                Text("YzY - Auto Buff")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .foregroundStyle(AppTheme.textPrimary)
                    .accessibilityIdentifier("app.title")
                Text("Power by 小新")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(AppTheme.textSecondary)
                    .accessibilityIdentifier("app.subtitle")
            }

            Spacer()

            Text("v\(AppConstants.appVersion)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(AppTheme.textSecondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(AppTheme.panel)
                .clipShape(Capsule())
                .overlay { Capsule().stroke(AppTheme.border) }
        }
    }

    private func dismissInputFocus() {
        NSApp.keyWindow?.makeFirstResponder(nil)
    }

    private var permissionBar: some View {
        HStack(spacing: 6) {
            statusChip(
                title: "辅助功能",
                granted: viewModel.accessibilityGranted,
                action: viewModel.requestAccessibility
            )
            statusChip(
                title: "屏幕录制",
                granted: viewModel.screenRecordingGranted,
                action: viewModel.requestScreenRecording
            )
            statusChip(
                title: "游戏窗口",
                granted: viewModel.selectedWindow != nil,
                action: viewModel.identifyWindow
            )

            if let window = viewModel.selectedWindow {
                Text("\(window.title) · \(Int(window.size.width))×\(Int(window.size.height))")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if viewModel.mode == .deadFlower {
                    Button {
                        Task { await viewModel.requestPortalMarker() }
                    } label: {
                        if viewModel.isCheckingPortalMarker {
                            ProgressView()
                                .controlSize(.mini)
                        } else {
                            Image(systemName: "mappin.and.ellipse")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(AppTheme.accent)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.isRunning || viewModel.isCheckingPortalMarker)
                    .help("标记传送门")
                }
            } else {
                Spacer(minLength: 0)
            }

            if !viewModel.accessibilityGranted || !viewModel.screenRecordingGranted {
                Button {
                    viewModel.repairAccessibility()
                } label: {
                    Image(systemName: "wrench.and.screwdriver")
                        .foregroundStyle(AppTheme.textSecondary)
                }
                .buttonStyle(.plain)
                .help("修复系统权限")
            }
        }
    }

    private func statusChip(title: String, granted: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Circle()
                    .fill(granted ? AppTheme.success : AppTheme.warning)
                    .frame(width: 6, height: 6)
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AppTheme.textSecondary)
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(AppTheme.panel.opacity(0.9))
            .clipShape(Capsule())
            .overlay { Capsule().stroke(AppTheme.border) }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(title == "游戏窗口" ? "window.identify" : "permission.\(title)")
    }

    private var modeSelector: some View {
        HStack(spacing: 8) {
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
        }
    }

    private func modeButton(_ mode: AppMode, icon: String, subtitle: String) -> some View {
        let selected = viewModel.mode == mode
        return Button {
            guard !viewModel.isRunning else { return }
            viewModel.setMode(mode)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 19))
                    .foregroundStyle(selected ? AppTheme.accent : AppTheme.textSecondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(mode.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                    Text(subtitle)
                        .font(.system(size: 9))
                        .foregroundStyle(AppTheme.textSecondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background(selected ? AppTheme.accentSoft : AppTheme.panel)
            .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(selected ? AppTheme.accent.opacity(0.55) : AppTheme.border)
            }
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isRunning)
        .accessibilityIdentifier("mode.\(mode.rawValue)")
    }

    private var primaryAction: some View {
        Button {
            viewModel.toggleWorker()
        } label: {
            HStack(spacing: 8) {
                Image(systemName: viewModel.isRunning ? "stop.fill" : "play.fill")
                Text(viewModel.isRunning ? "停止运行" : "开始运行")
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
}
