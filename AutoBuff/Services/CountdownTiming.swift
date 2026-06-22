import Foundation

enum CountdownTiming {
    static func nextRelease(
        pressedAt: TimeInterval,
        interval: TimeInterval,
        earlyBy: TimeInterval = 0
    ) -> TimeInterval {
        pressedAt + max(0, interval - earlyBy)
    }
    
    static func remainingSeconds(until nextRelease: TimeInterval, now: TimeInterval) -> Int {
        Int(ceil(max(0, nextRelease - now)))
    }
    
    static func clockText(for timestamp: TimeInterval) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: Date(timeIntervalSince1970: timestamp))
    }
}
