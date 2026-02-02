//
//  HotKeyManager.swift
//  notchtalk
//

import Cocoa
import Carbon

@MainActor
final class HotKeyManager {
    static let shared = HotKeyManager()

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var rightCommandDownTime: Date?
    private var otherKeyPressed = false

    var onToggle: (() -> Void)?

    private init() {}

    func start() {
        guard AXIsProcessTrusted() else {
            requestAccessibilityPermission()
            return
        }

        let eventMask: CGEventMask = (1 << CGEventType.flagsChanged.rawValue) | (1 << CGEventType.keyDown.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { proxy, type, event, refcon in
                guard let refcon = refcon else { return Unmanaged.passRetained(event) }
                let manager = Unmanaged<HotKeyManager>.fromOpaque(refcon).takeUnretainedValue()
                return manager.handleEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("Failed to create event tap")
            return
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    private nonisolated func handleEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .keyDown {
            Task { @MainActor in
                self.otherKeyPressed = true
            }
            return Unmanaged.passRetained(event)
        }

        if type == .flagsChanged {
            let flags = event.flags
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

            let isRightCommand = keyCode == 54
            let commandPressed = flags.contains(.maskCommand)

            Task { @MainActor in
                if isRightCommand {
                    if commandPressed {
                        self.rightCommandDownTime = Date()
                        self.otherKeyPressed = false
                    } else {
                        if let downTime = self.rightCommandDownTime,
                           !self.otherKeyPressed {
                            let duration = Date().timeIntervalSince(downTime)
                            if duration < 0.3 {
                                self.onToggle?()
                            }
                        }
                        self.rightCommandDownTime = nil
                        self.otherKeyPressed = false
                    }
                }
            }
        }

        return Unmanaged.passRetained(event)
    }

    private func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }
}
