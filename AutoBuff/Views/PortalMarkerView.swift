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
    
    private func scaled(_ point: CGPoint, in size: CGSize) -> CGPoint {
        guard regionSize.width > 0, regionSize.height > 0 else { return point }
        return CGPoint(x: point.x / regionSize.width * size.width, y: point.y / regionSize.height * size.height)
    }
    
    private func loadMinimap() async {
        isLoading = true
        defer { isLoading = false }
        let monitor = MinimapMonitor()
        monitor.setWindow(windowID)
        do {
            guard let region = try await monitor.autoDetectDarkRegion() else {
                statusText = "未识别到小地图：\(monitor.lastDetectionSummary)"
                minimapImage = nil
                regionSize = .zero
                detectedRegion = nil
                return
            }
            detectedRegion = region
            let buffer = try await monitor.captureMinimap()
            regionSize = CGSize(width: buffer.width, height: buffer.height)
            minimapImage = buffer.toPreviewImage()
            if showAutoPortal {
                autoPortal = try await monitor.findBluePortal(leftmost: true)
            }
            if let existingX, let existingY {
                manualPoint = CGPoint(x: existingX, y: existingY)
            }
            statusText = loadedStatusText
        } catch {
            statusText = "加载失败: \(error.localizedDescription)"
        }
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
