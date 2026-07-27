import AppKit
import CoreGraphics
import Foundation

struct EXPDataCollectionSnapshot: Equatable {
    var isRunning = false
    var savedRows = 0
    var savedGlyphs = 0
    var reviewItems = 0
    var lastRecognition: String?
    var status = "未启动"
}

@available(macOS 14.0, *)
@MainActor
final class EXPDataCollectionSession {
    var onSnapshot: ((EXPDataCollectionSnapshot) -> Void)?
    var onLog: ((String) -> Void)?

    private let captureService = GameCaptureService()
    private let store: EXPDatasetStore
    private var stabilizer = EXPReadingStabilizer()
    private var task: Task<Void, Never>?
    private var snapshot = EXPDataCollectionSnapshot()
    private var lastReviewDate = Date.distantPast
    private var runID = UUID()

    var isRunning: Bool { task != nil }
    var directoryURL: URL { store.rootURL }

    init(store: EXPDatasetStore = EXPDatasetStore()) {
        self.store = store
    }

    func start(windowID: CGWindowID) {
        stop()
        let currentRunID = UUID()
        runID = currentRunID
        stabilizer.reset()
        snapshot.isRunning = true
        snapshot.status = "正在寻找 EXP..."
        publish()
        onLog?("EXP 样本采集已启动：\(directoryURL.path)")
        task = Task { [weak self] in
            await self?.collect(windowID: windowID, runID: currentRunID)
        }
    }

    func stop() {
        runID = UUID()
        task?.cancel()
        task = nil
        captureService.clearCaptureCache()
        stabilizer.reset()
        if snapshot.isRunning {
            snapshot.isRunning = false
            snapshot.status = "采集已停止"
            publish()
        }
    }

    func revealDatasetDirectory() {
        try? FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        NSWorkspace.shared.activateFileViewerSelecting([directoryURL])
    }

    private func collect(windowID: CGWindowID, runID currentRunID: UUID) async {
        var consecutiveCaptureFailures = 0

        while currentRunID == runID && !Task.isCancelled {
            do {
                let captured = try await captureService.captureBGR(windowID: windowID)
                guard let searchRegion = EXPFrameRegionExtractor.extract(
                    from: captured.buffer
                ) else {
                    snapshot.status = "无法裁剪 EXP 搜索区域"
                    publish()
                    await pause()
                    continue
                }

                let attempt = await Task.detached(priority: .utility) {
                    EXPVisionRecognizer.recognize(in: searchRegion)
                }.value
                consecutiveCaptureFailures = 0
                process(attempt, searchRegion: searchRegion)
            } catch {
                consecutiveCaptureFailures += 1
                stabilizer.reset()
                snapshot.status = "截图失败（\(consecutiveCaptureFailures)）"
                publish()
                if consecutiveCaptureFailures == 1
                    || consecutiveCaptureFailures.isMultiple(of: 5) {
                    onLog?("EXP 采集截图失败：\(error.localizedDescription)")
                }
            }
            await pause()
        }

        guard currentRunID == runID else { return }
        task = nil
        snapshot.isRunning = false
        snapshot.status = "采集已停止"
        publish()
    }

    private func process(
        _ attempt: EXPRecognitionAttempt,
        searchRegion: ImageBuffer
    ) {
        guard let reading = attempt.reading else {
            stabilizer.reset()
            if let suspectedText = attempt.suspectedText {
                snapshot.lastRecognition = suspectedText
                snapshot.status = "发现疑似 EXP，等待有效格式"
                saveReviewIfNeeded(
                    searchRegion,
                    text: suspectedText,
                    confidence: attempt.suspectedConfidence
                )
            } else {
                snapshot.status = "正在寻找 EXP..."
            }
            publish()
            return
        }

        snapshot.lastRecognition = reading.displayText
        let isStable = stabilizer.update(reading)
        guard isStable else {
            snapshot.status = "候选 \(reading.displayText)，等待多帧确认"
            publish()
            return
        }

        let highConfidence = reading.confidence >= 0.48
            || (
                reading.preprocessingAgreement
                    && reading.confidence >= 0.25
            )
        guard highConfidence else {
            snapshot.status = "低置信度 \(reading.displayText)，已送待审核"
            saveReviewIfNeeded(
                searchRegion,
                text: reading.rawText,
                confidence: reading.confidence
            )
            publish()
            return
        }

        do {
            let result = try store.saveAutomatic(
                searchRegion: searchRegion,
                reading: reading
            )
            if result.wasDuplicate {
                snapshot.status = "已识别 \(reading.displayText)，样本重复"
            } else if result.rowURL != nil {
                snapshot.savedRows += 1
                snapshot.savedGlyphs += result.savedGlyphCount
                snapshot.status = "已归档 \(reading.displayText)"
                onLog?(
                    "EXP 自动归档：\(reading.displayText)，"
                        + "字符 \(result.savedGlyphCount) 个"
                )
            } else {
                snapshot.status = "已识别，但无法截取文字行"
            }
        } catch {
            snapshot.status = "保存失败：\(error.localizedDescription)"
            onLog?("EXP 样本保存失败：\(error.localizedDescription)")
        }
        publish()
    }

    private func saveReviewIfNeeded(
        _ searchRegion: ImageBuffer,
        text: String?,
        confidence: Float
    ) {
        guard Date().timeIntervalSince(lastReviewDate) >= 3 else { return }
        do {
            if try store.saveForReview(
                searchRegion: searchRegion,
                suspectedText: text,
                confidence: confidence
            ) {
                snapshot.reviewItems += 1
                lastReviewDate = Date()
            }
        } catch {
            onLog?("EXP 待审核样本保存失败：\(error.localizedDescription)")
        }
    }

    private func publish() {
        onSnapshot?(snapshot)
    }

    private func pause() async {
        try? await Task.sleep(for: .milliseconds(500))
    }
}
