import AppKit
import SwiftUI

@available(macOS 14.0, *)
struct PortalMarkerView: View {
    let windowID: CGWindowID
    let existingX: Int?
    let existingY: Int?
    var title = "标记传送门位置"
    var showAutoPortal = true
    var clearButtonTitle = "清除手动标记"
    var loadedStatusText = "蓝点=自动检测，红点=手动标记，点击图像设置手动位置"
    let onConfirm: (Int?, Int?, CGRect?) -> Void
    
    @Environment(\.dismiss) private var dismiss
    @State private var minimapImage: NSImage?
    @State private var autoPortal: CGPoint?
    @State private var manualPoint: CGPoint?
    @State private var regionSize: CGSize = .zero
    @State private var detectedRegion: CGRect?
    @State private var statusText = "加载中..."
    @State private var isLoading = true
    @State private var loadRequestID = UUID()
    @State private var gameBuffer: ImageBuffer?
    @State private var gameImage: NSImage?
    @State private var gameSize: CGSize = .zero
    @State private var selectedSearchRegion: CGRect?
    @State private var selectionStart: CGPoint?
    @State private var automaticDetectionTask: Task<ColorDetector.DarkRegionDetectionResult, Never>?
    
    var body: some View {
        VStack(spacing: 12) {
            Text(title)
                .font(.title2)
            Text(statusText)
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
                .multilineTextAlignment(.center)
                .lineLimit(3)
            if let image = minimapImage {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.none)
                    .frame(width: previewSize.width, height: previewSize.height)
                    .overlay {
                        Canvas { context, size in
                            if showAutoPortal, let auto = autoPortal {
                                let p = scaled(auto, in: size)
                                context.fill(Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)), with: .color(.blue))
                            }
                            if let manual = manualPoint {
                                let p = scaled(manual, in: size)
                                context.fill(Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)), with: .color(.red))
                            }
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { location in
                        guard previewScale > 0 else { return }
                        manualPoint = CGPoint(x: location.x / previewScale, y: location.y / previewScale)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay {
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(AppTheme.border)
                    }
            } else if let image = gameImage {
                VStack(spacing: 7) {
                    Text("在游戏画面中拖动圈选小地图的大致范围")
                        .font(.caption)
                        .foregroundStyle(AppTheme.textSecondary)

                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.none)
                        .frame(
                            width: gamePreviewSize.width,
                            height: gamePreviewSize.height
                        )
                        .overlay {
                            Canvas { context, _ in
                                guard let selectedSearchRegion else { return }
                                let previewRect = CGRect(
                                    x: selectedSearchRegion.minX * gamePreviewScale,
                                    y: selectedSearchRegion.minY * gamePreviewScale,
                                    width: selectedSearchRegion.width * gamePreviewScale,
                                    height: selectedSearchRegion.height * gamePreviewScale
                                )
                                context.fill(
                                    Path(previewRect),
                                    with: .color(AppTheme.accent.opacity(0.14))
                                )
                                context.stroke(
                                    Path(previewRect),
                                    with: .color(AppTheme.accent),
                                    lineWidth: 2
                                )
                            }
                        }
                        .contentShape(Rectangle())
                        .gesture(rangeSelectionGesture)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .overlay {
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(AppTheme.border)
                        }

                    Text("请沿小地图内容边缘框选，不要包含标题栏")
                        .font(.system(size: 10))
                        .foregroundStyle(AppTheme.textSecondary)
                }
            } else if isLoading {
                ProgressView()
                    .frame(width: 420, height: 240)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "map")
                        .font(.system(size: 28))
                        .foregroundStyle(AppTheme.textSecondary)
                    Text("未能加载小地图")
                        .font(.headline)
                    Text("请确认已选择游戏窗口，并且小地图在窗口左上区域可见。")
                        .font(.caption)
                        .foregroundStyle(AppTheme.textSecondary)
                        .multilineTextAlignment(.center)
                    Button("重试") {
                        Task { await loadMinimap() }
                    }
                }
                .frame(width: 420, height: 240)
                .background(AppTheme.panel)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(AppTheme.border)
                }
            }
            HStack {
                Button(clearButtonTitle) { manualPoint = nil }
                Spacer()
                Button("确认") {
                    if let manual = manualPoint {
                        onConfirm(Int(manual.x), Int(manual.y), detectedRegion)
                    } else {
                        onConfirm(nil, nil, nil)
                    }
                    dismiss()
                }
                Button("取消") { dismiss() }
            }
        }
        .padding()
        .frame(width: 480, height: 520)
        .task { await loadMinimap() }
        .onDisappear {
            automaticDetectionTask?.cancel()
            automaticDetectionTask = nil
        }
    }

    private var previewScale: CGFloat {
        guard regionSize.width > 0, regionSize.height > 0 else { return 1 }
        let maxPreview = CGSize(width: 420, height: 300)
        return min(
            2,
            maxPreview.width / regionSize.width,
            maxPreview.height / regionSize.height
        )
    }

    private var previewSize: CGSize {
        CGSize(width: regionSize.width * previewScale, height: regionSize.height * previewScale)
    }

    private var gamePreviewScale: CGFloat {
        guard gameSize.width > 0, gameSize.height > 0 else { return 1 }
        return min(420 / gameSize.width, 300 / gameSize.height)
    }

    private var gamePreviewSize: CGSize {
        CGSize(
            width: gameSize.width * gamePreviewScale,
            height: gameSize.height * gamePreviewScale
        )
    }

    private var rangeSelectionGesture: some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                let current = imagePoint(from: value.location)
                if selectionStart == nil {
                    selectionStart = imagePoint(from: value.startLocation)
                }
                guard let selectionStart else { return }
                selectedSearchRegion = normalizedSelection(
                    from: selectionStart,
                    to: current
                )
            }
            .onEnded { value in
                let start = selectionStart ?? imagePoint(from: value.startLocation)
                let region = normalizedSelection(
                    from: start,
                    to: imagePoint(from: value.location)
                )
                selectionStart = nil
                guard region.width >= 40, region.height >= 30 else {
                    statusText = "圈选范围太小，请重新拖动选择。"
                    return
                }
                selectedSearchRegion = region
                Task { await recognizeSelectedRange(region) }
            }
    }
    
    private func scaled(_ point: CGPoint, in size: CGSize) -> CGPoint {
        guard regionSize.width > 0, regionSize.height > 0 else { return point }
        return CGPoint(x: point.x / regionSize.width * size.width, y: point.y / regionSize.height * size.height)
    }

    private func imagePoint(from previewPoint: CGPoint) -> CGPoint {
        guard gamePreviewScale > 0 else { return .zero }
        return CGPoint(
            x: min(max(0, previewPoint.x / gamePreviewScale), gameSize.width),
            y: min(max(0, previewPoint.y / gamePreviewScale), gameSize.height)
        )
    }

    private func normalizedSelection(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, end.x),
            y: min(start.y, end.y),
            width: abs(end.x - start.x),
            height: abs(end.y - start.y)
        ).integral
    }
    
    private func loadMinimap() async {
        automaticDetectionTask?.cancel()
        automaticDetectionTask = nil
        let requestID = UUID()
        loadRequestID = requestID
        isLoading = true
        statusText = "正在读取游戏窗口..."
        minimapImage = nil
        detectedRegion = nil
        gameBuffer = nil
        gameImage = nil
        gameSize = .zero
        selectedSearchRegion = nil

        let slowLoadingTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled,
                  loadRequestID == requestID,
                  isLoading else { return }
            statusText = "仍在识别小地图，请稍候..."
        }
        let timeoutTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(30))
            guard !Task.isCancelled,
                  loadRequestID == requestID,
                  isLoading else { return }
            automaticDetectionTask?.cancel()
            automaticDetectionTask = nil
            statusText = "加载超时，请确认游戏窗口仍在屏幕上并重试。"
            isLoading = false
        }
        defer {
            slowLoadingTask.cancel()
            timeoutTask.cancel()
        }

        let monitor = MinimapMonitor()
        monitor.setWindow(windowID)
        do {
            let captured = try await monitor.captureGameScreen()
            guard loadRequestID == requestID, isLoading else { return }
            gameBuffer = captured
            gameImage = captured.toPreviewImage()
            gameSize = CGSize(width: captured.width, height: captured.height)
            statusText = "正在自动识别；也可以直接在画面中拖动圈选。"

            let detectionTask = Task.detached(priority: .userInitiated) {
                ColorDetector.detectMinimapRegion(in: captured)
            }
            automaticDetectionTask = detectionTask
            let result = await detectionTask.value
            if loadRequestID == requestID {
                automaticDetectionTask = nil
            }
            guard loadRequestID == requestID, isLoading else { return }
            guard let region = result.rect else {
                statusText = "自动识别失败，请在画面中拖动圈选小地图范围。"
                isLoading = false
                return
            }
            try await applyDetectedRegion(region, in: captured, requestID: requestID)
        } catch {
            guard loadRequestID == requestID, isLoading else { return }
            statusText = "加载失败: \(error.localizedDescription)"
            isLoading = false
        }
    }

    private func recognizeSelectedRange(_ searchRegion: CGRect) async {
        guard let gameBuffer else { return }
        automaticDetectionTask?.cancel()
        automaticDetectionTask = nil
        let requestID = UUID()
        loadRequestID = requestID
        isLoading = true
        statusText = "正在使用所选小地图范围..."
        do {
            try await applyDetectedRegion(
                searchRegion,
                in: gameBuffer,
                requestID: requestID
            )
        } catch {
            guard loadRequestID == requestID, isLoading else { return }
            statusText = "所选范围加载失败: \(error.localizedDescription)"
            isLoading = false
        }
    }

    private func applyDetectedRegion(
        _ region: CGRect,
        in source: ImageBuffer,
        requestID: UUID
    ) async throws {
        let x = max(0, Int(region.minX))
        let y = max(0, Int(region.minY))
        let width = min(Int(region.width), source.width - x)
        let height = min(Int(region.height), source.height - y)
        guard let buffer = source.cropped(
            x: x,
            y: y,
            width: width,
            height: height
        ) else {
            throw GameCaptureError.noImage
        }
        guard loadRequestID == requestID, isLoading else { return }

        detectedRegion = CGRect(x: x, y: y, width: width, height: height)
        regionSize = CGSize(width: buffer.width, height: buffer.height)
        minimapImage = buffer.toPreviewImage()
        if showAutoPortal {
            autoPortal = await Task.detached(priority: .userInitiated) {
                ColorDetector.findBluePortal(in: buffer, leftmost: true)
            }.value
        }
        guard loadRequestID == requestID, isLoading else { return }
        if let existingX, let existingY {
            manualPoint = CGPoint(x: existingX, y: existingY)
        }
        statusText = loadedStatusText
        isLoading = false
    }
}

private extension ImageBuffer {
    func toPreviewImage() -> NSImage? {
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        var dst = 0
        for i in stride(from: 0, to: bgr.count, by: 3) {
            rgba[dst] = bgr[i + 2]
            rgba[dst + 1] = bgr[i + 1]
            rgba[dst + 2] = bgr[i]
            rgba[dst + 3] = 255
            dst += 4
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let cg = CGImage(
                width: width, height: height,
                bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
              ) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: width, height: height))
    }
}
