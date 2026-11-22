import Foundation
import Testing
@testable import DisplayCore

@Suite("Settings")
@MainActor
struct SettingsTests {
    private func makeRecord(_ tag: Int, snapshot: DisplaySnapshot = Fixture.lenovo()) -> StoredRecord {
        StoredRecord(record: DisplayRecord(
            tag: DisplayTag(tag), identifiers: snapshot.identifiers, matchRule: .automatic, systemName: snapshot.name,
            kind: .external, isAppleMade: false, firstSeen: Date(timeIntervalSince1970: 0), lastSeen: Date(timeIntervalSince1970: 0)
        ))
    }

    @Test("Unset is different from a value that equals the default")
    func unsetIsNotDefault() throws {
        var document = SettingsDocument()
        document.displays.append(makeRecord(1))
        #expect(document.effectiveSettings(for: DisplayTag(1)).restoreFloor == SettingsDefaults.restoreFloor)
        #expect(document.displays[0].settings.display.restoreFloor == nil)

        document.displays[0].settings.display.restoreFloor = SettingsDefaults.restoreFloor
        let data = try DocumentCoding.encoder().encode(document)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("restoreFloor"), "an explicit value is written even when it equals the default")
        #expect(!text.contains("hardwareFloor"), "unset values are not written")
    }

    @Test("Record wins over model, model over global, global over the built-in default")
    func scopesLayer() {
        var document = SettingsDocument()
        document.displays.append(makeRecord(1))
        document.displays.append(makeRecord(2))
        let tag1 = DisplayTag(1), tag2 = DisplayTag(2)

        document.global.displays.restoreFloor = 0.2
        #expect(document.effectiveSettings(for: tag1).restoreFloor == 0.2)

        document.models[ModelKey(vendor: 0x30AE, model: 0x62A2).description] = {
            var model = DisplaySettings()
            model.restoreFloor = 0.3
            model.keyboardControl = false
            return model
        }()
        #expect(document.effectiveSettings(for: tag1).restoreFloor == 0.3)
        #expect(document.effectiveSettings(for: tag2).keyboardControl == false, "a model setting reaches every unit of the model")

        document.displays[0].settings.display.restoreFloor = 0.4
        #expect(document.effectiveSettings(for: tag1).restoreFloor == 0.4)
        #expect(document.effectiveSettings(for: tag2).restoreFloor == 0.3)
    }

    @Test("The document round-trips, including values keyed by control and controller")
    func roundTrip() throws {
        var document = SettingsDocument()
        document.nextTag = 5
        var stored = makeRecord(4)
        stored.settings.values = [.brightness: 0.6, .volume: 0.25]
        stored.settings.ownerOverrides = [.hardwareBrightness: .ddc]
        var ddc = ControllerSettings()
        ddc.startupPolicy = .writeStored
        ddc.detected = [.hardwareBrightness: ControlCapability(rawMaximum: 255)]
        var control = ControlSettings()
        control.codeOverride = [0x10, 0x12]
        ddc.controls = [.hardwareBrightness: control]
        stored.settings.controllers = [.ddc: ddc]
        stored.settings.inputs = [InputEntry(id: "usb-c", label: "USB-C", rawValue: 27, alternateCommand: true)]
        stored.settings.previousMode = Fixture.mode(2560, 1440)
        document.displays = [stored]
        document.pendingRestores = [PendingRestore(tag: DisplayTag(4), feature: "brightness", value: 0.6, queuedAt: Date(timeIntervalSince1970: 1_800_000_000))]

        let data = try DocumentCoding.encoder().encode(document)
        let decoded = try DocumentCoding.decoder().decode(SettingsDocument.self, from: data)
        #expect(decoded == document)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let first = try #require((object["displays"] as? [[String: Any]])?.first?["settings"] as? [String: Any])
        #expect((first["values"] as? [String: Any])?["brightness"] as? Double == 0.6, "values are stored as a dictionary keyed by control name")
        #expect((first["controllers"] as? [String: Any])?["ddc"] != nil)
    }

    @Test("A file with missing sections still loads, and tags are never handed out twice")
    func tolerantDecoding() throws {
        let json = #"{"displays":[{"record":{"tag":7,"identifiers":{},"matchRule":"automatic","systemName":"Old","kind":"external","isAppleMade":false,"firstSeen":"2026-01-01T00:00:00Z","lastSeen":"2026-01-01T00:00:00Z"},"settings":{}}],"nextTag":2}"#
        let document = try DocumentCoding.decoder().decode(SettingsDocument.self, from: Data(json.utf8))
        #expect(document.displays.count == 1)
        #expect(document.nextTag == 8)
        #expect(document.schemaVersion == 1)
    }

    @Test("Writes are debounced into one, and flush writes at once")
    func debouncedSave() {
        let scheduler = ManualScheduler()
        let persistence = MemoryPersistence()
        let store = SettingsStore(persistence: persistence, scheduler: scheduler, saveDelay: 0.5)
        for step in 1...20 {
            store.update { $0.global.displays.restoreFloor = Double(step) / 100 }
            scheduler.advance(by: 0.05)
        }
        #expect(persistence.saveCount == 0)
        scheduler.advance(by: 0.5)
        #expect(persistence.saveCount == 1)

        store.update { $0.global.retentionDays = 30 }
        store.flush()
        #expect(persistence.saveCount == 2)
        scheduler.advance(by: 5)
        #expect(persistence.saveCount == 2, "flush cancels the pending write")

        store.update { $0.global.retentionDays = 30 }
        scheduler.advance(by: 5)
        #expect(persistence.saveCount == 2, "an update that changes nothing is not written")
    }

    @Test("Settings from a newer version are left alone and defaults are used")
    func newerVersionIsNotOverwritten() throws {
        var document = SettingsDocument()
        document.schemaVersion = 99
        document.global.retentionDays = 7
        let persistence = MemoryPersistence(try DocumentCoding.encoder().encode(document))
        let store = SettingsStore(persistence: persistence, scheduler: ManualScheduler())
        #expect(store.loadOutcome == .newerVersion(99))
        #expect(store.document.retentionDays == SettingsDefaults.retentionDays)
    }

    @Test("An unreadable file falls back to defaults")
    func unreadableFile() {
        let store = SettingsStore(persistence: MemoryPersistence(Data("not json".utf8)), scheduler: ManualScheduler())
        if case .unreadable = store.loadOutcome {} else { Issue.record("expected an unreadable outcome") }
        #expect(store.document == SettingsDocument())
    }

    @Test("Files are written atomically into a private folder and read back")
    func filePersistence() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("display16x-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let persistence = FilePersistence(url: folder.appendingPathComponent("settings.json"))
        #expect(try persistence.load() == nil)
        try persistence.save(Data("{}".utf8))
        #expect(try persistence.load() == Data("{}".utf8))
        let permissions = try FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions] as? Int
        #expect(permissions == 0o700)
    }

    @Test("The recovery store is separate, writes at once, and survives a settings reset")
    func recoveryStore() {
        let recoveryPersistence = MemoryPersistence()
        let recovery = RecoveryStore(persistence: recoveryPersistence)
        recovery.update { $0.unconfirmedModes[DisplayTag(1)] = Fixture.mode(1920, 1080) }
        #expect(recoveryPersistence.saveCount == 1)

        let reloaded = RecoveryStore(persistence: recoveryPersistence)
        #expect(reloaded.document.unconfirmedModes[DisplayTag(1)] == Fixture.mode(1920, 1080))

        // Nothing in the settings store knows about the recovery file.
        let settings = SettingsStore(persistence: MemoryPersistence(), scheduler: ManualScheduler())
        settings.update { $0 = SettingsDocument() }
        #expect(RecoveryStore(persistence: recoveryPersistence).document.unconfirmedModes.count == 1)
    }
}
