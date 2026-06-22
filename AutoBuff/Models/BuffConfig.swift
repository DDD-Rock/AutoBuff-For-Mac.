import Foundation

struct BuffConfig: Codable, Identifiable, Equatable {
    var id: Int
    var enabled: Bool
    var key: String
    var duration: Double
    
    init(id: Int, enabled: Bool = false, key: String = "", duration: Double = 0) {
        self.id = id
        self.enabled = enabled
        self.key = key
        self.duration = duration
    }
}
