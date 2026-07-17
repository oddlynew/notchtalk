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
            if !appController.hasAccessibilityPermission {
                Text("Accessibility Permission Required")
                    .font(.headline)
                Button("Grant Permission...") {
                    appController.openAccessibilitySettings()
                }
                Divider()
            }

            if !appController.hasMicrophonePermission {
                Text("Microphone Permission Required")
                    .font(.headline)
                Button("Grant Permission...") {
                    appController.requestMicrophonePermission()
                }
                Divider()
            }

            Button("Settings...") {
                SettingsWindowController.show()
            }
            .keyboardShortcut(",")

            Divider()

            Button("About Notchtalk") {
                appController.showAbout()
            }

            Divider()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }
}

@MainActor
@Observable
final class AppController {
    private let stateManager = NotchStateManager.shared
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
            self?.stateManager.toggle()
        }
        HotKeyManager.shared.onCancel = { [weak self] in
            guard let self else { return }
            switch self.stateManager.state {
            case .recording, .processing:
                self.stateManager.cancel()
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
        alert.informativeText = "Press Right ⌘ to start/stop recording.\nPress Esc to cancel recording/transcription.\nIf Auto-paste is enabled, Notchtalk pastes at your cursor without overwriting your clipboard. Otherwise it copies to the clipboard."
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
