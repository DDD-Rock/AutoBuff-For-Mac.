import SwiftUI

@available(macOS 14.0, *)
struct DebugPanelView: View {
    @ObservedObject var viewModel: MainViewModel

    var body: some View {
        DisclosureGroup(isExpanded: $viewModel.debugExpanded) {
            VStack(alignment: .leading, spacing: 8) {
                LazyVGrid(columns: [
                    GridItem(.flexible()),
                    GridItem(.flexible()),
                ], spacing: 7) {
                    Button("截图预览") {
                        Task { await viewModel.capturePreview() }
                    }
                    .disabled(viewModel.isRunning)
                    Button("检测市场/传送门") {
                        Task { await DebugTools.testLeaveMarket(windowID: viewModel.selectedWindow?.windowID, log: viewModel.appendLog) }
                    }
                    .disabled(viewModel.isRunning)
                    Button("检测市场按钮") {
                        Task { await DebugTools.testReturnToMarket(windowID: viewModel.selectedWindow?.windowID, log: viewModel.appendLog) }
                    }
                    .disabled(viewModel.isRunning)
                    Button("关闭弹窗") {
                        Task { await DebugTools.testDismissDialog(windowID: viewModel.selectedWindow?.windowID, log: viewModel.appendLog) }
                    }
                    .disabled(viewModel.isRunning)
                    Button("测试自动接队") {
                        Task { await DebugTools.testPartyInvite(windowID: viewModel.selectedWindow?.windowID, log: viewModel.appendLog) }
                    }
                }
                .controlSize(.small)
                if let image = viewModel.previewImage {
                    HStack(alignment: .top, spacing: 12) {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(maxWidth: 280, maxHeight: 160)
                        Text(viewModel.previewInfo)
                            .font(.caption)
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                }
            }
            .padding(.top, 8)
        } label: {
            Label("开发与检测工具", systemImage: "hammer")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(AppTheme.textPrimary)
        }
        .tint(AppTheme.textSecondary)
        .appCard(padding: 12)
    }
}
