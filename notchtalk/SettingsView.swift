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
    @State private var showPrompt = false
    @State private var showTiming = false

    init(tab: SettingsTab = .transcripts) {
        _selectedTab = State(initialValue: tab)
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                navigationItem("Transcripts", icon: "list.bullet", tab: .transcripts)
                navigationItem("Settings", icon: "gearshape", tab: .settings)
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 16).frame(width: 150)
            .background(.black.opacity(0.025))
            .overlay(alignment: .trailing) { NotchtalkStyle.line.frame(width: 1) }
            Group {
                switch selectedTab {
                case .transcripts: TranscriptsView()
                case .settings: settingsTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .font(.system(size: 13))
        .foregroundStyle(NotchtalkStyle.ink)
        .background(NotchtalkStyle.panel)
        .tint(NotchtalkStyle.accent)
        .frame(width: 820, height: 640)
        .navigationTitle("Notchtalk")
    }

    private func navigationItem(_ title: String, icon: String, tab: SettingsTab) -> some View {
        Button { selectedTab = tab } label: {
            Label(title, systemImage: icon)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(selectedTab == tab ? NotchtalkStyle.accent : NotchtalkStyle.ink)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 9).padding(.vertical, 7)
                .background(selectedTab == tab ? NotchtalkStyle.accentSoft : .clear, in: RoundedRectangle(cornerRadius: 8))
                .contentShape(Rectangle())
        }.buttonStyle(.plain)
        .accessibilityAddTraits(selectedTab == tab ? .isSelected : [])
    }

    private var settingsTab: some View {
        ScrollView {
            VStack(spacing: 14) {
                SettingGroup("Transcription") {
                    SettingRow(first: true) {
                        Text("Provider")
                        Spacer()
                        SegmentedChoice(options: TranscriptionProvider.allCases.map { ($0, $0.displayName) }, selection: $settingsManager.transcriptionProvider)
                    }
                    if let model = settingsManager.transcriptionProvider.localModel {
                        SettingRow {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(model.name) on this Mac")
                                Text(localModelFooter(model)).font(.system(size: 11)).foregroundStyle(NotchtalkStyle.muted)
                            }
                            Spacer()
                            localModelSection(model.installer)
                        }
                        .id(model)
                        .onAppear { model.installer.refresh() }
                    } else {
                        apiKeySection
                    }
                    if settingsManager.transcriptionProvider == .openAI {
                        SettingRow {
                            Text("Prompt ") + Text("(optional)").font(.system(size: 11)).foregroundColor(NotchtalkStyle.muted)
                            Spacer()
                            Button(showPrompt ? "Done" : settingsManager.transcriptionPrompt.isEmpty ? "Add ›" : "Edit ›") { showPrompt.toggle() }
                                .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(NotchtalkStyle.muted)
                        }
                        if showPrompt {
                            SettingRow {
                                VStack(alignment: .leading, spacing: 4) {
                                    TextEditor(text: $settingsManager.transcriptionPrompt)
                                        .font(.system(size: 12)).scrollContentBackground(.hidden)
                                        .padding(4).background(NotchtalkStyle.chip, in: RoundedRectangle(cornerRadius: 7))
                                        .frame(minHeight: 60, maxHeight: 120)
                                    Text("Guides OpenAI, for example: “A technical discussion about Swift.”")
                                        .font(.system(size: 11)).foregroundStyle(NotchtalkStyle.muted)
                                }
                            }
                        }
                    } else if settingsManager.transcriptionProvider == .elevenLabs {
                        switchRow("Label speakers (Speaker 1, Speaker 2, …)", isOn: $settingsManager.elevenLabsSpeakerRecognitionEnabled)
                        switchRow("Match speakers from my ElevenLabs library", isOn: $settingsManager.elevenLabsSpeakerLibraryRecognitionEnabled)
                            .disabled(!settingsManager.elevenLabsSpeakerRecognitionEnabled)
                    }
                }

                SettingGroup("After recording") {
                    switchRow("Paste at the cursor", isOn: $settingsManager.autoPasteEnabled, first: true)
                        .help("Off: the transcript only goes to the clipboard.")
                    switchRow("Press Enter after pasting", isOn: $settingsManager.sendWithEnter)
                        .help("Sends the message when a held shortcut is released.")
                }

                SettingGroup("Listening in the background") {
                    switchRow("Ambient", detail: "keeps the last minutes in memory only", isOn: $settingsManager.ambientEnabled, first: true)
                    SettingRow {
                        Text("Keep the last")
                        Spacer()
                        SegmentedChoice(options: [(5, "5"), (10, "10"), (20, "20 min")], selection: $settingsManager.ambientWindowMinutes)
                    }
                    .disabled(!settingsManager.ambientEnabled)
                    switchRow("Record calls", detail: "iPhone and FaceTime on this Mac", isOn: $settingsManager.callRecordingEnabled)
                    if settingsManager.callRecordingEnabled, let problem = call.problem {
                        SettingRow { Text(problem).font(.system(size: 11)).foregroundStyle(.orange) }
                    }
                }

                SettingGroup("Shortcut") {
                    SettingRow(first: true) {
                        Text("Right ⌘ tap starts, tap again stops. Hold to talk. Esc cancels.")
                        Spacer()
                        Button(showTiming ? "Done" : "Timing ›") { showTiming.toggle() }
                            .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(NotchtalkStyle.muted)
                    }
                    if showTiming {
                        SettingRow {
                            Text("Hold mode after")
                            Spacer()
                            Slider(value: $settingsManager.startHoldDelay, in: 0.2...2, step: 0.05).frame(width: 160)
                                .accessibilityLabel("Hold mode threshold")
                            Text("\(Int(settingsManager.startHoldDelay * 1000)) ms").monospacedDigit().foregroundStyle(NotchtalkStyle.muted).frame(width: 56, alignment: .trailing)
                        }
                        SettingRow {
                            Text("Non-hold mode")
                            Spacer()
                            Picker("Non-hold mode", selection: $settingsManager.continuousFinishMode) {
                                ForEach(ContinuousFinishMode.allCases) { mode in
                                    Text(mode.title).tag(mode)
                                }
                            }
                            .labelsHidden().fixedSize()
                        }
                        SettingRow {
                            Text("Hold to send for")
                            Spacer()
                            Slider(value: $settingsManager.finishHoldDelay, in: 0.2...2, step: 0.05).frame(width: 160)
                                .accessibilityLabel("Hold to send threshold")
                            Text("\(Int(settingsManager.finishHoldDelay * 1000)) ms").monospacedDigit().foregroundStyle(NotchtalkStyle.muted).frame(width: 56, alignment: .trailing)
                        }
                    }
                    switchRow("Double-tap right ⌥ transcribes the ambient window", isOn: $settingsManager.ambientHotKeyEnabled)
                        .disabled(!settingsManager.ambientEnabled)
                }

                SettingGroup("Data") {
                    SettingRow(first: true) { Text("Audio is kept for 24 hours, then deleted.") }
                    SettingRow {
                        if let exportFeedbackMessage {
                            Text(exportFeedbackMessage)
                                .font(.system(size: 11))
                                .foregroundStyle(exportFeedbackIsError ? NotchtalkStyle.bad : NotchtalkStyle.muted)
                                .lineLimit(1)
                        }
                        Spacer()
                        Group {
                            Button(DiagnosticsExportFormat.json.buttonTitle) { exportDiagnostics(.json) }
                            Button(DiagnosticsExportFormat.csv.buttonTitle) { exportDiagnostics(.csv) }
                        }
                        .buttonStyle(QuietButtonStyle(size: .mini))
                        .disabled(diagnosticsStore.entries.isEmpty)
                    }
                }
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
        }
        .onChange(of: settingsManager.transcriptionProvider) {
            showAPIKeyField = false
            apiKeyInput = ""
            saveError = nil
            showSaveSuccess = false
        }
    }

    private func switchRow(_ title: String, detail: String? = nil, isOn: Binding<Bool>, first: Bool = false) -> some View {
        SettingRow(first: first) {
            if let detail {
                Text(title) + Text(" · \(detail)").font(.system(size: 11)).foregroundColor(NotchtalkStyle.muted)
            } else {
                Text(title)
            }
            Spacer()
            MiniSwitch(title: title, isOn: isOn)
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
                .font(.system(size: 11, weight: .medium)).foregroundStyle(NotchtalkStyle.ok)
        case .installing(let step):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(step)
            }
        case .notInstalled, .failed:
            VStack(alignment: .trailing, spacing: 4) {
                Button("Download and install") { installer.install() }
                    .buttonStyle(QuietButtonStyle(prominent: true, size: .mini))
                if case .failed(let message) = installer.state {
                    Text(message).font(.system(size: 11)).foregroundStyle(NotchtalkStyle.bad)
                }
            }
        }
    }

    @ViewBuilder
    private var apiKeySection: some View {
        SettingRow {
            Text("API key")
            Spacer()
            if settingsManager.hasAPIKey && !showAPIKeyField {
                Text("Saved in Keychain").font(.system(size: 11)).foregroundStyle(NotchtalkStyle.muted)
                Button("Change") {
                    showAPIKeyField = true
                    apiKeyInput = ""
                }
                .buttonStyle(QuietButtonStyle(size: .mini))
            } else {
                SecureField("Your \(settingsManager.transcriptionProvider.displayName) API key", text: $apiKeyInput)
                    .textFieldStyle(.plain).font(.system(size: 11))
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(NotchtalkStyle.chip, in: RoundedRectangle(cornerRadius: 7))
                    .frame(width: 240)
                Button(settingsManager.hasAPIKey ? "Update" : "Save") { saveAPIKey() }
                    .buttonStyle(QuietButtonStyle(prominent: true, size: .mini))
                    .disabled(apiKeyInput.isEmpty)
                if showAPIKeyField {
                    Button("Cancel") {
                        showAPIKeyField = false
                        apiKeyInput = ""
                        saveError = nil
                    }
                    .buttonStyle(QuietButtonStyle(size: .mini))
                }
            }
        }
        if let error = saveError {
            SettingRow { Text(error).font(.system(size: 11)).foregroundStyle(NotchtalkStyle.bad) }
        }
        if showSaveSuccess {
            SettingRow { Text("API key saved").font(.system(size: 11)).foregroundStyle(NotchtalkStyle.ok) }
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

/// A bordered group of settings with a small uppercase title, as in the mockup.
private struct SettingGroup<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 10, weight: .semibold)).textCase(.uppercase).tracking(0.5)
                .foregroundStyle(NotchtalkStyle.muted)
                .padding(.horizontal, 12).padding(.top, 8).padding(.bottom, 4)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(NotchtalkStyle.line))
    }
}

/// One line of a settings group, with a hairline above it unless it follows the title.
private struct SettingRow<Content: View>: View {
    var first = false
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 10) { content }
            .font(.system(size: 12))
            .padding(.horizontal, 12).padding(.vertical, 7)
            .frame(maxWidth: .infinity, minHeight: 31, alignment: .leading)
            .overlay(alignment: .top) { if !first { NotchtalkStyle.line.frame(height: 1) } }
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
