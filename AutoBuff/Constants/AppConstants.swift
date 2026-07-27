import Foundation

enum AppConstants {
    static let appName = "AutoBuff"
    static let appVersion = "2.0.1"

    static let defaultInterval: Double = 5.0
    static let defaultRandomDelay: Double = 2.0
    static let minInterval: Double = 0.1
    static let maxInterval: Double = 3600.0
    static let threadSleepInterval: Double = 0.1
    static let cyclePauseTime: Double = 0.5
    static let initialWaitTime: Double = 0

    static let gameWindowTitlePrefix = "MapleStory Worlds-Artale"
    static let settingsDirectoryName = "AutoBuff"
    static let settingsFileName = "settings.json"
    static let mapsFileName = "maps.json"
    static let persistenceBackupCount = 5

    static let defaultBuffSlotCount = 3
    static let maxBuffSlotCount = 8
    static let keyHoldMinMS = 50
    static let keyHoldMaxMS = 150
    static let skillGapMinMS = 2000
    static let skillGapMaxMS = 3000
}
