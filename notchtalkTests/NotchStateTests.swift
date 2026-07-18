import Foundation
import Testing
@testable import notchtalk

struct NotchStateTests {
    @Test("Escape requires two presses inside the confirmation window")
    func doublePressConfirmationGate() {
        var gate = DoublePressConfirmationGate()
        let start = Date(timeIntervalSince1970: 1_000)

        #expect(gate.registerPress(now: start, interval: 2.5) == false)
        #expect(gate.registerPress(now: start.addingTimeInterval(2.4), interval: 2.5) == true)

        #expect(gate.registerPress(now: start.addingTimeInterval(10), interval: 2.5) == false)
        #expect(gate.registerPress(now: start.addingTimeInterval(13), interval: 2.5) == false)
    }
}
