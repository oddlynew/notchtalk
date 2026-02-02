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
    private var _rightCommandDownTime: Date?
    private var _otherKeyPressed = false

    var onToggle: (@MainActor () -> Void)?

    private init() {}

    @MainActor
    func start() {
        guard AXIsProcessTrusted() else {
            requestAccessibilityPermission()
            print("Accessibility permission not granted")
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
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        if type == .keyDown {
            lock.lock()
            _otherKeyPressed = true
            lock.unlock()
            return Unmanaged.passUnretained(event)
        }

        if type == .flagsChanged {
            let flags = event.flags
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

            let isRightCommand = keyCode == 54
            let commandPressed = flags.contains(.maskCommand)

            if isRightCommand {
                lock.lock()
                if commandPressed {
                    _rightCommandDownTime = Date()
                    _otherKeyPressed = false
                    lock.unlock()
                } else {
                    let downTime = _rightCommandDownTime
                    let otherPressed = _otherKeyPressed
                    _rightCommandDownTime = nil
                    _otherKeyPressed = false
                    lock.unlock()

                    if let downTime = downTime, !otherPressed {
                        let duration = Date().timeIntervalSince(downTime)
                        if duration < 0.4 {
                            DispatchQueue.main.async { [weak self] in
                                self?.onToggle?()
                            }
                        }
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
