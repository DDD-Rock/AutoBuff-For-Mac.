import SwiftUI

struct LogSectionView: View {
    let logs: [String]
    let onClear: () -> Void
    @State private var expanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(spacing: 8) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 4) {
                            ForEach(Array(logs.enumerated()), id: \.offset) { index, line in
                                Text(line)
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(AppTheme.textSecondary)
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .id(index)
                            }
                        }
                    }
                    .onChange(of: logs.count) { _, _ in
                        if let last = logs.indices.last {
                            proxy.scrollTo(last, anchor: .bottom)
                        }
                    }
                }
                .frame(height: 120)
                .padding(9)
                .background(AppTheme.background.opacity(0.7))
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))

                HStack {
                    Spacer()
                    Button("清空日志", action: onClear)
                        .buttonStyle(.borderless)
                        .font(.system(size: 10))
                        .foregroundStyle(AppTheme.textSecondary)
                }
            }
            .padding(.top, 9)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: "text.alignleft")
                    .foregroundStyle(AppTheme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("运行日志")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(AppTheme.textPrimary)
                    Text(logs.last ?? "暂无运行记录")
                        .font(.system(size: 9))
                        .foregroundStyle(AppTheme.textSecondary)
                        .lineLimit(1)
                }
            }
        }
        .tint(AppTheme.textSecondary)
        .appCard(padding: 12)
    }
}
