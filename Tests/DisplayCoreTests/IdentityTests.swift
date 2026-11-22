import Foundation
import Testing
@testable import DisplayCore

@Suite("Identity matching")
struct IdentityMatcherTests {
    private func record(_ tag: Int, from snapshot: DisplaySnapshot, rule: MatchRule = .automatic) -> DisplayRecord {
        DisplayRecord(
            tag: DisplayTag(tag), identifiers: snapshot.identifiers, matchRule: rule, systemName: snapshot.name,
            kind: snapshot.kind, isAppleMade: false, firstSeen: Date(timeIntervalSince1970: 0), lastSeen: Date(timeIntervalSince1970: 0)
        )
    }

    @Test("The automatic rule keeps matching after the system UUID and display ID change")
    func automaticSurvivesUUIDChange() {
        let saved = record(1, from: Fixture.lenovo())
        let later = Fixture.lenovo(id: SystemDisplayID(9), uuid: "00000000-AAAA-BBBB-CCCC-000000000000", port: "dcpext0")
        let outcome = IdentityMatcher.match(records: [saved], snapshots: [later])
        #expect(outcome.bound == [SystemDisplayID(9): DisplayTag(1)])
        #expect(outcome.unmatched.isEmpty)
    }

    @Test("Different monitors never share a record")
    func differentMonitorsStayApart() {
        let saved = record(1, from: Fixture.lenovo())
        let outcome = IdentityMatcher.match(records: [saved], snapshots: [Fixture.lg()])
        #expect(outcome.bound.isEmpty)
        #expect(outcome.unmatched.count == 1)
    }

    @Test("Identical monitors are told apart by UUID first")
    func identicalMonitorsUseUUID() {
        let left = Fixture.lenovo(id: SystemDisplayID(4), uuid: "UUID-LEFT", port: "dcpext0")
        let right = Fixture.lenovo(id: SystemDisplayID(5), uuid: "UUID-RIGHT", port: "dcpext1")
        let records = [record(1, from: left), record(2, from: right)]
        // The system hands out new display IDs and the ports swap. UUIDs still tell them apart.
        let seenRight = Fixture.lenovo(id: SystemDisplayID(11), uuid: "UUID-RIGHT", port: "dcpext0")
        let seenLeft = Fixture.lenovo(id: SystemDisplayID(12), uuid: "UUID-LEFT", port: "dcpext1")
        let outcome = IdentityMatcher.match(records: records, snapshots: [seenRight, seenLeft])
        #expect(outcome.bound[SystemDisplayID(11)] == DisplayTag(2))
        #expect(outcome.bound[SystemDisplayID(12)] == DisplayTag(1))
    }

    @Test("Identical monitors fall back to the port when the UUIDs changed")
    func identicalMonitorsUsePort() {
        let left = Fixture.lenovo(id: SystemDisplayID(4), uuid: "UUID-LEFT", port: "dcpext0")
        let right = Fixture.lenovo(id: SystemDisplayID(5), uuid: "UUID-RIGHT", port: "dcpext1")
        let records = [record(1, from: left), record(2, from: right)]
        let seenRight = Fixture.lenovo(id: SystemDisplayID(21), uuid: "NEW-A", port: "dcpext1")
        let seenLeft = Fixture.lenovo(id: SystemDisplayID(22), uuid: "NEW-B", port: "dcpext0")
        let outcome = IdentityMatcher.match(records: records, snapshots: [seenRight, seenLeft])
        #expect(outcome.bound[SystemDisplayID(21)] == DisplayTag(2))
        #expect(outcome.bound[SystemDisplayID(22)] == DisplayTag(1))
    }

    @Test("A display without EDID identifiers is only recognized by UUID")
    func weakIdentityNeedsUUID() {
        var weak = DisplaySnapshot(systemID: SystemDisplayID(7), identifiers: DisplayIdentifiers(systemUUID: "WEAK-1", vendor: 0, model: 0), name: "Display")
        let saved = record(1, from: weak)
        #expect(IdentityMatcher.match(records: [saved], snapshots: [weak]).bound.count == 1)
        weak.identifiers.systemUUID = "WEAK-2"
        #expect(IdentityMatcher.match(records: [saved], snapshots: [weak]).bound.isEmpty)
    }

    @Test("Explicit rules bind on exactly what they name")
    func explicitRules() {
        let original = Fixture.lenovo()
        let movedPort = Fixture.lenovo(uuid: "OTHER", port: "dcpext0")
        #expect(IdentityMatcher.score(record: record(1, from: original, rule: .uuidOnly), snapshot: movedPort) == nil)
        #expect(IdentityMatcher.score(record: record(1, from: original, rule: .uuidOnly), snapshot: original) != nil)
        #expect(IdentityMatcher.score(record: record(1, from: original, rule: .identifiersOnly), snapshot: movedPort) != nil)
        #expect(IdentityMatcher.score(record: record(1, from: original, rule: .identifiersWithPort), snapshot: movedPort) == nil)
        #expect(IdentityMatcher.score(record: record(1, from: original, rule: .identifiersWithPort), snapshot: original) != nil)
        #expect(IdentityMatcher.score(record: record(1, from: original, rule: .fullEDID), snapshot: movedPort) != nil)
        var otherEDID = original
        otherEDID.identifiers.edidHash = "changed"
        #expect(IdentityMatcher.score(record: record(1, from: original, rule: .fullEDID), snapshot: otherEDID) == nil)
    }

    @Test("EDID fields are read from a captured block")
    func parsesCapturedEDID() throws {
        // First 128 bytes of the EDID the Lenovo P32p-20 returned on 22 November 2026, with the
        // serial number text and the manufacture date replaced by made-up ones.
        let hex = "00ffffffffffff0030aea262010101010a1e010380462778eae5a5ae4f43ab260c5054a10800d100d1c0b30081c081809500a9c081004dd000a0f0703e8030203500b9882100001a000000fd00174c1ea03c000a202020202020000000fc004c454e20503332702d32300a20000000ff004c454e30303030310a2020202001a8"
        let bytes = stride(from: 0, to: hex.count, by: 2).map { offset -> UInt8 in
            let start = hex.index(hex.startIndex, offsetBy: offset)
            return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
        }
        let info = try #require(EDIDInfo(bytes: bytes))
        #expect(info.vendor == 0x30AE)
        #expect(info.manufacturerCode == "LEN")
        #expect(info.product == 0x62A2)
        #expect(info.serialNumber == 0x0101_0101)
        #expect(info.productName == "LEN P32p-20")
        #expect(info.serialText == "LEN00001")
        #expect(info.manufactureYear == 2020)
        #expect(info.manufactureWeek == 10)
        #expect(EDIDInfo(bytes: Array(bytes.dropFirst())) == nil)
    }
}

@Suite("Display registry")
@MainActor
struct RegistryTests {
    @Test("New displays get increasing tags, and a tag is never reused")
    func tagsAreStableAndNeverReused() async {
        let rig = Rig()
        rig.plug(Fixture.lenovo())
        rig.plug(Fixture.lg())
        await rig.start()
        let lenovo = rig.tag(Fixture.lenovoID)
        let lg = rig.tag(Fixture.lgID)
        #expect(Set([lenovo, lg]) == [DisplayTag(1), DisplayTag(2)])

        rig.unplug(Fixture.lgID)
        await rig.reconfigure()
        #expect(rig.registry.state(of: lg) == .remembered)
        #expect(rig.registry.forget(lg).error == nil)
        #expect(rig.registry.record(for: lg) == nil)

        // The same monitor comes back as a new record with a new tag.
        rig.plug(Fixture.lg())
        await rig.reconfigure()
        #expect(rig.tag(Fixture.lgID) == DisplayTag(3))
    }

    @Test("A reconnect with a new system ID and UUID lands on the same record")
    func reconnectKeepsRecord() async {
        let rig = Rig()
        rig.plug(Fixture.lenovo())
        await rig.start()
        let tag = rig.tag(Fixture.lenovoID)
        rig.settings.updateRecord(tag) { $0.display.restoreFloor = 0.3 }

        rig.unplug(Fixture.lenovoID)
        await rig.reconfigure()
        #expect(rig.events.contains(.displayRemoved(tag)))

        rig.plug(Fixture.lenovo(id: SystemDisplayID(42), uuid: "A-NEW-UUID"))
        await rig.reconfigure()
        #expect(rig.tag(SystemDisplayID(42)) == tag)
        #expect(rig.settings.effective(tag).restoreFloor == 0.3)
        #expect(rig.registry.record(for: tag)?.identifiers.systemUUID == "A-NEW-UUID")
    }

    @Test("The placeholder display reported during wake is ignored")
    func placeholderIsIgnored() async {
        let rig = Rig()
        rig.plug(Fixture.lenovo())
        await rig.start()
        var placeholder = DisplaySnapshot(systemID: SystemDisplayID(99), identifiers: DisplayIdentifiers(systemUUID: "GENERIC"), name: "Display")
        placeholder.isPlaceholder = true
        rig.inventory.displays.append(placeholder)
        await rig.reconfigure()
        #expect(rig.registry.records.count == 1)
        #expect(rig.registry.liveDisplay(for: SystemDisplayID(99)) == nil)
    }

    @Test("Forget refuses a connected display, reset keeps identity, transfer replaces")
    func operations() async {
        let rig = Rig()
        rig.plug(Fixture.lenovo())
        rig.plug(Fixture.lg())
        await rig.start()
        let lenovo = rig.tag(Fixture.lenovoID)
        let lg = rig.tag(Fixture.lgID)

        #expect(rig.registry.forget(lenovo).error == .stillConnected)
        #expect(rig.registry.forget(DisplayTag(77)).error == .unknownDisplay)

        rig.registry.rename(lenovo, to: "  Desk  ")
        #expect(rig.registry.record(for: lenovo)?.displayName == "Desk")
        rig.settings.updateRecord(lenovo) {
            $0.display.keyboardControl = false
            $0.values[.contrast] = 0.4
        }
        rig.settings.updateRecord(lg) { $0.display.restoreFloor = 0.5 }

        #expect(rig.registry.transferSettings(from: lenovo, to: lg).error == nil)
        #expect(rig.settings.recordSettings(lg).display.keyboardControl == false)
        #expect(rig.settings.recordSettings(lg).display.restoreFloor == nil, "transfer replaces, it does not merge")
        #expect(rig.settings.recordSettings(lg).values[.contrast] == 0.4)

        rig.registry.clearValues(lg)
        #expect(rig.settings.recordSettings(lg).values.isEmpty)
        #expect(rig.settings.recordSettings(lg).display.keyboardControl == false, "clearing values leaves configuration alone")

        rig.registry.reset(lenovo)
        #expect(rig.settings.recordSettings(lenovo) == RecordSettings())
        #expect(rig.registry.record(for: lenovo)?.tag == lenovo)
        #expect(rig.registry.record(for: lenovo)?.customName == "Desk")
    }

    @Test("Records unseen for the retention period are removed, connected ones never")
    func retention() async {
        let rig = Rig()
        rig.plug(Fixture.lenovo())
        rig.plug(Fixture.lg())
        await rig.start()
        let lg = rig.tag(Fixture.lgID)
        rig.unplug(Fixture.lgID)
        await rig.reconfigure()

        rig.scheduler.advance(by: 89 * 86_400)
        #expect(rig.registry.pruneExpired().isEmpty)
        rig.scheduler.advance(by: 2 * 86_400)
        #expect(rig.registry.pruneExpired() == [lg])
        #expect(rig.registry.records.map(\.tag) == [rig.tag(Fixture.lenovoID)])
    }

    @Test("The default match rule applies only to displays never seen before")
    func defaultRuleOnlyForNewDisplays() async {
        let rig = Rig()
        rig.plug(Fixture.lenovo())
        await rig.start()
        let lenovo = rig.tag(Fixture.lenovoID)
        rig.settings.update { $0.global.defaultMatchRule = .uuidOnly }
        rig.plug(Fixture.lg())
        await rig.reconfigure()
        #expect(rig.registry.record(for: lenovo)?.matchRule == .automatic)
        #expect(rig.registry.record(for: rig.tag(Fixture.lgID))?.matchRule == .uuidOnly)
    }
}
