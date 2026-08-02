import CoreGraphics
import Foundation
import ImageIO

/// 把磁盘上的图片读成检测器能吃的 BGR 缓冲。
///
/// 走的是和实时截图完全相同的 `ImagePipeline.cgImageToBGRBuffer`，
/// 所以回放结果和真实运行时一致，不会因为读图路径不同而产生偏差。
enum RuneAlertImageLoader {
    static func loadBuffer(at url: URL) -> ImageBuffer? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        return ImagePipeline.cgImageToBGRBuffer(image)
    }
}

/// 单张图片的符文回放结果。
struct RuneAlertImageTestItem: Equatable, Sendable {
    let fileName: String
    let detection: RuneAlertDetection?
    /// 图片无法读取或解码；这类失败要和「读到了但没识别出符文」区分开。
    let isUnreadable: Bool

    var isDetected: Bool { detection != nil }
}

/// 一批图片的回放汇总。
struct RuneAlertImageTestReport: Equatable, Sendable {
    let items: [RuneAlertImageTestItem]

    var detectedItems: [RuneAlertImageTestItem] { items.filter(\.isDetected) }
    var unreadableItems: [RuneAlertImageTestItem] { items.filter(\.isUnreadable) }
    var missedItems: [RuneAlertImageTestItem] {
        items.filter { !$0.isUnreadable && !$0.isDetected }
    }

    /// 置信度最高的那张命中，用来驱动后续的状态注入和推送。
    /// 一批图里只推一次，避免选了 9 张就轰炸 9 条通知。
    var strongest: RuneAlertImageTestItem? {
        detectedItems.max {
            ($0.detection?.confidence ?? 0) < ($1.detection?.confidence ?? 0)
        }
    }

    var summary: String {
        guard !items.isEmpty else { return "没有选择图片" }

        var parts: [String] = []
        if detectedItems.count == items.count {
            parts.append("\(items.count) 张全部识别到符文")
        } else if detectedItems.isEmpty {
            parts.append("\(items.count) 张均未识别到符文")
        } else {
            parts.append("\(items.count) 张中 \(detectedItems.count) 张识别到符文")
        }
        if let confidence = confidenceText {
            parts.append("置信度 \(confidence)")
        }
        if !missedItems.isEmpty {
            parts.append("未识别：" + Self.nameList(missedItems))
        }
        if !unreadableItems.isEmpty {
            parts.append("无法读取：" + Self.nameList(unreadableItems))
        }
        return parts.joined(separator: "，")
    }

    private var confidenceText: String? {
        let values = detectedItems.compactMap { $0.detection?.confidence }.sorted()
        guard let lowest = values.first, let highest = values.last else { return nil }
        let lowestText = Self.percentText(lowest)
        let highestText = Self.percentText(highest)
        return lowestText == highestText ? lowestText : "\(lowestText)–\(highestText)"
    }

    private static func percentText(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    /// 文件名最多列 3 个，再多只报数量，避免一行文案被 9 个文件名撑爆。
    private static func nameList(_ items: [RuneAlertImageTestItem]) -> String {
        let names = items.map(\.fileName)
        guard names.count > 3 else { return names.joined(separator: "、") }
        return names.prefix(3).joined(separator: "、") + " 等 \(names.count) 张"
    }
}

enum RuneAlertImageTestRunner {
    /// 逐张回放。耗时与图片数量成正比，调用方应放到后台线程。
    static func run(urls: [URL]) -> RuneAlertImageTestReport {
        let items = urls.map { url -> RuneAlertImageTestItem in
            guard let buffer = RuneAlertImageLoader.loadBuffer(at: url) else {
                return RuneAlertImageTestItem(
                    fileName: url.lastPathComponent,
                    detection: nil,
                    isUnreadable: true
                )
            }
            return RuneAlertImageTestItem(
                fileName: url.lastPathComponent,
                detection: RuneAlertDetector.detect(in: buffer),
                isUnreadable: false
            )
        }
        return RuneAlertImageTestReport(items: items)
    }
}

enum RuneAlertImageTestPolicy {
    /// 服务端推送调度的扫描周期，仅用于说明下面保持时长的下限。
    static let serverScheduleInterval = Duration.seconds(5)

    /// 回放命中后，注入的「有符文」状态要保持这么久。
    ///
    /// 实时识别每秒一帧，若不保持，注入状态会在 1 秒内被真实画面（无符文）
    /// 覆盖，服务端那一轮扫描根本看不到它，推送永远不会触发。因此保持时长
    /// 必须大于服务端扫描周期，确保至少有一轮落在窗口内。
    static let stateHoldDuration = Duration.seconds(8)
}

/// 监控面板图片回放支持的告警类型。
enum MonitorImageTestKind: String, CaseIterable, Identifiable {
    case rune
    case mouseFollowVerification

    var id: Self { self }

    var title: String {
        switch self {
        case .rune: "符文"
        case .mouseFollowVerification: "测谎"
        }
    }

    var imagePrompt: String {
        switch self {
        case .rune: "符文截图"
        case .mouseFollowVerification: "测谎弹窗截图"
        }
    }
}

/// 单张图片的鼠标跟随验证（测谎）回放结果。
struct MouseFollowVerificationImageTestItem: Equatable, Sendable {
    let fileName: String
    let detection: MouseFollowVerificationDetection?
    let isUnreadable: Bool

    var isDetected: Bool { detection != nil }
}

struct MouseFollowVerificationImageTestReport: Equatable, Sendable {
    let items: [MouseFollowVerificationImageTestItem]

    var detectedItems: [MouseFollowVerificationImageTestItem] { items.filter(\.isDetected) }
    var unreadableItems: [MouseFollowVerificationImageTestItem] { items.filter(\.isUnreadable) }
    var missedItems: [MouseFollowVerificationImageTestItem] {
        items.filter { !$0.isUnreadable && !$0.isDetected }
    }
    var strongest: MouseFollowVerificationImageTestItem? {
        detectedItems.max {
            ($0.detection?.confidence ?? 0) < ($1.detection?.confidence ?? 0)
        }
    }

    var summary: String {
        guard !items.isEmpty else { return "没有选择图片" }

        var parts: [String] = []
        if detectedItems.count == items.count {
            parts.append("\(items.count) 张全部识别到测谎弹窗")
        } else if detectedItems.isEmpty {
            parts.append("\(items.count) 张均未识别到测谎弹窗")
        } else {
            parts.append("\(items.count) 张中 \(detectedItems.count) 张识别到测谎弹窗")
        }
        let confidences = detectedItems.compactMap { $0.detection?.confidence }.sorted()
        if let lowest = confidences.first, let highest = confidences.last {
            let low = Self.percentText(lowest)
            let high = Self.percentText(highest)
            parts.append("置信度 " + (low == high ? low : "\(low)–\(high)"))
        }
        if !missedItems.isEmpty {
            parts.append("未识别：" + Self.nameList(missedItems))
        }
        if !unreadableItems.isEmpty {
            parts.append("无法读取：" + Self.nameList(unreadableItems))
        }
        return parts.joined(separator: "，")
    }

    private static func percentText(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    private static func nameList(_ items: [MouseFollowVerificationImageTestItem]) -> String {
        let names = items.map(\.fileName)
        guard names.count > 3 else { return names.joined(separator: "、") }
        return names.prefix(3).joined(separator: "、") + " 等 \(names.count) 张"
    }
}

enum MouseFollowVerificationImageTestRunner {
    static func run(urls: [URL]) -> MouseFollowVerificationImageTestReport {
        let items = urls.map { url -> MouseFollowVerificationImageTestItem in
            guard let buffer = RuneAlertImageLoader.loadBuffer(at: url) else {
                return MouseFollowVerificationImageTestItem(
                    fileName: url.lastPathComponent,
                    detection: nil,
                    isUnreadable: true
                )
            }
            return MouseFollowVerificationImageTestItem(
                fileName: url.lastPathComponent,
                detection: MouseFollowVerificationDetector.detect(in: buffer),
                isUnreadable: false
            )
        }
        return MouseFollowVerificationImageTestReport(items: items)
    }
}
