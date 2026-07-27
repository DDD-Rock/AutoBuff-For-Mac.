import Foundation

struct MapTransferPackage: Codable, Equatable {
    static let currentFormatVersion = 1

    var formatVersion: Int
    var exportedAt: Date
    var maps: [MapTopology]

    init(
        formatVersion: Int = currentFormatVersion,
        exportedAt: Date = Date(),
        maps: [MapTopology]
    ) {
        self.formatVersion = formatVersion
        self.exportedAt = exportedAt
        self.maps = maps
    }
}

struct MapImportMergeResult: Equatable {
    var maps: [MapTopology]
    var addedCount: Int
    var replacedCount: Int
}

enum MapTransferError: LocalizedError, Equatable {
    case unreadableFile
    case unsupportedFormat(Int)
    case emptyPackage
    case emptyMapName(Int)
    case invalidMapSize(String)
    case duplicateMapName(String)

    var errorDescription: String? {
        switch self {
        case .unreadableFile:
            return "无法识别该地图文件"
        case .unsupportedFormat(let version):
            return "地图文件格式版本 \(version) 高于当前支持的版本"
        case .emptyPackage:
            return "地图文件中没有可导入的地图"
        case .emptyMapName(let index):
            return "地图文件中的第 \(index + 1) 张地图没有名称"
        case .invalidMapSize(let name):
            return "地图“\(name)”的参考尺寸无效"
        case .duplicateMapName(let name):
            return "地图文件中存在重复名称“\(name)”"
        }
    }
}

enum MapTransferService {
    private struct MapLibraryImportDocument: Codable {
        var schemaVersion: Int
        var maps: [MapTopology]
    }

    static func exportData(
        maps: [MapTopology],
        exportedAt: Date = Date()
    ) throws -> Data {
        let validatedMaps = try validate(maps)
        let package = MapTransferPackage(exportedAt: exportedAt, maps: validatedMaps)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(package)
    }

    static func importMaps(from data: Data) throws -> [MapTopology] {
        let decoder = JSONDecoder()
        let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]

        if root?["formatVersion"] != nil {
            let package: MapTransferPackage
            do {
                package = try decoder.decode(MapTransferPackage.self, from: data)
            } catch {
                throw MapTransferError.unreadableFile
            }
            guard package.formatVersion <= MapTransferPackage.currentFormatVersion else {
                throw MapTransferError.unsupportedFormat(package.formatVersion)
            }
            return try validate(package.maps)
        }

        if root?["schemaVersion"] != nil, root?["maps"] != nil {
            let document: MapLibraryImportDocument
            do {
                document = try decoder.decode(MapLibraryImportDocument.self, from: data)
            } catch {
                throw MapTransferError.unreadableFile
            }
            guard document.schemaVersion <= 1 else {
                throw MapTransferError.unsupportedFormat(document.schemaVersion)
            }
            return try validate(document.maps)
        }

        if let maps = try? decoder.decode([MapTopology].self, from: data) {
            return try validate(maps)
        }
        throw MapTransferError.unreadableFile
    }

    static func merge(
        importedMaps: [MapTopology],
        into existingMaps: [MapTopology]
    ) -> MapImportMergeResult {
        var merged = existingMaps
        var canonicalNames: [String: String] = [:]
        for map in existingMaps {
            canonicalNames[nameKey(map.mapName)] = map.mapName
        }
        for map in importedMaps {
            let trimmedName = map.mapName.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = nameKey(trimmedName)
            if canonicalNames[key] == nil {
                canonicalNames[key] = trimmedName
            }
        }

        var addedCount = 0
        var replacedCount = 0
        for imported in importedMaps {
            var normalized = imported
            let importedKey = nameKey(imported.mapName)
            normalized.mapName = canonicalNames[importedKey] ?? imported.mapName
            for index in normalized.portals.indices {
                guard let destination = normalized.portals[index].destinationMapName else {
                    continue
                }
                if let canonical = canonicalNames[nameKey(destination)] {
                    normalized.portals[index].destinationMapName = canonical
                }
            }

            if let existingIndex = merged.firstIndex(where: {
                nameKey($0.mapName) == importedKey
            }) {
                merged[existingIndex] = normalized
                replacedCount += 1
            } else {
                merged.append(normalized)
                addedCount += 1
            }
        }
        return MapImportMergeResult(
            maps: merged,
            addedCount: addedCount,
            replacedCount: replacedCount
        )
    }

    static func hasNameConflict(_ map: MapTopology, existingMaps: [MapTopology]) -> Bool {
        let key = nameKey(map.mapName)
        return existingMaps.contains { nameKey($0.mapName) == key }
    }

    private static func validate(_ maps: [MapTopology]) throws -> [MapTopology] {
        guard !maps.isEmpty else {
            throw MapTransferError.emptyPackage
        }
        var seenNames: Set<String> = []
        var normalizedMaps: [MapTopology] = []
        normalizedMaps.reserveCapacity(maps.count)

        for (index, map) in maps.enumerated() {
            var normalized = map
            normalized.mapName = map.mapName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.mapName.isEmpty else {
                throw MapTransferError.emptyMapName(index)
            }
            guard normalized.referenceWidth > 0, normalized.referenceHeight > 0 else {
                throw MapTransferError.invalidMapSize(normalized.mapName)
            }
            let key = nameKey(normalized.mapName)
            guard seenNames.insert(key).inserted else {
                throw MapTransferError.duplicateMapName(normalized.mapName)
            }
            normalizedMaps.append(normalized)
        }
        return normalizedMaps
    }

    private static func nameKey(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}
