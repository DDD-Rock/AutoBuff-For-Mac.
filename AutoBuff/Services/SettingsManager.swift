import Foundation

struct PersistenceSaveResult: Equatable {
    var errors: [String] = []

    var succeeded: Bool { errors.isEmpty }
}

private struct MapLibraryDocument: Codable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var maps: [MapTopology]

    init(schemaVersion: Int = currentSchemaVersion, maps: [MapTopology]) {
        self.schemaVersion = schemaVersion
        self.maps = maps
    }
}

final class SettingsManager {
    private enum StorageKind {
        case settings
        case maps

        var title: String {
            switch self {
            case .settings: return "设置"
            case .maps: return "地图库"
            }
        }
    }

    private let fileManager: FileManager
    private let directoryURL: URL
    private let settingsURL: URL
    private let mapsURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private(set) var protectionWarnings: [String] = []
    private(set) var settingsWriteBlocked = false
    private(set) var mapsWriteBlocked = false

    init(fileManager: FileManager = .default, settingsDirectory: URL? = nil) {
        self.fileManager = fileManager
        if let settingsDirectory {
            directoryURL = settingsDirectory
        } else {
            let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            directoryURL = appSupport.appendingPathComponent(
                AppConstants.settingsDirectoryName,
                isDirectory: true
            )
        }
        try? fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        settingsURL = directoryURL.appendingPathComponent(AppConstants.settingsFileName)
        mapsURL = directoryURL.appendingPathComponent(AppConstants.mapsFileName)
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()
    }

    func load() -> AppSettings {
        protectionWarnings.removeAll()
        settingsWriteBlocked = false
        mapsWriteBlocked = false

        let settings = loadSettings()
        var normalized = normalize(settings)
        let embeddedMaps = normalized.mapTopologies

        switch loadMapLibrary() {
        case .loaded(let maps):
            normalized.mapTopologies = maps
        case .missing:
            normalized.mapTopologies = embeddedMaps
            if !embeddedMaps.isEmpty {
                let result = saveMaps(embeddedMaps)
                if result == nil {
                    protectionWarnings.append("已将旧 settings.json 中的地图迁移到独立 maps.json")
                } else if let result {
                    protectionWarnings.append(result)
                }
            }
        case .unavailable:
            normalized.mapTopologies = embeddedMaps
        }

        return normalized
    }

    @discardableResult
    func save(_ settings: AppSettings) -> PersistenceSaveResult {
        var result = PersistenceSaveResult()
        let normalized = normalize(settings)

        if let error = saveMaps(normalized.mapTopologies) {
            result.errors.append(error)
        }

        if settingsWriteBlocked {
            result.errors.append("设置文件处于写保护状态，未覆盖原 settings.json")
            return result
        }

        var settingsOnly = normalized
        settingsOnly.schemaVersion = AppSettings.currentSchemaVersion
        settingsOnly.mapTopologies = []
        do {
            let data = try encoder.encode(settingsOnly)
            try writeProtected(
                data,
                to: settingsURL,
                kind: .settings,
                supportedSchemaVersion: AppSettings.currentSchemaVersion,
                canDecodeExisting: { [decoder] data in
                    (try? decoder.decode(AppSettings.self, from: data)) != nil
                }
            )
        } catch {
            result.errors.append("设置保存失败：\(error.localizedDescription)")
        }
        return result
    }

    private func loadSettings() -> AppSettings {
        guard fileManager.fileExists(atPath: settingsURL.path) else {
            return .default
        }
        do {
            let data = try Data(contentsOf: settingsURL)
            let settings = try decodeSettings(data)
            guard settings.schemaVersion <= AppSettings.currentSchemaVersion else {
                settingsWriteBlocked = true
                protectionWarnings.append(
                    "settings.json 来自更高版本（\(settings.schemaVersion)），已进入写保护"
                )
                return .default
            }
            return settings
        } catch {
            return recoverSettings(after: error)
        }
    }

    private func recoverSettings(after originalError: Error) -> AppSettings {
        preserveCorruptCopy(of: settingsURL, kind: .settings)
        for backupURL in backupURLs(for: settingsURL) {
            guard let data = try? Data(contentsOf: backupURL),
                  let settings = try? decodeSettings(data),
                  settings.schemaVersion <= AppSettings.currentSchemaVersion else {
                continue
            }
            do {
                try data.write(to: settingsURL, options: .atomic)
                protectionWarnings.append(
                    "settings.json 无法解码，已保留损坏副本并从 \(backupURL.lastPathComponent) 恢复"
                )
                return settings
            } catch {
                break
            }
        }
        settingsWriteBlocked = true
        protectionWarnings.append(
            "settings.json 无法解码且没有可用备份，已禁止写入：\(originalError.localizedDescription)"
        )
        return .default
    }

    private enum MapLoadResult {
        case loaded([MapTopology])
        case missing
        case unavailable
    }

    private func loadMapLibrary() -> MapLoadResult {
        guard fileManager.fileExists(atPath: mapsURL.path) else {
            return .missing
        }
        do {
            let data = try Data(contentsOf: mapsURL)
            let document = try decodeMapLibrary(data)
            guard document.schemaVersion <= MapLibraryDocument.currentSchemaVersion else {
                mapsWriteBlocked = true
                protectionWarnings.append(
                    "maps.json 来自更高版本（\(document.schemaVersion)），已进入写保护"
                )
                return .unavailable
            }
            return .loaded(document.maps)
        } catch {
            return recoverMapLibrary(after: error)
        }
    }

    private func recoverMapLibrary(after originalError: Error) -> MapLoadResult {
        preserveCorruptCopy(of: mapsURL, kind: .maps)
        for backupURL in backupURLs(for: mapsURL) {
            guard let data = try? Data(contentsOf: backupURL),
                  let document = try? decodeMapLibrary(data),
                  document.schemaVersion <= MapLibraryDocument.currentSchemaVersion else {
                continue
            }
            do {
                try data.write(to: mapsURL, options: .atomic)
                protectionWarnings.append(
                    "maps.json 无法解码，已保留损坏副本并从 \(backupURL.lastPathComponent) 恢复"
                )
                return .loaded(document.maps)
            } catch {
                break
            }
        }
        mapsWriteBlocked = true
        protectionWarnings.append(
            "maps.json 无法解码且没有可用备份，已禁止写入：\(originalError.localizedDescription)"
        )
        return .unavailable
    }

    private func decodeSettings(_ data: Data) throws -> AppSettings {
        try decoder.decode(AppSettings.self, from: data)
    }

    private func decodeMapLibrary(_ data: Data) throws -> MapLibraryDocument {
        if let document = try? decoder.decode(MapLibraryDocument.self, from: data) {
            return document
        }
        let legacyMaps = try decoder.decode([MapTopology].self, from: data)
        return MapLibraryDocument(maps: legacyMaps)
    }

    private func saveMaps(_ maps: [MapTopology]) -> String? {
        if mapsWriteBlocked {
            return "地图库处于写保护状态，未覆盖原 maps.json"
        }
        do {
            let document = MapLibraryDocument(maps: maps)
            let data = try encoder.encode(document)
            try writeProtected(
                data,
                to: mapsURL,
                kind: .maps,
                supportedSchemaVersion: MapLibraryDocument.currentSchemaVersion,
                canDecodeExisting: { [decoder] data in
                    (try? decoder.decode(MapLibraryDocument.self, from: data)) != nil
                        || (try? decoder.decode([MapTopology].self, from: data)) != nil
                }
            )
            return nil
        } catch {
            return "地图库保存失败：\(error.localizedDescription)"
        }
    }

    private func writeProtected(
        _ data: Data,
        to url: URL,
        kind: StorageKind,
        supportedSchemaVersion: Int,
        canDecodeExisting: (Data) -> Bool
    ) throws {
        if let existingData = try? Data(contentsOf: url) {
            if existingData == data {
                return
            }
            guard canDecodeExisting(existingData) else {
                switch kind {
                case .settings: settingsWriteBlocked = true
                case .maps: mapsWriteBlocked = true
                }
                preserveCorruptCopy(of: url, kind: kind)
                throw CocoaError(
                    .fileWriteNoPermission,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "\(kind.title)文件无法解码，已保留原文件并拒绝覆盖"
                    ]
                )
            }
            if let existingVersion = schemaVersion(in: existingData),
               existingVersion > supportedSchemaVersion {
                switch kind {
                case .settings: settingsWriteBlocked = true
                case .maps: mapsWriteBlocked = true
                }
                throw CocoaError(
                    .fileWriteNoPermission,
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "\(kind.title)文件来自更高版本 \(existingVersion)，拒绝降级覆盖"
                    ]
                )
            }
            try rotateBackups(for: url)
        }
        try data.write(to: url, options: .atomic)
    }

    private func rotateBackups(for url: URL) throws {
        let backups = backupURLs(for: url)
        guard !backups.isEmpty else { return }
        if fileManager.fileExists(atPath: backups.last!.path) {
            try fileManager.removeItem(at: backups.last!)
        }
        if backups.count > 1 {
            for index in stride(from: backups.count - 2, through: 0, by: -1) {
                let source = backups[index]
                guard fileManager.fileExists(atPath: source.path) else { continue }
                let destination = backups[index + 1]
                if fileManager.fileExists(atPath: destination.path) {
                    try fileManager.removeItem(at: destination)
                }
                try fileManager.moveItem(at: source, to: destination)
            }
        }
        try fileManager.copyItem(at: url, to: backups[0])
    }

    private func backupURLs(for url: URL) -> [URL] {
        (1...AppConstants.persistenceBackupCount).map { index in
            URL(fileURLWithPath: "\(url.path).bak.\(index)")
        }
    }

    private func preserveCorruptCopy(of url: URL, kind: StorageKind) {
        guard fileManager.fileExists(atPath: url.path) else { return }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let timestamp = formatter.string(from: Date())
        let suffix = UUID().uuidString.prefix(8)
        let destination = directoryURL.appendingPathComponent(
            "\(url.lastPathComponent).corrupt-\(timestamp)-\(suffix)"
        )
        do {
            try fileManager.copyItem(at: url, to: destination)
        } catch {
            protectionWarnings.append(
                "\(kind.title)损坏副本保存失败：\(error.localizedDescription)"
            )
        }
    }

    private func schemaVersion(in data: Data) -> Int? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object["schemaVersion"] as? Int
    }

    private func normalize(_ settings: AppSettings) -> AppSettings {
        var copy = settings
        copy.schemaVersion = AppSettings.currentSchemaVersion
        copy.monitorServerBaseURL = AppSettings.normalizedMonitorServerBaseURL(copy.monitorServerBaseURL)
        copy.returnToMarket = copy.mode == .deadFlower
        copy.loungeMoveMinMinutes = max(1, min(24 * 60, copy.loungeMoveMinMinutes))
        copy.loungeMoveMaxMinutes = max(1, min(24 * 60, copy.loungeMoveMaxMinutes))
        while copy.buffs.count > AppConstants.defaultBuffSlotCount,
              let last = copy.buffs.last,
              !last.enabled,
              last.key.isEmpty,
              last.duration <= 0 {
            copy.buffs.removeLast()
        }
        while copy.buffs.count < AppConstants.defaultBuffSlotCount {
            copy.buffs.append(BuffConfig(id: copy.buffs.count + 1))
        }
        if copy.buffs.count > AppConstants.maxBuffSlotCount {
            copy.buffs = Array(copy.buffs.prefix(AppConstants.maxBuffSlotCount))
        }
        for index in copy.buffs.indices {
            copy.buffs[index].id = index + 1
        }
        return copy
    }
}
