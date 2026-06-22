import SwiftUI

struct VirtualKeyboardView: View {
    let onSelect: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selectedKey = ""
    
    private let mainRows: [[String]] = [
        ["Esc", "F1", "F2", "F3", "F4", "F5", "F6", "F7", "F8", "F9", "F10", "F11", "F12"],
        ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0", "-", "="],
        ["Q", "W", "E", "R", "T", "Y", "U", "I", "O", "P"],
        ["A", "S", "D", "F", "G", "H", "J", "K", "L"],
        ["Z", "X", "C", "V", "B", "N", "M"],
    ]
    
    private let specialKeys = ["Ctrl", "Alt", "Space", "Shift"]
    private let arrowKeys = ["↑", "←", "↓", "→"]
    
    var body: some View {
        VStack(spacing: 12) {
            Text("选择按键")
                .font(.title2)
            if !selectedKey.isEmpty {
                Text("已选: \(selectedKey)")
                    .foregroundStyle(AppTheme.accent)
            }
            ForEach(mainRows.indices, id: \.self) { rowIndex in
                HStack(spacing: 4) {
                    ForEach(mainRows[rowIndex], id: \.self) { key in
                        keyButton(key)
                    }
                }
            }
            HStack(spacing: 4) {
                ForEach(specialKeys, id: \.self) { key in keyButton(key) }
            }
            HStack(spacing: 4) {
                ForEach(arrowKeys, id: \.self) { key in keyButton(key) }
            }
            HStack {
                Spacer()
                Button("确认") {
                    if !selectedKey.isEmpty {
                        onSelect(selectedKey)
                        dismiss()
                    }
                }
                .disabled(selectedKey.isEmpty)
                Button("取消") { dismiss() }
            }
        }
        .padding()
        .frame(width: 760, height: 400)
    }
    
    private func keyButton(_ key: String) -> some View {
        Button {
            selectedKey = key
        } label: {
            Text(key)
                .frame(minWidth: 36, minHeight: 28)
                .padding(.horizontal, 4)
                .background(selectedKey == key ? AppTheme.accent.opacity(0.4) : AppTheme.panel)
                .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
    }
}
