import Foundation
import Testing
@testable import DisplayCore

@Suite("Log")
struct LogTests {
    @Test("A burst of debug lines does not push out the lines a bug report needs")
    func debugBurstKeepsTheRest() {
        let center = LogCenter(capacity: 5, debugCapacity: 3)
        center.setVerbose(true)
        center.log(.info, category: "core", "display connected")
        center.log(.notice, category: "core", "restore failed")
        for index in 1...50 { center.log(.debug, category: "ddc", "write \(index)") }
        center.log(.info, category: "core", "after wake")

        let messages = center.recent().map(\.message)
        #expect(messages == ["display connected", "restore failed", "write 48", "write 49", "write 50", "after wake"])
    }

    @Test("Each kind of line is bounded on its own, and the order logged is kept")
    func bounded() {
        let center = LogCenter(capacity: 2, debugCapacity: 2)
        center.setVerbose(true)
        center.log(.info, category: "core", "one")
        center.log(.debug, category: "ddc", "a")
        center.log(.info, category: "core", "two")
        center.log(.debug, category: "ddc", "b")
        center.log(.error, category: "core", "three")
        center.log(.debug, category: "ddc", "c")

        #expect(center.recent().map(\.message) == ["two", "b", "three", "c"])
    }

    @Test("Debug lines are kept only when verbose logging is on")
    func debugNeedsVerbose() {
        let center = LogCenter()
        center.log(.debug, category: "ddc", "hidden")
        center.log(.info, category: "core", "shown")
        #expect(center.recent().map(\.message) == ["shown"])
    }
}
