import CoreGraphics
import Foundation
import Testing
@testable import AutoBuff

struct SettingsManagerTests {
    @Test func remoteMonitorAccountTokenPersistsWithoutKeychain() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let store = RemoteMonitorLocalStore(directoryURL: tempDir)
        try store.saveToken("access-token")

        #expect(store.loadToken() == "access-token")
        let attributes = try FileManager.default.attributesOfItem(
            atPath: store.fileURL.path
        )
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)

        store.deleteCredentials()
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    @Test func sidebarUsesTheFixedNarrowLayout() {
        #expect(MainWindowLayout.sidebarWidth == 56)
        #expect(MainWindowLayout.minimumContentWidth == 540)
        #expect(MainWindowLayout.preferredContentWidth == 600)
    }

    @Test func mainWindowHeightAdaptsToAvailableScreenSpace() {
        let laptopHeight = MainWindowLayout.preferredContentHeight(
            visibleScreenHeight: 800,
            windowChromeHeight: 28
        )
        let desktopHeight = MainWindowLayout.preferredContentHeight(
            visibleScreenHeight: 1_200,
            windowChromeHeight: 28
        )
        let constrainedHeight = MainWindowLayout.preferredContentHeight(
            visibleScreenHeight: 600,
            windowChromeHeight: 28
        )

        #expect(laptopHeight == 740)
        #expect(desktopHeight == 860)
        #expect(constrainedHeight == 540)
    }

    @Test func followHealAllowsAllBuffsDisabled() {
        var settings = AppSettings.default
        settings.buffs = settings.buffs.map {
            BuffConfig(id: $0.id, enabled: false, key: $0.key, duration: $0.duration)
        }
        settings.healSkillKey = "Q"
        settings.healAnchorX = 50

        let errors = WorkerConfigurationValidator.validationErrors(
            settings: settings,
            mode: .followHeal
        )

        #expect(errors.isEmpty)
    }

    @Test func nonFollowHealStillRequiresAnEnabledBuff() {
        var settings = AppSettings.default
        settings.buffs = settings.buffs.map {
            BuffConfig(id: $0.id, enabled: false, key: $0.key, duration: $0.duration)
        }

        let errors = WorkerConfigurationValidator.validationErrors(
            settings: settings,
            mode: .liveFlower
        )

        #expect(errors == ["请至少启用一个 Buff"])
    }

    @Test func templeFreeEntryUsesDeadFlowerRequirements() {
        var settings = AppSettings.default
        settings.templeFunction = .freeEntry
        settings.jumpKey = ""

        let errors = WorkerConfigurationValidator.validationErrors(
            settings: settings,
            mode: .temple
        )

        #expect(errors == ["跳跃键“”不受支持"])
        #expect(ModeRequirements.requiresAccessibility(.temple))
        #expect(ModeRequirements.requiresScreenRecording(.temple))
    }

    @Test func unfinishedTempleFunctionsCannotStart() {
        var settings = AppSettings.default
        settings.templeFunction = .lounge

        let loungeErrors = WorkerConfigurationValidator.validationErrors(
            settings: settings,
            mode: .temple
        )
        settings.templeFunction = .ropeParty
        let ropePartyErrors = WorkerConfigurationValidator.validationErrors(
            settings: settings,
            mode: .temple
        )

        #expect(loungeErrors == ["神殿模式的“休息室”功能配置尚未开放"])
        #expect(ropePartyErrors == ["神殿模式的“挂绳组队”功能配置尚未开放"])
    }

    @Test func monitorModeDoesNotRequireBuffsOrInputKeys() {
        var settings = AppSettings.default
        settings.buffs = settings.buffs.map {
            BuffConfig(id: $0.id, enabled: false, key: "", duration: 0)
        }
        settings.sitChairEnabled = true
        settings.chairKey = ""
        settings.jumpKey = ""
        settings.healSkillKey = ""

        let errors = WorkerConfigurationValidator.validationErrors(
            settings: settings,
            mode: .monitor
        )

        #expect(errors.isEmpty)
        #expect(!ModeRequirements.requiresAccessibility(.monitor))
        #expect(ModeRequirements.requiresScreenRecording(.monitor))
    }

    @Test func loadDefaultWhenMissing() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let manager = SettingsManager(settingsDirectory: tempDir)
        let settings = manager.load()
        #expect(settings.buffs.count == AppConstants.defaultBuffSlotCount)
        #expect(settings.buffs[0].enabled == true)
        #expect(settings.buffs[0].key == "1")
        #expect(settings.preSkillMoveMode == .rightOnly)
        #expect(settings.templeFunction == .freeEntry)
    }

    @Test func saveAndLoadRoundTrip() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

        var settings = AppSettings.default
        settings.manualPortalX = 42
        settings.manualPortalY = 88
        settings.movementMode = .right
        settings.preSkillMoveMode = .rightOnly
        settings.randomBehaviorValue = 15

        let manager = SettingsManager(settingsDirectory: tempDir)
        manager.save(settings)
        let loaded = manager.load()

        #expect(loaded.manualPortalX == 42)
        #expect(loaded.manualPortalY == 88)
        #expect(loaded.movementMode == .right)
        #expect(loaded.preSkillMoveMode == .rightOnly)
        #expect(loaded.randomBehaviorValue == 15)
    }

    @Test func legacyReturnToMarketMigratesToModeWhenModeMissing() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let json = """
        {
          "returnToMarket": false,
          "buffs": [
            { "id": 1, "enabled": true, "key": "1", "duration": 200 },
            { "id": 2, "enabled": true, "key": "2", "duration": 200 },
            { "id": 3, "enabled": false, "key": "", "duration": 0 }
          ]
        }
        """
        try json.data(using: .utf8)?.write(to: tempDir.appendingPathComponent(AppConstants.settingsFileName))

        let manager = SettingsManager(settingsDirectory: tempDir)
        let loaded = manager.load()

        #expect(loaded.mode == .liveFlower)
        #expect(loaded.returnToMarket == false)
    }

    @Test func followHealModeAndHealKeyPersist() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        var settings = AppSettings.default
        settings.mode = .followHeal
        settings.healSkillKey = "Q"
        settings.healAnchorX = 77
        settings.healAnchorY = 12
        settings.healMinimapRegion = CGRect(x: 8, y: 120, width: 164, height: 86)
        settings.followHealAdjustMinMS = 220
        settings.followHealAdjustMaxMS = 330

        let manager = SettingsManager(settingsDirectory: tempDir)
        manager.save(settings)
        let loaded = manager.load()

        #expect(loaded.mode == .followHeal)
        #expect(loaded.returnToMarket == false)
        #expect(loaded.healSkillKey == "Q")
        #expect(loaded.healAnchorX == 77)
        #expect(loaded.healAnchorY == 12)
        #expect(loaded.healMinimapRegion == CGRect(x: 8, y: 120, width: 164, height: 86))
        #expect(loaded.followHealAdjustMinMS == 220)
        #expect(loaded.followHealAdjustMaxMS == 330)
    }

    @Test func templeModeAndFunctionPersist() throws {
        for function in TempleFunction.allCases {
            let tempDir = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            var settings = AppSettings.default
            settings.mode = .temple
            settings.templeFunction = function

            let manager = SettingsManager(settingsDirectory: tempDir)
            manager.save(settings)
            let loaded = manager.load()

            #expect(loaded.mode == .temple)
            #expect(loaded.templeFunction == function)
            #expect(loaded.returnToMarket == false)
        }
    }

    @Test func monitorModeAndAllDisplayModesPersist() throws {
        for displayMode in MonitorDisplayMode.allCases {
            let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
            var settings = AppSettings.default
            settings.mode = .monitor
            settings.monitorDisplayMode = displayMode

            let manager = SettingsManager(settingsDirectory: tempDir)
            manager.save(settings)
            let loaded = manager.load()

            #expect(loaded.mode == .monitor)
            #expect(loaded.returnToMarket == false)
            #expect(loaded.monitorDisplayMode == displayMode)
        }
    }

    @Test func legacySettingsDefaultToMinimapWithAnnotations() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let json = """
        {
          "mode": "live",
          "returnToMarket": false,
          "buffs": [
            { "id": 1, "enabled": true, "key": "1", "duration": 200 },
            { "id": 2, "enabled": true, "key": "2", "duration": 200 },
            { "id": 3, "enabled": false, "key": "", "duration": 0 }
          ]
        }
        """
        try json.data(using: .utf8)?.write(to: tempDir.appendingPathComponent(AppConstants.settingsFileName))

        let loaded = SettingsManager(settingsDirectory: tempDir).load()

        #expect(loaded.monitorDisplayMode == .minimapWithAnnotations)
        #expect(loaded.templeFunction == .freeEntry)
    }

    @Test func mapLibraryIsStoredSeparatelyFromSettings() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let topology = MapTopology(
            mapName: "独立地图库",
            referenceWidth: 120,
            referenceHeight: 80,
            visualSignature: [UInt8](repeating: 12, count: MinimapVisualMatcher.columns * MinimapVisualMatcher.rows)
        )
        var settings = AppSettings.default
        settings.mapTopologies = [topology]

        let manager = SettingsManager(settingsDirectory: tempDir)
        let result = manager.save(settings)
        let settingsObject = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: tempDir.appendingPathComponent(AppConstants.settingsFileName))
            ) as? [String: Any]
        )
        let mapsObject = try #require(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: tempDir.appendingPathComponent(AppConstants.mapsFileName))
            ) as? [String: Any]
        )

        #expect(result.succeeded)
        #expect((settingsObject["mapTopologies"] as? [Any])?.isEmpty == true)
        #expect(settingsObject["schemaVersion"] as? Int == AppSettings.currentSchemaVersion)
        #expect((mapsObject["maps"] as? [Any])?.count == 1)
        #expect(manager.load().mapTopologies == [topology])
    }

    @Test func legacyEmbeddedMapsMigrateToSeparateLibrary() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let topology = MapTopology(
            mapName: "旧内嵌地图",
            referenceWidth: 100,
            referenceHeight: 60
        )
        var legacySettings = AppSettings.default
        legacySettings.schemaVersion = 1
        legacySettings.mapTopologies = [topology]
        let encoder = JSONEncoder()
        try encoder.encode(legacySettings).write(
            to: tempDir.appendingPathComponent(AppConstants.settingsFileName)
        )

        let manager = SettingsManager(settingsDirectory: tempDir)
        let loaded = manager.load()

        #expect(loaded.mapTopologies == [topology])
        #expect(FileManager.default.fileExists(
            atPath: tempDir.appendingPathComponent(AppConstants.mapsFileName).path
        ))
        #expect(manager.protectionWarnings.contains { $0.contains("迁移") })
    }

    @Test func oldSettingsWriterCannotEraseSeparateMapLibrary() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let topology = MapTopology(
            mapName: "受保护地图",
            referenceWidth: 100,
            referenceHeight: 60
        )
        var settings = AppSettings.default
        settings.mapTopologies = [topology]
        let manager = SettingsManager(settingsDirectory: tempDir)
        manager.save(settings)

        let oldSettingsJSON = """
        {
          "mode": "live",
          "returnToMarket": false,
          "buffs": [
            { "id": 1, "enabled": true, "key": "1", "duration": 200 }
          ]
        }
        """
        try #require(oldSettingsJSON.data(using: .utf8)).write(
            to: tempDir.appendingPathComponent(AppConstants.settingsFileName),
            options: .atomic
        )

        let reloaded = SettingsManager(settingsDirectory: tempDir).load()

        #expect(reloaded.mode == .liveFlower)
        #expect(reloaded.mapTopologies == [topology])
    }

    @Test func corruptSettingsWithoutBackupRemainUntouchedAndWriteProtected() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let settingsURL = tempDir.appendingPathComponent(AppConstants.settingsFileName)
        let corruptData = try #require("{not-json".data(using: .utf8))
        try corruptData.write(to: settingsURL)

        let manager = SettingsManager(settingsDirectory: tempDir)
        var loaded = manager.load()
        loaded.mode = .liveFlower
        let result = manager.save(loaded)

        #expect(manager.settingsWriteBlocked)
        #expect(!result.succeeded)
        #expect(try Data(contentsOf: settingsURL) == corruptData)
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
                .contains { $0.hasPrefix("settings.json.corrupt-") }
        )
    }

    @Test func corruptSettingsRestoreFromRotatingBackup() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let settingsURL = tempDir.appendingPathComponent(AppConstants.settingsFileName)
        let manager = SettingsManager(settingsDirectory: tempDir)
        var first = AppSettings.default
        first.mode = .liveFlower
        manager.save(first)
        var second = first
        second.mode = .monitor
        manager.save(second)
        try #require("{broken".data(using: .utf8)).write(to: settingsURL, options: .atomic)

        let recoveringManager = SettingsManager(settingsDirectory: tempDir)
        let recovered = recoveringManager.load()

        #expect(recovered.mode == .liveFlower)
        #expect(!recoveringManager.settingsWriteBlocked)
        #expect(recoveringManager.protectionWarnings.contains { $0.contains("恢复") })
        #expect(FileManager.default.fileExists(atPath: "\(settingsURL.path).bak.1"))
    }

    @Test func corruptMapLibraryRestoresFromRotatingBackup() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let mapsURL = tempDir.appendingPathComponent(AppConstants.mapsFileName)
        let firstTopology = MapTopology(
            mapName: "地图备份",
            referenceWidth: 100,
            referenceHeight: 60
        )
        let secondTopology = MapTopology(
            mapName: "当前地图",
            referenceWidth: 120,
            referenceHeight: 80
        )
        let manager = SettingsManager(settingsDirectory: tempDir)
        var settings = AppSettings.default
        settings.mapTopologies = [firstTopology]
        manager.save(settings)
        settings.mapTopologies = [secondTopology]
        manager.save(settings)
        try #require("{broken-map".data(using: .utf8)).write(to: mapsURL, options: .atomic)

        let recoveringManager = SettingsManager(settingsDirectory: tempDir)
        let recovered = recoveringManager.load()

        #expect(recovered.mapTopologies == [firstTopology])
        #expect(!recoveringManager.mapsWriteBlocked)
        #expect(recoveringManager.protectionWarnings.contains { $0.contains("maps.json") && $0.contains("恢复") })
        #expect(FileManager.default.fileExists(atPath: "\(mapsURL.path).bak.1"))
    }

    @Test func saveWithoutLoadDoesNotOverwriteCorruptMapLibrary() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let mapsURL = tempDir.appendingPathComponent(AppConstants.mapsFileName)
        let corruptData = try #require("{broken-map".data(using: .utf8))
        try corruptData.write(to: mapsURL)
        var settings = AppSettings.default
        settings.mapTopologies = [
            MapTopology(mapName: "不应覆盖", referenceWidth: 100, referenceHeight: 60)
        ]

        let manager = SettingsManager(settingsDirectory: tempDir)
        let result = manager.save(settings)

        #expect(manager.mapsWriteBlocked)
        #expect(!result.succeeded)
        #expect(try Data(contentsOf: mapsURL) == corruptData)
    }

    @Test func newerSettingsSchemaCannotBeDowngraded() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let settingsURL = tempDir.appendingPathComponent(AppConstants.settingsFileName)
        let futureJSON = """
        {
          "schemaVersion": 999,
          "mode": "live",
          "returnToMarket": false,
          "buffs": []
        }
        """
        let futureData = try #require(futureJSON.data(using: .utf8))
        try futureData.write(to: settingsURL)

        let manager = SettingsManager(settingsDirectory: tempDir)
        let loaded = manager.load()
        let result = manager.save(loaded)

        #expect(manager.settingsWriteBlocked)
        #expect(!result.succeeded)
        #expect(try Data(contentsOf: settingsURL) == futureData)
    }

    @Test func selectedMapsExportAndImportRoundTrip() throws {
        let first = MapTopology(
            mapName: "导出地图 A",
            referenceWidth: 120,
            referenceHeight: 80,
            visualSignature: [UInt8](repeating: 21, count: MinimapVisualMatcher.columns * MinimapVisualMatcher.rows),
            referenceBGR: Data([1, 2, 3]),
            platforms: [
                MapPlatform(points: [
                    NormalizedMapPoint(x: 0.1, y: 0.5),
                    NormalizedMapPoint(x: 0.9, y: 0.5)
                ])
            ]
        )
        let second = MapTopology(
            mapName: "导出地图 B",
            referenceWidth: 160,
            referenceHeight: 90,
            ropes: [MapRope(x: 0.5, topY: 0.2, bottomY: 0.8)]
        )

        let data = try MapTransferService.exportData(
            maps: [first, second],
            exportedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let imported = try MapTransferService.importMaps(from: data)
        let root = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])

        #expect(root["formatVersion"] as? Int == MapTransferPackage.currentFormatVersion)
        #expect(imported == [first, second])
    }

    @Test func mapImporterAcceptsMapLibraryAndLegacyArrayDocuments() throws {
        let map = MapTopology(
            mapName: "兼容导入",
            referenceWidth: 100,
            referenceHeight: 60
        )
        let encodedMap = try JSONEncoder().encode(map)
        let mapObject = try JSONSerialization.jsonObject(with: encodedMap)
        let libraryData = try JSONSerialization.data(withJSONObject: [
            "schemaVersion": 1,
            "maps": [mapObject]
        ])
        let arrayData = try JSONSerialization.data(withJSONObject: [mapObject])

        #expect(try MapTransferService.importMaps(from: libraryData) == [map])
        #expect(try MapTransferService.importMaps(from: arrayData) == [map])
    }

    @Test func mapImportMergeReplacesConflictsAndRepairsPortalNames() {
        let existing = MapTopology(
            mapName: "Town",
            referenceWidth: 100,
            referenceHeight: 60,
            platforms: [
                MapPlatform(points: [
                    NormalizedMapPoint(x: 0.1, y: 0.5),
                    NormalizedMapPoint(x: 0.9, y: 0.5)
                ])
            ]
        )
        let replacement = MapTopology(
            mapName: "town",
            referenceWidth: 120,
            referenceHeight: 70,
            portals: [
                MapPortal(
                    point: NormalizedMapPoint(x: 0.8, y: 0.7),
                    type: .mapExit,
                    destinationMapName: "FOREST"
                )
            ]
        )
        let newMap = MapTopology(
            mapName: "Forest",
            referenceWidth: 140,
            referenceHeight: 80
        )

        let result = MapTransferService.merge(
            importedMaps: [replacement, newMap],
            into: [existing]
        )

        #expect(result.addedCount == 1)
        #expect(result.replacedCount == 1)
        #expect(result.maps.map(\.mapName) == ["Town", "Forest"])
        #expect(result.maps[0].referenceWidth == 120)
        #expect(result.maps[0].portals.first?.destinationMapName == "Forest")
    }

    @Test func mapImporterRejectsDuplicateNamesAndFuturePackages() throws {
        let first = MapTopology(mapName: "Duplicate", referenceWidth: 100, referenceHeight: 60)
        let second = MapTopology(mapName: "duplicate", referenceWidth: 120, referenceHeight: 70)

        do {
            _ = try MapTransferService.exportData(maps: [first, second])
            Issue.record("大小写不同的重复地图名称不应允许导出")
        } catch let error as MapTransferError {
            #expect(error == .duplicateMapName("duplicate"))
        } catch {
            Issue.record("收到非预期错误：\(error)")
        }

        let futurePackage = MapTransferPackage(
            formatVersion: 999,
            exportedAt: Date(timeIntervalSince1970: 0),
            maps: [first]
        )
        let futureData = try JSONEncoder().encode(futurePackage)
        do {
            _ = try MapTransferService.importMaps(from: futureData)
            Issue.record("未来版本地图包不应允许导入")
        } catch let error as MapTransferError {
            #expect(error == .unsupportedFormat(999))
        } catch {
            Issue.record("收到非预期错误：\(error)")
        }
    }

    @Test func monitorMapMatcherDoesNotReuseWrongTopology() {
        let darkFrame = ImageBuffer(
            width: 48,
            height: 32,
            bgr: [UInt8](repeating: 20, count: 48 * 32 * 3)
        )
        let brightFrame = ImageBuffer(
            width: 48,
            height: 32,
            bgr: [UInt8](repeating: 210, count: 48 * 32 * 3)
        )
        let topology = MapTopology(
            mapName: "测试地图",
            referenceWidth: 48,
            referenceHeight: 32,
            visualSignature: MinimapVisualMatcher.signature(for: darkFrame)
        )

        #expect(MonitorMapMatcher.match(frame: darkFrame, maps: [topology])?.mapName == "测试地图")
        #expect(MonitorMapMatcher.match(frame: brightFrame, maps: [topology]) == nil)
    }

    @Test func monitorOverlayMapsPlayerPointToCanvas() {
        let mapped = MapTopologyOverlayRenderer.displayPoint(
            for: CGPoint(x: 50, y: 25),
            contentSize: CGSize(width: 100, height: 50),
            canvasSize: CGSize(width: 400, height: 200)
        )

        #expect(mapped == CGPoint(x: 200, y: 100))
        #expect(
            MapTopologyOverlayRenderer.displayPoint(
                for: .zero,
                contentSize: .zero,
                canvasSize: CGSize(width: 400, height: 200)
            ) == nil
        )
    }

    @Test func legacyEmptyBuffSlotsCollapseToThree() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        var settings = AppSettings.default
        settings.buffs.append(contentsOf: [
            BuffConfig(id: 4),
            BuffConfig(id: 5),
            BuffConfig(id: 6),
        ])

        let manager = SettingsManager(settingsDirectory: tempDir)
        manager.save(settings)
        let loaded = manager.load()

        #expect(loaded.buffs.count == 3)
    }

    @Test func configuredAdditionalBuffSlotsArePreserved() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        var settings = AppSettings.default
        settings.buffs.append(BuffConfig(id: 4, enabled: true, key: "4", duration: 180))

        let manager = SettingsManager(settingsDirectory: tempDir)
        manager.save(settings)
        let loaded = manager.load()

        #expect(loaded.buffs.count == 4)
        #expect(loaded.buffs[3].key == "4")
    }

    @Test func bgrConversionProducesExpectedDimensions() {
        var bgra = [UInt8](repeating: 0, count: 4 * 4 * 4)
        for i in stride(from: 0, to: bgra.count, by: 4) {
            bgra[i] = 255     // R
            bgra[i + 1] = 0   // G
            bgra[i + 2] = 0   // B
            bgra[i + 3] = 255 // A
        }
        guard let provider = CGDataProvider(data: Data(bgra) as CFData),
              let cgImage = CGImage(
                width: 4, height: 4,
                bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 16,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
              ),
              let buffer = ImagePipeline.cgImageToBGRBuffer(cgImage) else {
            Issue.record("Failed to create test image")
            return
        }
        #expect(buffer.width == 4)
        #expect(buffer.height == 4)
        #expect(buffer.bgr.count == 4 * 4 * 3)
        if let pixel = buffer.pixelBGR(x: 0, y: 0) {
            #expect(pixel.r == 255)
            #expect(pixel.g == 0)
            #expect(pixel.b == 0)
        }
    }

    @Test func bgrConversionPreservesRowOrder() {
        let rgba: [UInt8] = [
            255, 0, 0, 255,   0, 255, 0, 255,
            0, 0, 255, 255,   255, 255, 255, 255,
        ]
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let image = CGImage(
                width: 2, height: 2,
                bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
              ),
              let buffer = ImagePipeline.cgImageToBGRBuffer(image) else {
            Issue.record("Failed to create orientation test image")
            return
        }
        #expect(buffer.pixelBGR(x: 0, y: 0)?.r == 255)
        #expect(buffer.pixelBGR(x: 1, y: 0)?.g == 255)
        #expect(buffer.pixelBGR(x: 0, y: 1)?.b == 255)
    }

    @Test func imageCoordinatesMapToQuartzCoordinatesWithoutYFlip() {
        let point = ImagePipeline.imagePointToScreenPoint(
            CGPoint(x: 50, y: 25),
            imageSize: CGSize(width: 200, height: 100),
            windowBounds: CGRect(x: 100, y: 300, width: 400, height: 200)
        )
        #expect(point == CGPoint(x: 200, y: 350))
    }

    @Test func portalArrivalUsesPointResolutionTolerance() {
        #expect(PortalNavigation.hasArrived(playerX: 30, portalX: 32.5))
        #expect(!PortalNavigation.hasArrived(playerX: 30, portalX: 35))
    }

    @Test func dialogConfirmButtonValidationAcceptsOrangeButtonBackground() {
        let width = 20
        let height = 20
        var data = [UInt8](repeating: 220, count: width * height * 3)
        for y in 7..<13 {
            for x in 5..<13 {
                let index = (y * width + x) * 3
                data[index] = 35
                data[index + 1] = 125
                data[index + 2] = 225
            }
        }
        let image = ImageBuffer(width: width, height: height, bgr: data)
        let match = MatchResult(
            x: 5,
            y: 7,
            width: 8,
            height: 6,
            confidence: 0.8,
            scaleX: 1,
            scaleY: 1
        )

        #expect(DialogConfirmButtonValidator.isPlausible(in: image, match: match))
    }

    @Test func dialogConfirmButtonValidationRejectsNeutralToolbarRegion() {
        let image = ImageBuffer(
            width: 12,
            height: 8,
            bgr: [UInt8](repeating: 220, count: 12 * 8 * 3)
        )
        let match = MatchResult(
            x: 0,
            y: 0,
            width: 12,
            height: 8,
            confidence: 0.55,
            scaleX: 0.6,
            scaleY: 0.6
        )

        #expect(!DialogConfirmButtonValidator.isPlausible(in: image, match: match))
    }

    @Test func followHealNavigationChoosesDirectionToBase() {
        #expect(FollowHealNavigation.directionToBase(currentX: 104, baseX: 100) == .left)
        #expect(FollowHealNavigation.directionToBase(currentX: 96, baseX: 100) == .right)
        #expect(FollowHealNavigation.directionToBase(currentX: 102.5, baseX: 100) == nil)
    }

    @Test func playerDetectionPrefersTheCandidateNearTheMarkedAnchor() {
        let width = 40
        let height = 20
        var data = [UInt8](repeating: 0, count: width * height * 3)
        for originX in [4, 28] {
            for y in 7..<11 {
                for x in originX..<(originX + 4) {
                    let index = (y * width + x) * 3
                    data[index] = 0
                    data[index + 1] = 230
                    data[index + 2] = 255
                }
            }
        }
        let image = ImageBuffer(width: width, height: height, bgr: data)
        let result = ColorDetector.detectPlayerMarker(
            in: image,
            near: CGPoint(x: 30, y: 9)
        )

        #expect(result.point == CGPoint(x: 29.5, y: 8.5))
    }

    @Test func followHealInitialDetectionDoesNotBiasTowardDestinationAnchor() {
        let width = 140
        let height = 120
        var data = [UInt8](repeating: 20, count: width * height * 3)
        func paint(x: Int, y: Int, width: Int, height: Int) {
            for row in y..<(y + height) {
                for column in x..<(x + width) {
                    let index = (row * width + column) * 3
                    data[index] = 0
                    data[index + 1] = 235
                    data[index + 2] = 255
                }
            }
        }

        paint(x: 101, y: 95, width: 3, height: 2)
        paint(x: 48, y: 76, width: 6, height: 5)
        let image = ImageBuffer(width: width, height: height, bgr: data)

        let result = ColorDetector.detectPlayerMarker(
            in: image,
            minArea: FollowHealNavigation.playerMarkerMinArea
        )

        #expect(result.point == CGPoint(x: 50.5, y: 78))
        #expect(result.selectedArea == 30)
    }

    @Test func followHealCenterAdjustmentMovesTowardBaseOrRightWhenCentered() {
        #expect(FollowHealNavigation.directionForCenterAdjustment(currentX: 104, baseX: 100) == .left)
        #expect(FollowHealNavigation.directionForCenterAdjustment(currentX: 96, baseX: 100) == .right)
        #expect(FollowHealNavigation.directionForCenterAdjustment(currentX: 102.5, baseX: 100) == .right)
    }

    @Test func followHealAnchorBandAllowsSmallSideSteps() {
        #expect(!FollowHealNavigation.isOutsideAnchorBand(currentX: 106, baseX: 100))
        #expect(!FollowHealNavigation.isOutsideAnchorBand(currentX: 94, baseX: 100))
        #expect(FollowHealNavigation.isOutsideAnchorBand(currentX: 106.5, baseX: 100))
        #expect(FollowHealNavigation.isOutsideAnchorBand(currentX: 93.5, baseX: 100))
    }

    @Test func followHealCenterAdjustIntervalIsFrequent() {
        for _ in 0..<20 {
            let interval = FollowHealNavigation.nextCenterAdjustInterval()
            #expect(interval >= 12)
            #expect(interval <= 15)
        }
    }

    @Test func keyCodeMapUsesRealMacKeyPositions() {
        #expect(KeyCodeMap.virtualKeyCode(for: "A") == 0x00)
        #expect(KeyCodeMap.virtualKeyCode(for: "B") == 0x0B)
        #expect(KeyCodeMap.virtualKeyCode(for: "Y") == 0x10)
        #expect(KeyCodeMap.virtualKeyCode(for: "1") == 0x12)
        #expect(KeyCodeMap.virtualKeyCode(for: "↑") == 0x7E)
    }

    @Test func countdownStartsAtFinalBuffPress() {
        let next = CountdownTiming.nextRelease(
            pressedAt: 1_000,
            interval: 200,
            earlyBy: 7.5
        )
        #expect(next == 1_192.5)
        #expect(CountdownTiming.remainingSeconds(until: next, now: 1_000) == 193)
        #expect(CountdownTiming.remainingSeconds(until: next, now: 1_000.1) == 193)
        #expect(CountdownTiming.remainingSeconds(until: next, now: 1_192.6) == 0)
    }

    @Test @MainActor
    func countdownPublisherContinuesDecreasing() async {
        let publisher = CountdownPublisher()
        var received: [Int] = []
        publisher.start { info in
            if let value = info[1] {
                received.append(value)
            }
        }

        let now = Date().timeIntervalSince1970
        publisher.replaceDeadlines([1: now + 2], now: now)
        try? await Task.sleep(nanoseconds: 1_250_000_000)
        publisher.stop()

        #expect(received.contains(2))
        #expect(received.contains(1))
    }

    @Test func colorDetectionFindsLargestYellowBlobAndBluePortal() {
        var data = [UInt8](repeating: 0, count: 20 * 12 * 3)
        func paint(x: Int, y: Int, width: Int, height: Int, b: UInt8, g: UInt8, r: UInt8) {
            for row in y..<(y + height) {
                for column in x..<(x + width) {
                    let index = (row * 20 + column) * 3
                    data[index] = b
                    data[index + 1] = g
                    data[index + 2] = r
                }
            }
        }
        paint(x: 1, y: 1, width: 2, height: 3, b: 0, g: 250, r: 250)
        paint(x: 10, y: 5, width: 4, height: 3, b: 0, g: 255, r: 255)
        paint(x: 4, y: 3, width: 3, height: 5, b: 255, g: 0, r: 0)
        let image = ImageBuffer(width: 20, height: 12, bgr: data)

        let player = ColorDetector.findYellowCentroid(in: image)
        let portal = ColorDetector.findBluePortal(in: image)
        #expect(player == CGPoint(x: 11.5, y: 6))
        #expect(portal == CGPoint(x: 5, y: 5))
    }

    @Test func playerDetectionAcceptsResampledYellowMarker() {
        let width = 24
        let height = 14
        var data = [UInt8](repeating: 20, count: width * height * 3)
        for y in 5..<8 {
            for x in 15..<19 {
                let index = (y * width + x) * 3
                data[index] = 38
                data[index + 1] = 205
                data[index + 2] = 220
            }
        }
        let image = ImageBuffer(width: width, height: height, bgr: data)

        let result = ColorDetector.detectPlayerMarker(in: image)
        #expect(result.point == CGPoint(x: 16.5, y: 6))
        #expect(result.selectedArea == 12)
    }

    @Test func playerDetectionRejectsThinYellowUiGlyphs() {
        let width = 40
        let height = 20
        var data = [UInt8](repeating: 20, count: width * height * 3)
        func paint(x: Int, y: Int, width: Int, height: Int, b: UInt8, g: UInt8, r: UInt8) {
            for row in y..<(y + height) {
                for column in x..<(x + width) {
                    let index = (row * 40 + column) * 3
                    data[index] = b
                    data[index + 1] = g
                    data[index + 2] = r
                }
            }
        }

        paint(x: 4, y: 7, width: 4, height: 4, b: 0, g: 255, r: 255)
        paint(x: 26, y: 3, width: 2, height: 12, b: 0, g: 255, r: 255)
        let image = ImageBuffer(width: width, height: height, bgr: data)

        let result = ColorDetector.detectPlayerMarker(in: image)
        #expect(result.point == CGPoint(x: 5.5, y: 8.5))
        #expect(result.selectedArea == 16)
    }

    @Test func playerDetectionUsesVividYellowCoreWhenGoldPixelsTouchMarker() {
        let width = 60
        let height = 30
        var data = [UInt8](repeating: 20, count: width * height * 3)
        func paint(
            x: Int,
            y: Int,
            width: Int,
            height: Int,
            b: UInt8,
            g: UInt8,
            r: UInt8
        ) {
            for row in y..<(y + height) {
                for column in x..<(x + width) {
                    let index = (row * 60 + column) * 3
                    data[index] = b
                    data[index + 1] = g
                    data[index + 2] = r
                }
            }
        }

        paint(x: 2, y: 8, width: 4, height: 4, b: 40, g: 190, r: 220)
        paint(x: 20, y: 12, width: 24, height: 5, b: 70, g: 190, r: 220)
        paint(x: 30, y: 12, width: 4, height: 4, b: 0, g: 255, r: 255)
        let image = ImageBuffer(width: width, height: height, bgr: data)

        let result = ColorDetector.detectPlayerMarker(
            in: image,
            near: CGPoint(x: 3.5, y: 9.5)
        )

        #expect(result.point == CGPoint(x: 31.5, y: 13.5))
        #expect(result.selectedArea == 16)
    }

    @Test func darkRegionDetectionClosesSmallHolesAndRejectsNoise() {
        let width = 120
        let height = 90
        var data = [UInt8](repeating: 240, count: width * height * 3)
        func setGray(x: Int, y: Int, value: UInt8) {
            let index = (y * width + x) * 3
            data[index] = value
            data[index + 1] = value
            data[index + 2] = value
        }
        for y in 15..<65 {
            for x in 20..<90 {
                setGray(x: x, y: y, value: 30)
            }
        }
        for x in 30..<80 {
            setGray(x: x, y: 40, value: 240)
        }
        for y in 5..<8 {
            for x in 5..<8 {
                setGray(x: x, y: y, value: 20)
            }
        }

        let image = ImageBuffer(width: width, height: height, bgr: data)
        let region = ColorDetector.autoDetectDarkRegion(
            in: image,
            searchWidth: width,
            searchHeight: height,
            minArea: 2_000
        )
        #expect(region == CGRect(x: 20, y: 15, width: 70, height: 50))
    }

    @Test func darkRegionDetectionUsesExternalContourArea() {
        let width = 160
        let height = 100
        var data = [UInt8](repeating: 230, count: width * height * 3)
        func setGray(x: Int, y: Int, value: UInt8) {
            let index = (y * width + x) * 3
            data[index] = value
            data[index + 1] = value
            data[index + 2] = value
        }

        // A dark rectangular frame with a large bright interior has low dark
        // pixel density, but OpenCV RETR_EXTERNAL sees the whole outer contour.
        for y in 20..<80 {
            for x in 25..<135 {
                let isFrame = x < 33 || x >= 127 || y < 28 || y >= 72
                if isFrame {
                    setGray(x: x, y: y, value: 25)
                }
            }
        }

        let image = ImageBuffer(width: width, height: height, bgr: data)
        let result = ColorDetector.detectDarkRegion(
            in: image,
            searchWidth: width,
            searchHeight: height,
            thresholds: [100],
            minArea: 3_000
        )
        #expect(result.rect == CGRect(x: 25, y: 20, width: 110, height: 60))
        #expect(result.bestRectangularity > 0.9)
    }

    @Test func darkRegionDetectionRejectsOversizedGameBackground() {
        let width = 420
        let height = 260
        var data = [UInt8](repeating: 230, count: width * height * 3)
        func setGray(x: Int, y: Int, value: UInt8) {
            let index = (y * width + x) * 3
            data[index] = value
            data[index + 1] = value
            data[index + 2] = value
        }

        for y in 20..<250 {
            for x in 190..<410 {
                setGray(x: x, y: y, value: 35)
            }
        }
        for y in 70..<150 {
            for x in 35..<165 {
                setGray(x: x, y: y, value: 20)
            }
        }

        let image = ImageBuffer(width: width, height: height, bgr: data)
        let result = ColorDetector.detectDarkRegion(
            in: image,
            searchWidth: width,
            searchHeight: height,
            thresholds: [100],
            minArea: 2_000,
            maxCandidateWidth: 180,
            maxCandidateHeight: 120
        )
        #expect(result.rect == CGRect(x: 35, y: 70, width: 130, height: 80))
    }

    @Test func minimapRegionDetectionPrefersMarkedDarkMapOverBackground() {
        let width = 320
        let height = 240
        var data = [UInt8](repeating: 230, count: width * height * 3)
        func setBGR(x: Int, y: Int, b: UInt8, g: UInt8, r: UInt8) {
            let index = (y * width + x) * 3
            data[index] = b
            data[index + 1] = g
            data[index + 2] = r
        }
        func setGray(x: Int, y: Int, value: UInt8) {
            setBGR(x: x, y: y, b: value, g: value, r: value)
        }

        for y in 20..<230 {
            for x in 180..<315 {
                setGray(x: x, y: y, value: 35)
            }
        }
        for y in 95..<185 {
            for x in 40..<170 {
                setGray(x: x, y: y, value: 25)
            }
        }
        for y in 130..<134 {
            for x in 88..<92 {
                setBGR(x: x, y: y, b: 0, g: 235, r: 255)
            }
        }
        for y in 150..<154 {
            for x in 120..<124 {
                setBGR(x: x, y: y, b: 255, g: 80, r: 20)
            }
        }

        let image = ImageBuffer(width: width, height: height, bgr: data)
        let result = ColorDetector.detectMinimapRegion(in: image, searchWidth: width, searchHeight: height)
        #expect(result.rect == CGRect(x: 40, y: 95, width: 130, height: 90))
    }

    @Test func minimapRegionDetectionPrefersWhiteFrame() {
        let width = 1_056
        let height = 320
        var data = [UInt8](repeating: 110, count: width * height * 3)
        func setBGR(x: Int, y: Int, b: UInt8, g: UInt8, r: UInt8) {
            let index = (y * width + x) * 3
            data[index] = b
            data[index + 1] = g
            data[index + 2] = r
        }
        func setGray(x: Int, y: Int, value: UInt8) {
            setBGR(x: x, y: y, b: value, g: value, r: value)
        }

        for y in 20..<260 {
            for x in 700..<900 {
                setGray(x: x, y: y, value: 35)
            }
        }

        let left = 0
        let top = 0
        let frameWidth = 176
        let frameHeight = 199
        let right = left + frameWidth - 1
        let bottom = top + frameHeight - 1

        let contentLeft = left + max(3, Int((Double(frameWidth) * 0.018).rounded()))
        let contentTop = top + Int((Double(frameHeight) * 0.335).rounded())
        let contentBottomInset = max(5, Int((Double(frameHeight) * 0.052).rounded()))
        let contentWidth = frameWidth - (contentLeft - left) * 2
        let contentHeight = frameHeight - (contentTop - top) - contentBottomInset
        for y in contentTop..<(contentTop + contentHeight) {
            for x in contentLeft..<(contentLeft + contentWidth) {
                setGray(x: x, y: y, value: 28)
            }
        }
        // Bright map artwork just inside the content edge must not be mistaken
        // for another frame row and ratchet the detected region inward.
        for x in contentLeft..<(contentLeft + contentWidth) {
            setGray(x: x, y: contentTop + 3, value: 245)
        }
        for x in left...right {
            setGray(x: x, y: top, value: 245)
            setGray(x: x, y: bottom, value: 245)
        }
        for y in top...bottom {
            setGray(x: left, y: y, value: 245)
            setGray(x: right, y: y, value: 245)
        }
        for y in (contentTop + 16)..<(contentTop + 20) {
            for x in (contentLeft + 45)..<(contentLeft + 49) {
                setBGR(x: x, y: y, b: 0, g: 235, r: 255)
            }
        }
        for y in (contentTop + 34)..<(contentTop + 38) {
            for x in (contentLeft + 86)..<(contentLeft + 90) {
                setBGR(x: x, y: y, b: 255, g: 80, r: 20)
            }
        }

        let image = ImageBuffer(width: width, height: height, bgr: data)
        let result = ColorDetector.detectMinimapRegion(in: image, searchWidth: width, searchHeight: height)
        #expect(result.rect != nil)
        if let rect = result.rect {
            #expect(abs(Int(rect.minX) - contentLeft) <= 2)
            #expect(abs(Int(rect.minY) - contentTop) <= 2)
            #expect(abs(Int(rect.width) - contentWidth) <= 4)
            #expect(abs(Int(rect.height) - contentHeight) <= 4)
        }
    }

    @Test func minimapRegionDetectionIgnoresClippedMacTitleBar() {
        let width = 1_055
        let height = 647
        var data = [UInt8](repeating: 90, count: width * height * 3)
        func setGray(x: Int, y: Int, value: UInt8) {
            let index = (y * width + x) * 3
            data[index] = value
            data[index + 1] = value
            data[index + 2] = value
        }
        func paint(x: Int, y: Int, width: Int, height: Int, value: UInt8) {
            for row in y..<(y + height) {
                for column in x..<(x + width) {
                    setGray(x: column, y: row, value: value)
                }
            }
        }

        // When ScreenCaptureKit retains the macOS title bar, cropping the
        // upper-left search area turns it into a misleading full-width run.
        paint(x: 0, y: 0, width: width, height: 29, value: 235)

        let left = 2
        let right = 180
        let top = 29
        let dividerTop = 86
        let dividerBottom = 98
        let contentTop = dividerBottom + 1
        let bottomBorderTop = 222
        let bottom = 234

        paint(x: left, y: top, width: right - left + 1, height: 2, value: 245)
        paint(x: left, y: top, width: 3, height: bottom - top + 1, value: 245)
        paint(x: right - 2, y: top, width: 3, height: bottom - top + 1, value: 245)
        paint(
            x: left,
            y: dividerTop,
            width: right - left + 1,
            height: dividerBottom - dividerTop + 1,
            value: 245
        )
        paint(
            x: left,
            y: bottomBorderTop,
            width: right - left + 1,
            height: bottom - bottomBorderTop + 1,
            value: 245
        )

        let image = ImageBuffer(width: width, height: height, bgr: data)
        let result = ColorDetector.detectMinimapRegion(in: image)
        #expect(result.rect != nil)
        if let rect = result.rect {
            #expect(abs(Int(rect.minX) - 5) <= 2)
            #expect(abs(Int(rect.minY) - contentTop) <= 1)
            #expect(abs(Int(rect.maxY) - bottomBorderTop) <= 1)
            #expect(rect.minY > 90)
        }
    }

    @Test func minimapRegionDetectionSupportsVariableMapHeight() {
        let width = 1_055
        let height = 520
        var data = [UInt8](repeating: 75, count: width * height * 3)
        func setGray(x: Int, y: Int, value: UInt8) {
            let index = (y * width + x) * 3
            data[index] = value
            data[index + 1] = value
            data[index + 2] = value
        }
        func paint(x: Int, y: Int, width: Int, height: Int, value: UInt8) {
            for row in y..<(y + height) {
                for column in x..<(x + width) {
                    setGray(x: column, y: row, value: value)
                }
            }
        }

        let left = 2
        let right = 180
        let top = 0
        let dividerTop = 58
        let dividerBottom = 66
        let bottomBorderTop = 286
        let bottom = 298

        paint(x: left, y: top, width: right - left + 1, height: 2, value: 245)
        paint(x: left, y: top, width: 3, height: bottom - top + 1, value: 245)
        paint(x: right - 2, y: top, width: 3, height: bottom - top + 1, value: 245)
        paint(
            x: left,
            y: dividerTop,
            width: right - left + 1,
            height: dividerBottom - dividerTop + 1,
            value: 245
        )
        paint(
            x: left,
            y: bottomBorderTop,
            width: right - left + 1,
            height: bottom - bottomBorderTop + 1,
            value: 245
        )

        let image = ImageBuffer(width: width, height: height, bgr: data)
        let result = ColorDetector.detectMinimapRegion(in: image)
        #expect(result.rect != nil)
        if let rect = result.rect {
            #expect(abs(Int(rect.minY) - (dividerBottom + 1)) <= 1)
            #expect(abs(Int(rect.maxY) - bottomBorderTop) <= 1)
            #expect(rect.height > 200)
        }
    }

    @Test func minimapRegionDetectionSearchesInsideManualSelection() {
        let width = 280
        let height = 290
        var data = [UInt8](repeating: 80, count: width * height * 3)
        func paint(x: Int, y: Int, width: Int, height: Int, value: UInt8) {
            for row in y..<(y + height) {
                for column in x..<(x + width) {
                    let index = (row * 280 + column) * 3
                    data[index] = value
                    data[index + 1] = value
                    data[index + 2] = value
                }
            }
        }

        let left = 42
        let right = 220
        let top = 24
        let dividerBottom = 92
        let bottomBorderTop = 216
        let bottom = 228
        paint(x: left, y: top, width: right - left + 1, height: 2, value: 245)
        paint(x: left, y: top, width: 3, height: bottom - top + 1, value: 245)
        paint(x: right - 2, y: top, width: 3, height: bottom - top + 1, value: 245)
        paint(x: left, y: 82, width: right - left + 1, height: 11, value: 245)
        paint(
            x: left,
            y: bottomBorderTop,
            width: right - left + 1,
            height: bottom - bottomBorderTop + 1,
            value: 245
        )

        let result = ColorDetector.detectMinimapRegion(
            in: ImageBuffer(width: width, height: height, bgr: data),
            searchWidth: width,
            searchHeight: height,
            requiresTopLeftAnchor: false
        )
        #expect(result.rect != nil)
        if let rect = result.rect {
            #expect(abs(Int(rect.minX) - (left + 3)) <= 2)
            #expect(abs(Int(rect.minY) - (dividerBottom + 1)) <= 1)
            #expect(abs(Int(rect.maxY) - bottomBorderTop) <= 1)
        }
    }

    @Test func minimapContentValidationRejectsWhiteBorder() {
        let width = 120
        let height = 80
        var data = [UInt8](repeating: 24, count: width * height * 3)
        func setBGR(x: Int, y: Int, b: UInt8, g: UInt8, r: UInt8) {
            let index = (y * width + x) * 3
            data[index] = b
            data[index + 1] = g
            data[index + 2] = r
        }

        for y in 30..<34 {
            for x in 52..<56 {
                setBGR(x: x, y: y, b: 0, g: 235, r: 255)
            }
        }
        let content = ImageBuffer(width: width, height: height, bgr: data)
        #expect(ColorDetector.validateMinimapContent(in: content).isValid)

        for x in 0..<width {
            setBGR(x: x, y: 0, b: 245, g: 245, r: 245)
            setBGR(x: x, y: 1, b: 245, g: 245, r: 245)
            setBGR(x: x, y: height - 2, b: 245, g: 245, r: 245)
            setBGR(x: x, y: height - 1, b: 245, g: 245, r: 245)
        }
        for y in 0..<height {
            setBGR(x: 0, y: y, b: 245, g: 245, r: 245)
            setBGR(x: 1, y: y, b: 245, g: 245, r: 245)
            setBGR(x: width - 2, y: y, b: 245, g: 245, r: 245)
            setBGR(x: width - 1, y: y, b: 245, g: 245, r: 245)
        }
        let framed = ImageBuffer(width: width, height: height, bgr: data)
        let validation = ColorDetector.validateMinimapContent(in: framed)
        #expect(!validation.isValid)
        #expect(validation.maximumBrightEdgeRatio > 0.9)
    }

    @Test func minimapWhiteFrameAcceptsMultipleScalesAndAspectRatios() {
        let cases = [180, 258, 308, 380].map { panelWidth in
            let panelHeight = Int((Double(panelWidth) * 1.13).rounded())
            return (panelWidth, panelWidth * 6, panelHeight + 120, 0)
        } + [
            // Current compact-height, ultra-wide Free Market window whose
            // ScreenCaptureKit frame retains the macOS title bar.
            (138, 1_722, 519, 29),
            // Some maps use a narrower panel at the same ordinary window
            // resolution; panel width is map-dependent, not UI-scale-only.
            (138, 1_055, 647, 29),
        ]

        for (panelWidth, width, height, frameTop) in cases {
            let panelHeight = Int((Double(panelWidth) * 1.13).rounded())
            var data = [UInt8](repeating: 110, count: width * height * 3)

            func setBGR(x: Int, y: Int, b: UInt8, g: UInt8, r: UInt8) {
                let index = (y * width + x) * 3
                data[index] = b
                data[index + 1] = g
                data[index + 2] = r
            }
            func setGray(x: Int, y: Int, value: UInt8) {
                setBGR(x: x, y: y, b: value, g: value, r: value)
            }

            let frameRight = panelWidth - 1
            let frameBottom = frameTop + panelHeight - 1
            for x in 0...frameRight {
                setGray(x: x, y: frameTop, value: 225)
                setGray(x: x, y: frameBottom, value: 225)
            }
            for y in frameTop...frameBottom {
                setGray(x: 0, y: y, value: 225)
                setGray(x: frameRight, y: y, value: 225)
            }

            let expectedX = max(3, Int((Double(panelWidth) * 0.018).rounded()))
            let expectedY = frameTop + Int((Double(panelHeight) * 0.335).rounded())
            let expectedBottomInset = max(
                5,
                Int((Double(panelHeight) * 0.052).rounded())
            )
            let expectedWidth = panelWidth - expectedX * 2
            let expectedHeight =
                panelHeight - (expectedY - frameTop) - expectedBottomInset

            // Time Road is intentionally bright. Only platforms, ropes and
            // markers are dark/colored; darkness must not be a prerequisite.
            for y in expectedY..<(expectedY + expectedHeight) {
                for x in expectedX..<(expectedX + expectedWidth) {
                    setGray(x: x, y: y, value: 238)
                }
            }
            for x in expectedX..<(expectedX + expectedWidth) {
                setGray(x: x, y: expectedY + expectedHeight / 2, value: 55)
            }
            for y in (expectedY + 8)..<(expectedY + expectedHeight - 8) {
                setGray(x: expectedX + expectedWidth / 2, y: y, value: 65)
            }
            for y in (expectedY + 20)..<(expectedY + 24) {
                for x in (expectedX + 30)..<(expectedX + 34) {
                    setBGR(x: x, y: y, b: 0, g: 235, r: 255)
                }
            }

            let image = ImageBuffer(width: width, height: height, bgr: data)
            let result = ColorDetector.detectMinimapRegion(
                in: image,
                searchWidth: width,
                searchHeight: height
            )

            let rect = try? #require(result.rect)
            #expect(abs(Int(rect?.minX ?? -1) - expectedX) <= 1)
            #expect(abs(Int(rect?.minY ?? -1) - expectedY) <= 1)
            #expect(abs(Int(rect?.width ?? -1) - expectedWidth) <= 1)
            #expect(abs(Int(rect?.height ?? -1) - expectedHeight) <= 1)
        }
    }

    @Test func minimapWhiteFrameExcludesScaledVerticalBorders() throws {
        let width = 1_355
        let height = 882
        let frameLeft = 0
        let frameTop = 29
        let frameRight = 181
        let frameBottom = 243
        let dividerTop = 115
        let dividerBottom = 118
        let bottomBorderTop = 240
        let expectedLeft = 5
        let expectedRightExclusive = 177
        let expectedTop = dividerBottom + 1
        let expectedBottomExclusive = bottomBorderTop
        var data = [UInt8](repeating: 110, count: width * height * 3)

        func setBGR(x: Int, y: Int, b: UInt8, g: UInt8, r: UInt8) {
            let index = (y * width + x) * 3
            data[index] = b
            data[index + 1] = g
            data[index + 2] = r
        }
        func setGray(x: Int, y: Int, value: UInt8) {
            setBGR(x: x, y: y, b: value, g: value, r: value)
        }
        func fillHorizontalBand(from startY: Int, through endY: Int) {
            for y in startY...endY {
                for x in frameLeft...frameRight {
                    setGray(x: x, y: y, value: 230)
                }
            }
        }

        fillHorizontalBand(from: frameTop, through: frameTop + 2)
        fillHorizontalBand(from: dividerTop, through: dividerBottom)
        fillHorizontalBand(from: bottomBorderTop, through: frameBottom)
        for y in frameTop...frameBottom {
            for x in frameLeft..<expectedLeft {
                setGray(x: x, y: y, value: 230)
            }
            for x in expectedRightExclusive...frameRight {
                setGray(x: x, y: y, value: 230)
            }
        }
        for y in expectedTop..<expectedBottomExclusive {
            for x in expectedLeft..<expectedRightExclusive {
                setGray(x: x, y: y, value: 24)
            }
        }
        for y in (expectedTop + 35)..<(expectedTop + 39) {
            for x in (expectedLeft + 70)..<(expectedLeft + 74) {
                setBGR(x: x, y: y, b: 0, g: 235, r: 255)
            }
        }

        let image = ImageBuffer(width: width, height: height, bgr: data)
        let result = ColorDetector.detectMinimapRegion(in: image)
        let rect = try #require(result.rect)
        let content = try #require(
            image.cropped(
                x: Int(rect.minX),
                y: Int(rect.minY),
                width: Int(rect.width),
                height: Int(rect.height)
            )
        )
        let validation = ColorDetector.validateMinimapContent(in: content)

        #expect(Int(rect.minX) == expectedLeft)
        #expect(Int(rect.maxX) == expectedRightExclusive)
        #expect(Int(rect.minY) == expectedTop)
        #expect(Int(rect.maxY) == expectedBottomExclusive)
        #expect(validation.isValid)
        #expect(validation.maximumBrightEdgeRatio < 0.25)
    }

    @Test func mapTopologyPersistsAndValidatesRopeConnection() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        var settings = AppSettings.default
        let topology = MapTopology(
            mapName: "苔藓森林小径",
            referenceWidth: 138,
            referenceHeight: 99,
            platforms: [
                MapPlatform(points: [
                    NormalizedMapPoint(x: 0.2, y: 0.5),
                    NormalizedMapPoint(x: 0.8, y: 0.5),
                ]),
            ],
            ropes: [MapRope(x: 0.55, topY: 0.35, bottomY: 0.65)],
            portals: [
                MapPortal(
                    point: NormalizedMapPoint(x: 0.3, y: 0.48),
                    type: .mapExit,
                    destinationMapName: "苔藓森林入口"
                ),
            ]
        )
        settings.mapTopologies = [topology]

        let manager = SettingsManager(settingsDirectory: tempDir)
        manager.save(settings)
        let loaded = manager.load()

        #expect(loaded.mapTopologies == [topology])
        #expect(MapTopologyValidator.messages(for: topology).isEmpty)
    }

    @Test func platformTraceMergesRoundTripIntoSingleSlopedPolyline() {
        let size = CGSize(width: 120, height: 90)
        let xs = Array(stride(from: CGFloat(10), through: 105, by: 2))
        func platformY(_ x: CGFloat) -> CGFloat {
            x <= 55 ? 38 : 38 + (x - 55) * 0.22
        }
        var samples = xs.map { CGPoint(x: $0, y: platformY($0)) }
        samples += xs.reversed().map { CGPoint(x: $0, y: platformY($0) + 0.8) }
        samples += xs.map { CGPoint(x: $0, y: platformY($0) - 0.6) }
        samples.append(CGPoint(x: 60, y: 80))

        let points = PlatformTraceBuilder.buildPolyline(from: samples, canvasSize: size)

        #expect(points.count >= 3)
        #expect(points.count < 15)
        #expect((points.first?.x ?? 1) < 0.12)
        #expect((points.last?.x ?? 0) > 0.85)
        #expect(zip(points, points.dropFirst()).allSatisfy { pair in pair.0.x < pair.1.x })
        #expect(points.allSatisfy { $0.y < 0.75 })
    }

    @Test func legacyMapTopologyWithoutPortalsMigratesToEmptyPortalList() throws {
        let json = """
        {"version":2,"mapName":"旧地图","referenceWidth":120,"referenceHeight":80,"platforms":[],"ropes":[]}
        """
        let topology = try JSONDecoder().decode(MapTopology.self, from: Data(json.utf8))
        #expect(topology.mapName == "旧地图")
        #expect(topology.portals.isEmpty)
    }

    @Test func navigationGraphBuildsWalkClimbApproachAndTeleportEdges() {
        let sourcePortalID = UUID()
        let targetPortalID = UUID()
        let source = MapTopology(
            mapName: "地图甲",
            referenceWidth: 120,
            referenceHeight: 80,
            platforms: [MapPlatform(points: [
                NormalizedMapPoint(x: 0.1, y: 0.7),
                NormalizedMapPoint(x: 0.9, y: 0.7),
            ])],
            ropes: [MapRope(x: 0.5, topY: 0.3, bottomY: 0.7)],
            portals: [MapPortal(
                id: sourcePortalID,
                point: NormalizedMapPoint(x: 0.2, y: 0.68),
                destinationMapName: "地图乙",
                destinationPortalID: targetPortalID
            )]
        )
        let target = MapTopology(
            mapName: "地图乙",
            referenceWidth: 120,
            referenceHeight: 80,
            platforms: [MapPlatform(points: [
                NormalizedMapPoint(x: 0.1, y: 0.6),
                NormalizedMapPoint(x: 0.9, y: 0.6),
            ])],
            portals: [MapPortal(
                id: targetPortalID,
                point: NormalizedMapPoint(x: 0.2, y: 0.58)
            )]
        )

        let graph = MapNavigationGraphBuilder.build(from: [source, target])
        #expect(graph.nodes.contains { $0.kind == .ropeTop })
        #expect(graph.edges.contains { $0.kind == .walk })
        #expect(graph.edges.contains { $0.kind == .climb })
        #expect(graph.edges.contains { $0.kind == .approach })
        #expect(graph.edges.contains { $0.kind == .teleport })
    }

    @Test func navigationGraphSupportsDirectedIntraMapPortalCycle() {
        let ids = [UUID(), UUID(), UUID()]
        let portals = ids.enumerated().map { index, id in
            MapPortal(
                id: id,
                point: NormalizedMapPoint(x: 0.2 + Double(index) * 0.25, y: 0.6),
                type: .intraMap,
                destinationMapName: "循环地图",
                destinationPortalID: ids[(index + 1) % ids.count]
            )
        }
        let map = MapTopology(
            mapName: "循环地图",
            referenceWidth: 120,
            referenceHeight: 80,
            platforms: [MapPlatform(points: [
                NormalizedMapPoint(x: 0.1, y: 0.62),
                NormalizedMapPoint(x: 0.9, y: 0.62),
            ])],
            portals: portals
        )

        let graph = MapNavigationGraphBuilder.build(from: [map])
        let teleportEdges = graph.edges.filter { $0.kind == .teleport }
        #expect(teleportEdges.count == 3)
        #expect(Set(teleportEdges.map(\.from)).count == 3)
        #expect(Set(teleportEdges.map(\.to)).count == 3)
    }

    @Test func navigationGraphBuildsDirectedJumpAndDropEdgesWithExecutionParameters() throws {
        let upper = MapPlatform(points: [
            NormalizedMapPoint(x: 0.1, y: 0.3), NormalizedMapPoint(x: 0.5, y: 0.3),
        ])
        let lower = MapPlatform(points: [
            NormalizedMapPoint(x: 0.35, y: 0.7), NormalizedMapPoint(x: 0.9, y: 0.7),
        ])
        let jump = MapTraversalConnection(
            kind: .jump,
            fromPlatformID: lower.id,
            toPlatformID: upper.id,
            startPoint: NormalizedMapPoint(x: 0.4, y: 0.7),
            landingPoint: NormalizedMapPoint(x: 0.45, y: 0.3),
            direction: .right,
            keyHoldMilliseconds: 350,
            landingTolerance: 0.07
        )
        let drop = MapTraversalConnection(
            kind: .drop,
            fromPlatformID: upper.id,
            toPlatformID: lower.id,
            startPoint: NormalizedMapPoint(x: 0.4, y: 0.3),
            landingPoint: NormalizedMapPoint(x: 0.4, y: 0.7),
            direction: .neutral,
            keyHoldMilliseconds: 150
        )
        let map = MapTopology(
            mapName: "动作地图",
            referenceWidth: 120,
            referenceHeight: 80,
            platforms: [upper, lower],
            traversalConnections: [jump, drop]
        )

        let graph = MapNavigationGraphBuilder.build(from: [map])
        let reloadedMap = try JSONDecoder().decode(MapTopology.self, from: JSONEncoder().encode(map))
        #expect(reloadedMap == map)
        let jumpEdge = graph.edges.first { $0.kind == .jump }
        let dropEdges = graph.edges.filter { $0.kind == .drop && $0.sourceConnectionID == drop.id }
        #expect(jumpEdge?.sourceConnectionID == jump.id)
        #expect(jumpEdge?.direction == .right)
        #expect(jumpEdge?.keyHoldMilliseconds == 350)
        #expect(jumpEdge?.landingTolerance == 0.07)
        #expect(dropEdges.count == 1)
        #expect(dropEdges.first?.sourceConnectionID == drop.id)
        #expect(MapTopologyValidator.messages(for: map).isEmpty == false) // No ropes or portals yet.
        #expect(!MapTopologyValidator.messages(for: map).contains { $0.contains("下落连接") })
    }

    @Test func navigationGraphAutomaticallyDropsOnlyToNearestLowerPlatform() {
        let top = MapPlatform(points: [
            NormalizedMapPoint(x: 0.2, y: 0.2), NormalizedMapPoint(x: 0.8, y: 0.2),
        ])
        let middle = MapPlatform(points: [
            NormalizedMapPoint(x: 0.15, y: 0.5), NormalizedMapPoint(x: 0.85, y: 0.5),
        ])
        let bottom = MapPlatform(points: [
            NormalizedMapPoint(x: 0.1, y: 0.8), NormalizedMapPoint(x: 0.9, y: 0.8),
        ])
        let map = MapTopology(
            mapName: "三层地图",
            referenceWidth: 120,
            referenceHeight: 80,
            platforms: [top, middle, bottom]
        )
        let graph = MapNavigationGraphBuilder.build(from: [map])
        let automaticDrops = graph.edges.filter { $0.kind == .drop && $0.sourceConnectionID == nil }

        #expect(automaticDrops.contains { edge in
            graph.nodes.first(where: { $0.id == edge.from })?.sourceID == top.id
                && graph.nodes.first(where: { $0.id == edge.to })?.sourceID == middle.id
        })
        #expect(!automaticDrops.contains { edge in
            graph.nodes.first(where: { $0.id == edge.from })?.sourceID == top.id
                && graph.nodes.first(where: { $0.id == edge.to })?.sourceID == bottom.id
        })
        #expect(!automaticDrops.contains { edge in
            graph.nodes.first(where: { $0.id == edge.from })?.sourceID == bottom.id
        })
        #expect(automaticDrops.filter { $0.direction == .neutral }.allSatisfy { edge in
            guard let startX = edge.actionStartPoint?.x, let endX = edge.actionEndPoint?.x else { return false }
            return abs(startX - endX) < 0.000001
        })
    }

    @Test func navigationGraphDoesNotGenerateVerticalDropThroughRope() {
        let top = MapPlatform(points: [
            NormalizedMapPoint(x: 0.2, y: 0.25), NormalizedMapPoint(x: 0.8, y: 0.25),
        ])
        let lower = MapPlatform(points: [
            NormalizedMapPoint(x: 0.15, y: 0.7), NormalizedMapPoint(x: 0.85, y: 0.7),
        ])
        let map = MapTopology(
            mapName: "绳索阻挡下跳",
            referenceWidth: 120,
            referenceHeight: 80,
            platforms: [top, lower],
            ropes: [MapRope(x: 0.5, topY: 0.25, bottomY: 0.7)]
        )
        let graph = MapNavigationGraphBuilder.build(from: [map])
        let invalidDrops = graph.edges.filter { edge in
            guard edge.kind == .drop, edge.direction == .neutral,
                  let from = graph.nodes.first(where: { $0.id == edge.from }),
                  let to = graph.nodes.first(where: { $0.id == edge.to }) else { return false }
            return from.sourceID == top.id && to.sourceID == lower.id
        }
        #expect(invalidDrops.isEmpty)
        #expect(graph.edges.contains { $0.kind == .climb })
    }

    @Test func navigationGraphBuildsHumanizedJumpGrabRopeEdge() {
        let platform = MapPlatform(points: [
            NormalizedMapPoint(x: 0.2, y: 0.7), NormalizedMapPoint(x: 0.7, y: 0.7),
        ])
        let rope = MapRope(x: 0.75, topY: 0.3, bottomY: 0.68)
        let map = MapTopology(
            mapName: "抓绳地图",
            referenceWidth: 120,
            referenceHeight: 80,
            platforms: [platform],
            ropes: [rope]
        )
        let graph = MapNavigationGraphBuilder.build(from: [map])
        let edge = graph.edges.first { $0.kind == .jumpGrabRope }

        #expect(edge != nil)
        #expect(edge?.direction == .right)
        #expect(edge?.jumpKeyReleaseMilliseconds == 135)
        #expect(edge?.directionKeyReleaseMilliseconds == 175)
        #expect(edge?.jumpKeyReleaseMilliseconds != edge?.directionKeyReleaseMilliseconds)
        #expect(graph.nodes.first(where: { $0.id == edge?.to })?.sourceID == rope.id)
        #expect((edge?.actionStartPoint?.x ?? 1) < rope.x)
        #expect(abs((edge?.actionStartPoint?.x ?? 0) - rope.x) >= 0.015)
        #expect(abs((edge?.actionEndPoint?.y ?? 1) - (edge?.actionStartPoint?.y ?? 0)) <= 0.065)
    }

    @Test func navigationGraphRejectsJumpGrabWhenRopeIsTooHigh() {
        let reachable = MapPlatform(points: [
            NormalizedMapPoint(x: 0.45, y: 0.46), NormalizedMapPoint(x: 0.8, y: 0.46),
        ])
        let tooLow = MapPlatform(points: [
            NormalizedMapPoint(x: 0.35, y: 0.76), NormalizedMapPoint(x: 0.75, y: 0.76),
        ])
        let rope = MapRope(x: 0.4, topY: 0.2, bottomY: 0.52)
        let map = MapTopology(
            mapName: "有限跳高地图",
            referenceWidth: 120,
            referenceHeight: 80,
            platforms: [reachable, tooLow],
            ropes: [rope]
        )
        let graph = MapNavigationGraphBuilder.build(from: [map])
        let jumpEdges = graph.edges.filter { $0.kind == .jumpGrabRope }
        let sourceIDs = Set(jumpEdges.compactMap { edge in
            graph.nodes.first(where: { $0.id == edge.from })?.sourceID
        })
        #expect(sourceIDs.contains(reachable.id))
        #expect(!sourceIDs.contains(tooLow.id))
    }

    @Test func pathPlannerLocatesPlayerAndPlansRopeRouteWithoutExecuting() {
        let lower = MapPlatform(points: [
            NormalizedMapPoint(x: 0.1, y: 0.7), NormalizedMapPoint(x: 0.7, y: 0.7),
        ])
        let upper = MapPlatform(points: [
            NormalizedMapPoint(x: 0.65, y: 0.3), NormalizedMapPoint(x: 0.95, y: 0.3),
        ])
        let map = MapTopology(
            mapName: "规划地图",
            referenceWidth: 120,
            referenceHeight: 80,
            platforms: [lower, upper],
            ropes: [MapRope(x: 0.7, topY: 0.3, bottomY: 0.68)]
        )
        let graph = MapNavigationGraphBuilder.build(from: [map])
        let current = MapPathPlanner.locateCurrentNode(
            point: NormalizedMapPoint(x: 0.3, y: 0.69),
            topology: map,
            graph: graph
        )
        #expect(current?.sourceID == lower.id)

        let path = current.flatMap {
            MapPathPlanner.shortestPath(
                graph: graph,
                from: $0.id,
                targetSourceID: upper.id,
                targetMapName: map.mapName
            )
        }
        #expect(path != nil)
        #expect(path?.edges.contains { $0.kind == .jumpGrabRope } == true)
        #expect(path?.edges.contains { $0.kind == .climb } == true)
    }

    @Test func pathPlannerPrefersPlatformWhenPlayerOverlapsRopeAtJunction() {
        let platform = MapPlatform(points: [
            NormalizedMapPoint(x: 0.1, y: 0.7), NormalizedMapPoint(x: 0.8, y: 0.7),
        ])
        let rope = MapRope(x: 0.5, topY: 0.3, bottomY: 0.72)
        let map = MapTopology(
            mapName: "交叉点地图",
            referenceWidth: 120,
            referenceHeight: 80,
            platforms: [platform],
            ropes: [rope]
        )
        let graph = MapNavigationGraphBuilder.build(from: [map])
        let node = MapPathPlanner.locateCurrentNode(
            point: NormalizedMapPoint(x: 0.5, y: 0.69),
            topology: map,
            graph: graph
        )
        #expect(node?.sourceID == platform.id)
        #expect(node?.kind == .platformPoint)
    }

    @Test func pathPlannerPrefersRopeWhenHangingNearButNotOnPlatform() {
        let nearbyPlatform = MapPlatform(points: [
            NormalizedMapPoint(x: 0.25, y: 0.54), NormalizedMapPoint(x: 0.75, y: 0.54),
        ])
        let rope = MapRope(x: 0.5, topY: 0.25, bottomY: 0.75)
        let map = MapTopology(
            mapName: "绳索中段地图",
            referenceWidth: 120,
            referenceHeight: 80,
            platforms: [nearbyPlatform],
            ropes: [rope]
        )
        let graph = MapNavigationGraphBuilder.build(from: [map])
        let node = MapPathPlanner.locateCurrentNode(
            point: NormalizedMapPoint(x: 0.505, y: 0.5),
            topology: map,
            graph: graph
        )
        #expect(node?.sourceID == rope.id)
        #expect(node?.kind == .ropeTop || node?.kind == .ropeBottom)
    }

    @Test func pathPlannerReportsIsolatedPlatform() {
        let connected = MapPlatform(points: [
            NormalizedMapPoint(x: 0.1, y: 0.7), NormalizedMapPoint(x: 0.4, y: 0.7),
        ])
        let isolated = MapPlatform(points: [
            NormalizedMapPoint(x: 0.7, y: 0.2), NormalizedMapPoint(x: 0.9, y: 0.2),
        ])
        let map = MapTopology(
            mapName: "孤立地图",
            referenceWidth: 120,
            referenceHeight: 80,
            platforms: [connected, isolated]
        )
        let graph = MapNavigationGraphBuilder.build(from: [map])
        let isolatedIDs = MapPathPlanner.isolatedSourceIDs(in: graph, mapName: map.mapName)
        #expect(isolatedIDs.contains(isolated.id))
    }

    @Test func humanizedWalkTimingSamplesStayInsideConfiguredRanges() {
        let timing = HumanizedWalkTiming(
            reactionMilliseconds: 60...90,
            observationMilliseconds: 110...160,
            settleMilliseconds: 170...210,
            correctionPauseMilliseconds: 220...300
        )
        let reactions = (0..<200).map { _ in timing.sampleReactionMilliseconds() }
        let observations = (0..<200).map { _ in timing.sampleObservationMilliseconds() }
        let settles = (0..<200).map { _ in timing.sampleSettleMilliseconds() }
        let corrections = (0..<200).map { _ in timing.sampleCorrectionPauseMilliseconds() }
        #expect(reactions.allSatisfy { (60...90).contains($0) })
        #expect(observations.allSatisfy { (110...160).contains($0) })
        #expect(settles.allSatisfy { (170...210).contains($0) })
        #expect(corrections.allSatisfy { (220...300).contains($0) })
        #expect(Set(reactions).count > 1)
        #expect(Set(observations).count > 1)
    }

    @Test func humanizedDropTimingSamplesStayInsideConfiguredRanges() {
        let timing = HumanizedDropTiming(
            preparationMilliseconds: 80...120,
            downLeadMilliseconds: 40...70,
            jumpHoldMilliseconds: 60...90,
            releaseGapMilliseconds: 20...50,
            observationMilliseconds: 55...85,
            landingSettleMilliseconds: 130...180
        )
        let ranges = [
            timing.preparationMilliseconds,
            timing.downLeadMilliseconds,
            timing.jumpHoldMilliseconds,
            timing.releaseGapMilliseconds,
            timing.observationMilliseconds,
            timing.landingSettleMilliseconds,
        ]
        for range in ranges {
            let values = (0..<200).map { _ in timing.sample(range) }
            #expect(values.allSatisfy { range.contains($0) })
            #expect(Set(values).count > 1)
        }
        #expect(timing.releaseGapMilliseconds.lowerBound > 0)
    }

    @Test func legacyMapTopologyWithoutTraversalConnectionsMigratesToEmptyList() throws {
        let json = """
        {"version":3,"mapName":"旧地图","referenceWidth":120,"referenceHeight":80,"platforms":[],"ropes":[],"portals":[]}
        """
        let topology = try JSONDecoder().decode(MapTopology.self, from: Data(json.utf8))
        #expect(topology.traversalConnections.isEmpty)
    }

    @Test func ropeTraceMergesUpDownMovementIntoOneRope() {
        let size = CGSize(width: 120, height: 90)
        let ys = Array(stride(from: CGFloat(12), through: 78, by: 2))
        var samples = ys.map { CGPoint(x: 61, y: $0) }
        samples += ys.reversed().map { CGPoint(x: 62, y: $0) }
        samples.append(CGPoint(x: 105, y: 42))

        let rope = RopeTraceBuilder.buildRope(from: samples, canvasSize: size)
        #expect(rope != nil)
        #expect(abs((rope?.x ?? 0) - 0.51) < 0.03)
        #expect((rope?.topY ?? 1) < 0.18)
        #expect((rope?.bottomY ?? 0) > 0.82)
    }

    @Test func minimapSignatureIgnoresMovingColoredMarker() {
        let width = 120
        let height = 80
        var first = [UInt8](repeating: 0, count: width * height * 3)
        for x in 10..<105 {
            let index = (45 * width + x) * 3
            first[index] = 210; first[index + 1] = 210; first[index + 2] = 210
        }
        var second = first
        for y in 20..<24 { for x in 70..<74 {
            let index = (y * width + x) * 3
            second[index] = 0; second[index + 1] = 245; second[index + 2] = 255
        }}
        // Several other-player red dots, including anti-aliased darker edges.
        for center in [(18, 18), (44, 31), (92, 60), (106, 25)] {
            for y in (center.1 - 2)...(center.1 + 2) { for x in (center.0 - 2)...(center.0 + 2) {
                let index = (y * width + x) * 3
                let edge = abs(x - center.0) == 2 || abs(y - center.1) == 2
                second[index] = edge ? 28 : 35
                second[index + 1] = edge ? 45 : 55
                second[index + 2] = edge ? 125 : 240
            }}
        }
        let signature1 = MinimapVisualMatcher.signature(for: ImageBuffer(width: width, height: height, bgr: first))
        let signature2 = MinimapVisualMatcher.signature(for: ImageBuffer(width: width, height: height, bgr: second))
        #expect(MinimapVisualMatcher.matches(signature1, signature2))
        let sameMapComparison = MinimapVisualMatcher.comparison(signature1, signature2)
        #expect(sameMapComparison.isMatch)
        #expect(sameMapComparison.similarityPercentage > 95)

        var different = first
        for x in stride(from: 15, through: 105, by: 10) {
            for y in 12..<70 {
                let index = (y * width + x) * 3
                different[index] = 220; different[index + 1] = 220; different[index + 2] = 220
            }
        }
        let differentSignature = MinimapVisualMatcher.signature(
            for: ImageBuffer(width: width, height: height, bgr: different)
        )
        #expect(!MinimapVisualMatcher.matches(signature1, differentSignature))
        let differentMapComparison = MinimapVisualMatcher.comparison(signature1, differentSignature)
        #expect(!differentMapComparison.isMatch)
        #expect(differentMapComparison.similarityPercentage < sameMapComparison.similarityPercentage)
    }

    @Test func minimapSignatureToleratesOneCellShiftAfterWindowScaling() {
        var original = [UInt8](
            repeating: 0,
            count: MinimapVisualMatcher.columns * MinimapVisualMatcher.rows
        )
        var scaled = original
        for row in 2..<(MinimapVisualMatcher.rows - 2) {
            original[row * MinimapVisualMatcher.columns + 7] = 210
            scaled[row * MinimapVisualMatcher.columns + 8] = 195
        }
        for column in 3..<18 {
            original[10 * MinimapVisualMatcher.columns + column] = 180
            scaled[11 * MinimapVisualMatcher.columns + column] = 170
        }

        #expect(MinimapVisualMatcher.distance(original, scaled) > 6)
        let comparison = MinimapVisualMatcher.comparison(original, scaled)
        #expect(comparison.isMatch)
        #expect(comparison.usesScaleTolerance)
        #expect(comparison.similarityPercentage > 90)
    }

    @Test func minimapSimilarityAtSixtyPercentIsAMatch() {
        let count = MinimapVisualMatcher.columns * MinimapVisualMatcher.rows
        let reference = [UInt8](repeating: 100, count: count)
        let brightnessShifted = [UInt8](repeating: 128, count: count)

        let comparison = MinimapVisualMatcher.comparison(reference, brightnessShifted)

        #expect(comparison.similarityPercentage >= 60)
        #expect(comparison.similarityPercentage < 61)
        #expect(comparison.structuralMismatch == 0)
        #expect(comparison.isMatch)
    }

    @Test func monitorMapMatcherChoosesHighestSimilarityInsteadOfFirstMatch() {
        let width = 120
        let height = 80
        let frame = ImageBuffer(
            width: width,
            height: height,
            bgr: [UInt8](repeating: 100, count: width * height * 3)
        )
        let count = MinimapVisualMatcher.columns * MinimapVisualMatcher.rows
        let lowerSimilarity = MapTopology(
            mapName: "较低相似度",
            referenceWidth: width,
            referenceHeight: height,
            visualSignature: [UInt8](repeating: 108, count: count)
        )
        let higherSimilarity = MapTopology(
            mapName: "最高相似度",
            referenceWidth: width,
            referenceHeight: height,
            visualSignature: [UInt8](repeating: 102, count: count)
        )

        let match = MonitorMapMatcher.match(
            frame: frame,
            maps: [lowerSimilarity, higherSimilarity]
        )

        #expect(match?.mapName == "最高相似度")
    }

    @Test func monitorWindowGeometryDetectsResizeButIgnoresRoundingNoise() {
        #expect(!MonitorWindowGeometry.changed(
            from: CGSize(width: 1280, height: 720),
            to: CGSize(width: 1281, height: 719)
        ))
        #expect(MonitorWindowGeometry.changed(
            from: CGSize(width: 1280, height: 720),
            to: CGSize(width: 1440, height: 810)
        ))
    }

    @Test func runtimeTemplatesArePackagedAndReadable() {
        #expect(TemplatePaths.load(TemplatePaths.marketButton) != nil)
        #expect(TemplatePaths.load(TemplatePaths.marketLogo) != nil)
        #expect(TemplatePaths.load(TemplatePaths.confirmButton) != nil)
        #expect(TemplatePaths.load(TemplatePaths.partyAcceptButton) != nil)
        #expect(TemplatePaths.load(TemplatePaths.partyDeclineButton) != nil)
    }

    @Test @available(macOS 14.0, *)
    func locationClassifierRejectsWeakMarketLogoMatch() {
        let state = MarketButtonDetector.classifyLocation(
            hasMarketButton: true,
            marketLogoConfidence: 0.42
        )

        #expect(state == .monsterMap)
    }

    @Test @available(macOS 14.0, *)
    func locationClassifierAcceptsStrongMarketLogoMatch() {
        let state = MarketButtonDetector.classifyLocation(
            hasMarketButton: true,
            marketLogoConfidence: 0.613
        )

        #expect(state == .market)
    }

    @Test @available(macOS 14.0, *)
    func marketLogoMatcherIncludesCompactWindowScale() {
        #expect(MarketButtonDetector.marketLogoScales.contains(0.55))
        #expect(MarketButtonDetector.marketLogoConfidence == 0.55)
    }

    @Test @available(macOS 14.0, *)
    func locationClassifierRequiresMarketButtonEvidence() {
        let state = MarketButtonDetector.classifyLocation(
            hasMarketButton: false,
            marketLogoConfidence: 0.95
        )

        #expect(state == .unknown)
    }

    @Test func acceleratedTemplateMatcherFindsExactLocation() {
        let templateWidth = 7
        let templateHeight = 5
        var templateData = [UInt8](repeating: 0, count: templateWidth * templateHeight * 3)
        for y in 0..<templateHeight {
            for x in 0..<templateWidth {
                let value = UInt8((x * 31 + y * 47 + x * y * 7) % 255)
                let index = (y * templateWidth + x) * 3
                templateData[index] = value
                templateData[index + 1] = value
                templateData[index + 2] = value
            }
        }
        let template = ImageBuffer(width: templateWidth, height: templateHeight, bgr: templateData)

        let imageWidth = 32
        let imageHeight = 20
        var imageData = [UInt8](repeating: 24, count: imageWidth * imageHeight * 3)
        let expectedX = 13
        let expectedY = 8
        for y in 0..<templateHeight {
            for x in 0..<templateWidth {
                let source = (y * templateWidth + x) * 3
                let destination = ((expectedY + y) * imageWidth + expectedX + x) * 3
                imageData[destination] = templateData[source]
                imageData[destination + 1] = templateData[source + 1]
                imageData[destination + 2] = templateData[source + 2]
            }
        }
        let image = ImageBuffer(width: imageWidth, height: imageHeight, bgr: imageData)
        let result = TemplateMatcher.matchSingleScale(
            image: image,
            template: template,
            scaleX: 1,
            scaleY: 1
        )
        #expect(result?.x == expectedX)
        #expect(result?.y == expectedY)
        #expect((result?.confidence ?? 0) > 0.99)
    }
}
