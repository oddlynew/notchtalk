import Testing
@testable import notchtalk

struct EscapeReleaseGestureTests {
    @Test func releaseOrderAndIsolation() {
        var escape = EscapeReleaseGesture()
        // Escape first: cancellation happens on release, never on repeated down.
        #expect(escape.press(recording: true))
        #expect(!escape.press(recording: true))
        #expect(escape.release())
        #expect(!escape.commandReleased())
        #expect(!escape.release())
        // Command first: finish without sending; late Escape release is inert.
        #expect(escape.press(recording: true))
        #expect(escape.commandReleased())
        #expect(!escape.commandReleased())
        #expect(!escape.press(recording: false))
        #expect(!escape.release())
        // Escape pressed after transcription started cannot cancel it.
        #expect(!escape.press(recording: false))
        #expect(!escape.release())
        // A subsequent recording gets a fresh override.
        #expect(escape.press(recording: true))
        #expect(escape.release())
        #expect(escape.press(recording: true))
        escape.reset()
        #expect(!escape.release())
    }
}
