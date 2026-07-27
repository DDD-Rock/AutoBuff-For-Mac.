import AppKit
import CoreGraphics
import SwiftUI

@available(macOS 14.0, *)
@MainActor
final class MapActionTestWindowController: NSWindowController {
    init(windowID: CGWindowID, jumpKey: String) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 570, height: 590),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "地图动作独立测试"
        window.minSize = NSSize(width: 520, height: 520)
        window.isReleasedWhenClosed = false
        let autosaveName = "MapActionTestWindowFrame"
        let restoredPreviousFrame = window.setFrameUsingName(autosaveName)
        window.setFrameAutosaveName(autosaveName)
        if !restoredPreviousFrame { window.center() }
        window.contentView = NSHostingView(
            rootView: MapActionTestView(windowID: windowID, jumpKey: jumpKey)
        )
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

@available(macOS 14.0, *)
private struct MapActionTestView: View {
    private enum TestAction: String {
        case walkLeft
        case walkRight
        case enterRope
        case climbUp
        case climbDown
        case downJump
        case walkOffLeft
        case walkOffRight
        case jumpGrabLeft
        case jumpGrabRight
        case dismountLeft
        case dismountRight
        case portal
    }

    let windowID: CGWindowID
    let jumpKey: String

    @State private var isRunning = false
    @State private var runningTitle = ""
    @State private var statusText = "请先在游戏中把角色放到动作所需的起始位置。"
    @State private var executionTask: Task<Void, Never>?
    @State private var human: HumanInput?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("地图动作独立测试")
                    .font(.title2.bold())
                Text("每次只发送一个正式流程使用的动作组合；时长和按键间隔会在拟人范围内随机。")
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    actionSection("基础移动", description: "用于确认方向键持续按压，以及从绳索顶部按下进入绳索。") {
                        actionButton("向左步行 2 秒", icon: "arrow.left", action: .walkLeft)
                        actionButton("向右步行 2 秒", icon: "arrow.right", action: .walkRight)
                        actionButton("按下进入绳索", icon: "arrow.down", action: .enterRope)
                    }

                    actionSection("绳索移动", description: "角色需要已经挂在绳索上。") {
                        actionButton("向上爬绳 2 秒", icon: "arrow.up", action: .climbUp)
                        actionButton("向下爬绳 2 秒", icon: "arrow.down", action: .climbDown)
                    }

                    actionSection("平台下落", description: "下跳需站在平台上；走出平台会持续按方向键约 1 秒。") {
                        actionButton("原地下跳", icon: "arrow.down.to.line", action: .downJump)
                        actionButton("向左走出平台", icon: "arrow.down.left", action: .walkOffLeft)
                        actionButton("向右走出平台", icon: "arrow.down.right", action: .walkOffRight)
                    }

                    actionSection("跳抓绳", description: "站在绳索侧下方：先按方向，再按跳跃，随后按住上键 2 秒。") {
                        actionButton("向左跳抓绳", icon: "arrow.up.left", action: .jumpGrabLeft)
                        actionButton("向右跳抓绳", icon: "arrow.up.right", action: .jumpGrabRight)
                    }

                    actionSection("离开绳索", description: "角色需要已经挂在绳索上：先按落点方向，再按跳跃。") {
                        actionButton("向左跳离绳索", icon: "arrow.left", action: .dismountLeft)
                        actionButton("向右跳离绳索", icon: "arrow.right", action: .dismountRight)
                    }

                    actionSection("传送", description: "角色需要站在传送点位置。") {
                        actionButton("按上进入传送点", icon: "door.left.hand.open", action: .portal)
                    }
                }
            }
            Divider()
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: isRunning ? "keyboard.badge.ellipsis" : "info.circle")
                    .foregroundStyle(isRunning ? AppTheme.accent : AppTheme.textSecondary)
                Text(statusText)
                    .font(.caption)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button("紧急停止", systemImage: "stop.fill", role: .destructive) {
                    stopExecution()
                }
                .buttonStyle(.borderedProminent)
                .tint(AppTheme.danger)
                .disabled(!isRunning)
            }
        }
        .padding(18)
        .frame(minWidth: 520, minHeight: 520)
        .onDisappear { stopExecution() }
    }

    private func actionSection<Content: View>(
        _ title: String,
        description: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.headline)
            Text(description)
                .font(.caption2)
                .foregroundStyle(AppTheme.textSecondary)
            HStack(spacing: 8) { content() }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 9))
    }

    private func actionButton(_ title: String, icon: String, action: TestAction) -> some View {
        Button(title, systemImage: icon) { start(action, title: title) }
            .buttonStyle(.bordered)
            .disabled(isRunning)
    }

    private func start(_ action: TestAction, title: String) {
        guard !isRunning else { return }
        let input = HumanInput()
        human = input
        isRunning = true
        runningTitle = title
        statusText = "准备执行“\(title)”并切换到游戏窗口..."
        executionTask = Task { @MainActor in
            defer {
                isRunning = false
                runningTitle = ""
                executionTask = nil
                human = nil
                NSApp.activate(ignoringOtherApps: true)
            }
            do {
                _ = WindowSelector().bringWindowToFront(windowID: windowID)
                try await Task.sleep(for: .milliseconds(Int.random(in: 140...280)))
                try Task.checkCancellation()
                statusText = "正在执行“\(title)”..."
                try await perform(action, using: input)
                await input.releaseAll()
                statusText = "“\(title)”测试完成，全部按键已释放。"
            } catch is CancellationError {
                await input.releaseAll()
                statusText = "“\(title)”已停止，全部按键已释放。"
            } catch {
                await input.releaseAll()
                statusText = "“\(title)”失败：\(error.localizedDescription)"
            }
        }
    }

    private func perform(_ action: TestAction, using input: HumanInput) async throws {
        switch action {
        case .walkLeft, .walkRight:
            await input.holdDirection(action == .walkLeft ? .left : .right)
            try await Task.sleep(for: .milliseconds(2000))
        case .enterRope:
            await input.holdDirection(.down)
            try await Task.sleep(for: .milliseconds(Int.random(in: 850...1150)))
        case .climbUp:
            await input.holdDirection(.up)
            try await Task.sleep(for: .milliseconds(2000))
        case .climbDown:
            await input.holdDirection(.down)
            try await Task.sleep(for: .milliseconds(2000))
        case .downJump:
            let lead = Int.random(in: 45...110)
            let hold = Int.random(in: 65...125)
            let release = Int.random(in: 25...min(75, max(25, hold - 1)))
            try await input.performDownJump(
                jumpKey: jumpKey,
                downLeadMS: lead,
                jumpHoldMS: hold,
                downReleaseAfterJumpMS: release
            )
        case .walkOffLeft, .walkOffRight:
            await input.holdDirection(action == .walkOffLeft ? .left : .right)
            try await Task.sleep(for: .milliseconds(Int.random(in: 850...1150)))
        case .jumpGrabLeft, .jumpGrabRight:
            let upLead = Int.random(in: 20...55)
            try await input.performJumpGrabRope(
                jumpKey: jumpKey,
                direction: action == .jumpGrabLeft ? .left : .right,
                directionLeadMS: Int.random(in: 35...90),
                upLeadMS: upLead,
                jumpHoldMS: Int.random(in: (upLead + 45)...175),
                directionReleaseGapMS: Int.random(in: 25...80),
                upHoldMS: 2000
            )
        case .dismountLeft, .dismountRight:
            try await input.performRopeDismount(
                jumpKey: jumpKey,
                direction: action == .dismountLeft ? .left : .right,
                directionLeadMS: Int.random(in: 45...115),
                jumpHoldMS: Int.random(in: 70...140),
                directionReleaseGapMS: Int.random(in: 25...80)
            )
        case .portal:
            await input.tapDirection(.up, holdMS: 180...520, intervalMS: 70...190)
        }
    }

    private func stopExecution() {
        guard isRunning else { return }
        statusText = "正在停止“\(runningTitle)”并释放全部按键..."
        executionTask?.cancel()
        if let human { Task { await human.releaseAll() } }
    }
}
