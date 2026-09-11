/// Escape changes the outcome of one recording, never the saved default.
struct EscapeReleaseGesture {
    private(set) var down = false
    // Ownership lasts through key-up, even if Command already finished the recording.
    private(set) var capturesEvents = false
    private var cancelOnRelease = false

    mutating func press(recording: Bool) -> Bool {
        guard !down else { return false }
        down = true
        capturesEvents = recording
        cancelOnRelease = recording
        return recording
    }
    mutating func commandReleased() -> Bool {
        guard down && cancelOnRelease else { return false }
        cancelOnRelease = false
        return true
    }
    mutating func release() -> Bool {
        let cancel = down && cancelOnRelease
        down = false
        capturesEvents = false
        cancelOnRelease = false
        return cancel
    }
    mutating func cancelPendingAction() { cancelOnRelease = false }
    mutating func reset() { down = false; capturesEvents = false; cancelOnRelease = false }
}
