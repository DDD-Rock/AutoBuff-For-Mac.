import CoreGraphics
import Foundation

enum AppMode: String, Codable, CaseIterable {
    case deadFlower = "dead"
    case liveFlower = "live"
    case temple
    case followHeal = "follow_heal"
    case monitor

    static let defaultAuthorized: Set<AppMode> = [.deadFlower, .liveFlower, .temple]

    var title: String {
        switch self {
        case .deadFlower: return "死花模式"
        case .liveFlower: return "活花模式"
        case .temple: return "神殿模式"
        case .followHeal: return "跟补模式"
        case .monitor: return "监控模式"
        }
    }
}

enum TempleFunction: String, Codable, CaseIterable {
    case lounge
    case ropeParty = "rope_party"
    case freeEntry = "free_entry"

    var title: String {
        switch self {
        case .lounge: return "休息室"
        case .ropeParty: return "挂绳组队"
        case .freeEntry: return "进出自由"
        }
    }
}

enum MonitorDisplayMode: String, Codable, CaseIterable {
    case minimapOnly = "minimap_only"
    case minimapWithAnnotations = "minimap_with_annotations"
    case annotationsOnly = "annotations_only"

    var title: String {
        switch self {
        case .minimapOnly: return "纯小地图"
        case .minimapWithAnnotations: return "小地图 + 标注"
        case .annotationsOnly: return "纯标注"
        }
    }
}

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
        case .rightOnly: return "只向右（骨龙、忘却）"
        }
    }
}

struct AppSettings: Codable, Equatable {
    static let currentSchemaVersion = 8

    var schemaVersion: Int = currentSchemaVersion
    var mode: AppMode = .deadFlower
    var returnToMarket: Bool = true
    var templeFunction: TempleFunction = .freeEntry
    var characterName: String = ""
    var loungeMoveMinMinutes: Int = 15
    var loungeMoveMaxMinutes: Int = 30
    var ropePartyTeamID: Int64? = nil
    var ropePartyIsLeader: Bool = false
    var ropePartyInviteRoleNames: [String] = []
    var jumpKey: String = "Alt"
    var healSkillKey: String = ""
    var teleportSkillKey: String = ""
    var healAnchorX: Int? = nil
    var healAnchorY: Int? = nil
    var followHealBoundaryTolerance: Double = 6
    var healMinimapRegionX: Int? = nil
    var healMinimapRegionY: Int? = nil
    var healMinimapRegionWidth: Int? = nil
    var healMinimapRegionHeight: Int? = nil
    var sitChairEnabled: Bool = false
    var chairKey: String = "="
    var randomBehaviorEnabled: Bool = true
    var randomBehaviorValue: Int = 20
    var autoAcceptPartyInviteEnabled: Bool = false
    var movementMode: MovementMode = .none
    var preSkillMoveMode: PreSkillMoveMode = .rightOnly
    var manualPortalX: Int? = nil
    var manualPortalY: Int? = nil
    var portalWidthThreshold: Double = 2.5
    var mapTopologies: [MapTopology] = []
    var monitorDisplayMode: MonitorDisplayMode = .minimapWithAnnotations
    var monitorServerBaseURL: String = "http://106.52.208.129:28671"
    var monitorAccountUsername: String = ""
    var monitorAccountNickname: String = ""
    var monitorSafeZone: MonitorSafeZone? = nil
    var buffs: [BuffConfig]

    static var `default`: AppSettings {
        var buffs = (1...AppConstants.defaultBuffSlotCount).map { BuffConfig(id: $0) }
        buffs[0] = BuffConfig(id: 1, enabled: true, key: "1", duration: 200)
        buffs[1] = BuffConfig(id: 2, enabled: true, key: "2", duration: 200)
        return AppSettings(buffs: buffs)
    }
}

extension AppSettings {
    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case mode
        case returnToMarket
        case templeFunction
        case characterName
        case loungeMoveMinMinutes
        case loungeMoveMaxMinutes
        case ropePartyTeamID
        case ropePartyIsLeader
        case ropePartyInviteRoleNames
        case jumpKey
        case healSkillKey
        case teleportSkillKey
        case healAnchorX
        case healAnchorY
        case followHealBoundaryTolerance
        case healMinimapRegionX
        case healMinimapRegionY
        case healMinimapRegionWidth
        case healMinimapRegionHeight
        case sitChairEnabled
        case chairKey
        case randomBehaviorEnabled
        case randomBehaviorValue
        case autoAcceptPartyInviteEnabled
        case movementMode
        case preSkillMoveMode
        case manualPortalX
        case manualPortalY
        case portalWidthThreshold
        case mapTopology
        case mapTopologies
        case monitorDisplayMode
        case monitorServerBaseURL
        case monitorAccountUsername
        case monitorAccountNickname
        case monitorSafeZone
        case buffs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        let returnToMarket = try container.decodeIfPresent(Bool.self, forKey: .returnToMarket) ?? true
        self.mode = try container.decodeIfPresent(AppMode.self, forKey: .mode)
            ?? (returnToMarket ? .deadFlower : .liveFlower)
        self.returnToMarket = returnToMarket
        self.templeFunction = try container.decodeIfPresent(
            TempleFunction.self,
            forKey: .templeFunction
        ) ?? .freeEntry
        self.characterName = try container.decodeIfPresent(String.self, forKey: .characterName) ?? ""
        self.loungeMoveMinMinutes = try container.decodeIfPresent(
            Int.self,
            forKey: .loungeMoveMinMinutes
        ) ?? 15
        self.loungeMoveMaxMinutes = try container.decodeIfPresent(
            Int.self,
            forKey: .loungeMoveMaxMinutes
        ) ?? 30
        self.ropePartyTeamID = try container.decodeIfPresent(Int64.self, forKey: .ropePartyTeamID)
        self.ropePartyIsLeader = try container.decodeIfPresent(Bool.self, forKey: .ropePartyIsLeader) ?? false
        self.ropePartyInviteRoleNames = try container.decodeIfPresent(
            [String].self,
            forKey: .ropePartyInviteRoleNames
        ) ?? []
        self.jumpKey = try container.decodeIfPresent(String.self, forKey: .jumpKey) ?? "Alt"
        self.healSkillKey = try container.decodeIfPresent(String.self, forKey: .healSkillKey) ?? ""
        self.teleportSkillKey = try container.decodeIfPresent(String.self, forKey: .teleportSkillKey) ?? ""
        self.healAnchorX = try container.decodeIfPresent(Int.self, forKey: .healAnchorX)
        self.healAnchorY = try container.decodeIfPresent(Int.self, forKey: .healAnchorY)
        self.followHealBoundaryTolerance = try container.decodeIfPresent(
            Double.self,
            forKey: .followHealBoundaryTolerance
        ) ?? 6
        self.healMinimapRegionX = try container.decodeIfPresent(Int.self, forKey: .healMinimapRegionX)
        self.healMinimapRegionY = try container.decodeIfPresent(Int.self, forKey: .healMinimapRegionY)
        self.healMinimapRegionWidth = try container.decodeIfPresent(Int.self, forKey: .healMinimapRegionWidth)
        self.healMinimapRegionHeight = try container.decodeIfPresent(Int.self, forKey: .healMinimapRegionHeight)
        self.sitChairEnabled = try container.decodeIfPresent(Bool.self, forKey: .sitChairEnabled) ?? false
        self.chairKey = try container.decodeIfPresent(String.self, forKey: .chairKey) ?? "="
        self.randomBehaviorEnabled = try container.decodeIfPresent(Bool.self, forKey: .randomBehaviorEnabled) ?? true
        self.randomBehaviorValue = try container.decodeIfPresent(Int.self, forKey: .randomBehaviorValue) ?? 20
        self.autoAcceptPartyInviteEnabled = try container.decodeIfPresent(Bool.self, forKey: .autoAcceptPartyInviteEnabled) ?? false
        self.movementMode = try container.decodeIfPresent(MovementMode.self, forKey: .movementMode) ?? .none
        self.preSkillMoveMode = try container.decodeIfPresent(PreSkillMoveMode.self, forKey: .preSkillMoveMode) ?? .rightOnly
        self.manualPortalX = try container.decodeIfPresent(Int.self, forKey: .manualPortalX)
        self.manualPortalY = try container.decodeIfPresent(Int.self, forKey: .manualPortalY)
        self.portalWidthThreshold = try container.decodeIfPresent(
            Double.self,
            forKey: .portalWidthThreshold
        ) ?? 2.5
        self.mapTopologies = try container.decodeIfPresent([MapTopology].self, forKey: .mapTopologies)
            ?? container.decodeIfPresent(MapTopology.self, forKey: .mapTopology).map { [$0] }
            ?? []
        self.monitorDisplayMode = try container.decodeIfPresent(
            MonitorDisplayMode.self,
            forKey: .monitorDisplayMode
        ) ?? .minimapWithAnnotations
        self.monitorServerBaseURL = try container.decodeIfPresent(
            String.self,
            forKey: .monitorServerBaseURL
        ) ?? "http://106.52.208.129:28671"
        self.monitorAccountUsername = try container.decodeIfPresent(
            String.self,
            forKey: .monitorAccountUsername
        ) ?? ""
        self.monitorAccountNickname = try container.decodeIfPresent(
            String.self,
            forKey: .monitorAccountNickname
        ) ?? ""
        self.monitorSafeZone = try container.decodeIfPresent(
            MonitorSafeZone.self,
            forKey: .monitorSafeZone
        )
        self.buffs = try container.decodeIfPresent([BuffConfig].self, forKey: .buffs) ?? AppSettings.default.buffs
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(mode, forKey: .mode)
        try container.encode(returnToMarket, forKey: .returnToMarket)
        try container.encode(templeFunction, forKey: .templeFunction)
        try container.encode(characterName, forKey: .characterName)
        try container.encode(loungeMoveMinMinutes, forKey: .loungeMoveMinMinutes)
        try container.encode(loungeMoveMaxMinutes, forKey: .loungeMoveMaxMinutes)
        try container.encodeIfPresent(ropePartyTeamID, forKey: .ropePartyTeamID)
        try container.encode(ropePartyIsLeader, forKey: .ropePartyIsLeader)
        try container.encode(ropePartyInviteRoleNames, forKey: .ropePartyInviteRoleNames)
        try container.encode(jumpKey, forKey: .jumpKey)
        try container.encode(healSkillKey, forKey: .healSkillKey)
        try container.encode(teleportSkillKey, forKey: .teleportSkillKey)
        try container.encodeIfPresent(healAnchorX, forKey: .healAnchorX)
        try container.encodeIfPresent(healAnchorY, forKey: .healAnchorY)
        try container.encode(followHealBoundaryTolerance, forKey: .followHealBoundaryTolerance)
        try container.encodeIfPresent(healMinimapRegionX, forKey: .healMinimapRegionX)
        try container.encodeIfPresent(healMinimapRegionY, forKey: .healMinimapRegionY)
        try container.encodeIfPresent(healMinimapRegionWidth, forKey: .healMinimapRegionWidth)
        try container.encodeIfPresent(healMinimapRegionHeight, forKey: .healMinimapRegionHeight)
        try container.encode(sitChairEnabled, forKey: .sitChairEnabled)
        try container.encode(chairKey, forKey: .chairKey)
        try container.encode(randomBehaviorEnabled, forKey: .randomBehaviorEnabled)
        try container.encode(randomBehaviorValue, forKey: .randomBehaviorValue)
        try container.encode(autoAcceptPartyInviteEnabled, forKey: .autoAcceptPartyInviteEnabled)
        try container.encode(movementMode, forKey: .movementMode)
        try container.encode(preSkillMoveMode, forKey: .preSkillMoveMode)
        try container.encodeIfPresent(manualPortalX, forKey: .manualPortalX)
        try container.encodeIfPresent(manualPortalY, forKey: .manualPortalY)
        try container.encode(portalWidthThreshold, forKey: .portalWidthThreshold)
        try container.encode(mapTopologies, forKey: .mapTopologies)
        try container.encode(monitorDisplayMode, forKey: .monitorDisplayMode)
        try container.encode(monitorServerBaseURL, forKey: .monitorServerBaseURL)
        try container.encode(monitorAccountUsername, forKey: .monitorAccountUsername)
        try container.encode(monitorAccountNickname, forKey: .monitorAccountNickname)
        try container.encodeIfPresent(monitorSafeZone, forKey: .monitorSafeZone)
        try container.encode(buffs, forKey: .buffs)
    }
}

extension AppSettings {
    var loungeMoveIntervalMinutes: ClosedRange<Int> {
        let minimum = max(1, min(loungeMoveMinMinutes, loungeMoveMaxMinutes))
        let maximum = min(24 * 60, max(loungeMoveMinMinutes, loungeMoveMaxMinutes))
        return minimum...max(minimum, maximum)
    }

    var healMinimapRegion: CGRect? {
        get {
            guard let x = healMinimapRegionX,
                  let y = healMinimapRegionY,
                  let width = healMinimapRegionWidth,
                  let height = healMinimapRegionHeight,
                  width > 0,
                  height > 0 else {
                return nil
            }
            return CGRect(x: x, y: y, width: width, height: height)
        }
        set {
            guard let newValue else {
                healMinimapRegionX = nil
                healMinimapRegionY = nil
                healMinimapRegionWidth = nil
                healMinimapRegionHeight = nil
                return
            }
            healMinimapRegionX = Int(newValue.minX.rounded())
            healMinimapRegionY = Int(newValue.minY.rounded())
            healMinimapRegionWidth = Int(newValue.width.rounded())
            healMinimapRegionHeight = Int(newValue.height.rounded())
        }
    }
}
