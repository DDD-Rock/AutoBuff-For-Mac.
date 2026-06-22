import Foundation

struct GameConfig: Codable, Equatable {
    var resolutionWidth: Int = 0
    var resolutionHeight: Int = 0
    var randomBehaviorEnabled: Bool = true
    var randomBehaviorValue: Int = 20
}
