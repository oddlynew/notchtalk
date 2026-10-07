//
//  SettingsView.swift
//  notchtalk
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The app window: Transcripts and Settings.
@MainActor
struct SettingsView: View {
    enum SettingsTab: Hashable {
        case transcripts
        case settings
    }

    enum DiagnosticsExportFormat {
        case json
        case csv

        var buttonTitle: String {
            switch self {
            case .json: "Export JSON"
            case .csv: "Export CSV"
            }
        }

        var fileExtension: String {
            switch self {
            case .json: "json"
            case .csv: "csv"
            }
        }

        var contentType: UTType {
            switch self {
            case .json: .json
            case .csv: .commaSeparatedText
            }
        }
    }

    @Bindable private var settingsManager = SettingsManager.shared
    @Bindable private var diagnosticsStore = TranscriptionDiagnosticsStore.shared
    private let call = CallRecorder.shared
    @State private var apiKeyInput = ""
    @State private var showAPIKeyField = false
    @State private var saveError: String?
    @State private var showSaveSuccess = false
    @State private var selectedTab: SettingsTab
    @State private var exportFeedbackMessage: String?
    @State private var exportFeedbackIsError = false

    init(tab: SettingsTab = .transcripts) {
        _selectedTab = State(initialValue: tab)
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Label("Notchtalk", systemImage: "waveform")
                    .font(.system(size: 15, weight: .semibold))
                    .padding(.horizontal, 10).padding(.bottom, 18)
                navigationItem("Transcripts", icon: "list.bullet", tab: .transcripts)
                navigationItem("Settings", icon: "gearshape", tab: .settings)
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 18).frame(width: 170).background(.quaternary.opacity(0.35))
            Divider()
            Group {
                switch selectedTab {
                case .transcripts: TranscriptsView()
                case .settings: settingsTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .tint(NotchtalkStyle.accent)
        .frame(width: 820, height: 640)
        .navigationTitle("Notchtalk")
    }

    private func navigationItem(_ title: String, icon: String, tab: SettingsTab) -> some View {
        Button { selectedTab = tab } label: {
            Label(title, systemImage: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(selectedTab == tab ? NotchtalkStyle.accent : .primary)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 10).padding(.vertical, 7)
                .background(selectedTab == tab ? NotchtalkStyle.accent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
        .accessibilityAddTraits(selectedTab == tab ? .isSelected : [])
    }

    private var settingsTab: some View {
        Form {
            Section("Transcription") {
                Picker("Provider", selection: $settingsManager.transcriptionProvider) {
                    ForEach(TranscriptionProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .pickerStyle(.segmented)

                if let model = settingsManager.transcriptionProvider.localModel {
                    LabeledContent("\(model.name) on this Mac") {
                        localModelSection(model.installer)
                    }
                    .id(model)
                    .onAppear { model.installer.refresh() }
                    Text(localModelFooter(model)).font(.caption).foregroundStyle(.secondary)
                } else {
                    apiKeySection
                }

                if settingsManager.transcriptionProvider == .openAI {
                    DisclosureGroup("Prompt (optional)") {
                        TextEditor(text: $settingsManager.transcriptionPrompt)
                            .frame(minHeight: 60, maxHeight: 120)
                            .font(.body)
                        Text("Guides OpenAI, for example: “A technical discussion about Swift.”")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } else if settingsManager.transcriptionProvider == .elevenLabs {
                    Toggle("Label speakers (Speaker 1, Speaker 2, …)", isOn: $settingsManager.elevenLabsSpeakerRecognitionEnabled)
                    Toggle("Match speakers from my ElevenLabs library", isOn: $settingsManager.elevenLabsSpeakerLibraryRecognitionEnabled)
                        .disabled(!settingsManager.elevenLabsSpeakerRecognitionEnabled)
                }
            }

            Section("After recording") {
                Toggle("Paste at the cursor", isOn: $settingsManager.autoPasteEnabled)
                    .help("Off: the transcript only goes to the clipboard.")
                Toggle("Press Enter after pasting", isOn: $settingsManager.sendWithEnter)
                    .help("Sends the message when a held shortcut is released.")
            }

            Section("Listening in the background") {
                Toggle(isOn: $settingsManager.ambientEnabled) {
                    Text("Ambient")
                    Text("Keeps the last minutes in memory only, nothing is saved or sent until you ask.")
                }
                Picker("Keep the last", selection: $settingsManager.ambientWindowMinutes) {
                    ForEach([5, 10, 20], id: \.self) { minutes in
                        Text("\(minutes) min").tag(minutes)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(!settingsManager.ambientEnabled)
                Toggle(isOn: $settingsManager.callRecordingEnabled) {
                    Text("Record calls")
                    Text("Both sides of iPhone and FaceTime calls on this Mac.")
                }
                if settingsManager.callRecordingEnabled, let problem = call.problem {
                    Text(problem).font(.caption).foregroundStyle(.orange)
                }
            }

            Section("Shortcut") {
                Text("Right ⌘: tap to start and tap again to stop, or hold to talk. Esc cancels.")
                DisclosureGroup("Timing") {
                    VStack(alignment: .leading) {
                        LabeledContent("Hold mode after", value: "\(Int(settingsManager.startHoldDelay * 1000)) ms")
                        Slider(value: $settingsManager.startHoldDelay, in: 0.2...2, step: 0.05)
                            .accessibilityLabel("Hold mode threshold")
                    }
                    Picker("Non-hold mode", selection: $settingsManager.continuousFinishMode) {
                        ForEach(ContinuousFinishMode.allCases) { mode in
                            Text(mode.title).tag(mode)
                        }
                    }
                    VStack(alignment: .leading) {
                        LabeledContent("Hold to send for", value: "\(Int(settingsManager.finishHoldDelay * 1000)) ms")
                        Slider(value: $settingsManager.finishHoldDelay, in: 0.2...2, step: 0.05)
                            .accessibilityLabel("Hold to send threshold")
                    }
                }
                Toggle("Double-tap right ⌥ transcribes the ambient window", isOn: $settingsManager.ambientHotKeyEnabled)
                    .disabled(!settingsManager.ambientEnabled)
            }

            Section("Data") {
                Text("Audio is kept for 24 hours, then deleted.")
                HStack(spacing: 8) {
                    if let exportFeedbackMessage {
                        Text(exportFeedbackMessage)
                            .font(.caption)
                            .foregroundStyle(exportFeedbackIsError ? .red : .secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Button(DiagnosticsExportFormat.json.buttonTitle) { exportDiagnostics(.json) }
                    Button(DiagnosticsExportFormat.csv.buttonTitle) { exportDiagnostics(.csv) }
                }
                .disabled(diagnosticsStore.entries.isEmpty)
            }
        }
        .formStyle(.grouped)
        .onChange(of: settingsManager.transcriptionProvider) {
            showAPIKeyField = false
            apiKeyInput = ""
            saveError = nil
            showSaveSuccess = false
        }
    }

    private func exportDiagnostics(_ format: DiagnosticsExportFormat) {
        let entries = diagnosticsStore.entries
        guard !entries.isEmpty else {
            setExportFeedback(message: "No diagnostics to export.", isError: true)
            return
        }

        let panel = NSSavePanel()
        panel.allowedContentTypes = [format.contentType]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = defaultExportFilename(fileExtension: format.fileExtension)
        panel.title = format.buttonTitle
        panel.message = "Export \(entries.count) diagnostics entries."

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        do {
            let data: Data
            switch format {
            case .json:
                data = try makeJSONExport(entries: entries)
            case .csv:
                data = makeCSVExport(entries: entries).data(using: .utf8) ?? Data()
            }

            try data.write(to: url, options: .atomic)
            setExportFeedback(message: "Exported \(entries.count) entries to \(url.lastPathComponent).", isError: false)
        } catch {
            setExportFeedback(message: "Export failed: \(error.localizedDescription)", isError: true)
        }
    }

    private func defaultExportFilename(fileExtension: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        return "notchtalk_diagnostics_\(formatter.string(from: Date())).\(fileExtension)"
    }

    private func makeJSONExport(entries: [TranscriptionDiagnosticsEntry]) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(entries)
    }

    private func makeCSVExport(entries: [TranscriptionDiagnosticsEntry]) -> String {
        let header = [
            "id",
            "status",
            "created_at",
            "updated_at",
            "audio_filename",
            "provider",
            "model",
            "speaker_recognition_enabled",
            "retained_audio_filename",
            "retained_audio_expires_at",
            "prompt_provided",
            "retry_count",
            "output_character_count",
            "error_message",
            "transcript_text",
            "logs"
        ].joined(separator: ",")

        let rows = entries.map { entry in
            let logs = entry.logs.map { event in
                let timestamp = event.timestamp.formatted(date: .abbreviated, time: .standard)
                return "[\(timestamp) \(event.level.rawValue.uppercased())] \(event.message)"
            }.joined(separator: " | ")

            let columns: [String] = [
                entry.id.uuidString,
                entry.status.rawValue,
                ISO8601DateFormatter().string(from: entry.createdAt),
                ISO8601DateFormatter().string(from: entry.updatedAt),
                entry.sourceAudioFilename,
                (entry.provider ?? .openAI).rawValue,
                entry.model ?? entry.provider?.fixedModel ?? "",
                String(entry.speakerRecognitionEnabled ?? false),
                entry.retainedAudioFilename ?? "",
                entry.retainedAudioExpiresAt.map { ISO8601DateFormatter().string(from: $0) } ?? "",
                String(entry.promptProvided),
                String(entry.retryCount),
                entry.outputCharacterCount.map(String.init) ?? "",
                entry.errorMessage ?? "",
                entry.transcriptText ?? "",
                logs
            ]
            return columns.map { csvEscaped($0) }.joined(separator: ",")
        }

        return ([header] + rows).joined(separator: "\n")
    }

    private func csvEscaped(_ value: String) -> String {
        if value.contains(",") || value.contains("\"") || value.contains("\n") {
            return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return value
    }

    private func setExportFeedback(message: String, isError: Bool) {
        exportFeedbackMessage = message
        exportFeedbackIsError = isError

        Task {
            try? await Task.sleep(for: .seconds(4))
            if exportFeedbackMessage == message {
                exportFeedbackMessage = nil
            }
        }
    }

    private func localModelFooter(_ model: LocalModel) -> String {
        switch model {
        case .parakeet:
            "Audio never leaves this Mac, with no key or bill. The first install downloads about 2.8 GB; needs Apple silicon."
        case .phonon2:
            "Audio never leaves this Mac, with no key or bill. The first install downloads about 1.4 GB; fast, but it garbles German."
        }
    }

    @ViewBuilder
    private func localModelSection(_ installer: LocalModelInstaller) -> some View {
        switch installer.state {
        case .installed:
            Label("Installed", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .installing(let step):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(step)
            }
        case .notInstalled, .failed:
            HStack {
                Text("Not installed")
                Spacer()
                Button("Download and install") { installer.install() }
                    .buttonStyle(.borderedProminent)
            }
            if case .failed(let message) = installer.state {
                Text(message)
                    .foregroundStyle(.red)
                    .font(.caption)
            }
        }
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
                SecureField("Enter your \(settingsManager.transcriptionProvider.displayName) API key", text: $apiKeyInput)
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
            try settingsManager.saveAPIKey(apiKeyInput, for: settingsManager.transcriptionProvider)
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
    static func show(tab: SettingsView.SettingsTab = .transcripts) {
        if let existingController = windowController, let window = existingController.window, window.isVisible {
            (window.contentViewController as? NSHostingController<SettingsView>)?.rootView = SettingsView(tab: tab)
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hostingController = NSHostingController(rootView: SettingsView(tab: tab))

        let window = NSWindow(contentViewController: hostingController)
        window.title = "Notchtalk"
        window.styleMask = [.titled, .closable]
        window.center()
        window.setFrameAutosaveName("SettingsWindow")

        let controller = NSWindowController(window: window)
        windowController = controller

        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

#if DEBUG
#Preview {
    SettingsView()
}
#endif
