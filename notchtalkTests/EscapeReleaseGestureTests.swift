import Testing
@testable import notchtalk

struct EscapeReleaseGestureTests {
    @Test func interruptedGestureStillOwnsItsKeyUp() {
        var escape = EscapeReleaseGesture()
        #expect(escape.press(recording: true))
        escape.cancelPendingAction()
        #expect(escape.capturesEvents)
        #expect(!escape.release())
        #expect(!escape.capturesEvents)
    }

    @Test func capturedPressIncludesRepeatsAndReleaseAfterFinishing() {
        var escape = EscapeReleaseGesture()
        #expect(escape.press(recording: true))
        #expect(escape.capturesEvents)
        #expect(escape.commandReleased())
        // Finishing without Enter starts processing before Escape is released.
        #expect(!escape.press(recording: false))
        #expect(escape.capturesEvents)
        #expect(!escape.release())
        #expect(!escape.capturesEvents)
    }

    @Test func captureDoesNotStartHalfwayThroughAnotherAppsPress() {
        var escape = EscapeReleaseGesture()
        #expect(!escape.press(recording: false))
        #expect(!escape.capturesEvents)
        // A recording starts while Escape is held by the foreground app.
        #expect(!escape.press(recording: true))
        #expect(!escape.capturesEvents)
        #expect(!escape.release())
        #expect(escape.press(recording: true))
        #expect(escape.capturesEvents)
        #expect(escape.release())
        #expect(!escape.capturesEvents)
    }

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
