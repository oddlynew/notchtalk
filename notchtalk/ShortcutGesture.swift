import Foundation

// Pure gesture transitions; the event tap owns the one-shot 800 ms timer.
struct ShortcutGesture {
    enum Action { case none, endHold }
    private(set) var down = false
    private(set) var holding = false
    private var allowed = false
    private var pressedAt: TimeInterval = 0

    mutating func press(allowed: Bool, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard !down else { return false }
        down = true
        pressedAt = now
        self.allowed = allowed
        return allowed
    }
    mutating func threshold() -> Bool {
        guard down && allowed && !holding else { return false }
        holding = true
        return true
    }
    /// A slow tap just past a short hold delay is not a dictation; ending it would drop everything said next.
    static let minimumHold: TimeInterval = 1

    mutating func release(now: TimeInterval = ProcessInfo.processInfo.systemUptime, holdDelay: TimeInterval = 0.8) -> Action {
        let held = now - pressedAt
        let action: Action = down && allowed && held >= max(holdDelay, Self.minimumHold) ? .endHold : .none
        cancel()
        return action
    }
    mutating func cancel() { down = false; holding = false; allowed = false }
}

// Two clean taps of one modifier: press and release, nothing else in between, both quickly.
// Fires on the second release, so a second press that turns into a chord (Option+L for @) never counts.
struct DoubleTapGesture {
    private var pressedAt: TimeInterval?
    private var tappedAt: TimeInterval?
    private var secondPress = false
    private let window: TimeInterval = 0.35

    /// `key` is false for every other key or modifier, which breaks the sequence.
    mutating func handle(key: Bool, down: Bool, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard key else { self = DoubleTapGesture(); return false }
        if down {
            secondPress = tappedAt.map { now - $0 <= window } ?? false
            tappedAt = nil
            pressedAt = now
            return false
        }
        let quick = pressedAt.map { now - $0 <= window } ?? false
        if quick && secondPress {
            self = DoubleTapGesture()
            return true
        }
        tappedAt = quick ? now : nil
        pressedAt = nil
        secondPress = false
        return false
    }
}

// Right Command twice: the second press within 0.4 s of the press that started a recording pastes the
// last transcript instead of finishing. Held as long as the finish gesture, the paste also sends Enter.
struct PasteGesture {
    static let window: TimeInterval = 0.4
    private var startedAt: TimeInterval?
    private(set) var deadline: TimeInterval?
    var pending: Bool { deadline != nil }

    mutating func recordingStarted(now: TimeInterval = ProcessInfo.processInfo.systemUptime) { startedAt = now }
    /// True when this press is the second tap; the caller drops the first tap's recording.
    mutating func secondPress(now: TimeInterval = ProcessInfo.processInfo.systemUptime, holdDelay: TimeInterval) -> Bool {
        guard let startedAt, now - startedAt <= Self.window else { return false }
        self.startedAt = nil
        deadline = now + holdDelay
        return true
    }
    /// Whether the paste sends Enter, or nil when no paste is waiting.
    mutating func release(now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool? {
        guard let deadline else { return nil }
        self.deadline = nil
        return now >= deadline
    }
    /// Another key before the second press: that press finishes the recording as before.
    mutating func interrupt() { startedAt = nil }
    mutating func cancel() { startedAt = nil; deadline = nil }
}
