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
    private var holdTimer: DispatchWorkItem?

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

        let eventMask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
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
            holdTimer?.cancel()
            lock.unlock()
            if wasHolding { DispatchQueue.main.async { [weak self] in self?.onCancel?() } }
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        if type == .keyDown || (type == .flagsChanged && keyCode != 54) {
            lock.lock()
            let wasHolding = gesture.down
            gesture.cancel()
            holdTimer?.cancel()
            lock.unlock()
            if keyCode == 53 {
                DispatchQueue.main.async { [weak self] in self?.onCancel?() }
            } else if wasHolding {
                DispatchQueue.main.async { [weak self] in self?.onChordCancel?() }
            }
        } else if type == .flagsChanged && keyCode == 54 {
            // Device-specific flags distinguish right Command from a held left Command.
            let pressed = event.flags.rawValue & UInt64(NX_DEVICERCMDKEYMASK) != 0
            lock.lock()
            if pressed {
                let modifiers = event.flags.intersection([.maskShift, .maskControl, .maskAlternate])
                if gesture.press(allowed: modifiers.isEmpty) {
                    DispatchQueue.main.async { [weak self] in self?.onToggle?() }
                    let timer = DispatchWorkItem { [weak self] in
                        guard let self else { return }
                        self.lock.lock()
                        _ = self.gesture.threshold()
                        self.lock.unlock()
                    }
                    holdTimer = timer
                    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(800), execute: timer)
                }
                lock.unlock()
            } else {
                holdTimer?.cancel()
                let action = gesture.release()
                lock.unlock()
                DispatchQueue.main.async { [weak self] in
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
