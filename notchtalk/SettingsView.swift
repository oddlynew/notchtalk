//
//  SettingsView.swift
//  notchtalk
//

import SwiftUI

struct SettingsView: View {
    @Bindable private var settingsManager = SettingsManager.shared
    @State private var apiKeyInput = ""
    @State private var showAPIKeyField = false
    @State private var saveError: String?
    @State private var showSaveSuccess = false

    var body: some View {
        Form {
            Section {
                apiKeySection
            } header: {
                Text("OpenAI API Key")
            } footer: {
                Text("Your API key is stored securely in the macOS Keychain.")
                    .foregroundStyle(.secondary)
            }

            Section {
                TextEditor(text: $settingsManager.transcriptionPrompt)
                    .frame(minHeight: 60, maxHeight: 120)
                    .font(.body)
            } header: {
                Text("Transcription Prompt")
            } footer: {
                Text("Optional prompt to guide the transcription. Example: \"This is a technical discussion about Swift programming.\"")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Auto-paste after transcription", isOn: $settingsManager.autoPasteEnabled)
            } header: {
                Text("Behavior")
            } footer: {
                Text("Automatically paste the transcription at your cursor position.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 450, height: 400)
        .navigationTitle("Notchtalk Settings")
    }

    @ViewBuilder
    private var apiKeySection: some View {
        if settingsManager.hasAPIKey && !showAPIKeyField {
            HStack {
                SecureField("API Key", text: .constant("••••••••••••••••••••"))
                    .disabled(true)

                Button("Change") {
                    showAPIKeyField = true
                    apiKeyInput = ""
                }
                .buttonStyle(.bordered)
            }
        } else {
            HStack {
                SecureField("Enter your OpenAI API key", text: $apiKeyInput)
                    .textFieldStyle(.roundedBorder)

                Button(settingsManager.hasAPIKey ? "Update" : "Save") {
                    saveAPIKey()
                }
                .buttonStyle(.borderedProminent)
                .disabled(apiKeyInput.isEmpty)

                if showAPIKeyField {
                    Button("Cancel") {
                        showAPIKeyField = false
                        apiKeyInput = ""
                        saveError = nil
                    }
                    .buttonStyle(.bordered)
                }
            }
        }

        if let error = saveError {
            Text(error)
                .foregroundStyle(.red)
                .font(.caption)
        }

        if showSaveSuccess {
            Text("API key saved successfully")
                .foregroundStyle(.green)
                .font(.caption)
        }
    }

    private func saveAPIKey() {
        do {
            try settingsManager.saveAPIKey(apiKeyInput)
            apiKeyInput = ""
            showAPIKeyField = false
            saveError = nil
            showSaveSuccess = true

            Task {
                try? await Task.sleep(for: .seconds(2))
                showSaveSuccess = false
            }
        } catch {
            saveError = error.localizedDescription
        }
    }
}

struct SettingsWindowController {
    private static var windowController: NSWindowController?

    @MainActor
    static func show() {
        if let existingController = windowController, let window = existingController.window, window.isVisible {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let settingsView = SettingsView()
        let hostingController = NSHostingController(rootView: settingsView)

        let window = NSWindow(contentViewController: hostingController)
        window.title = "Notchtalk Settings"
        window.styleMask = [.titled, .closable]
        window.center()
        window.setFrameAutosaveName("SettingsWindow")

        let controller = NSWindowController(window: window)
        windowController = controller

        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

#Preview {
    SettingsView()
}
