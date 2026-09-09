/// Escape changes the outcome of one recording, never the saved default.
struct EscapeReleaseGesture {
    private(set) var down = false
    private var cancelOnRelease = false

    mutating func press(recording: Bool) -> Bool {
        guard !down else { return false }
        down = true
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
        cancelOnRelease = false
        return cancel
    }
    mutating func reset() { down = false; cancelOnRelease = false }
}
