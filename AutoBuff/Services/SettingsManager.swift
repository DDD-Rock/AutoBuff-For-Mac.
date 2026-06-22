import Foundation

final class SettingsManager {
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileManager: FileManager = .default, settingsDirectory: URL? = nil) {
        let dir: URL
        if let settingsDirectory {
            dir = settingsDirectory
        } else {
            let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            dir = appSupport.appendingPathComponent(AppConstants.settingsDirectoryName, isDirectory: true)
        }
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent(AppConstants.settingsFileName)
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        decoder = JSONDecoder()
    }

    func load() -> AppSettings {
        guard let data = try? Data(contentsOf: fileURL),
              let settings = try? decoder.decode(AppSettings.self, from: data) else {
            return .default
        }
        return normalize(settings)
    }

    func save(_ settings: AppSettings) {
        let normalized = normalize(settings)
        guard let data = try? encoder.encode(normalized) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private func normalize(_ settings: AppSettings) -> AppSettings {
        var copy = settings
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
