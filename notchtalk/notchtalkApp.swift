//
//  notchtalkApp.swift
//  notchtalk
//
//  Created by Alex Gogl on 02.02.26.
//

import SwiftUI

@main
@MainActor
struct notchtalkApp: App {
    @State private var appController = AppController()

    var body: some Scene {
        MenuBarExtra("Notchtalk", systemImage: appController.menuBarIcon) {
            NotchtalkMenu(controller: appController)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
@Observable
final class AppController {
    private let stateManager = NotchStateManager.shared
    private var gestureStartedRecording = false
    private var windowController: NotchWindowController?
    private(set) var hasAccessibilityPermission = false
    private(set) var hasMicrophonePermission = false

    var menuBarIcon: String {
        if !hasAccessibilityPermission || !hasMicrophonePermission {
            return "exclamationmark.triangle.fill"
        }
        return "mic.fill"
    }

    init() {
        windowController = NotchWindowController(stateManager: stateManager)
        windowController?.setup()

        HotKeyManager.shared.onToggle = { [weak self] in
            guard let self else { return }
            if self.stateManager.state == .recording {
                self.gestureStartedRecording = false
                self.stateManager.beginFinishGesture()
            } else {
                self.stateManager.toggle()
                self.gestureStartedRecording = self.stateManager.state == .recording
            }
        }
        HotKeyManager.shared.onHoldActivated = { [weak self] in
            guard let self, self.gestureStartedRecording, self.stateManager.state == .recording else { return }
            self.stateManager.isHoldRecording = true
        }
        HotKeyManager.shared.onEscapeHeld = { [weak self] in
            guard let self else { return }
            self.stateManager.noSendForRecording = true
            // Stop the continuous finish timer, so Escape can safely modify release.
            self.stateManager.abandonFinishGesture()
        }
        HotKeyManager.shared.onFinishWithoutSending = { [weak self] in
            guard let self, self.stateManager.state == .recording else { return }
            self.gestureStartedRecording = false
            self.stateManager.stopRecording(submitAfterPaste: false)
        }
        HotKeyManager.shared.onRelease = { [weak self] in
            self?.stateManager.releaseFinishGesture()
        }
        HotKeyManager.shared.onChordCancel = { [weak self] in
            guard let self else { return }
            if self.stateManager.finishProgress != nil {
                self.stateManager.abandonFinishGesture()
                return
            }
            guard self.gestureStartedRecording else { return }
            self.gestureStartedRecording = false
            self.stateManager.cancel()
        }
        HotKeyManager.shared.onHoldEnd = { [weak self] in
            guard let self, self.gestureStartedRecording, self.stateManager.state == .recording else { return }
            self.gestureStartedRecording = false
            self.stateManager.stopRecording(submitAfterPaste: SettingsManager.shared.sendWithEnter && !self.stateManager.noSendForRecording)
        }
        HotKeyManager.shared.onCancel = { [weak self] in
            guard let self else { return }
            switch self.stateManager.state {
            case .recording, .processing:
                self.stateManager.cancel(reason: "Escape key")
            default:
                break
            }
        }

        checkAndStartHotKey()
        checkMicrophonePermission()
        observeStateChanges()
    }

    private func checkAndStartHotKey() {
        hasAccessibilityPermission = AXIsProcessTrusted()
        HotKeyManager.shared.start()

        if !hasAccessibilityPermission {
            Task {
                while !AXIsProcessTrusted() {
                    try? await Task.sleep(for: .seconds(1))
                }
                hasAccessibilityPermission = true
                HotKeyManager.shared.start()
            }
        }
    }

    private func checkMicrophonePermission() {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            hasMicrophonePermission = true
        case .notDetermined:
            hasMicrophonePermission = false
        case .denied, .restricted:
            hasMicrophonePermission = false
        @unknown default:
            hasMicrophonePermission = false
        }
    }

    func requestMicrophonePermission() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            Task { @MainActor [weak self] in
                self?.hasMicrophonePermission = granted
            }
        }
    }

    private func observeStateChanges() {
        func observe() {
            withObservationTracking {
                _ = stateManager.state
            } onChange: { [weak self] in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if stateManager.state == .idle {
                        windowController?.hide()
                    } else {
                        windowController?.show()
                    }
                    observe()
                }
            }
        }
        observe()

        if stateManager.state != .idle {
            windowController?.show()
        }
    }

    func showAbout() {
        let alert = NSAlert()
        alert.messageText = "Notchtalk"
        alert.informativeText = "Press Right ⌘ to start immediately. Release within 0.8 seconds to keep recording; hold longer and release to finish. Tap again and release to transcribe, or hold again for 0.8 seconds to transcribe and send.\nRelease Escape before right Command to cancel recording. Release right Command while holding Escape to transcribe without sending.\nIf Auto-paste is enabled, Notchtalk pastes at your cursor without overwriting your clipboard. Otherwise it copies to the clipboard."
        alert.alertStyle = .informational
        alert.runModal()
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}

import AVFoundation
