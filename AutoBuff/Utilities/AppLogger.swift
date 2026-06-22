import Foundation

@MainActor
final class AppLogger: ObservableObject {
    @Published private(set) var entries: [String] = []
    private let maxEntries = 1000
    
    func log(_ message: String) {
        let timestamp = Self.timeFormatter.string(from: Date())
        entries.append("[\(timestamp)] \(message)")
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
    }
    
    func clear() {
        entries.removeAll()
    }
    
    var text: String {
        entries.joined(separator: "\n")
    }
    
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
