import SwiftUI

struct WindowPickerView: View {
    let loadWindows: () -> [GameWindowInfo]
    let onSelect: (GameWindowInfo) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var windows: [GameWindowInfo] = []
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("选择游戏窗口")
                .font(.title2)
            if windows.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "macwindow.badge.plus")
                        .font(.system(size: 30))
                        .foregroundStyle(.secondary)
                    Text("未找到可选择的窗口")
                        .font(.headline)
                    Text("请确认游戏已启动，然后点击“刷新”。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(windows) { window in
                    Button {
                        onSelect(window)
                        dismiss()
                    } label: {
                        VStack(alignment: .leading) {
                            Text(window.title).font(.headline)
                            Text("\(window.ownerName) · \(Int(window.size.width))×\(Int(window.size.height))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            HStack {
                Button {
                    refresh()
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                Spacer()
                Button("取消") { dismiss() }
            }
        }
        .padding()
        .frame(width: 520, height: 420)
        .onAppear {
            refresh()
        }
    }

    private func refresh() {
        windows = loadWindows()
    }
}
