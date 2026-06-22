import AppKit
import SwiftUI

@available(macOS 14.0, *)
struct PortalMarkerView: View {
    let windowID: CGWindowID
    let existingX: Int?
    let existingY: Int?
    let onConfirm: (Int?, Int?) -> Void
    
    @Environment(\.dismiss) private var dismiss
    @State private var minimapImage: NSImage?
    @State private var autoPortal: CGPoint?
    @State private var manualPoint: CGPoint?
    @State private var regionSize: CGSize = .zero
    @State private var statusText = "加载中..."
    
    var body: some View {
        VStack(spacing: 12) {
            Text("标记传送门位置")
                .font(.title2)
            Text(statusText)
                .font(.caption)
                .foregroundStyle(AppTheme.textSecondary)
            if let image = minimapImage {
                Image(nsImage: image)
                    .interpolation(.none)
                    .scaleEffect(2)
                    .frame(width: regionSize.width * 2, height: regionSize.height * 2)
                    .overlay {
                        Canvas { context, size in
                            if let auto = autoPortal {
                                let p = scaled(auto, in: size)
                                context.fill(Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)), with: .color(.blue))
                            }
                            if let manual = manualPoint {
                                let p = scaled(manual, in: size)
                                context.fill(Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)), with: .color(.red))
                            }
                        }
                    }
                    .onTapGesture { location in
                        manualPoint = CGPoint(x: location.x / 2, y: location.y / 2)
                    }
            } else {
                ProgressView()
                    .frame(height: 200)
            }
            HStack {
                Button("清除手动标记") { manualPoint = nil }
                Spacer()
                Button("确认") {
                    if let manual = manualPoint {
                        onConfirm(Int(manual.x), Int(manual.y))
                    } else {
                        onConfirm(nil, nil)
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
    
    private func scaled(_ point: CGPoint, in size: CGSize) -> CGPoint {
        guard regionSize.width > 0, regionSize.height > 0 else { return point }
        return CGPoint(x: point.x / regionSize.width * size.width, y: point.y / regionSize.height * size.height)
    }
    
    private func loadMinimap() async {
        let monitor = MinimapMonitor()
        monitor.setWindow(windowID)
        do {
            _ = try await monitor.autoDetectDarkRegion()
            let buffer = try await monitor.captureMinimap()
            regionSize = CGSize(width: buffer.width, height: buffer.height)
            minimapImage = buffer.toPreviewImage()
            autoPortal = try await monitor.findBluePortal(leftmost: true)
            if let existingX, let existingY {
                manualPoint = CGPoint(x: existingX, y: existingY)
            }
            statusText = "蓝点=自动检测，红点=手动标记，点击图像设置手动位置"
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
