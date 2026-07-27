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
                }
                .controlSize(.small)
                Divider()
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("EXP 样本采集")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(AppTheme.textPrimary)
                            Text(viewModel.expDataCollection.status)
                                .font(.caption)
                                .foregroundStyle(AppTheme.textSecondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Button {
                            viewModel.revealEXPDataCollectionDirectory()
                        } label: {
                            Image(systemName: "folder")
                        }
                        .help("打开 EXP 数据目录")
                        Button(
                            viewModel.expDataCollection.isRunning ? "停止采集" : "开始采集"
                        ) {
                            viewModel.toggleEXPDataCollection()
                        }
                        .disabled(
                            !viewModel.expDataCollection.isRunning
                                && viewModel.selectedWindow == nil
                        )
                    }
                    Text(
                        "整行 \(viewModel.expDataCollection.savedRows) · "
                            + "字符 \(viewModel.expDataCollection.savedGlyphs) · "
                            + "待审核 \(viewModel.expDataCollection.reviewItems)"
                    )
                    .font(.caption2)
                    .foregroundStyle(AppTheme.textSecondary)
                    if let lastRecognition = viewModel.expDataCollection.lastRecognition {
                        Text("最近识别：\(lastRecognition)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(AppTheme.textSecondary)
                    }
                }
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
