import AppKit
import SwiftUI

@available(macOS 14.0, *)
struct MapTopologyEditorView: View {
    private enum DrawingTool: String, CaseIterable, Identifiable {
        case platform = "平台"
        case rope = "绳索"
        case portal = "传送点"

        var id: String { rawValue }
        var color: Color {
            switch self {
            case .platform: return .green
            case .rope: return .orange
            case .portal: return .blue
            }
        }
        var systemImage: String {
            switch self {
            case .platform: return "line.diagonal"
            case .rope: return "arrow.up.and.down"
            case .portal: return "door.left.hand.open"
            }
        }
    }

    let windowID: CGWindowID
    let onConfirm: (MapTopology) -> Void
    let availableMaps: [MapTopology]
    let jumpKey: String
    let allowsInputActions: Bool
    let liveComparisonRegion: CGRect?

    @Environment(\.dismiss) private var dismiss
    @State private var topology: MapTopology
    @State private var tool: DrawingTool = .platform
    @State private var minimapImage: NSImage?
    @State private var minimapBuffer: ImageBuffer?
    @State private var contentSize: CGSize = .zero
    @State private var contentRegion: CGRect?
    @State private var statusText = "正在识别小地图内容区..."
    @State private var isLoading = true
    @State private var isMergingReference = false
    @State private var dragStart: CGPoint?
    @State private var dragCurrent: CGPoint?
    @State private var history: [MapTopology] = []
    @State private var isTracing = false
    @State private var traceTask: Task<Void, Never>?
    @State private var traceSamples: [CGPoint] = []
    @State private var liveTracePoints: [NormalizedMapPoint] = []
    @State private var liveRope: MapRope?
    @State private var latestPlayerPoint: CGPoint?
    @State private var discardTraceResult = false
    @State private var liveRefreshTask: Task<Void, Never>?
    @State private var liveSimilarity: MinimapVisualMatcher.Comparison?
    @State private var liveSimilarityStatus = "等待当前游戏小地图..."
    @State private var platformsExpanded = true
    @State private var ropesExpanded = false
    @State private var portalsExpanded = false
    @State private var showClearConfirmation = false
    @State private var selectedPathTarget = ""
    @State private var plannedPath: PlannedMapPath?
    @State private var plannerStatus = "请选择目标平台或传送点"
    @State private var isExecutingWalk = false
    @State private var walkExecutionTask: Task<Void, Never>?
    @State private var walkExecutor: MapWalkExecutor?
    @State private var isExecutingDrop = false
    @State private var dropExecutionTask: Task<Void, Never>?
    @State private var dropExecutor: MapDropExecutor?
    @State private var isExecutingRoute = false
    @State private var routeExecutionTask: Task<Void, Never>?
    @State private var routeExecutor: MapRouteExecutor?
    @State private var actionTestWindowController: MapActionTestWindowController?

    @State private var fallbackBuffer: ImageBuffer?
    @State private var fallbackImage: NSImage?
    @State private var cropStart: CGPoint?
    @State private var cropCurrent: CGPoint?

    init(
        windowID: CGWindowID,
        existingTopology: MapTopology?,
        availableMaps: [MapTopology] = [],
        jumpKey: String = "Alt",
        allowsInputActions: Bool = true,
        initialBuffer: ImageBuffer? = nil,
        liveRegion: CGRect? = nil,
        liveComparisonRegion: CGRect? = nil,
        onConfirm: @escaping (MapTopology) -> Void
    ) {
        self.windowID = windowID
        self.onConfirm = onConfirm
        self.availableMaps = availableMaps
        self.jumpKey = jumpKey
        self.allowsInputActions = allowsInputActions
        self.liveComparisonRegion = liveComparisonRegion ?? liveRegion
        _topology = State(
            initialValue: existingTopology
                ?? MapTopology(referenceWidth: 0, referenceHeight: 0)
        )
        if let initialBuffer {
            _minimapBuffer = State(initialValue: initialBuffer)
            _minimapImage = State(initialValue: initialBuffer.mapEditorImage())
            _contentSize = State(initialValue: CGSize(width: initialBuffer.width, height: initialBuffer.height))
            _contentRegion = State(initialValue: liveRegion)
            _statusText = State(initialValue: liveRegion == nil ? "正在编辑已保存的地图参考图；切换到该地图后可自动采集" : "当前小地图已匹配，可手工或自动采集")
            _isLoading = State(initialValue: false)
        }
    }

    var body: some View {
        VStack(spacing: 12) {
            header
            Divider()
            if isLoading {
                ProgressView(statusText)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if minimapImage != nil {
                annotationBody
            } else if fallbackImage != nil {
                manualCropBody
            } else {
                failureBody
            }
            Divider()
            footer
        }
        .padding(16)
        .frame(minWidth: 900, idealWidth: 980, minHeight: 650, idealHeight: 720)
        .task {
            if minimapImage == nil { await loadMinimap() }
            startLiveRefresh()
        }
        .onDisappear {
            discardTraceResult = true
            traceTask?.cancel()
            liveRefreshTask?.cancel()
            walkExecutionTask?.cancel()
            if let walkExecutor { Task { await walkExecutor.stop() } }
            dropExecutionTask?.cancel()
            if let dropExecutor { Task { await dropExecutor.stop() } }
            routeExecutionTask?.cancel()
            if let routeExecutor { Task { await routeExecutor.stop() } }
            actionTestWindowController?.close()
        }
        .confirmationDialog(
            "确认清空这张地图的全部标注？",
            isPresented: $showClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("确认清空全部标注", role: .destructive) { clearAll() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("将删除平台 \(topology.platforms.count) 个、绳索 \(topology.ropes.count) 个、传送点 \(topology.portals.count) 个。此操作会立即保存，但仍可在当前编辑窗口中使用“撤销”恢复。")
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text("地图标注与路径连接")
                    .font(.title2.bold())
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(2)
            }
            Spacer()
            if minimapImage != nil, allowsInputActions {
                Button("动作测试", systemImage: "keyboard") {
                    openActionTestWindow()
                }
                .buttonStyle(.bordered)
                .disabled(isExecutingAction)
                Button("重新识别小地图", systemImage: "arrow.clockwise") {
                    reloadMinimap()
                }
                .buttonStyle(.bordered)
                .disabled(isLoading || isMergingReference || isTracing || isExecutingAction)
                Button(
                    isMergingReference ? "正在融合" : "抓取当前小地图并融合",
                    systemImage: "square.stack.3d.up"
                ) {
                    mergeCurrentMinimapIntoReference()
                }
                .buttonStyle(.bordered)
                .disabled(isLoading || isMergingReference || isTracing || isExecutingAction)
                Text(topology.mapName)
                    .font(.headline)
                    .foregroundStyle(AppTheme.textSecondary)
            }
        }
    }

    private var annotationBody: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 10) {
                annotationToolbar

                Text(toolHelpText)
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)

                annotationCanvas
                    .frame(width: previewSize.width, height: previewSize.height)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(AppTheme.border, lineWidth: 1)
                    }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            topologySidebar
                .frame(width: 230)
        }
    }

    private var annotationToolbar: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text("基础标注").font(.caption.weight(.semibold)).foregroundStyle(AppTheme.textSecondary)
                    .frame(width: 58, alignment: .leading)
                toolButton(.platform)
                toolButton(.rope)
                toolButton(.portal)
                Divider().frame(height: 22)
                if tool == .platform || tool == .rope {
                    Button {
                        isTracing ? finishTrace() : startTrace()
                    } label: {
                        isTracing
                            ? Label("结束采集", systemImage: "stop.fill")
                            : Label("开始采集\(tool.rawValue)", systemImage: "record.circle")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(isTracing ? AppTheme.danger : AppTheme.accent)
                    .disabled(contentRegion == nil)
                } else if tool == .portal {
                    Button("标记角色当前位置", systemImage: "location.fill") {
                        markPortalAtPlayerPosition()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                    .disabled(contentRegion == nil || latestPlayerPoint == nil || isTracing)
                }
            }
            HStack(spacing: 8) {
                Text("编辑操作").font(.caption.weight(.semibold)).foregroundStyle(AppTheme.textSecondary)
                    .frame(width: 58, alignment: .leading)
                Button("撤销", systemImage: "arrow.uturn.backward") { undo() }
                    .disabled(history.isEmpty)
                Button("清空", systemImage: "trash") { showClearConfirmation = true }
                    .disabled(topology.isEmpty)
            }
        }
    }

    private func toolButton(_ item: DrawingTool) -> some View {
        Button {
            tool = item
            switch item {
            case .platform: platformsExpanded = true
            case .rope: ropesExpanded = true
            case .portal: portalsExpanded = true
            }
        } label: {
            Label(item.rawValue, systemImage: item.systemImage).frame(minWidth: 72)
        }
        .buttonStyle(.borderedProminent)
        .tint(tool == item ? item.color : Color.gray.opacity(0.55))
    }

    private var annotationCanvas: some View {
        ZStack {
            if let minimapImage {
                Image(nsImage: minimapImage)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: previewSize.width, height: previewSize.height)
            }
            Canvas { context, size in
                drawTopology(context: &context, size: size)
                drawPlannedPath(context: &context, size: size)
                drawLiveTrace(context: &context, size: size)
                drawDraft(context: &context, size: size)
            }
            Rectangle()
                .fill(.clear)
                .contentShape(Rectangle())
                .gesture(annotationDragGesture)
                .allowsHitTesting(!isTracing && tool != .portal)
        }
    }

    private var topologySidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("标注对象")
                .font(.headline)
            Text("平台 \(topology.platforms.count) · 绳索 \(topology.ropes.count) · 传送点 \(topology.portals.count)")
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
            liveSimilarityPanel
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    DisclosureGroup(isExpanded: $platformsExpanded) {
                        VStack(spacing: 6) {
                            ForEach(Array(topology.platforms.enumerated()), id: \.element.id) { index, platform in
                                objectRow(title: "P\(index + 1)", color: .green) {
                                    removePlatform(platform.id)
                                }
                            }
                        }
                        .padding(.top, 5)
                    } label: {
                        categoryLabel("平台", count: topology.platforms.count, color: .green)
                    }

                    DisclosureGroup(isExpanded: $ropesExpanded) {
                        VStack(spacing: 6) {
                            ForEach(Array(topology.ropes.enumerated()), id: \.element.id) { index, rope in
                                objectRow(title: "R\(index + 1)", color: .orange) {
                                    removeRope(rope.id)
                                }
                            }
                        }
                        .padding(.top, 5)
                    } label: {
                        categoryLabel("绳索", count: topology.ropes.count, color: .orange)
                    }

                    DisclosureGroup(isExpanded: $portalsExpanded) {
                        VStack(spacing: 6) {
                            ForEach(Array(topology.portals.enumerated()), id: \.element.id) { index, portal in
                                portalRow(index: index, portal: portal)
                            }
                        }
                        .padding(.top, 5)
                    } label: {
                        categoryLabel("传送点", count: topology.portals.count, color: .blue)
                    }

                }
            }
            .frame(maxHeight: 285)
            Divider()
            pathPreviewPanel
            Divider()
            let messages = MapTopologyValidator.messages(for: topology)
            if messages.isEmpty {
                Label("基础标注检查通过", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(AppTheme.success)
            } else {
                ForEach(messages, id: \.self) { message in
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(AppTheme.warning)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(AppTheme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    private var liveSimilarityPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("实时相似度", systemImage: "waveform.path.ecg")
                    .font(.caption.weight(.semibold))
                Spacer()
                if let liveSimilarity {
                    Text(String(format: "%.1f%%", liveSimilarity.similarityPercentage))
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(liveSimilarity.isMatch ? AppTheme.success : AppTheme.warning)
                } else {
                    Text("--")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(AppTheme.textSecondary)
                }
            }

            ProgressView(value: liveSimilarity?.similarityPercentage ?? 0, total: 100)
                .tint(liveSimilarity?.isMatch == true ? AppTheme.success : AppTheme.warning)

            if let liveSimilarity {
                HStack(spacing: 5) {
                    Image(systemName: liveSimilarity.isMatch ? "checkmark.circle.fill" : "xmark.circle.fill")
                    Text(liveSimilarity.isMatch ? "符合实际匹配条件" : "未达到实际匹配条件")
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(liveSimilarity.isMatch ? AppTheme.success : AppTheme.warning)

                Text(
                    "灰度差 \(String(format: "%.2f", liveSimilarity.appearanceDistance))"
                        + " · 结构差 \(String(format: "%.1f%%", liveSimilarity.structuralMismatch * 100))"
                        + (liveSimilarity.usesScaleTolerance ? " · 已使用缩放容错" : "")
                )
                .font(.caption2.monospacedDigit())
                .foregroundStyle(AppTheme.textSecondary)
                .lineLimit(2)
                Text(
                    "判定线：相似度 ≥ \(Int(MinimapVisualMatcher.minimumMatchPercentage))%"
                )
                .font(.caption2)
                .foregroundStyle(AppTheme.textSecondary)
            } else {
                Text(liveSimilarityStatus)
                    .font(.caption2)
                    .foregroundStyle(AppTheme.textSecondary)
                    .lineLimit(2)
            }
        }
        .padding(8)
        .background(AppTheme.background.opacity(0.8))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(AppTheme.border)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("mapEditor.liveSimilarity")
    }

    private var pathPreviewPanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("路径预览").font(.subheadline.weight(.semibold))
            Picker("目标", selection: $selectedPathTarget) {
                Text("请选择").tag("")
                ForEach(Array(topology.platforms.enumerated()), id: \.element.id) { index, platform in
                    Text("平台 P\(index + 1)").tag("platform:\(platform.id.uuidString)")
                }
                ForEach(Array(topology.portals.enumerated()), id: \.element.id) { index, portal in
                    Text("传送点 T\(index + 1)").tag("portal:\(portal.id.uuidString)")
                }
            }
            .onChange(of: selectedPathTarget) { _, _ in refreshPlannedPath() }
            Text(plannerStatus)
                .font(.caption)
                .foregroundStyle(plannedPath == nil ? AppTheme.textSecondary : AppTheme.success)
                .lineLimit(3)
            let isolatedCount = MapPathPlanner.isolatedSourceIDs(
                in: currentNavigationGraph,
                mapName: topology.mapName
            ).count
            if isolatedCount > 0 {
                Label("发现 \(isolatedCount) 个孤立标注对象", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(AppTheme.warning)
            }
            if let plannedPath, !plannedPath.edges.isEmpty {
                Text(plannedPath.edges.map(actionTitle).joined(separator: " → "))
                    .font(.caption2)
                    .foregroundStyle(AppTheme.accent)
                    .lineLimit(4)
            }
            if allowsInputActions {
                HStack {
                    Button("执行完整路径", systemImage: "point.topleft.down.to.point.bottomright.curvepath") {
                        startRouteExecution()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canExecuteRoute)
                    if isExecutingAction {
                        Button("紧急停止", systemImage: "stop.fill", role: .destructive) { stopCurrentExecution() }
                            .buttonStyle(.borderedProminent)
                            .tint(AppTheme.danger)
                    }
                }
                if plannedPath != nil, !canExecuteRoute, !isExecutingAction {
                    Text(walkDisabledReason)
                        .font(.caption2)
                        .foregroundStyle(AppTheme.warning)
                }
            }
        }
    }

    private var canExecuteWalk: Bool {
        !isExecutingAction && contentRegion != nil && plannedPath?.edges.first?.kind == .walk
    }

    private var canExecuteDrop: Bool {
        !isExecutingAction && contentRegion != nil && plannedPath?.edges.first?.kind == .drop
    }

    private var canExecuteRoute: Bool {
        !isExecutingAction && contentRegion != nil && !(plannedPath?.edges.isEmpty ?? true)
    }

    private var isExecutingAction: Bool {
        isExecutingWalk || isExecutingDrop || isExecutingRoute
    }
    private var canExecuteCurrentAction: Bool { canExecuteWalk || canExecuteDrop }

    private var walkDisabledReason: String {
        guard contentRegion != nil else { return "当前地图不是实时地图，无法执行" }
        guard let first = plannedPath?.edges.first else { return "当前没有需要执行的动作" }
        return first.kind == .walk || first.kind == .drop ? "" : "路径第一步是“\(actionTitle(first))”，该动作尚未接入自动执行"
    }

    private func categoryLabel(_ title: String, count: Int, color: Color) -> some View {
        HStack(spacing: 7) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(title).font(.subheadline.weight(.semibold))
            Spacer()
            Text("\(count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(AppTheme.textSecondary)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(AppTheme.background)
                .clipShape(Capsule())
        }
    }

    private var toolHelpText: String {
        if isTracing {
            return "正在持续读取最新小地图。请手动控制角色沿\(tool == .platform ? "平台左右" : "绳索上下")移动，完成后点击“结束采集”。"
        }
        switch tool {
        case .platform:
            return "可手动画线修正；也可点击“开始采集平台”，然后在游戏中手动左右移动。"
        case .rope:
            return "可手动画绳索；也可点击“开始采集绳索”，然后在游戏中手动上下攀爬。"
        case .portal:
            return contentRegion == nil
                ? "当前编辑的不是游戏正在显示的地图，无法读取角色位置。"
                : "等待识别实时黄点后，点击“标记角色当前位置”，再在右侧配置连接目标。"
        }
    }

    private func connectionRow(index: Int, connection: MapTraversalConnection) -> some View {
        let color: Color = connection.kind == .jump ? .purple : .red
        return VStack(alignment: .leading, spacing: 5) {
            objectRow(
                title: "\(connection.kind == .jump ? "J" : "D")\(index + 1)",
                color: color
            ) { removeConnection(connection.id) }
            Toggle("启用", isOn: connectionEnabledBinding(for: connection.id))
                .toggleStyle(.switch)
                .controlSize(.mini)
            HStack {
                Text("方向").foregroundStyle(AppTheme.textSecondary)
                Spacer()
                Text(connection.direction == .left ? "向左" : connection.direction == .right ? "向右" : "原地")
            }
            .font(.caption)
            Stepper(
                "按键 \(connection.keyHoldMilliseconds)ms",
                value: connectionHoldBinding(for: connection.id),
                in: 50...2000,
                step: 50
            )
            .font(.caption)
        }
        .padding(6)
        .background(AppTheme.background.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private func objectRow(title: String, color: Color, onDelete: @escaping () -> Void) -> some View {
        HStack {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(title).font(.system(.body, design: .monospaced))
            Spacer()
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .foregroundStyle(AppTheme.textSecondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(AppTheme.background.opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private func portalRow(index: Int, portal: MapPortal) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            objectRow(title: "T\(index + 1)", color: .blue) { removePortal(portal.id) }
            Picker("类型", selection: portalTypeBinding(for: portal.id)) {
                ForEach(MapPortalType.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Picker("目标地图", selection: destinationMapBinding(for: portal.id)) {
                Text("未连接").tag("")
                Text("\(topology.mapName)（当前地图）").tag(topology.mapName)
                ForEach(availableMaps.filter { $0.mapName != topology.mapName }, id: \.mapName) {
                    Text($0.mapName).tag($0.mapName)
                }
            }
            if let targetName = portal.destinationMapName,
               let targetMap = targetMap(named: targetName),
               !targetMap.portals.isEmpty {
                Picker("目标传送点", selection: destinationPortalBinding(for: portal.id)) {
                    Text("未指定").tag(UUID?.none)
                    ForEach(Array(targetMap.portals.enumerated()).filter { $0.element.id != portal.id }, id: \.element.id) { targetIndex, target in
                        Text("T\(targetIndex + 1)").tag(Optional(target.id))
                    }
                }
            }
        }
        .padding(6)
        .background(AppTheme.background.opacity(0.45))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }

    private var manualCropBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("请在完整游戏画面中大致框住小地图面板。", systemImage: "crop")
                .font(.headline)
            Text("框内可以包含白色边框和地图名称。确认后，软件会在所选范围内继续识别并裁出纯内容区。")
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
            manualCropCanvas
                .frame(width: fallbackPreviewSize.width, height: fallbackPreviewSize.height)
                .background(Color.black)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay { RoundedRectangle(cornerRadius: 8).stroke(AppTheme.border) }
            Button("在框选范围内识别", systemImage: "viewfinder") {
                Task { await applyManualCrop() }
            }
                .buttonStyle(.borderedProminent)
                .disabled(cropRect(in: fallbackPreviewSize) == nil || isLoading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var manualCropCanvas: some View {
        ZStack {
            if let fallbackImage {
                Image(nsImage: fallbackImage)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: fallbackPreviewSize.width, height: fallbackPreviewSize.height)
            }
            Canvas { context, _ in
                if let rect = cropRect(in: fallbackPreviewSize) {
                    context.fill(Path(rect), with: .color(.green.opacity(0.16)))
                    context.stroke(Path(rect), with: .color(.green), lineWidth: 2)
                }
            }
            Rectangle()
                .fill(.clear)
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 2)
                        .onChanged { value in
                            if cropStart == nil { cropStart = value.startLocation }
                            cropCurrent = value.location
                        }
                        .onEnded { value in cropCurrent = value.location }
                )
        }
    }

    private var failureBody: some View {
        VStack(spacing: 12) {
            Image(systemName: "map.fill")
                .font(.system(size: 36))
                .foregroundStyle(AppTheme.textSecondary)
            Text("无法获得可标注的小地图内容区")
                .font(.headline)
            Text("请确认游戏窗口可见、小地图已展开，并已授予屏幕录制权限。")
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
            HStack(spacing: 8) {
                Button("重新识别", systemImage: "arrow.clockwise") {
                    Task { await loadMinimap() }
                }
                Button("手动框选", systemImage: "crop") {
                    Task { await beginManualCrop() }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        HStack {
            if minimapImage != nil {
                Text("坐标基于纯内容区并以归一化形式保存")
                    .font(.caption)
                    .foregroundStyle(AppTheme.textSecondary)
            }
            Spacer()
            Button("取消") { dismiss() }
            Button("保存地图") {
                onConfirm(topology)
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .disabled(minimapImage == nil || topology.mapName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private var previewSize: CGSize {
        guard contentSize.width > 0, contentSize.height > 0 else { return .zero }
        let scale = min(5, 620 / contentSize.width, 420 / contentSize.height)
        return CGSize(width: contentSize.width * scale, height: contentSize.height * scale)
    }

    private var fallbackPreviewSize: CGSize {
        guard let fallbackBuffer else { return .zero }
        let size = CGSize(width: fallbackBuffer.width, height: fallbackBuffer.height)
        let scale = min(2, 780 / size.width, 520 / size.height)
        return CGSize(width: size.width * scale, height: size.height * scale)
    }

    private var annotationDragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if dragStart == nil { dragStart = value.startLocation }
                dragCurrent = value.location
            }
            .onEnded { value in
                finishAnnotation(from: dragStart ?? value.startLocation, to: value.location)
                dragStart = nil
                dragCurrent = nil
            }
    }

    private func finishAnnotation(from start: CGPoint, to end: CGPoint) {
        guard previewSize.width > 0,
              previewSize.height > 0 else { return }
        if tool == .portal { return }
        guard hypot(end.x - start.x, end.y - start.y) >= 8 else { return }
        pushHistory()
        let first = NormalizedMapPoint(start, in: previewSize)
        let second = NormalizedMapPoint(end, in: previewSize)
        switch tool {
        case .platform:
            if abs(first.y - second.y) <= 0.035 {
                let y = (first.y + second.y) / 2
                topology.platforms.append(
                    MapPlatform(points: [
                        NormalizedMapPoint(x: first.x, y: y),
                        NormalizedMapPoint(x: second.x, y: y),
                    ])
                )
            } else {
                topology.platforms.append(MapPlatform(points: [first, second]))
            }
        case .rope:
            topology.ropes.append(
                MapRope(
                    x: (first.x + second.x) / 2,
                    topY: first.y,
                    bottomY: second.y
                )
            )
        case .portal:
            break
        }
        onConfirm(topology)
    }

    private func drawTopology(context: inout GraphicsContext, size: CGSize) {
        MapTopologyOverlayRenderer.draw(
            topology: topology,
            context: &context,
            size: size
        )
    }

    private func drawArrow(from start: CGPoint, to end: CGPoint, color: Color, context: inout GraphicsContext) {
        var path = Path()
        path.move(to: start)
        path.addLine(to: end)
        let angle = atan2(end.y - start.y, end.x - start.x)
        let arrowLength: CGFloat = 11
        path.move(to: end)
        path.addLine(to: CGPoint(x: end.x - arrowLength * cos(angle - .pi / 6), y: end.y - arrowLength * sin(angle - .pi / 6)))
        path.move(to: end)
        path.addLine(to: CGPoint(x: end.x - arrowLength * cos(angle + .pi / 6), y: end.y - arrowLength * sin(angle + .pi / 6)))
        context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
    }

    private func drawPlannedPath(context: inout GraphicsContext, size: CGSize) {
        guard let plannedPath else { return }
        let graph = currentNavigationGraph
        let nodes = Dictionary(uniqueKeysWithValues: graph.nodes.map { ($0.id, $0) })
        for edge in plannedPath.edges {
            guard let from = nodes[edge.from], let to = nodes[edge.to],
                  from.mapName == topology.mapName, to.mapName == topology.mapName else { continue }
            drawArrow(
                from: (edge.actionStartPoint ?? from.point).point(in: size),
                to: (edge.actionEndPoint ?? to.point).point(in: size),
                color: .cyan,
                context: &context
            )
        }
        if let start = nodes[plannedPath.startNodeID], start.mapName == topology.mapName {
            let point = start.point.point(in: size)
            context.fill(Path(ellipseIn: CGRect(x: point.x - 7, y: point.y - 7, width: 14, height: 14)), with: .color(.yellow))
            context.stroke(Path(ellipseIn: CGRect(x: point.x - 8, y: point.y - 8, width: 16, height: 16)), with: .color(.black), lineWidth: 2)
        }
        if let target = nodes[plannedPath.targetNodeID], target.mapName == topology.mapName {
            let point = target.point.point(in: size)
            context.stroke(Path(ellipseIn: CGRect(x: point.x - 9, y: point.y - 9, width: 18, height: 18)), with: .color(.pink), lineWidth: 4)
        }
    }

    private var currentNavigationGraph: MapNavigationGraph {
        var maps = availableMaps.filter { $0.mapName != topology.mapName }
        maps.append(topology)
        return MapNavigationGraphBuilder.build(from: maps)
    }

    private func refreshPlannedPath() {
        guard !selectedPathTarget.isEmpty else {
            plannedPath = nil
            plannerStatus = "请选择目标平台或传送点"
            return
        }
        guard let player = latestPlayerPoint, contentSize.width > 0, contentSize.height > 0 else {
            plannedPath = nil
            plannerStatus = "当前未识别到角色黄点"
            return
        }
        guard let separator = selectedPathTarget.firstIndex(of: ":"),
              let targetID = UUID(uuidString: String(selectedPathTarget[selectedPathTarget.index(after: separator)...])) else {
            plannedPath = nil
            plannerStatus = "目标数据无效"
            return
        }
        let graph = currentNavigationGraph
        let playerPoint = NormalizedMapPoint(player, in: contentSize)
        guard let currentNode = MapPathPlanner.locateCurrentNode(point: playerPoint, topology: topology, graph: graph) else {
            plannedPath = nil
            plannerStatus = "黄点不在已标注的平台或绳索附近"
            return
        }
        guard let path = MapPathPlanner.shortestPath(
            graph: graph,
            from: currentNode.id,
            targetSourceID: targetID,
            targetMapName: topology.mapName
        ) else {
            plannedPath = nil
            plannerStatus = "目标不可达，请检查平台、绳索或传送点连接"
            return
        }
        plannedPath = path
        plannerStatus = path.edges.isEmpty ? "角色已经位于目标位置" : "已规划 \(path.edges.count) 步，只预览不执行"
    }

    private func actionTitle(_ edge: NavigationEdge) -> String {
        switch edge.kind {
        case .walk: return "步行"
        case .climb: return "爬绳"
        case .approach: return "接近"
        case .jumpGrabRope: return "跳抓绳"
        case .drop: return edge.direction == .left ? "向左下落" : edge.direction == .right ? "向右下落" : "下跳"
        case .teleport: return "传送"
        case .jump: return "跳跃"
        }
    }

    private func startWalkExecution() {
        guard canExecuteWalk, let path = plannedPath, let contentRegion else { return }
        let graph = currentNavigationGraph
        let executor = MapWalkExecutor()
        walkExecutor = executor
        isExecutingWalk = true
        plannerStatus = "准备执行连续步行；所有按压和间隔均在范围内随机"
        walkExecutionTask = Task { @MainActor in
            defer {
                isExecutingWalk = false
                walkExecutionTask = nil
                walkExecutor = nil
                NSApp.activate(ignoringOtherApps: true)
            }
            do {
                try await executor.executeWalkPrefix(
                    path: path,
                    graph: graph,
                    topology: topology,
                    windowID: windowID,
                    minimapRegion: contentRegion,
                    onFrame: { frame, player in
                        minimapBuffer = frame
                        minimapImage = frame.mapEditorImage()
                        latestPlayerPoint = player
                    },
                    onUpdate: { message in
                        plannerStatus = message
                    }
                )
                plannerStatus = "连续步行执行完成；后续动作尚未自动执行"
                refreshPlannedPath()
            } catch is CancellationError {
                plannerStatus = "执行已紧急停止，方向键已释放"
            } catch {
                plannerStatus = "执行停止：\(error.localizedDescription)"
            }
        }
    }

    private func stopWalkExecution() {
        walkExecutionTask?.cancel()
        if let walkExecutor { Task { await walkExecutor.stop() } }
        plannerStatus = "正在紧急停止并释放方向键..."
    }

    private func startDropExecution() {
        guard canExecuteDrop,
              let edge = plannedPath?.edges.first,
              let contentRegion else { return }
        let graph = currentNavigationGraph
        let executor = MapDropExecutor()
        dropExecutor = executor
        isExecutingDrop = true
        plannerStatus = "准备执行下落；所有按压、间隔和松键时间均在范围内随机"
        dropExecutionTask = Task { @MainActor in
            defer {
                isExecutingDrop = false
                dropExecutionTask = nil
                dropExecutor = nil
                NSApp.activate(ignoringOtherApps: true)
            }
            do {
                try await executor.execute(
                    edge: edge,
                    graph: graph,
                    topology: topology,
                    jumpKey: jumpKey,
                    windowID: windowID,
                    minimapRegion: contentRegion,
                    onFrame: { frame, player in
                        minimapBuffer = frame
                        minimapImage = frame.mapEditorImage()
                        latestPlayerPoint = player
                    },
                    onUpdate: { message in plannerStatus = message }
                )
                plannerStatus = "下落执行完成，已确认落到目标平台"
                refreshPlannedPath()
            } catch is CancellationError {
                plannerStatus = "执行已紧急停止，相关按键已释放"
            } catch {
                plannerStatus = "下落执行停止：\(error.localizedDescription)"
            }
        }
    }

    private func stopCurrentExecution() {
        stopWalkExecution()
        dropExecutionTask?.cancel()
        if let dropExecutor { Task { await dropExecutor.stop() } }
        routeExecutionTask?.cancel()
        if let routeExecutor { Task { await routeExecutor.stop() } }
        plannerStatus = "正在紧急停止并释放全部相关按键..."
    }

    private func openActionTestWindow() {
        if let actionTestWindowController {
            actionTestWindowController.showWindow(nil)
            actionTestWindowController.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let controller = MapActionTestWindowController(windowID: windowID, jumpKey: jumpKey)
        actionTestWindowController = controller
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func startRouteExecution() {
        guard canExecuteRoute, let path = plannedPath, let contentRegion else { return }
        let graph = currentNavigationGraph
        let executor = MapRouteExecutor()
        routeExecutor = executor
        isExecutingRoute = true
        plannerStatus = "开始执行完整路径；所有动作按拟人随机时序执行"
        routeExecutionTask = Task { @MainActor in
            defer {
                isExecutingRoute = false
                routeExecutionTask = nil
                routeExecutor = nil
                NSApp.activate(ignoringOtherApps: true)
            }
            do {
                try await executor.execute(
                    path: path,
                    graph: graph,
                    topology: topology,
                    jumpKey: jumpKey,
                    windowID: windowID,
                    minimapRegion: contentRegion,
                    onFrame: { frame, player in
                        minimapBuffer = frame
                        minimapImage = frame.mapEditorImage()
                        latestPlayerPoint = player
                    },
                    onUpdate: { message in plannerStatus = message }
                )
                plannerStatus = "完整路径执行完成"
                refreshPlannedPath()
            } catch is CancellationError {
                plannerStatus = "完整路径已紧急停止，全部按键已释放"
            } catch {
                plannerStatus = "路径执行停止：\(error.localizedDescription)"
            }
        }
    }

    private func drawLiveTrace(context: inout GraphicsContext, size: CGSize) {
        if liveTracePoints.count >= 2 {
            var path = Path()
            path.move(to: liveTracePoints[0].point(in: size))
            for point in liveTracePoints.dropFirst() {
                path.addLine(to: point.point(in: size))
            }
            context.stroke(
                path,
                with: .color(.cyan),
                style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round, dash: [5, 3])
            )
        }
        if let rope = liveRope {
            var path = Path()
            path.move(to: CGPoint(x: rope.x * size.width, y: rope.topY * size.height))
            path.addLine(to: CGPoint(x: rope.x * size.width, y: rope.bottomY * size.height))
            context.stroke(path, with: .color(.cyan), style: StrokeStyle(lineWidth: 3, dash: [5, 3]))
        }
        if let player = latestPlayerPoint, contentSize.width > 0, contentSize.height > 0 {
            let displayPoint = CGPoint(
                x: player.x / contentSize.width * size.width,
                y: player.y / contentSize.height * size.height
            )
            context.fill(
                Path(ellipseIn: CGRect(x: displayPoint.x - 5, y: displayPoint.y - 5, width: 10, height: 10)),
                with: .color(.yellow)
            )
            context.stroke(
                Path(ellipseIn: CGRect(x: displayPoint.x - 6, y: displayPoint.y - 6, width: 12, height: 12)),
                with: .color(.black),
                lineWidth: 1
            )
        }
    }

    private func drawDraft(context: inout GraphicsContext, size: CGSize) {
        guard let start = dragStart, let current = dragCurrent else { return }
        var path = Path()
        switch tool {
        case .platform:
            path.move(to: start)
            if abs(current.y - start.y) <= size.height * 0.035 {
                path.addLine(to: CGPoint(x: current.x, y: (start.y + current.y) / 2))
            } else {
                path.addLine(to: current)
            }
        case .rope:
            let x = (start.x + current.x) / 2
            path.move(to: CGPoint(x: x, y: start.y))
            path.addLine(to: CGPoint(x: x, y: current.y))
        case .portal:
            context.fill(Path(ellipseIn: CGRect(x: current.x - 6, y: current.y - 6, width: 12, height: 12)), with: .color(.blue.opacity(0.8)))
        }
        context.stroke(path, with: .color(tool.color.opacity(0.8)), style: StrokeStyle(lineWidth: 3, dash: [6, 4]))
    }

    private func removePlatform(_ id: UUID) {
        pushHistory()
        topology.platforms.removeAll { $0.id == id }
        topology.traversalConnections.removeAll {
            $0.fromPlatformID == id || $0.toPlatformID == id
        }
        onConfirm(topology)
    }

    private func removeRope(_ id: UUID) {
        pushHistory()
        topology.ropes.removeAll { $0.id == id }
        onConfirm(topology)
    }

    private func removePortal(_ id: UUID) {
        pushHistory()
        topology.portals.removeAll { $0.id == id }
        onConfirm(topology)
    }

    private func removeConnection(_ id: UUID) {
        pushHistory()
        topology.traversalConnections.removeAll { $0.id == id }
        onConfirm(topology)
    }

    private func connectionEnabledBinding(for id: UUID) -> Binding<Bool> {
        Binding(get: { topology.traversalConnections.first(where: { $0.id == id })?.isEnabled ?? false }) { value in
            guard let index = topology.traversalConnections.firstIndex(where: { $0.id == id }) else { return }
            topology.traversalConnections[index].isEnabled = value
            onConfirm(topology)
        }
    }

    private func connectionHoldBinding(for id: UUID) -> Binding<Int> {
        Binding(get: { topology.traversalConnections.first(where: { $0.id == id })?.keyHoldMilliseconds ?? 300 }) { value in
            guard let index = topology.traversalConnections.firstIndex(where: { $0.id == id }) else { return }
            topology.traversalConnections[index].keyHoldMilliseconds = value
            onConfirm(topology)
        }
    }

    private func markPortalAtPlayerPosition() {
        guard let player = latestPlayerPoint, contentSize.width > 0, contentSize.height > 0 else {
            statusText = "尚未识别到角色黄点，无法标记传送点"
            return
        }
        pushHistory()
        topology.portals.append(MapPortal(point: NormalizedMapPoint(player, in: contentSize)))
        onConfirm(topology)
        statusText = "已按角色当前黄点位置添加并保存传送点"
    }

    private func portalTypeBinding(for id: UUID) -> Binding<MapPortalType> {
        Binding(get: { topology.portals.first(where: { $0.id == id })?.type ?? .normal }) { value in
            guard let index = topology.portals.firstIndex(where: { $0.id == id }) else { return }
            topology.portals[index].type = value
            if value == .intraMap {
                topology.portals[index].destinationMapName = topology.mapName
                if topology.portals[index].destinationPortalID == id {
                    topology.portals[index].destinationPortalID = nil
                }
            }
            onConfirm(topology)
        }
    }

    private func destinationMapBinding(for id: UUID) -> Binding<String> {
        Binding(get: { topology.portals.first(where: { $0.id == id })?.destinationMapName ?? "" }) { value in
            guard let index = topology.portals.firstIndex(where: { $0.id == id }) else { return }
            topology.portals[index].destinationMapName = value.isEmpty ? nil : value
            topology.portals[index].destinationPortalID = nil
            onConfirm(topology)
        }
    }

    private func destinationPortalBinding(for id: UUID) -> Binding<UUID?> {
        Binding(get: { topology.portals.first(where: { $0.id == id })?.destinationPortalID }) { value in
            guard let index = topology.portals.firstIndex(where: { $0.id == id }) else { return }
            topology.portals[index].destinationPortalID = value
            onConfirm(topology)
        }
    }

    private func targetMap(named name: String) -> MapTopology? {
        name == topology.mapName ? topology : availableMaps.first { $0.mapName == name }
    }

    private func nearestPlatform(to point: NormalizedMapPoint) -> (id: UUID, point: NormalizedMapPoint)? {
        var best: (id: UUID, point: NormalizedMapPoint, distance: Double)?
        for platform in topology.platforms {
            for (start, end) in zip(platform.points, platform.points.dropFirst()) {
                let dx = end.x - start.x
                let dy = end.y - start.y
                let lengthSquared = dx * dx + dy * dy
                let t = lengthSquared > 0.000001
                    ? min(max(((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared, 0), 1)
                    : 0
                let projected = NormalizedMapPoint(x: start.x + t * dx, y: start.y + t * dy)
                let distance = hypot(point.x - projected.x, point.y - projected.y)
                if best == nil || distance < best!.distance {
                    best = (platform.id, projected, distance)
                }
            }
        }
        guard let best, best.distance <= 0.08 else { return nil }
        return (best.id, best.point)
    }

    private func clearAll() {
        pushHistory()
        topology.platforms.removeAll()
        topology.ropes.removeAll()
        topology.portals.removeAll()
        topology.traversalConnections.removeAll()
        onConfirm(topology)
    }

    private func pushHistory() {
        history.append(topology)
        if history.count > 50 { history.removeFirst() }
    }

    private func undo() {
        guard let previous = history.popLast() else { return }
        topology = previous
        onConfirm(topology)
    }

    private func cropRect(in displaySize: CGSize) -> CGRect? {
        guard let start = cropStart, let current = cropCurrent else { return nil }
        let rect = CGRect(
            x: min(start.x, current.x),
            y: min(start.y, current.y),
            width: abs(current.x - start.x),
            height: abs(current.y - start.y)
        ).intersection(CGRect(origin: .zero, size: displaySize))
        return rect.width >= 30 && rect.height >= 20 ? rect : nil
    }

    @MainActor
    private func applyManualCrop() async {
        guard let fallbackBuffer,
              let displayRect = cropRect(in: fallbackPreviewSize),
              fallbackPreviewSize.width > 0,
              fallbackPreviewSize.height > 0 else { return }
        let scaleX = CGFloat(fallbackBuffer.width) / fallbackPreviewSize.width
        let scaleY = CGFloat(fallbackBuffer.height) / fallbackPreviewSize.height
        let x = max(0, Int(displayRect.minX * scaleX))
        let y = max(0, Int(displayRect.minY * scaleY))
        let width = min(fallbackBuffer.width - x, Int(displayRect.width * scaleX))
        let height = min(fallbackBuffer.height - y, Int(displayRect.height * scaleY))
        guard let searchBuffer = fallbackBuffer.cropped(
            x: x,
            y: y,
            width: width,
            height: height
        ) else { return }

        isLoading = true
        statusText = "正在框选范围内识别小地图..."
        let result = await Task.detached(priority: .userInitiated) {
            ColorDetector.detectMinimapRegion(
                in: searchBuffer,
                searchWidth: searchBuffer.width,
                searchHeight: searchBuffer.height,
                requiresTopLeftAnchor: false
            )
        }.value

        guard let localRegion = result.rect,
              let selected = searchBuffer.cropped(
                  x: Int(localRegion.minX),
                  y: Int(localRegion.minY),
                  width: Int(localRegion.width),
                  height: Int(localRegion.height)
              ) else {
            statusText = "框选范围内仍未找到小地图，请放宽范围并完整包含白框后重试。"
            isLoading = false
            return
        }
        let resolvedRegion = localRegion.offsetBy(dx: CGFloat(x), dy: CGFloat(y))

        let validation = ColorDetector.validateMinimapContent(in: selected)
        guard validation.isValid else {
            statusText = "框选范围内仍未找到小地图：\(validation.summary)"
            isLoading = false
            return
        }
        contentRegion = resolvedRegion
        acceptMinimap(selected, validation: validation)
        isLoading = false
    }

    @MainActor
    private func beginManualCrop() async {
        isLoading = true
        fallbackBuffer = nil
        fallbackImage = nil
        cropStart = nil
        cropCurrent = nil
        statusText = "正在读取完整游戏画面..."

        let monitor = MinimapMonitor()
        monitor.setWindow(windowID)
        do {
            let fullScreen = try await monitor.captureGameScreen()
            fallbackBuffer = fullScreen
            fallbackImage = fullScreen.mapEditorImage()
            statusText = "请大致框住小地图面板，再点击“在框选范围内识别”。"
        } catch {
            statusText = "完整游戏画面加载失败：\(error.localizedDescription)"
        }
        isLoading = false
    }

    @MainActor
    private func loadMinimap() async {
        isLoading = true
        minimapImage = nil
        contentRegion = nil
        fallbackImage = nil
        fallbackBuffer = nil
        cropStart = nil
        cropCurrent = nil
        defer { isLoading = false }

        let monitor = MinimapMonitor()
        monitor.setWindow(windowID)
        do {
            if let region = try await monitor.autoDetectDarkRegion() {
                let buffer = try await monitor.captureMinimap()
                let validation = ColorDetector.validateMinimapContent(in: buffer)
                if validation.isValid {
                    contentRegion = region
                    acceptMinimap(buffer, validation: validation)
                    return
                }
                statusText = "自动裁剪未通过校验：\(validation.summary)"
            } else {
                statusText = "自动裁剪失败：\(monitor.lastDetectionSummary)"
            }
            statusText += "；可点击“手动框选”指定搜索范围"
        } catch {
            statusText = "加载小地图失败：\(error.localizedDescription)"
        }
    }

    private func acceptMinimap(
        _ buffer: ImageBuffer,
        validation: ColorDetector.MinimapContentValidationResult
    ) {
        minimapBuffer = buffer
        minimapImage = buffer.mapEditorImage()
        contentSize = CGSize(width: buffer.width, height: buffer.height)
        topology.referenceWidth = buffer.width
        topology.referenceHeight = buffer.height
        fallbackBuffer = nil
        fallbackImage = nil
        statusText = "已截取纯内容区 \(buffer.width)×\(buffer.height)：\(validation.summary)"
    }

    private func startTrace() {
        guard !isTracing, let contentRegion else { return }
        discardTraceResult = false
        traceSamples = []
        liveTracePoints = []
        liveRope = nil
        latestPlayerPoint = nil
        isTracing = true
        statusText = "采集已开始：请在游戏中手动控制角色沿\(tool == .platform ? "平台左右" : "绳索上下")移动"
        let tracingTool = tool
        traceTask = Task { @MainActor in
            defer {
                isTracing = false
                traceTask = nil
                NSApp.activate(ignoringOtherApps: true)
            }
            let recorder = PlatformTraceRecorder()
            do {
                let samples = try await recorder.recordUntilStopped(
                    windowID: windowID,
                    minimapRegion: contentRegion
                ) { frame, player, samples in
                    minimapBuffer = frame
                    minimapImage = frame.mapEditorImage()
                    latestPlayerPoint = player
                    traceSamples = samples
                    if tracingTool == .platform {
                        liveTracePoints = PlatformTraceBuilder.buildPolyline(from: samples, canvasSize: contentSize)
                        liveRope = nil
                    } else {
                        liveTracePoints = []
                        liveRope = RopeTraceBuilder.buildRope(from: samples, canvasSize: contentSize)
                    }
                    if let player {
                        statusText = "采集中：黄点 (\(Int(player.x)), \(Int(player.y)))，已记录 \(samples.count) 个样本"
                    } else {
                        statusText = "采集中：当前帧未识别到黄点，已记录 \(samples.count) 个样本"
                    }
                }
                guard !discardTraceResult else { return }
                if tracingTool == .platform {
                    let points = PlatformTraceBuilder.buildPolyline(from: samples, canvasSize: contentSize)
                    guard points.count >= 2 else { throw PlatformTraceRecorder.TraceError.insufficientSamples }
                    pushHistory()
                    topology.platforms.append(MapPlatform(points: points))
                    onConfirm(topology)
                    statusText = "采集完成：\(samples.count) 个黄点样本已融合为 \(points.count) 个平台折线点"
                } else {
                    guard let rope = RopeTraceBuilder.buildRope(from: samples, canvasSize: contentSize) else {
                        throw PlatformTraceRecorder.TraceError.insufficientSamples
                    }
                    pushHistory()
                    topology.ropes.append(rope)
                    onConfirm(topology)
                    statusText = "采集完成：\(samples.count) 个黄点样本已融合为一条绳索"
                }
                liveTracePoints = []
                liveRope = nil
                latestPlayerPoint = nil
            } catch {
                guard !discardTraceResult else { return }
                statusText = "采集未生成\(tracingTool.rawValue)：有效移动轨迹不足"
            }
        }
    }

    private func finishTrace() {
        guard isTracing else { return }
        statusText = "正在结束采集并融合\(tool.rawValue)轨迹..."
        traceTask?.cancel()
    }

    private func startLiveRefresh() {
        guard liveRefreshTask == nil else { return }
        guard let refreshRegion = contentRegion ?? liveComparisonRegion else {
            liveSimilarity = nil
            liveSimilarityStatus = "没有可用的实时小地图区域，请先重新识别"
            return
        }
        liveRefreshTask = Task { @MainActor in
            let monitor = MinimapMonitor()
            monitor.setWindow(windowID)
            monitor.setMinimapRegion(refreshRegion)
            while !Task.isCancelled {
                if !isTracing && !isExecutingAction {
                    do {
                        let frame = try await monitor.captureMinimap()
                        let referenceSignature = topology.visualSignature
                            ?? storedReferenceSignature()
                        let analysis = await Task.detached(priority: .userInitiated) {
                            let detection = ColorDetector.detectPlayerMarker(in: frame)
                            let comparison = referenceSignature.map {
                                MinimapVisualMatcher.comparison(
                                    MinimapVisualMatcher.signature(for: frame),
                                    $0
                                )
                            }
                            return (detection, comparison)
                        }.value
                        liveSimilarity = analysis.1
                        liveSimilarityStatus = analysis.1 == nil
                            ? "这张地图没有可用的参考签名"
                            : "实时计算中"

                        // A comparison region may belong to a different map.
                        // Keep the saved reference image and editing actions
                        // untouched until the current map actually matches.
                        if contentRegion != nil {
                            minimapBuffer = frame
                            minimapImage = frame.mapEditorImage()
                            latestPlayerPoint = analysis.0.point
                            if !selectedPathTarget.isEmpty { refreshPlannedPath() }
                            if tool == .portal {
                                statusText = analysis.0.point == nil
                                    ? "实时小地图已刷新，当前帧未识别到角色黄点"
                                    : "实时小地图已刷新，可以标记角色当前位置"
                            }
                        }
                    } catch {
                        liveSimilarity = nil
                        liveSimilarityStatus = "实时小地图读取失败：\(error.localizedDescription)"
                        if contentRegion != nil {
                            statusText = "实时小地图刷新失败：\(error.localizedDescription)"
                        }
                    }
                }
                try? await Task.sleep(for: .milliseconds(90))
            }
        }
    }

    private func reloadMinimap() {
        guard !isLoading, !isMergingReference, !isTracing, !isExecutingAction else { return }
        liveRefreshTask?.cancel()
        liveRefreshTask = nil
        liveSimilarity = nil
        liveSimilarityStatus = "正在重新识别当前游戏小地图..."
        latestPlayerPoint = nil
        plannedPath = nil
        plannerStatus = "正在重新识别小地图..."
        Task { @MainActor in
            await loadMinimap()
            startLiveRefresh()
            if !selectedPathTarget.isEmpty { refreshPlannedPath() }
        }
    }

    private func mergeCurrentMinimapIntoReference() {
        guard !isLoading, !isMergingReference, !isTracing, !isExecutingAction else { return }
        guard let stored = storedReferenceBuffer() else {
            statusText = "这张地图没有可融合的已保存参考图"
            return
        }
        isMergingReference = true
        statusText = "正在抓取当前小地图并检查是否匹配..."

        Task { @MainActor in
            defer { isMergingReference = false }
            let monitor = MinimapMonitor()
            monitor.setWindow(windowID)
            do {
                guard let region = try await monitor.autoDetectDarkRegion() else {
                    statusText = "无法识别当前小地图：\(monitor.lastDetectionSummary)"
                    return
                }
                let current = try await monitor.captureMinimap()
                let validation = ColorDetector.validateMinimapContent(in: current)
                guard validation.isValid else {
                    statusText = "当前小地图校验失败：\(validation.summary)"
                    return
                }
                guard current.width == stored.width, current.height == stored.height else {
                    statusText = "当前小地图尺寸为 \(current.width)×\(current.height)，与已保存的 \(stored.width)×\(stored.height) 不一致，未融合"
                    return
                }

                let currentSignature = MinimapVisualMatcher.signature(for: current)
                let referenceSignature = topology.visualSignature
                    ?? MinimapVisualMatcher.signature(for: stored)
                let comparison = MinimapVisualMatcher.comparison(currentSignature, referenceSignature)
                guard comparison.isMatch else {
                    statusText = "当前小地图与“\(topology.mapName)”仅相似 \(String(format: "%.1f", comparison.similarityPercentage))%，为避免串图未融合"
                    return
                }

                let result = try await Task.detached(priority: .userInitiated) {
                    try MinimapBackgroundSynthesizer.mergeReference(
                        stored: stored,
                        current: current
                    )
                }.value
                pushHistory()
                topology.referenceWidth = result.buffer.width
                topology.referenceHeight = result.buffer.height
                topology.referenceBGR = Data(result.buffer.bgr)
                topology.visualSignature = MinimapVisualMatcher.signature(for: result.buffer)
                minimapBuffer = result.buffer
                minimapImage = result.buffer.mapEditorImage()
                contentSize = CGSize(width: result.buffer.width, height: result.buffer.height)
                contentRegion = region
                onConfirm(topology)
                statusText = result.replacedPixelCount > 0
                    ? "融合并保存完成：用当前未遮挡区域修补了 \(result.replacedPixelCount) 个像素；仍有 \(result.stillCoveredPixelCount) 个像素被标记遮挡"
                    : "已检查并保存：当前截图没有可用于修补的新增未遮挡区域"
            } catch {
                statusText = "小地图融合失败：\(error.localizedDescription)"
            }
        }
    }

    private func storedReferenceBuffer() -> ImageBuffer? {
        guard let data = topology.referenceBGR,
              topology.referenceWidth > 0,
              topology.referenceHeight > 0,
              data.count == topology.referenceWidth * topology.referenceHeight * 3 else {
            return nil
        }
        return ImageBuffer(
            width: topology.referenceWidth,
            height: topology.referenceHeight,
            bgr: Array(data)
        )
    }

    private func storedReferenceSignature() -> [UInt8]? {
        guard let buffer = storedReferenceBuffer() else { return nil }
        return MinimapVisualMatcher.signature(for: buffer)
    }
}

extension ImageBuffer {
    func mapEditorImage() -> NSImage? {
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        var destination = 0
        for source in stride(from: 0, to: bgr.count, by: 3) {
            rgba[destination] = bgr[source + 2]
            rgba[destination + 1] = bgr[source + 1]
            rgba[destination + 2] = bgr[source]
            rgba[destination + 3] = 255
            destination += 4
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let cgImage = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: width, height: height))
    }
}
