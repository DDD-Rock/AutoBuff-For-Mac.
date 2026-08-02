import SwiftUI
import UniformTypeIdentifiers

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
    @State private var showsRuneTestImporter = false
    @State private var imageTestKind: MonitorImageTestKind = .rune

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

            remoteMonitorActionsSection

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

            mouseFollowVerificationReadout

            runeAlertImageTestRow

            safeZoneReadout

            safeZoneControls

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
        let recognitionMethod = viewModel.monitorEXPReading?.recognitionMethod
        let methodColor = switch recognitionMethod {
        case .ppOCRv4:
            AppTheme.success
        case .fixedTemplate:
            AppTheme.accent
        case nil:
            AppTheme.textSecondary
        }
        return HStack(spacing: 12) {
            Image(systemName: "chart.bar.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(
                    viewModel.monitorEXPReading == nil
                        ? AppTheme.textSecondary
                        : AppTheme.success
                )

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text("经验识别")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(AppTheme.textSecondary)
                    Text(recognitionMethod?.displayName ?? "未识别")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(methodColor)
                        .lineLimit(1)
                        .frame(width: 58)
                        .padding(.vertical, 2)
                        .background(methodColor.opacity(0.12), in: Capsule())
                }
                Text(viewModel.monitorEXPStatus)
                    .font(.system(size: 9))
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(1)
            }

            Spacer()

            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .trailing, spacing: 1) {
                    Text("当前 EXP")
                        .font(.system(size: 9))
                        .foregroundStyle(AppTheme.textSecondary)
                    Text(viewModel.monitorEXPReading.map { "\($0.currentEXP)" } ?? "--")
                        .font(.system(size: 15, weight: .bold, design: .monospaced))
                        .foregroundStyle(
                            viewModel.monitorEXPReading == nil
                                ? AppTheme.textSecondary
                                : AppTheme.textPrimary
                        )
                }
                VStack(alignment: .trailing, spacing: 1) {
                    Text("已获得")
                        .font(.system(size: 9))
                        .foregroundStyle(AppTheme.textSecondary)
                    Text(viewModel.monitorEXPReading.map { "\($0.percentText)%" } ?? "--%")
                        .font(.system(size: 15, weight: .bold, design: .monospaced))
                        .foregroundStyle(
                            viewModel.monitorEXPReading == nil
                                ? AppTheme.textSecondary
                                : AppTheme.success
                        )
                }
            }
            .monospacedDigit()
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

    private var mouseFollowVerificationReadout: some View {
        let isPresent = viewModel.monitorMouseFollowVerificationPresent
        return HStack(spacing: 12) {
            Image(systemName: isPresent ? "cursorarrow.motionlines.click" : "checkmark.shield")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isPresent ? AppTheme.danger : AppTheme.textSecondary)

            VStack(alignment: .leading, spacing: 2) {
                Text("鼠标跟随验证")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(AppTheme.textSecondary)
                Text(
                    viewModel.isRunning
                        ? (isPresent ? "验证弹窗已出现，请立即人工处理" : "未出现验证弹窗")
                        : "尚未开始监控"
                )
                .font(.system(size: 9))
                .foregroundStyle(AppTheme.textSecondary)
                .lineLimit(1)
            }

            Spacer()

            if isPresent, let detection = viewModel.monitorMouseFollowVerificationDetection {
                Text("置信度 \(Int((detection.confidence * 100).rounded()))%")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(AppTheme.danger)
            } else {
                Text(isPresent ? "紧急" : "正常")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(isPresent ? AppTheme.danger : AppTheme.textSecondary)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(
            (isPresent ? AppTheme.danger.opacity(0.14) : AppTheme.accentSoft.opacity(0.55)),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(
                    isPresent ? AppTheme.danger.opacity(0.60) : AppTheme.border.opacity(0.7),
                    lineWidth: 1
                )
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("monitor.mouseFollowVerificationReadout")
    }

    private var safeZoneReadout: some View {
        let zone = viewModel.settings.monitorSafeZone
        let isOutside = viewModel.monitorZoneOutside
        return HStack(spacing: 12) {
            Image(systemName: isOutside ? "figure.walk.departure" : "shield.checkered")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isOutside ? AppTheme.danger : AppTheme.textSecondary)

            VStack(alignment: .leading, spacing: 2) {
                Text("安全区")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(AppTheme.textSecondary)
                Text(safeZoneStatusText)
                    .font(.system(size: 9))
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(1)
            }

            Spacer()

            if zone != nil {
                Text(isOutside ? "已离开" : "区内")
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(isOutside ? AppTheme.danger : AppTheme.success)
            } else {
                Text("未设置")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(AppTheme.textSecondary)
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(
            (isOutside ? AppTheme.danger.opacity(0.10) : AppTheme.accentSoft.opacity(0.55)),
            in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(
                    isOutside ? AppTheme.danger.opacity(0.45) : AppTheme.border.opacity(0.7),
                    lineWidth: 1
                )
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("monitor.safeZoneReadout")
    }

    private var safeZoneStatusText: String {
        guard let zone = viewModel.settings.monitorSafeZone else {
            return "设置基准点后，角色离开范围会报警"
        }
        let center = String(
            format: "中心 %.0f%% · %.0f%%",
            zone.center.x * 100,
            zone.center.y * 100
        )
        if viewModel.isRunning {
            return viewModel.monitorZoneOutside
                ? "角色已离开安全区，正在报警"
                : "\(center)，角色在范围内"
        }
        return "\(center)，开始监控后生效"
    }

    /// 基准点用与跟补相同的点击取点弹窗设置；长宽按小地图百分比调整，
    /// 这样不依赖当前分辨率，换窗口大小也不用重设。
    private var safeZoneControls: some View {
        HStack(spacing: 8) {
            Button(viewModel.settings.monitorSafeZone == nil ? "设置基准点" : "重设基准点") {
                viewModel.requestMonitorZoneMarker()
            }
            .controlSize(.small)
            .disabled(viewModel.isRunning)
            .help("停止监控后，在小地图上点击安全区中心")

            zoneSideStepper(title: "宽", percent: $viewModel.monitorZoneWidthPercent)
            zoneSideStepper(title: "高", percent: $viewModel.monitorZoneHeightPercent)

            if viewModel.settings.monitorSafeZone != nil {
                Button("清除") {
                    viewModel.clearMonitorSafeZone()
                }
                .controlSize(.small)
                .disabled(viewModel.isRunning)
            }

            Spacer(minLength: 0)
        }
        .accessibilityIdentifier("monitor.safeZoneControls")
    }

    /// 标签用固定宽度：百分比在 2%~100% 之间变化时行的固有宽度保持不变，
    /// 不会因为多一位数字就重新协商整行布局。
    private func zoneSideStepper(title: String, percent: Binding<Double>) -> some View {
        Stepper(value: percent, in: 2...100, step: 5) {
            Text(String(format: "%@ %.0f%%", title, percent.wrappedValue))
                .font(.system(size: 10, design: .monospaced))
                .monospacedDigit()
                .frame(width: 52, alignment: .leading)
        }
        .disabled(viewModel.settings.monitorSafeZone == nil)
    }

    /// 用本地截图回放符文或测谎链路，方便在告警不易复现时验证。
    private var runeAlertImageTestRow: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                Picker("测试类型", selection: $imageTestKind) {
                    ForEach(MonitorImageTestKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 112)
                .onChange(of: imageTestKind) { _, _ in
                    viewModel.monitorRuneTestSummary = ""
                }

                Button {
                    showsRuneTestImporter = true
                } label: {
                    Label("图片测试", systemImage: "photo.badge.checkmark")
                }
                .controlSize(.small)
                .disabled(!viewModel.isRunning || viewModel.monitorRuneTestBusy)
                .help("选择\(imageTestKind.imagePrompt)，走一遍识别、面板提示和推送")

                Spacer(minLength: 0)
            }

            // 结果文案单独一行铺满宽度。它不能和按钮同行、也不能用 fixedSize
            // 反推高度：文案里可能带一串文件名，单行理想宽度远超窗口，
            // 会被 AppKit 反复重算结构区域直到抛异常。
            Text(runeTestHintText)
                .font(.system(size: 9))
                .foregroundStyle(AppTheme.textSecondary)
                .lineLimit(2)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fileImporter(
            isPresented: $showsRuneTestImporter,
            allowedContentTypes: [.png, .jpeg, .image],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                viewModel.runMonitorImageTest(kind: imageTestKind, urls: urls)
            case .failure(let error):
                viewModel.reportMonitorImageTestFailure(error)
            }
        }
        .accessibilityIdentifier("monitor.alertImageTest")
    }

    private var runeTestHintText: String {
        if !viewModel.monitorRuneTestSummary.isEmpty {
            return viewModel.monitorRuneTestSummary
        }
        return viewModel.isRunning
            ? "选择\(imageTestKind.imagePrompt)，走一遍识别与推送"
            : "开始监控后可用截图回放验证"
    }

    private var remoteMonitorActionsSection: some View {
        HStack(spacing: 8) {
            Button {
                viewModel.openRemoteMonitorPage()
            } label: {
                Label("打开监控网页", systemImage: "safari")
            }
            .buttonStyle(.borderedProminent)

            Button {
                viewModel.copyRemoteMonitorPageLink()
            } label: {
                Label(
                    viewModel.remoteMonitorLinkCopied ? "已复制" : "复制链接",
                    systemImage: viewModel.remoteMonitorLinkCopied ? "checkmark" : "doc.on.doc"
                )
            }
            .buttonStyle(.bordered)

            Spacer()
        }
        .controlSize(.small)
        .accessibilityIdentifier("monitor.remoteActions")
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
                    playerContentSize: viewModel.monitorContentSize,
                    safeZone: viewModel.settings.monitorSafeZone,
                    isOutsideSafeZone: viewModel.monitorZoneOutside
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
