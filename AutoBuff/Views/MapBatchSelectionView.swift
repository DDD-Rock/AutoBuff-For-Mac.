import SwiftUI
import UniformTypeIdentifiers

struct MapTransferFileDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }

    let data: Data

    init(data: Data) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents else {
            throw MapTransferError.unreadableFile
        }
        self.data = data
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

@available(macOS 14.0, *)
struct MapBatchSelectionView: View {
    let title: String
    let explanation: String
    let actionTitle: String
    let maps: [MapTopology]
    let existingMaps: [MapTopology]
    let showsImportConflicts: Bool
    let onConfirm: ([MapTopology]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selectedNames: Set<String>

    init(
        title: String,
        explanation: String,
        actionTitle: String,
        maps: [MapTopology],
        existingMaps: [MapTopology] = [],
        showsImportConflicts: Bool = false,
        onConfirm: @escaping ([MapTopology]) -> Void
    ) {
        self.title = title
        self.explanation = explanation
        self.actionTitle = actionTitle
        self.maps = maps
        self.existingMaps = existingMaps
        self.showsImportConflicts = showsImportConflicts
        self.onConfirm = onConfirm
        _selectedNames = State(initialValue: Set(maps.map(\.mapName)))
    }

    private var selectedMaps: [MapTopology] {
        maps.filter { selectedNames.contains($0.mapName) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.title2.bold())
            Text(explanation)
                .font(.callout)
                .foregroundStyle(AppTheme.textSecondary)

            HStack {
                Text("已选择 \(selectedNames.count) / \(maps.count) 张")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Button("全选") {
                    selectedNames = Set(maps.map(\.mapName))
                }
                .disabled(selectedNames.count == maps.count)
                Button("全不选") {
                    selectedNames.removeAll()
                }
                .disabled(selectedNames.isEmpty)
            }

            List(maps, id: \.mapName) { map in
                Toggle(isOn: selectionBinding(for: map.mapName)) {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(map.mapName)
                                .fontWeight(.medium)
                            Text(
                                "平台 \(map.platforms.count) · 绳索 \(map.ropes.count) · "
                                    + "传送点 \(map.portals.count) · 连线 \(map.traversalConnections.count)"
                            )
                            .font(.caption)
                            .foregroundStyle(AppTheme.textSecondary)
                        }
                        Spacer()
                        if showsImportConflicts,
                           MapTransferService.hasNameConflict(map, existingMaps: existingMaps) {
                            Text("将覆盖同名地图")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(AppTheme.warning)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(AppTheme.warning.opacity(0.12))
                                .clipShape(Capsule())
                        }
                    }
                }
                .toggleStyle(.checkbox)
                .padding(.vertical, 3)
            }
            .frame(minHeight: 260)

            if showsImportConflicts {
                Label(
                    "只有已勾选的同名地图会被替换，保存前会自动进入 maps.json 备份链。",
                    systemImage: "externaldrive.badge.checkmark"
                )
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
            }

            HStack {
                Spacer()
                Button("取消") {
                    dismiss()
                }
                Button(actionTitle) {
                    let result = selectedMaps
                    dismiss()
                    DispatchQueue.main.async {
                        onConfirm(result)
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedNames.isEmpty)
            }
        }
        .padding(18)
        .frame(minWidth: 600, minHeight: 480)
    }

    private func selectionBinding(for mapName: String) -> Binding<Bool> {
        Binding(
            get: { selectedNames.contains(mapName) },
            set: { isSelected in
                if isSelected {
                    selectedNames.insert(mapName)
                } else {
                    selectedNames.remove(mapName)
                }
            }
        )
    }
}
