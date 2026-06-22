import Foundation

enum MovementMode: String, Codable, CaseIterable {
    case none
    case right
    case left

    var label: String {
        switch self {
        case .none: return "原地不动"
        case .right: return "右走(回左)"
        case .left: return "左走(回右)"
        }
    }
}

enum PreSkillMoveMode: String, Codable, CaseIterable {
    case rightLeft = "right_left"
    case leftOnly = "left_only"
    case rightOnly = "right_only"

    var label: String {
        switch self {
        case .rightLeft: return "先右再左"
        case .leftOnly: return "只向左（鱼窝）"
        case .rightOnly: return "只向右（骨龙）"
        }
    }
}

struct AppSettings: Codable, Equatable {
    var returnToMarket: Bool = true
    var jumpKey: String = "Alt"
    var sitChairEnabled: Bool = false
    var chairKey: String = "="
    var randomBehaviorEnabled: Bool = true
    var randomBehaviorValue: Int = 20
    var movementMode: MovementMode = .none
    var preSkillMoveMode: PreSkillMoveMode = .rightOnly
    var manualPortalX: Int? = nil
    var manualPortalY: Int? = nil
    var buffs: [BuffConfig]

    static var `default`: AppSettings {
        var buffs = (1...AppConstants.defaultBuffSlotCount).map { BuffConfig(id: $0) }
        buffs[0] = BuffConfig(id: 1, enabled: true, key: "1", duration: 200)
        buffs[1] = BuffConfig(id: 2, enabled: true, key: "2", duration: 200)
        return AppSettings(buffs: buffs)
    }
}
