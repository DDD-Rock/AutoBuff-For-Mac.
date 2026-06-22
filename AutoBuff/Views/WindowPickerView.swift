import SwiftUI

struct WindowPickerView: View {
    let windows: [GameWindowInfo]
    let onSelect: (GameWindowInfo) -> Void
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("选择游戏窗口")
                .font(.title2)
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
            HStack {
                Spacer()
                Button("取消") { dismiss() }
            }
        }
        .padding()
        .frame(width: 520, height: 420)
    }
}
