//
//  HotKeyManager.swift
//  notchtalk
//

import Cocoa
import Carbon

final class HotKeyManager: @unchecked Sendable {
    static let shared = HotKeyManager()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private let lock = NSLock()
    private var gesture = ShortcutGesture()
    private var escapeGesture = EscapeReleaseGesture()
    private var holdTimer: DispatchWorkItem?
    private var currentHoldDelay: TimeInterval = 0.8

    var onEscapeHeld: (@MainActor () -> Void)?
    var onFinishWithoutSending: (@MainActor () -> Void)?
    var onHoldActivated: (@MainActor () -> Void)?
    var onRelease: (@MainActor () -> Void)?
    var onToggle: (@MainActor () -> Void)?
    var onChordCancel: (@MainActor () -> Void)?
    var onHoldEnd: (@MainActor () -> Void)?
    var onCancel: (@MainActor () -> Void)?

    private init() {}

    @MainActor
    func start() {
        guard AXIsProcessTrusted() else {
            requestAccessibilityPermission()
            print("Accessibility permission not granted")
            return
        }

        guard eventTap == nil else {
            return
        }

        let eventMask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: { proxy, type, event, refcon in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                let manager = Unmanaged<HotKeyManager>.fromOpaque(refcon).takeUnretainedValue()
                return manager.handleEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("Failed to create event tap - check Accessibility permissions")
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        print("Event tap started successfully")
    }

    func stop() {
        lock.lock()
        gesture.cancel()
        escapeGesture.reset()
        holdTimer?.cancel()
        lock.unlock()
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    private func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            lock.lock()
            let wasHolding = gesture.down
            gesture.cancel()
            escapeGesture.reset()
            holdTimer?.cancel()
            lock.unlock()
            if wasHolding { DispatchQueue.main.async { [weak self] in self?.onCancel?() } }
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        if event.getIntegerValueField(.eventSourceUserData) == ClipboardService.syntheticEventTag {
            return Unmanaged.passUnretained(event)
        }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        if keyCode == 53 {
            if type == .keyDown {
                let recording = MainActor.assumeIsolated { NotchStateManager.shared.state == .recording }
                if escapeGesture.press(recording: recording) {
                    MainActor.assumeIsolated { onEscapeHeld?() }
                }
            } else if type == .keyUp && escapeGesture.release() {
                lock.lock()
                gesture.cancel()
                holdTimer?.cancel()
                lock.unlock()
                MainActor.assumeIsolated {
                    if NotchStateManager.shared.state == .recording { onCancel?() }
                }
            }
            return Unmanaged.passUnretained(event)
        }
        if type == .keyDown || (type == .flagsChanged && keyCode != 54) {
            lock.lock()
            let wasHolding = gesture.down
            gesture.cancel()
            holdTimer?.cancel()
            lock.unlock()
            if wasHolding {
                DispatchQueue.main.async { [weak self] in self?.onChordCancel?() }
            }
        } else if type == .flagsChanged && keyCode == 54 {
            // Device-specific flags distinguish right Command from a held left Command.
            let pressed = event.flags.rawValue & UInt64(NX_DEVICERCMDKEYMASK) != 0
            lock.lock()
            if pressed {
                let modifiers = event.flags.intersection([.maskShift, .maskControl, .maskAlternate])
                if gesture.press(allowed: modifiers.isEmpty) {
                    currentHoldDelay = MainActor.assumeIsolated { SettingsManager.shared.startHoldDelay }
                    DispatchQueue.main.async { [weak self] in self?.onToggle?() }
                    let timer = DispatchWorkItem { [weak self] in
                        guard let self else { return }
                        self.lock.lock()
                        let activated = self.gesture.threshold()
                        self.lock.unlock()
                        if activated { MainActor.assumeIsolated { self.onHoldActivated?() } }
                    }
                    holdTimer = timer
                    DispatchQueue.main.asyncAfter(deadline: .now() + currentHoldDelay, execute: timer)
                }
                lock.unlock()
            } else {
                holdTimer?.cancel()
                let finishWithoutSending = gesture.down && escapeGesture.commandReleased()
                let action = gesture.release(holdDelay: currentHoldDelay)
                lock.unlock()
                DispatchQueue.main.async { [weak self] in
                    if finishWithoutSending {
                        self?.onFinishWithoutSending?()
                        return
                    }
                    self?.onRelease?()
                    switch action {
                    case .endHold: self?.onHoldEnd?()
                    case .none: break
                    }
                }
            }
        }

        return Unmanaged.passUnretained(event)
    }

    @MainActor
    private func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }
}
