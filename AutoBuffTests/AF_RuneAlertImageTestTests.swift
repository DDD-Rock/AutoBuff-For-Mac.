import CoreGraphics
import Foundation
import Testing
@testable import AutoBuff

struct RuneAlertImageTestTests {
    // MARK: - 真实截图回放

    @Test func replaysCollectedScreenshotsThroughTheRunner() throws {
        let urls = try fixtureURLs()
        #expect(urls.count == 9)

        let report = RuneAlertImageTestRunner.run(urls: urls)

        #expect(report.items.count == 9)
        #expect(report.detectedItems.count == 9, "\(report.summary)")
        #expect(report.unreadableItems.isEmpty)
        #expect(report.missedItems.isEmpty)
        #expect(report.summary.contains("9 张全部识别到符文"))
    }

    @Test func picksTheStrongestDetectionToDriveASinglePush() throws {
        let urls = try fixtureURLs()
        let report = RuneAlertImageTestRunner.run(urls: urls)

        let strongest = try #require(report.strongest?.detection)
        let highest = try #require(
            report.detectedItems.compactMap { $0.detection?.confidence }.max()
        )
        // 一批图只推一次，选的必须是置信度最高的那张。
        #expect(strongest.confidence == highest)
    }

    @Test func reportsUnreadableFilesInsteadOfTreatingThemAsMisses() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("RuneAlertImageTest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // 后缀像图片但内容不是，必须归入「无法读取」而不是「没识别到」。
        let broken = directory.appendingPathComponent("broken.png")
        try Data("not an image".utf8).write(to: broken)

        let report = RuneAlertImageTestRunner.run(urls: [broken])

        #expect(report.unreadableItems.count == 1)
        #expect(report.missedItems.isEmpty)
        #expect(report.strongest == nil)
        #expect(report.summary.contains("无法读取：broken.png"))
    }

    // MARK: - 汇总文案

    @Test func summarizesAnAllDetectedBatchWithAConfidenceRange() {
        let report = RuneAlertImageTestReport(items: [
            detected("a.png", confidence: 0.62),
            detected("b.png", confidence: 0.881)
        ])

        #expect(report.summary == "2 张全部识别到符文，置信度 62%–88%")
    }

    @Test func collapsesTheConfidenceRangeWhenAllSamplesMatch() {
        let report = RuneAlertImageTestReport(items: [
            detected("a.png", confidence: 0.7),
            detected("b.png", confidence: 0.7)
        ])

        #expect(report.summary == "2 张全部识别到符文，置信度 70%")
    }

    @Test func namesTheMissedFilesSoTheyCanBeInspected() {
        let report = RuneAlertImageTestReport(items: [
            detected("hit.png", confidence: 0.8),
            missed("miss.png")
        ])

        #expect(report.summary.contains("2 张中 1 张识别到符文"))
        #expect(report.summary.contains("未识别：miss.png"))
    }

    @Test func collapsesLongFileNameListsIntoACount() {
        let report = RuneAlertImageTestReport(items: [
            missed("1.png"),
            missed("2.png"),
            missed("3.png"),
            missed("4.png")
        ])

        #expect(report.summary.contains("4 张均未识别到符文"))
        // 只列前 3 个文件名，避免一行文案被撑爆。
        #expect(report.summary.contains("未识别：1.png、2.png、3.png 等 4 张"))
    }

    @Test func reportsAnEmptySelectionExplicitly() {
        #expect(RuneAlertImageTestReport(items: []).summary == "没有选择图片")
    }

    // MARK: - 状态保持

    @Test func holdsInjectedStateLongerThanTheServerScheduleInterval() {
        // 服务端每 5 秒扫一轮，保持时长必须大于它，否则那一轮看不到注入的状态，
        // 推送永远不会触发。
        #expect(
            RuneAlertImageTestPolicy.stateHoldDuration
                > RuneAlertImageTestPolicy.serverScheduleInterval
        )
    }

    @Test func keepsTheHoldShorterThanTheServerFreshnessWindow() {
        // 服务端认为超过 12 秒未更新的上报已过期。保持时长短于它，
        // 测试结束后状态自然停止推送，不依赖客户端再发一条。
        #expect(RuneAlertImageTestPolicy.stateHoldDuration < .seconds(12))
    }

    // MARK: - 辅助

    private func fixtureURLs() throws -> [URL] {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/RuneAlert", isDirectory: true)
        return try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "png" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    private func detected(_ name: String, confidence: Double) -> RuneAlertImageTestItem {
        RuneAlertImageTestItem(
            fileName: name,
            detection: RuneAlertDetection(
                rect: CGRect(x: 0, y: 0, width: 100, height: 20),
                lineCoverage: 0.5,
                interiorTint: 0.4,
                confidence: confidence
            ),
            isUnreadable: false
        )
    }

    private func missed(_ name: String) -> RuneAlertImageTestItem {
        RuneAlertImageTestItem(fileName: name, detection: nil, isUnreadable: false)
    }
}
