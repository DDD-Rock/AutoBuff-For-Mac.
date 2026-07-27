import SwiftUI

enum MonitorCoordinateReadout {
    static func positionText(_ point: CGPoint?) -> String {
        guard let point else {
            return "X -- · Y --"
        }
        return String(
            format: "X %.1f · Y %.1f",
            Double(point.x),
            Double(point.y)
        )
    }

    static func rangeText(contentSize: CGSize) -> String {
        let width = Int(contentSize.width.rounded(.down))
        let height = Int(contentSize.height.rounded(.down))
        guard width > 0, height > 0 else {
            return "范围 X -- · Y --"
        }
        return "范围 X 0–\(width - 1) · Y 0–\(height - 1)"
    }
}

@available(macOS 14.0, *)
struct MonitoringPanelView: View {
    @ObservedObject var viewModel: MainViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("地图监控")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(AppTheme.textPrimary)
                        .accessibilityIdentifier("monitor.title")
                }
                Spacer()
                Button("管理地图") {
                    viewModel.requestMapTopologyEditor()
                }
                .controlSize(.small)
                .disabled(viewModel.isRunning)
            }

            remoteAccountSection

            Picker("显示方式", selection: $viewModel.settings.monitorDisplayMode) {
                ForEach(MonitorDisplayMode.allCases, id: \.self) { displayMode in
                    Text(displayMode.title).tag(displayMode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(viewModel.isRunning && viewModel.monitorImage == nil)
            .onChange(of: viewModel.settings.monitorDisplayMode) { _, _ in
                viewModel.saveSettings()
            }
            .accessibilityIdentifier("monitor.displayMode")

            monitorCanvas

            expReadout

            runeAlertReadout

            HStack(spacing: 8) {
                Circle()
                    .fill(viewModel.isRunning ? AppTheme.success : AppTheme.textSecondary)
                    .frame(width: 7, height: 7)
                Text(viewModel.monitorStatusText)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(2)
                Spacer()
                if viewModel.monitorFPS > 0 {
                    Text(String(format: "%.1f FPS", viewModel.monitorFPS))
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(AppTheme.textSecondary)
                }
                if viewModel.monitorImage != nil {
                    Label(
                        viewModel.monitorPlayerPoint == nil ? "未识别玩家" : "玩家已识别",
                        systemImage: viewModel.monitorPlayerPoint == nil
                            ? "location.slash"
                            : "location.fill"
                    )
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(
                        viewModel.monitorPlayerPoint == nil
                            ? AppTheme.warning
                            : AppTheme.success
                    )
                }
            }

            if viewModel.monitorImage != nil {
                HStack(spacing: 10) {
                    Label(
                        MonitorCoordinateReadout.positionText(
                            viewModel.monitorPlayerPoint
                        ),
                        systemImage: "scope"
                    )
                    .foregroundStyle(
                        viewModel.monitorPlayerPoint == nil
                            ? AppTheme.warning
                            : AppTheme.textPrimary
                    )

                    Label(
                        "队友 \(viewModel.monitorTeammatePoints.count)",
                        systemImage: "person.2.fill"
                    )
                    .foregroundStyle(
                        viewModel.monitorTeammatePoints.isEmpty
                            ? AppTheme.textSecondary
                            : Color.orange
                    )

                    Label(
                        "红点 \(viewModel.monitorOtherPlayerPoints.count)",
                        systemImage: "person.2.fill"
                    )
                    .foregroundStyle(
                        viewModel.monitorOtherPlayerPoints.isEmpty
                            ? AppTheme.textSecondary
                            : Color.red
                    )

                    Spacer()

                    Text(
                        MonitorCoordinateReadout.rangeText(
                            contentSize: viewModel.monitorContentSize
                        )
                    )
                    .foregroundStyle(AppTheme.textSecondary)
                }
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .help("小地图纯内容区坐标：左上角为 (0, 0)，X 向右，Y 向下")
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("monitor.coordinates")
            }
        }
        .appCard()
    }

    private var expReadout: some View {
        HStack(spacing: 12) {
            Image(systemName: "chart.bar.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(
                    viewModel.monitorEXPReading == nil
                        ? AppTheme.textSecondary
                        : AppTheme.success
                )

            VStack(alignment: .leading, spacing: 2) {
                Text("经验识别")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(AppTheme.textSecondary)
                Text(viewModel.monitorEXPStatus)
                    .font(.system(size: 9))
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(1)
            }

            Spacer()

            if let reading = viewModel.monitorEXPReading {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("当前 EXP")
                            .font(.system(size: 9))
                            .foregroundStyle(AppTheme.textSecondary)
                        Text("\(reading.currentEXP)")
                            .font(.system(size: 15, weight: .bold, design: .monospaced))
                            .foregroundStyle(AppTheme.textPrimary)
                    }
                    VStack(alignment: .trailing, spacing: 1) {
                        Text("已获得")
                            .font(.system(size: 9))
                            .foregroundStyle(AppTheme.textSecondary)
                        Text("\(reading.percentText)%")
                            .font(.system(size: 15, weight: .bold, design: .monospaced))
                            .foregroundStyle(AppTheme.success)
                    }
                }
                .monospacedDigit()
            } else {
                Text("EXP --  (--%)")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(AppTheme.textSecondary)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(AppTheme.accentSoft.opacity(0.55), in: RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(AppTheme.border.opacity(0.7), lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("monitor.expReadout")
    }

    private var runeAlertReadout: some View {
        let isPresent = viewModel.monitorRuneAlertPresent
        return HStack(spacing: 12) {
            Image(systemName: isPresent ? "exclamationmark.triangle.fill" : "checkmark.seal")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isPresent ? AppTheme.danger : AppTheme.textSecondary)

            VStack(alignment: .leading, spacing: 2) {
                Text("符文诅咒")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(AppTheme.textSecondary)
                Text(
                    viewModel.isRunning
                        ? (isPresent ? "画面出现符文提示，请尽快解除" : "未出现符文提示")
                        : "尚未开始监控"
                )
                .font(.system(size: 9))
                .foregroundStyle(AppTheme.textSecondary)
                .lineLimit(1)
            }

            Spacer()

            if isPresent, let detection = viewModel.monitorRuneAlertDetection {
                Text("置信度 \(Int((detection.confidence * 100).rounded()))%")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(AppTheme.danger)
            } else {
                Text(isPresent ? "已触发" : "正常")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(isPresent ? AppTheme.danger : AppTheme.textSecondary)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(
            (isPresent ? AppTheme.danger.opacity(0.10) : AppTheme.accentSoft.opacity(0.55)),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(
                    isPresent ? AppTheme.danger.opacity(0.45) : AppTheme.border.opacity(0.7),
                    lineWidth: 1
                )
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("monitor.runeAlertReadout")
    }

    private var remoteAccountSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Label("远程预览", systemImage: "network")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(AppTheme.textPrimary)
                Spacer()
            }

            if viewModel.remoteMonitorAuthenticated {
                HStack(spacing: 8) {
                    Image(systemName: "person.crop.circle.fill")
                        .foregroundStyle(AppTheme.success)
                    Text(viewModel.settings.monitorAccountUsername)
                        .font(.system(size: 11, weight: .semibold))
                    Spacer()
                    Button("复制链接") {
                        viewModel.copyRemoteMonitorPreviewURL()
                    }
                    .controlSize(.small)
                    .disabled(viewModel.remoteMonitorPreviewURL.isEmpty)
                    Button("打开预览") {
                        viewModel.openRemoteMonitorPreviewURL()
                    }
                    .controlSize(.small)
                    .disabled(viewModel.remoteMonitorPreviewURL.isEmpty)
                    Button("退出") {
                        viewModel.logoutRemoteMonitor()
                    }
                    .controlSize(.small)
                }

                if !viewModel.remoteMonitorPreviewURL.isEmpty {
                    Text(viewModel.remoteMonitorPreviewURL)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(AppTheme.textSecondary)
                        .lineLimit(1)
                        .textSelection(.enabled)
                }
            } else {
                HStack(spacing: 8) {
                    TextField("用户名", text: $viewModel.settings.monitorAccountUsername)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 110)
                    SecureField("密码（至少 8 位）", text: $viewModel.remoteMonitorPassword)
                        .textFieldStyle(.roundedBorder)
                        .frame(minWidth: 140)
                        .onSubmit {
                            viewModel.loginRemoteMonitor()
                        }
                    Button("登录") {
                        viewModel.loginRemoteMonitor()
                    }
                    .controlSize(.small)
                    .disabled(viewModel.remoteMonitorAuthBusy)
                    Button("网页注册") {
                        viewModel.openRemoteMonitorRegistrationPage()
                    }
                    .controlSize(.small)
                }
            }

        }
        .padding(10)
        .background(AppTheme.background.opacity(0.75))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(AppTheme.border)
        }
        .accessibilityIdentifier("monitor.remoteAccount")
    }

    private var monitorCanvas: some View {
        ZStack {
            Color(red: 0.055, green: 0.065, blue: 0.085)

            if viewModel.settings.monitorDisplayMode != .annotationsOnly,
               let image = viewModel.monitorImage {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.none)
                    .scaledToFit()
            }

            if viewModel.settings.monitorDisplayMode != .minimapOnly {
                MapTopologyOverlayView(
                    topology: viewModel.monitorMatchedTopology,
                    playerPoint: viewModel.monitorPlayerPoint,
                    teammatePoints: viewModel.monitorTeammatePoints,
                    otherPlayerPoints: viewModel.monitorOtherPlayerPoints,
                    playerContentSize: viewModel.monitorContentSize
                )
            }

            if viewModel.monitorImage == nil {
                VStack(spacing: 8) {
                    Image(systemName: "map")
                        .font(.system(size: 28))
                        .foregroundStyle(AppTheme.textSecondary)
                    Text(viewModel.isRunning ? "正在读取实时小地图..." : "开始监控后显示实时小地图")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(AppTheme.textSecondary)
                }
            } else if viewModel.settings.monitorDisplayMode != .minimapOnly,
                      viewModel.monitorMatchedTopology == nil {
                VStack {
                    Text("未匹配到已标注地图")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.black.opacity(0.7))
                        .clipShape(Capsule())
                    Spacer()
                }
                .padding(.top, 8)
            }
        }
        .aspectRatio(canvasAspectRatio, contentMode: .fit)
        .frame(maxWidth: .infinity)
        .background(.black)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(AppTheme.border)
        }
        .accessibilityIdentifier("monitor.canvas")
    }

    private var canvasAspectRatio: CGFloat {
        guard viewModel.monitorContentSize.width > 0,
              viewModel.monitorContentSize.height > 0 else {
            return 16 / 9
        }
        return viewModel.monitorContentSize.width / viewModel.monitorContentSize.height
    }
}
