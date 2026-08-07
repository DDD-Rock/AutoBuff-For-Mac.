import CoreGraphics
import Foundation

struct MonitoringFrame: Sendable {
    let buffer: ImageBuffer
    let playerPoint: CGPoint?
    let teammatePoints: [CGPoint]
    let otherPlayerPoints: [CGPoint]
    let matchedTopology: MapTopology?
    let framesPerSecond: Double
}

enum MonitorMapMatcher {
    static func match(frame: ImageBuffer, maps: [MapTopology]) -> MapTopology? {
        guard !maps.isEmpty else { return nil }
        let currentSignature = MinimapVisualMatcher.signature(for: frame)
        guard !currentSignature.isEmpty else { return nil }
        return maps.compactMap { map -> (map: MapTopology, similarity: Double)? in
            guard let storedSignature = map.visualSignature else { return nil }
            let comparison = MinimapVisualMatcher.comparison(currentSignature, storedSignature)
            guard comparison.isMatch else { return nil }
            return (map, comparison.similarityPercentage)
        }
        .max { $0.similarity < $1.similarity }?
        .map
    }
}

struct MonitorMapMatchStabilizer {
    static let requiredConsecutiveMisses = 5

    private(set) var currentTopology: MapTopology?
    private(set) var consecutiveMisses = 0

    mutating func update(candidate: MapTopology?) -> MapTopology? {
        guard let candidate else {
            guard currentTopology != nil else {
                consecutiveMisses = 0
                return nil
            }
            consecutiveMisses += 1
            if consecutiveMisses >= Self.requiredConsecutiveMisses {
                currentTopology = nil
                consecutiveMisses = 0
            }
            return currentTopology
        }

        currentTopology = candidate
        consecutiveMisses = 0
        return candidate
    }

    mutating func reset() {
        currentTopology = nil
        consecutiveMisses = 0
    }
}

enum ModeRequirements {
    static func requiresAccessibility(_ mode: AppMode) -> Bool {
        mode != .monitor
    }

    static func requiresScreenRecording(_ mode: AppMode) -> Bool {
        mode == .deadFlower || mode == .temple || mode == .followHeal || mode == .monitor
    }
}

enum MonitorFrameScheduler {
    static let targetFramesPerSecond = 30.0
    static let targetFrameInterval = 1.0 / targetFramesPerSecond
    static let windowValidationInterval = 30
    static let mapMatchInterval = 6
    /// 整窗识别任务每 500ms 抓一帧；符文识别每两帧做一次，即约每秒一次。
    static let windowFrameInterval = Duration.milliseconds(500)
    static let verificationRecordingFrameInterval = Duration.milliseconds(100)
    static let runeAlertFrameInterval = 2

    static func shouldValidateWindow(frameIndex: Int) -> Bool {
        frameIndex == 0 || frameIndex.isMultiple(of: windowValidationInterval)
    }

    static func shouldRefreshMapMatch(frameIndex: Int) -> Bool {
        frameIndex == 0 || frameIndex.isMultiple(of: mapMatchInterval)
    }

    static func shouldDetectRuneAlert(windowFrameIndex: Int) -> Bool {
        windowFrameIndex.isMultiple(of: runeAlertFrameInterval)
    }

    /// 鼠标跟随验证会很快变暗，整窗任务的每一帧都要识别，最坏延迟约 500ms。
    static func shouldDetectMouseFollowVerification(windowFrameIndex _: Int) -> Bool {
        true
    }

    static func seconds(in duration: Duration) -> Double {
        Double(duration.components.seconds)
            + Double(duration.components.attoseconds) / 1_000_000_000_000_000_000
    }
}

enum MonitorWindowGeometry {
    static func changed(from previous: CGSize, to current: CGSize, tolerance: CGFloat = 2) -> Bool {
        guard previous.width > 0, previous.height > 0,
              current.width > 0, current.height > 0 else { return false }
        return abs(previous.width - current.width) > tolerance
            || abs(previous.height - current.height) > tolerance
    }
}

@available(macOS 14.0, *)
@MainActor
final class MonitoringSession {
    var onFrame: ((MonitoringFrame) -> Void)?
    var onStatus: ((String) -> Void)?
    var onEXPReading: ((EXPRecognitionResult?) -> Void)?
    var onEXPStatus: ((String) -> Void)?
    /// 符文提示状态。`isPresent` 已经过防抖，`detection` 仅在出现时携带。
    var onRuneAlert: ((_ isPresent: Bool, _ detection: RuneAlertDetection?) -> Void)?
    /// 「寻找透明图形」鼠标跟随验证弹窗状态。
    var onMouseFollowVerification: ((
        _ isPresent: Bool,
        _ detection: MouseFollowVerificationDetection?
    ) -> Void)?
    var onVerificationRecordingEvent: ((String) -> Void)?
    var onStopped: ((String) -> Void)?

    private let minimap = MinimapMonitor()
    private let windowSelector = WindowSelector()
    private let expCaptureService = GameCaptureService()
    private let verificationRecorder = VerificationRegionRecorder()
    private var task: Task<Void, Never>?
    private var expTask: Task<Void, Never>?
    private var activeStream: GameRegionCaptureStream?
    private var runID = UUID()
    private var lastStatus: String?

    func start(windowID: CGWindowID, maps: [MapTopology]) {
        stop()
        let currentRunID = UUID()
        runID = currentRunID
        minimap.setWindow(windowID)
        lastStatus = nil
        publishStatus("正在识别小地图...")
        task = Task { [weak self] in
            await self?.run(windowID: windowID, maps: maps, runID: currentRunID)
        }
        onEXPReading?(nil)
        onEXPStatus?("正在识别 EXP...")
        onRuneAlert?(false, nil)
        onMouseFollowVerification?(false, nil)
        expTask = Task { [weak self] in
            await self?.runWindowRecognition(windowID: windowID, runID: currentRunID)
        }
    }

    func stop() {
        runID = UUID()
        task?.cancel()
        task = nil
        expTask?.cancel()
        expTask = nil
        expCaptureService.clearCaptureCache()
        finishVerificationRecording()
        let stream = activeStream
        activeStream = nil
        if let stream {
            Task {
                await stream.stop()
            }
        }
        minimap.clearMinimapRegion()
    }

    /// 平时每 500ms 抓一帧完整游戏窗口；验证录像期间提高到 10 FPS，但 EXP 与符文
    /// 仍保持原识别频率。所有任务共用同一帧，不额外截图。
    private func runWindowRecognition(windowID: CGWindowID, runID currentRunID: UUID) async {
        // 两帧一致即可发布：在 500ms 固定周期下，数值变化约 0.5～1 秒可见。
        var stabilizer = EXPRecognitionStabilizer(requiredMatches: 2, toleratedMisses: 3)
        var runeStabilizer = RuneAlertStabilizer()
        var verificationStabilizer = MouseFollowVerificationStabilizer()
        var consecutiveCaptureFailures = 0
        var windowFrameIndex = 0
        let expRecognizer = EXPProductionRecognizer()

        while currentRunID == runID && !Task.isCancelled {
            let cycleStartedAt = ContinuousClock.now
            do {
                let captured = try await expCaptureService.captureBGR(windowID: windowID)
                let recordingStride = verificationRecorder.isRecording ? 5 : 1
                let shouldRecognizeEXP = windowFrameIndex.isMultiple(of: recordingStride)
                let shouldDetectRune = verificationRecorder.isRecording
                    ? windowFrameIndex.isMultiple(of: 10)
                    : MonitorFrameScheduler.shouldDetectRuneAlert(
                        windowFrameIndex: windowFrameIndex
                    )
                let shouldDetectVerification = MonitorFrameScheduler
                    .shouldDetectMouseFollowVerification(windowFrameIndex: windowFrameIndex)
                let analysis = await Task.detached(priority: .utility) {
                    (
                        shouldDetectVerification
                            ? MouseFollowVerificationDetector.detect(in: captured.buffer)
                            : nil,
                        shouldRecognizeEXP
                            ? expRecognizer.recognize(in: captured.buffer)
                            : nil,
                        shouldDetectRune
                            ? RuneAlertDetector.detect(in: captured.buffer)
                            : nil
                    )
                }.value
                consecutiveCaptureFailures = 0
                windowFrameIndex &+= 1

                if shouldDetectVerification {
                    publishMouseFollowVerification(
                        &verificationStabilizer,
                        detection: analysis.0
                    )
                    updateVerificationRecording(
                        frame: captured.buffer,
                        stabilizer: verificationStabilizer
                    )
                }
                if shouldDetectRune {
                    publishRuneAlert(&runeStabilizer, detection: analysis.2)
                }

                if shouldRecognizeEXP {
                    let stable = stabilizer.update(analysis.1)
                    onEXPReading?(stable)
                    if let stable {
                        onEXPStatus?(
                            "\(stable.recognitionMethod.displayName) · 置信度 "
                                + "\(Int((stable.confidence * 100).rounded()))%"
                        )
                    } else if analysis.1 != nil {
                        onEXPStatus?("正在确认 EXP 数值...")
                    } else {
                        onEXPStatus?("未识别到 EXP")
                    }
                }
            } catch {
                consecutiveCaptureFailures += 1
                let stable = stabilizer.update(nil)
                onEXPReading?(stable)
                // 读不到画面时不能继续声称符文提示还在，否则服务器会一直推送。
                publishRuneAlert(&runeStabilizer, detection: nil)
                publishMouseFollowVerification(&verificationStabilizer, detection: nil)
                if !verificationStabilizer.isPresent {
                    finishVerificationRecording()
                }
                if consecutiveCaptureFailures == 1 || consecutiveCaptureFailures.isMultiple(of: 5) {
                    onEXPStatus?("EXP 画面读取失败")
                }
                expCaptureService.clearCaptureCache()
            }
            let elapsed = cycleStartedAt.duration(to: .now)
            let targetInterval = verificationRecorder.isRecording
                ? MonitorFrameScheduler.verificationRecordingFrameInterval
                : MonitorFrameScheduler.windowFrameInterval
            let remaining = targetInterval - elapsed
            if remaining > .zero {
                try? await Task.sleep(for: remaining)
            }
        }
    }

    /// 无论状态是否变化都向外发布，让远端保持新鲜的心跳；
    /// 是否节流由 `RemoteMonitorClient` 决定。
    private func publishRuneAlert(
        _ stabilizer: inout RuneAlertStabilizer,
        detection: RuneAlertDetection?
    ) {
        stabilizer.update(detection)
        onRuneAlert?(stabilizer.isPresent, stabilizer.latestDetection)
    }

    /// 与符文状态一样持续发新鲜心跳；客户端上报层负责 3 秒节流。
    private func publishMouseFollowVerification(
        _ stabilizer: inout MouseFollowVerificationStabilizer,
        detection: MouseFollowVerificationDetection?
    ) {
        stabilizer.update(detection)
        onMouseFollowVerification?(stabilizer.isPresent, stabilizer.latestDetection)
    }

    private func updateVerificationRecording(
        frame: ImageBuffer,
        stabilizer: MouseFollowVerificationStabilizer
    ) {
        do {
            if stabilizer.isPresent, let detection = stabilizer.latestDetection {
                if verificationRecorder.isRecording {
                    try verificationRecorder.append(frame: frame, bodyRect: detection.bodyRect)
                } else {
                    let url = try verificationRecorder.start(
                        frame: frame,
                        bodyRect: detection.bodyRect
                    )
                    onVerificationRecordingEvent?("已开始录制验证区域：\(url.lastPathComponent)")
                }
            } else {
                finishVerificationRecording()
            }
        } catch {
            verificationRecorder.stop()
            onVerificationRecordingEvent?("验证区域录制失败：\(error.localizedDescription)")
        }
    }

    private func finishVerificationRecording() {
        guard let url = verificationRecorder.stop() else { return }
        onVerificationRecordingEvent?("验证区域录像已保存：\(url.path)")
    }

    private func run(windowID: CGWindowID, maps: [MapTopology], runID currentRunID: UUID) async {
        var hasMinimapRegion = false
        var consecutiveFailures = 0
        var frameIndex = 0
        var mapMatchStabilizer = MonitorMapMatchStabilizer()
        var framesSinceRateSample = 0
        var rateSampleStart = ContinuousClock.now
        var measuredFPS = 0.0
        var observedWindowSize = windowSelector.getWindowInfo(windowID: windowID)?.size ?? .zero

        monitoringLoop: while currentRunID == runID && !Task.isCancelled {
            guard !MonitorFrameScheduler.shouldValidateWindow(frameIndex: frameIndex)
                    || windowSelector.isWindowValid(windowID: windowID) else {
                finish(runID: currentRunID, reason: "游戏窗口已失效，请重新识别")
                return
            }

            if !hasMinimapRegion {
                do {
                    guard let region = try await minimap.autoDetectDarkRegion() else {
                        publishStatus("未识别到小地图：\(minimap.lastDetectionSummary)")
                        await pause(seconds: 1)
                        continue
                    }
                    hasMinimapRegion = true
                    consecutiveFailures = 0
                    frameIndex = 0
                    framesSinceRateSample = 0
                    rateSampleStart = .now
                    publishStatus("已识别小地图 \(Int(region.width))×\(Int(region.height))")
                } catch {
                    consecutiveFailures += 1
                    publishStatus("小地图识别失败：\(error.localizedDescription)")
                    if consecutiveFailures >= 5 {
                        finish(runID: currentRunID, reason: "连续无法读取游戏画面，请检查屏幕录制权限")
                        return
                    }
                    await pause(seconds: 1)
                    continue
                }
            }

            do {
                let stream = try await minimap.startMinimapStream(
                    targetFramesPerSecond: MonitorFrameScheduler.targetFramesPerSecond
                )
                activeStream = stream

                for try await frame in stream.frames {
                    guard currentRunID == runID, !Task.isCancelled else {
                        break
                    }
                    guard !MonitorFrameScheduler.shouldValidateWindow(frameIndex: frameIndex)
                            || windowSelector.isWindowValid(windowID: windowID) else {
                        await stream.stop()
                        if activeStream === stream {
                            activeStream = nil
                        }
                        finish(runID: currentRunID, reason: "游戏窗口已失效，请重新识别")
                        return
                    }
                    if MonitorFrameScheduler.shouldValidateWindow(frameIndex: frameIndex),
                       let currentWindow = windowSelector.getWindowInfo(windowID: windowID) {
                        if observedWindowSize.width <= 0 || observedWindowSize.height <= 0 {
                            observedWindowSize = currentWindow.size
                        } else if MonitorWindowGeometry.changed(
                            from: observedWindowSize,
                            to: currentWindow.size
                        ) {
                            observedWindowSize = currentWindow.size
                            await stream.stop()
                            if activeStream === stream {
                                activeStream = nil
                            }
                            hasMinimapRegion = false
                            frameIndex = 0
                            mapMatchStabilizer.reset()
                            minimap.clearMinimapRegion()
                            publishStatus("检测到游戏窗口尺寸变化，正在重新识别小地图...")
                            continue monitoringLoop
                        }
                    }

                    let shouldRefreshMapMatch = MonitorFrameScheduler.shouldRefreshMapMatch(
                        frameIndex: frameIndex
                    )
                    let analysis = await Task.detached(priority: .userInitiated) {
                        (
                            ColorDetector.detectPlayerMarker(in: frame).point,
                            ColorDetector.detectTeammateMarkers(in: frame).points,
                            ColorDetector.detectOtherPlayerMarkers(in: frame).points,
                            shouldRefreshMapMatch
                                ? MonitorMapMatcher.match(frame: frame, maps: maps)
                                : nil
                        )
                    }.value

                    let matchedTopology = shouldRefreshMapMatch
                        ? mapMatchStabilizer.update(candidate: analysis.3)
                        : mapMatchStabilizer.currentTopology

                    consecutiveFailures = 0
                    frameIndex += 1
                    framesSinceRateSample += 1
                    let elapsed = rateSampleStart.duration(to: .now)
                    if elapsed >= .seconds(1) {
                        let seconds = MonitorFrameScheduler.seconds(in: elapsed)
                        if seconds > 0 {
                            measuredFPS = Double(framesSinceRateSample) / seconds
                        }
                        framesSinceRateSample = 0
                        rateSampleStart = .now
                    }

                    onFrame?(
                        MonitoringFrame(
                            buffer: frame,
                            playerPoint: analysis.0,
                            teammatePoints: analysis.1,
                            otherPlayerPoints: analysis.2,
                            matchedTopology: matchedTopology,
                            framesPerSecond: measuredFPS
                        )
                    )
                    if maps.isEmpty {
                        publishStatus("尚未创建地图标注")
                    } else if let matchedTopology {
                        publishStatus("已匹配：\(matchedTopology.mapName)")
                    } else {
                        publishStatus("未匹配到已标注地图")
                    }
                }

                await stream.stop()
                if activeStream === stream {
                    activeStream = nil
                }
                if currentRunID != runID || Task.isCancelled {
                    return
                }
                throw GameCaptureError.captureFailed
            } catch {
                if let stream = activeStream {
                    await stream.stop()
                    if activeStream === stream {
                        activeStream = nil
                    }
                }
                consecutiveFailures += 1
                hasMinimapRegion = false
                mapMatchStabilizer.reset()
                minimap.clearMinimapRegion()
                publishStatus("实时小地图读取失败，正在重新识别：\(error.localizedDescription)")
                if consecutiveFailures >= 5 {
                    finish(runID: currentRunID, reason: "连续无法读取实时小地图，请检查游戏窗口和屏幕录制权限")
                    return
                }
                await pause(seconds: 1)
            }
        }
    }

    private func finish(runID currentRunID: UUID, reason: String) {
        guard currentRunID == runID else { return }
        task = nil
        expTask?.cancel()
        expTask = nil
        expCaptureService.clearCaptureCache()
        finishVerificationRecording()
        let stream = activeStream
        activeStream = nil
        if let stream {
            Task {
                await stream.stop()
            }
        }
        minimap.clearMinimapRegion()
        // 会话自行结束时也要撤销符文状态，否则服务器会按最后一次上报继续推送。
        onRuneAlert?(false, nil)
        onMouseFollowVerification?(false, nil)
        onStopped?(reason)
    }

    private func publishStatus(_ status: String) {
        guard status != lastStatus else { return }
        lastStatus = status
        onStatus?(status)
    }

    private func pause(seconds: Double) async {
        try? await Task.sleep(for: .seconds(seconds))
    }
}
