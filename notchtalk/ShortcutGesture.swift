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
