import SwiftUI

@available(macOS 14.0, *)
struct SettingsSectionView: View {
    @ObservedObject var viewModel: MainViewModel
    @FocusState private var focusedDurationID: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("BUFF 配置")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(AppTheme.textPrimary)
                        .accessibilityIdentifier("settings.title")
                    Text("按键完成后立即开始独立倒计时")
                        .font(.system(size: 10))
                        .foregroundStyle(AppTheme.textSecondary)
                }
                Spacer()
                if viewModel.settings.buffs.count < AppConstants.maxBuffSlotCount {
                    Button {
                        viewModel.addBuff()
                    } label: {
                        Label("添加", systemImage: "plus")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(AppTheme.accent)
                    .disabled(viewModel.isRunning)
                    .accessibilityIdentifier("buff.add")
                }
            }

            VStack(spacing: 0) {
                ForEach(viewModel.settings.buffs.indices, id: \.self) { index in
                    BuffRowView(
                        buff: $viewModel.settings.buffs[index],
                        countdown: viewModel.countdowns[viewModel.settings.buffs[index].id],
                        canRemove: viewModel.settings.buffs.count > AppConstants.defaultBuffSlotCount,
                        isRunning: viewModel.isRunning,
                        focusedDurationID: $focusedDurationID,
                        onKeyTap: { viewModel.openKeyboard(for: .buff(index)) },
                        onRemove: {
                            focusedDurationID = nil
                            viewModel.removeBuff(at: index)
                        }
                    )
                    if index < viewModel.settings.buffs.count - 1 {
                        Divider().overlay(AppTheme.border)
                    }
                }
            }
            .background(AppTheme.background.opacity(0.55))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            Divider().overlay(AppTheme.border)

            partyInviteOption

            Divider().overlay(AppTheme.border)

            mapTopologyOption

            Divider().overlay(AppTheme.border)

            if viewModel.mode == .liveFlower {
                liveOptions
            } else if viewModel.mode == .deadFlower {
                deadOptions
            } else {
                followHealOptions
            }
        }
        .appCard()
        .onAppear {
            focusedDurationID = nil
        }
        .onChange(of: viewModel.settings) { _, _ in viewModel.saveSettings() }
    }

    private var partyInviteOption: some View {
        HStack(spacing: 10) {
            Label("自动同意组队", systemImage: "person.2.badge.gearshape")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppTheme.textPrimary)
            Spacer(minLength: 0)
            Text(viewModel.isPartyInviteWorkerActive ? "运行中" : "待机")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(viewModel.isPartyInviteWorkerActive ? AppTheme.success : AppTheme.textSecondary)
                .frame(width: 42, alignment: .trailing)
            Toggle(
                "",
                isOn: Binding(
                    get: { viewModel.settings.autoAcceptPartyInviteEnabled },
                    set: { viewModel.setAutoAcceptPartyInviteEnabled($0) }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
        }
        .frame(minHeight: 24)
    }

    private var mapTopologyOption: some View {
        HStack(spacing: 10) {
            Label("地图标注", systemImage: "map")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppTheme.textPrimary)
            Spacer(minLength: 0)
            if !viewModel.settings.mapTopologies.isEmpty {
                Text("已创建 \(viewModel.settings.mapTopologies.count) 张地图")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(1)
            } else {
                Text("未标注")
                    .font(.system(size: 10))
                    .foregroundStyle(AppTheme.textSecondary)
            }
            Button("管理地图") {
                viewModel.requestMapTopologyEditor()
            }
            .controlSize(.small)
            .disabled(viewModel.isRunning)
        }
        .frame(minHeight: 24)
    }

    private var liveOptions: some View {
        HStack(alignment: .top, spacing: 10) {
            optionColumn("移动方式") {
                Picker("", selection: $viewModel.settings.movementMode) {
                    ForEach(MovementMode.allCases, id: \.self) { item in
                        Text(item.label).tag(item)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
            }

            Divider().frame(height: 44)

            optionColumn("提前释放") {
                HStack(spacing: 6) {
                    Toggle("", isOn: $viewModel.settings.randomBehaviorEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                    if viewModel.settings.randomBehaviorEnabled {
                        Stepper(
                            "\(viewModel.settings.randomBehaviorValue) 秒",
                            value: $viewModel.settings.randomBehaviorValue,
                            in: 1...60
                        )
                        .font(.system(size: 11))
                        .frame(width: 82)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider().frame(height: 44)

            optionColumn("空闲时坐椅子") {
                HStack(spacing: 6) {
                    Toggle("", isOn: $viewModel.settings.sitChairEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                    if viewModel.settings.sitChairEnabled {
                        Button(viewModel.settings.chairKey) {
                            viewModel.openKeyboard(for: .chairKey)
                        }
                        .controlSize(.small)
                        .frame(width: 42)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minHeight: 44)
        .allowsHitTesting(!viewModel.isRunning)
    }
    
    private var deadOptions: some View {
        HStack(alignment: .top, spacing: 10) {
            optionColumn("出市场后移动方式") {
                Picker("", selection: $viewModel.settings.preSkillMoveMode) {
                    ForEach(PreSkillMoveMode.allCases, id: \.self) { item in
                        Text(item.label).tag(item)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
            }

            Divider().frame(height: 44)

            optionColumn("跳跃键") {
                Button(viewModel.settings.jumpKey) {
                    viewModel.openKeyboard(for: .jumpKey)
                }
                .controlSize(.small)
                .frame(width: 52)
            }

            Divider().frame(height: 44)

            optionColumn("空闲时坐椅子") {
                HStack(spacing: 6) {
                    Toggle("", isOn: $viewModel.settings.sitChairEnabled)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                    if viewModel.settings.sitChairEnabled {
                        Button(viewModel.settings.chairKey) {
                            viewModel.openKeyboard(for: .chairKey)
                        }
                        .controlSize(.small)
                        .frame(width: 42)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minHeight: 44)
        .allowsHitTesting(!viewModel.isRunning)
    }

    private var followHealOptions: some View {
        HStack(alignment: .top, spacing: 10) {
            optionColumn("加血技能键") {
                Button(viewModel.settings.healSkillKey.isEmpty ? "选键" : viewModel.settings.healSkillKey) {
                    viewModel.openKeyboard(for: .healSkillKey)
                }
                .controlSize(.small)
                .frame(width: 58)
            }

            Divider().frame(height: 44)

            optionColumn("基准点") {
                Button(followHealAnchorTitle) {
                    viewModel.requestFollowHealMarker()
                }
                .controlSize(.small)
                .frame(width: 86)
            }

            Divider().frame(height: 54)

            optionColumn("修正按住") {
                VStack(alignment: .leading, spacing: 2) {
                    Stepper(
                        "最短 \(viewModel.settings.followHealAdjustMinMS)ms",
                        value: $viewModel.settings.followHealAdjustMinMS,
                        in: 50...1000,
                        step: 10
                    )
                    Stepper(
                        "最长 \(viewModel.settings.followHealAdjustMaxMS)ms",
                        value: $viewModel.settings.followHealAdjustMaxMS,
                        in: 50...1000,
                        step: 10
                    )
                }
                .font(.system(size: 10))
                .frame(width: 96, alignment: .leading)
            }

            Spacer(minLength: 0)
        }
        .frame(minHeight: 54)
        .allowsHitTesting(!viewModel.isRunning)
    }

    private var followHealAnchorTitle: String {
        if let x = viewModel.settings.healAnchorX {
            return "X \(x)"
        }
        return "标记点位"
    }

    private func optionColumn<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(AppTheme.textSecondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct BuffRowView: View {
    @Binding var buff: BuffConfig
    let countdown: Int?
    let canRemove: Bool
    let isRunning: Bool
    let focusedDurationID: FocusState<Int?>.Binding
    let onKeyTap: () -> Void
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 9) {
            Toggle("", isOn: $buff.enabled)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .disabled(isRunning)

            Text("BUFF \(buff.id)")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(buff.enabled ? AppTheme.textPrimary : AppTheme.textSecondary)
                .frame(width: 48, alignment: .leading)

            Button(buff.key.isEmpty ? "选键" : buff.key, action: onKeyTap)
                .controlSize(.small)
                .frame(width: 54)
                .disabled(isRunning)

            HStack(spacing: 3) {
                TextField("时长", value: $buff.duration, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.trailing)
                    .focused(focusedDurationID, equals: buff.id)
                    .accessibilityIdentifier("buff.duration.\(buff.id)")
                    .frame(width: 62)
                    .disabled(isRunning)
                Text("秒")
                    .font(.system(size: 10))
                    .foregroundStyle(AppTheme.textSecondary)
            }

            Spacer(minLength: 0)

            Text(countdown.map { "\($0)s" } ?? "--")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(countdownColor)
                .contentTransition(.numericText())
                .frame(width: 54)
                .padding(.vertical, 5)
                .background(countdownBackground)
                .clipShape(Capsule())

            if canRemove {
                Button(action: onRemove) {
                    Image(systemName: "trash")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(AppTheme.textSecondary)
                }
                .buttonStyle(.plain)
                .disabled(isRunning)
                .frame(width: 18)
                .help("删除此 BUFF")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .opacity(buff.enabled || isRunning ? 1 : 0.72)
    }

    private var countdownColor: Color {
        guard let countdown else { return AppTheme.textSecondary }
        if countdown <= 5 { return AppTheme.danger }
        if countdown <= 30 { return AppTheme.warning }
        return AppTheme.success
    }

    private var countdownBackground: Color {
        guard let countdown else { return AppTheme.panel }
        if countdown <= 5 { return AppTheme.danger.opacity(0.10) }
        if countdown <= 30 { return AppTheme.warning.opacity(0.12) }
        return AppTheme.success.opacity(0.10)
    }
}
