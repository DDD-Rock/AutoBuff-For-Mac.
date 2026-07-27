import AppKit
import SwiftUI
import UniformTypeIdentifiers

@available(macOS 14.0, *)
struct MapTopologyLibraryView: View {
    let windowID: CGWindowID
    let initialMaps: [MapTopology]
    let jumpKey: String
    let allowsInputActions: Bool
    let onSave: ([MapTopology]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var maps: [MapTopology]
    @State private var mapName = ""
    @State private var currentBuffer: ImageBuffer?
    @State private var currentRegion: CGRect?
    @State private var currentSignature: [UInt8] = []
    @State private var status = "正在识别当前小地图..."
    @State private var isCapturingCleanMap = false
    @State private var cleanCaptureRequestID = UUID()
    @State private var selectedName = ""
    @State private var editingMap: MapTopology?
    @State private var showsExportSelection = false
    @State private var showsFileImporter = false
    @State private var showsFileExporter = false
    @State private var pendingImport: PendingMapImport?
    @State private var exportDocument: MapTransferFileDocument?
    @State private var exportFilename = "AutoBuff-地图备份"
    @State private var transferStatus: String?
    @State private var transferAlert: MapTransferAlert?

    init(
        windowID: CGWindowID,
        maps: [MapTopology],
        jumpKey: String,
        allowsInputActions: Bool = true,
        onSave: @escaping ([MapTopology]) -> Void
    ) {
        self.windowID = windowID
        self.initialMaps = maps
        self.jumpKey = jumpKey
        self.allowsInputActions = allowsInputActions
        self.onSave = onSave
        _maps = State(initialValue: maps)
        _selectedName = State(initialValue: maps.first?.mapName ?? "")
    }

    private var matchedMap: MapTopology? {
        guard !currentSignature.isEmpty else { return nil }
        return maps.first { stored in
            guard let signature = stored.visualSignature else { return false }
            return MinimapVisualMatcher.matches(currentSignature, signature)
        }
    }

    private var trimmedName: String { mapName.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canCreate: Bool {
        !isCapturingCleanMap && currentBuffer != nil && matchedMap == nil && !trimmedName.isEmpty
            && !maps.contains { $0.mapName.caseInsensitiveCompare(trimmedName) == .orderedSame }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("地图标注").font(.title2.bold())
            GroupBox("第一步：根据当前小地图新建") {
                HStack(spacing: 16) {
                    minimapPreview
                    VStack(alignment: .leading, spacing: 9) {
                        Text(status).font(.caption).foregroundStyle(AppTheme.textSecondary)
                        HStack(spacing: 8) {
                            Button(
                                isCapturingCleanMap ? "正在合成纯净小地图" : "重新抓取纯净小地图",
                                systemImage: "arrow.triangle.2.circlepath"
                            ) {
                                cleanCaptureRequestID = UUID()
                            }
                            .disabled(isCapturingCleanMap)
                            if isCapturingCleanMap {
                                ProgressView()
                                    .controlSize(.small)
                            }
                        }
                        if let matchedMap, !isCapturingCleanMap {
                            Label("当前小地图已匹配“\(matchedMap.mapName)”，不能重复创建", systemImage: "checkmark.seal.fill")
                                .foregroundStyle(AppTheme.warning)
                        }
                        TextField("输入新地图名称", text: $mapName).textFieldStyle(.roundedBorder)
                        Button("新建当前地图", systemImage: "plus") { createMap() }
                            .buttonStyle(.borderedProminent)
                            .disabled(!canCreate)
                        if !trimmedName.isEmpty && maps.contains(where: { $0.mapName.caseInsensitiveCompare(trimmedName) == .orderedSame }) {
                            Text("地图名称已存在").font(.caption).foregroundStyle(AppTheme.danger)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(8)
            }

            GroupBox("第二步：选择已创建地图并修改") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("地图库共 \(maps.count) 张")
                            .font(.subheadline.weight(.medium))
                        Spacer()
                        Button("批量导入", systemImage: "square.and.arrow.down") {
                            showsFileImporter = true
                        }
                        Button("批量导出", systemImage: "square.and.arrow.up") {
                            showsExportSelection = true
                        }
                        .disabled(maps.isEmpty)
                    }

                    Divider()

                    HStack(spacing: 12) {
                        if maps.isEmpty {
                            Text("还没有创建地图").foregroundStyle(AppTheme.textSecondary)
                        } else {
                            Picker("地图", selection: $selectedName) {
                                ForEach(maps, id: \.mapName) { map in Text(map.mapName).tag(map.mapName) }
                            }
                            .frame(maxWidth: 360)
                            if let selected = maps.first(where: { $0.mapName == selectedName }) {
                                Text("平台 \(selected.platforms.count) · 绳索 \(selected.ropes.count) · 传送点 \(selected.portals.count)")
                                    .foregroundStyle(AppTheme.textSecondary)
                            }
                            Spacer()
                            Button("修改", systemImage: "pencil") {
                                editingMap = maps.first { $0.mapName == selectedName }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }

                    if let transferStatus {
                        Label(transferStatus, systemImage: "checkmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(AppTheme.success)
                    }
                }
                .padding(8)
            }
            Spacer()
            HStack {
                Spacer()
                Button("完成") { persist(); dismiss() }.buttonStyle(.borderedProminent)
            }
        }
        .padding(18)
        .frame(minWidth: 760, minHeight: 500)
        .task(id: cleanCaptureRequestID) {
            await captureCleanCurrentMap(requestID: cleanCaptureRequestID)
        }
        .sheet(item: $editingMap) { selected in
            let isCurrent = selected.visualSignature.map { MinimapVisualMatcher.matches(currentSignature, $0) } ?? false
            MapTopologyEditorView(
                windowID: windowID,
                existingTopology: selected,
                availableMaps: maps,
                jumpKey: jumpKey,
                allowsInputActions: allowsInputActions,
                initialBuffer: isCurrent ? currentBuffer : referenceBuffer(for: selected),
                liveRegion: isCurrent ? currentRegion : nil,
                liveComparisonRegion: currentRegion
            ) { updated in
                if let index = maps.firstIndex(where: { $0.mapName == selected.mapName }) {
                    maps[index] = updated
                    selectedName = updated.mapName
                    persist()
                }
            }
        }
        .sheet(isPresented: $showsExportSelection) {
            MapBatchSelectionView(
                title: "批量导出地图",
                explanation: "勾选需要写入同一个导出文件的地图。",
                actionTitle: "导出已选地图",
                maps: maps
            ) { selectedMaps in
                prepareExport(selectedMaps)
            }
        }
        .sheet(item: $pendingImport) { pending in
            MapBatchSelectionView(
                title: "批量导入地图",
                explanation: "勾选需要导入的地图。同名地图会替换当前版本。",
                actionTitle: "导入已选地图",
                maps: pending.maps,
                existingMaps: maps,
                showsImportConflicts: true
            ) { selectedMaps in
                applyImport(selectedMaps)
            }
        }
        .fileImporter(
            isPresented: $showsFileImporter,
            allowedContentTypes: [.json],
            allowsMultipleSelection: false,
            onCompletion: handleImportResult
        )
        .fileExporter(
            isPresented: $showsFileExporter,
            document: exportDocument,
            contentType: .json,
            defaultFilename: exportFilename,
            onCompletion: handleExportResult
        )
        .alert(item: $transferAlert) { alert in
            Alert(
                title: Text(alert.title),
                message: Text(alert.message),
                dismissButton: .default(Text("知道了"))
            )
        }
    }

    private var minimapPreview: some View {
        Group {
            if let image = currentBuffer?.mapEditorImage() {
                Image(nsImage: image).resizable().interpolation(.none).scaledToFit()
            } else {
                ProgressView()
            }
        }
        .frame(width: 260, height: 180)
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @MainActor private func captureCleanCurrentMap(requestID: UUID) async {
        guard !isCapturingCleanMap else { return }
        isCapturingCleanMap = true
        defer {
            if cleanCaptureRequestID == requestID {
                isCapturingCleanMap = false
            }
        }

        let monitor = MinimapMonitor()
        monitor.setWindow(windowID)
        do {
            try Task.checkCancellation()
            guard let region = try await monitor.autoDetectDarkRegion() else {
                status = "无法识别当前小地图：\(monitor.lastDetectionSummary)"; return
            }
            try Task.checkCancellation()
            let firstFrame = try await monitor.captureMinimap()
            guard ColorDetector.validateMinimapContent(in: firstFrame).isValid else {
                status = "当前小地图纯内容区校验失败"; return
            }
            let sampleCount = 12
            var frames = [firstFrame]
            frames.reserveCapacity(sampleCount)
            status = "正在采样纯净小地图 1/\(sampleCount)，请保持游戏窗口可见"

            for sampleIndex in 1..<sampleCount {
                try await Task.sleep(for: .milliseconds(160))
                try Task.checkCancellation()
                let frame = try await monitor.captureMinimap()
                guard frame.width == firstFrame.width,
                      frame.height == firstFrame.height else {
                    throw MinimapBackgroundSynthesisError.inconsistentFrameSize
                }
                frames.append(frame)
                status = "正在采样纯净小地图 \(sampleIndex + 1)/\(sampleCount)，正在过滤黄/橙/红点"
            }

            status = "正在合成无移动目标的小地图..."
            let synthesis = try await Task.detached(priority: .userInitiated) {
                try MinimapBackgroundSynthesizer.synthesize(frames: frames)
            }.value
            try Task.checkCancellation()
            guard cleanCaptureRequestID == requestID else { return }

            currentRegion = region
            currentBuffer = synthesis.buffer
            currentSignature = MinimapVisualMatcher.signature(for: synthesis.buffer)
            status = "纯净小地图已合成 \(synthesis.buffer.width)×\(synthesis.buffer.height)"
                + " · 采样 \(synthesis.sampledFrameCount) 帧"
                + " · 清理 \(synthesis.cleanedPixelCount) 像素"
                + (
                    synthesis.spatiallyRepairedPixelCount > 0
                        ? " · 补齐 \(synthesis.spatiallyRepairedPixelCount) 像素"
                        : ""
                )
        } catch is CancellationError {
            return
        } catch {
            guard cleanCaptureRequestID == requestID else { return }
            status = "纯净小地图抓取失败：\(error.localizedDescription)"
        }
    }

    private func createMap() {
        guard canCreate, let buffer = currentBuffer else { return }
        let map = MapTopology(
            mapName: trimmedName,
            referenceWidth: buffer.width,
            referenceHeight: buffer.height,
            visualSignature: currentSignature,
            referenceBGR: Data(buffer.bgr)
        )
        maps.append(map)
        selectedName = map.mapName
        mapName = ""
        persist()
    }

    private func referenceBuffer(for map: MapTopology) -> ImageBuffer? {
        guard let data = map.referenceBGR,
              data.count == map.referenceWidth * map.referenceHeight * 3 else { return nil }
        return ImageBuffer(width: map.referenceWidth, height: map.referenceHeight, bgr: Array(data))
    }

    private func prepareExport(_ selectedMaps: [MapTopology]) {
        do {
            let data = try MapTransferService.exportData(maps: selectedMaps)
            exportDocument = MapTransferFileDocument(data: data)
            exportFilename = defaultExportFilename()
            showsFileExporter = true
        } catch {
            showTransferError(title: "无法导出地图", error: error)
        }
    }

    private func handleExportResult(_ result: Result<URL, Error>) {
        defer { exportDocument = nil }
        switch result {
        case .success(let url):
            transferStatus = "地图已导出到 \(url.lastPathComponent)"
        case .failure(let error):
            guard !isUserCancelled(error) else { return }
            showTransferError(title: "地图导出失败", error: error)
        }
    }

    private func handleImportResult(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let hasSecurityAccess = url.startAccessingSecurityScopedResource()
            defer {
                if hasSecurityAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            do {
                let importedMaps = try MapTransferService.importMaps(from: Data(contentsOf: url))
                pendingImport = PendingMapImport(maps: importedMaps)
            } catch {
                showTransferError(title: "无法导入地图", error: error)
            }
        case .failure(let error):
            guard !isUserCancelled(error) else { return }
            showTransferError(title: "地图导入失败", error: error)
        }
    }

    private func applyImport(_ importedMaps: [MapTopology]) {
        let result = MapTransferService.merge(importedMaps: importedMaps, into: maps)
        maps = result.maps
        if let lastImported = importedMaps.last,
           let imported = maps.first(where: {
               $0.mapName.caseInsensitiveCompare(lastImported.mapName) == .orderedSame
           }) {
            selectedName = imported.mapName
        } else if !maps.contains(where: { $0.mapName == selectedName }) {
            selectedName = maps.first?.mapName ?? ""
        }
        persist()

        var parts: [String] = []
        if result.addedCount > 0 {
            parts.append("新增 \(result.addedCount) 张")
        }
        if result.replacedCount > 0 {
            parts.append("替换 \(result.replacedCount) 张")
        }
        transferStatus = "导入完成：" + parts.joined(separator: "，")
    }

    private func defaultExportFilename() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return "AutoBuff-地图备份-\(formatter.string(from: Date()))"
    }

    private func isUserCancelled(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == NSCocoaErrorDomain && nsError.code == NSUserCancelledError
    }

    private func showTransferError(title: String, error: Error) {
        transferAlert = MapTransferAlert(
            title: title,
            message: error.localizedDescription
        )
    }

    private func persist() { onSave(maps) }
}

extension MapTopology: Identifiable {
    var id: String { mapName }
}

private struct PendingMapImport: Identifiable {
    let id = UUID()
    let maps: [MapTopology]
}

private struct MapTransferAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}
