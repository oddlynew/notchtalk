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
    mutating func release(now: TimeInterval = ProcessInfo.processInfo.systemUptime, holdDelay: TimeInterval = 0.8) -> Action {
        let action: Action = down && allowed ? ((holding || now - pressedAt >= holdDelay) ? .endHold : .none) : .none
        cancel()
        return action
    }
    mutating func cancel() { down = false; holding = false; allowed = false }
}

// Two clean taps of one modifier: press and release, nothing else in between, both quickly.
struct DoubleTapGesture {
    private var pressedAt: TimeInterval?
    private var tappedAt: TimeInterval?
    private let window: TimeInterval = 0.35

    /// `key` is false for every other key or modifier, which breaks the sequence.
    mutating func handle(key: Bool, down: Bool, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard key else { self = DoubleTapGesture(); return false }
        if down {
            if let tappedAt, now - tappedAt <= window {
                self = DoubleTapGesture()
                return true
            }
            tappedAt = nil
            pressedAt = now
        } else {
            tappedAt = pressedAt.flatMap { now - $0 <= window ? now : nil }
            pressedAt = nil
        }
        return false
    }
}
