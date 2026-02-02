//
//  notchtalkApp.swift
//  notchtalk
//
//  Created by Alex Gogl on 02.02.26.
//

import SwiftUI

@main
struct notchtalkApp: App {
    @State private var appController = AppController()

    var body: some Scene {
        MenuBarExtra("Notchtalk", systemImage: "mic.fill") {
            Button("About Notchtalk") {
                appController.showAbout()
            }
            Divider()
            Button("Open Accessibility Settings") {
                appController.openAccessibilitySettings()
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
    private let stateManager = NotchStateManager()
    private var windowController: NotchWindowController?

    init() {
        windowController = NotchWindowController(stateManager: stateManager)
        windowController?.setup()

        HotKeyManager.shared.onToggle = { [weak self] in
            self?.stateManager.toggle()
        }
        HotKeyManager.shared.start()

        observeStateChanges()
    }

    private func observeStateChanges() {
        Task { [weak self] in
            var previousState: AppState?
            while !Task.isCancelled {
                guard let self else { return }
                let currentState = stateManager.state
                if currentState != previousState {
                    if currentState == .idle {
                        windowController?.hide()
                    } else {
                        windowController?.show()
                    }
                    previousState = currentState
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
    }

    func showAbout() {
        let alert = NSAlert()
        alert.messageText = "Notchtalk"
        alert.informativeText = "Press Right ⌘ to start/stop recording.\nTranscription will be copied to clipboard."
        alert.alertStyle = .informational
        alert.runModal()
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
