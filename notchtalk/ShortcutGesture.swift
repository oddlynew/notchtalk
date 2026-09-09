// Pure gesture transitions; the event tap owns the one-shot 800 ms timer.
struct ShortcutGesture {
    enum Action { case none, toggle, endHold }
    private(set) var down = false
    private(set) var holding = false
    private var allowed = false

    mutating func press(allowed: Bool) -> Bool {
        guard !down else { return false }
        down = true
        self.allowed = allowed
        return allowed
    }
    mutating func threshold() -> Bool {
        guard down && allowed && !holding else { return false }
        holding = true
        return true
    }
    mutating func release() -> Action {
        let action: Action = down && allowed ? (holding ? .endHold : .toggle) : .none
        cancel()
        return action
    }
    mutating func cancel() { down = false; holding = false; allowed = false }
}
