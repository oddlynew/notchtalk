//
//  SettingsView.swift
//  notchtalk
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct SettingsView: View {
    enum SettingsTab: Hashable {
        case history
        case settings
    }

    enum DiagnosticsExportFormat {
        case json
        case csv

        var buttonTitle: String {
            switch self {
            case .json:
                return "Export JSON"
            case .csv:
                return "Export CSV"
            }
        }

        var fileExtension: String {
            switch self {
            case .json:
                return "json"
            case .csv:
                return "csv"
            }
        }

        var contentType: UTType {
            switch self {
            case .json:
                return .json
            case .csv:
                return .commaSeparatedText
            }
        }
    }

    @Bindable private var settingsManager = SettingsManager.shared
    @Bindable private var diagnosticsStore = TranscriptionDiagnosticsStore.shared
    @State private var apiKeyInput = ""
    @State private var showAPIKeyField = false
    @State private var saveError: String?
    @State private var showSaveSuccess = false
    @State private var selectedTab: SettingsTab = .history
    @State private var selectedHistoryStatus: TranscriptionDiagnosticsEntry.Status?
    @State private var selectedHistoryID: UUID?
    @State private var searchText = ""
    @State private var exportFeedbackMessage: String?
    @State private var exportFeedbackIsError = false
    @State private var historyDetailsMode: HistoryDetailsMode = .transcript

    var body: some View {
        TabView(selection: $selectedTab) {
            historyTab
                .tabItem {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }
                .tag(SettingsTab.history)

            settingsTab
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
                .tag(SettingsTab.settings)
        }
        .frame(width: 760, height: 520)
        .navigationTitle("Notchtalk")
    }

    private var settingsTab: some View {
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
                Toggle("Keep failed recordings for manual retry (recommended)", isOn: $settingsManager.retainFailedRecordingsEnabled)
            } header: {
                Text("Behavior")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Auto-paste inserts the transcription at your cursor position without overwriting your clipboard.")
                    Text("If a transcription fails after retries, Notchtalk can retain the audio locally so you can re-transcribe it from History.")
                }
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private enum HistoryDetailsMode: Hashable {
        case transcript
        case diagnostics
    }

    private var historyTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("Status", selection: $selectedHistoryStatus) {
                    Text("All").tag(Optional<TranscriptionDiagnosticsEntry.Status>.none)
                    Text("Pending").tag(Optional(TranscriptionDiagnosticsEntry.Status.pending))
                    Text("Succeeded").tag(Optional(TranscriptionDiagnosticsEntry.Status.succeeded))
                    Text("Failed").tag(Optional(TranscriptionDiagnosticsEntry.Status.failed))
                    Text("Cancelled").tag(Optional(TranscriptionDiagnosticsEntry.Status.cancelled))
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 440)

                Spacer()

                Text("\(filteredHistoryEntries.count) entries")
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .top, spacing: 12) {
                historyList
                historyDetails
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(16)
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search transcript, error, logs")
        .onAppear {
            if selectedHistoryID == nil {
                selectedHistoryID = filteredHistoryEntries.first?.id
            }
        }
        .onChange(of: filteredHistoryEntries.map(\.id)) {
            if let selectedHistoryID, filteredHistoryEntries.contains(where: { $0.id == selectedHistoryID }) {
                return
            }
            self.selectedHistoryID = filteredHistoryEntries.first?.id
        }
    }

    private var historyList: some View {
        List(filteredHistoryEntries, selection: $selectedHistoryID) { entry in
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    statusDot(for: entry.status)
                    Text(titleText(for: entry))
                        .font(.headline)
                        .lineLimit(2)
                    Spacer()
                    Text(entry.updatedAt, format: .dateTime.hour().minute().second())
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 10) {
                    Text(entry.status.rawValue.capitalized)
                    Text("Retries: \(entry.retryCount)")
                    if let outputCharacterCount = entry.outputCharacterCount {
                        Text("Chars: \(outputCharacterCount)")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                if let errorMessage = entry.errorMessage, !errorMessage.isEmpty {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                }
            }
            .padding(.vertical, 2)
            .tag(entry.id)
            .contextMenu {
                if let transcript = entry.transcriptText, !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button("Copy text") {
                        ClipboardService.copy(transcript)
                    }
                }

                if shouldShowRetranscribe(for: entry) {
                    Button("Re-transcribe") {
                        NotchStateManager.shared.retranscribe(diagnosticsID: entry.id)
                    }
                }

                Button("See diagnostics") {
                    selectedHistoryID = entry.id
                    historyDetailsMode = .diagnostics
                }
            }
        }
        .frame(minWidth: 320, maxWidth: 360, maxHeight: .infinity)
    }

    private var historyDetails: some View {
        Group {
            if let entry = selectedHistoryEntry {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 8) {
                        Button("Copy") {
                            if let transcript = entry.transcriptText {
                                ClipboardService.copy(transcript)
                            }
                        }
                        .disabled((entry.transcriptText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        Button("Re-transcribe") {
                            NotchStateManager.shared.retranscribe(diagnosticsID: entry.id)
                        }
                        .disabled(!shouldShowRetranscribe(for: entry))

                        Spacer()
                    }

                    Picker("Details", selection: $historyDetailsMode) {
                        Text("Transcript").tag(HistoryDetailsMode.transcript)
                        Text("Diagnostics").tag(HistoryDetailsMode.diagnostics)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 360)

                    Group {
                        switch historyDetailsMode {
                        case .transcript:
                            transcriptDetails(for: entry)
                        case .diagnostics:
                            diagnosticsDetails(for: entry)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
            } else {
                ContentUnavailableView("No history selected", systemImage: "list.bullet.rectangle.portrait")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var filteredHistoryEntries: [TranscriptionDiagnosticsEntry] {
        diagnosticsStore.entries.filter { entry in
            if let selectedHistoryStatus, entry.status != selectedHistoryStatus {
                return false
            }

            if searchText.isEmpty {
                return true
            }

            let needle = searchText.lowercased()
            if entry.sourceAudioFilename.lowercased().contains(needle) {
                return true
            }
            if let transcriptText = entry.transcriptText, transcriptText.lowercased().contains(needle) {
                return true
            }
            if let errorMessage = entry.errorMessage, errorMessage.lowercased().contains(needle) {
                return true
            }
            return entry.logs.contains { $0.message.lowercased().contains(needle) }
        }
    }

    private var selectedHistoryEntry: TranscriptionDiagnosticsEntry? {
        guard let selectedHistoryID else {
            return nil
        }
        return filteredHistoryEntries.first(where: { $0.id == selectedHistoryID })
    }

    private func titleText(for entry: TranscriptionDiagnosticsEntry) -> String {
        if let transcriptText = entry.transcriptText?.trimmingCharacters(in: .whitespacesAndNewlines), !transcriptText.isEmpty {
            return transcriptText
        }

        switch entry.status {
        case .pending:
            return "Transcribing..."
        case .failed:
            return "Failed transcription"
        case .cancelled:
            return "Cancelled transcription"
        case .succeeded:
            return entry.sourceAudioFilename
        }
    }

    private func shouldShowRetranscribe(for entry: TranscriptionDiagnosticsEntry) -> Bool {
        if entry.status != .failed && entry.status != .cancelled {
            return false
        }

        guard let url = diagnosticsStore.retainedAudioURL(for: entry.id) else {
            return false
        }

        return FileManager.default.fileExists(atPath: url.path)
    }

    @ViewBuilder
    private func transcriptDetails(for entry: TranscriptionDiagnosticsEntry) -> some View {
        if let transcriptText = entry.transcriptText?.trimmingCharacters(in: .whitespacesAndNewlines), !transcriptText.isEmpty {
            ScrollView {
                Text(transcriptText)
                    .font(.body)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 6)
            }
        } else {
            switch entry.status {
            case .pending:
                VStack(alignment: .leading, spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Transcribing...")
                        .foregroundStyle(.secondary)
                }
            case .failed:
                ContentUnavailableView("No transcript available", systemImage: "exclamationmark.triangle.fill")
            case .cancelled:
                ContentUnavailableView("Transcription cancelled", systemImage: "xmark.circle")
            case .succeeded:
                ContentUnavailableView("No transcript stored", systemImage: "doc.text.magnifyingglass")
            }
        }
    }

    @ViewBuilder
    private func diagnosticsDetails(for entry: TranscriptionDiagnosticsEntry) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Diagnostics")
                        .font(.title3.weight(.semibold))
                    Spacer()

                    Menu("Export") {
                        Button(DiagnosticsExportFormat.json.buttonTitle) {
                            exportDiagnostics(.json)
                        }
                        Button(DiagnosticsExportFormat.csv.buttonTitle) {
                            exportDiagnostics(.csv)
                        }
                    }
                    .disabled(filteredHistoryEntries.isEmpty)
                }

                if let exportFeedbackMessage {
                    Text(exportFeedbackMessage)
                        .font(.caption)
                        .foregroundStyle(exportFeedbackIsError ? .red : .secondary)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        detailsRow(title: "Status", value: entry.status.rawValue.capitalized)
                        detailsRow(title: "Created", value: formattedTimestamp(entry.createdAt))
                        detailsRow(title: "Updated", value: formattedTimestamp(entry.updatedAt))
                        detailsRow(title: "Prompt", value: entry.promptProvided ? "Included" : "None")
                        detailsRow(title: "Retries", value: "\(entry.retryCount)")
                        detailsRow(title: "Audio File", value: entry.sourceAudioFilename)
                        detailsRow(title: "Retained Audio", value: entry.retainedAudioFilename == nil ? "None" : "Available")
                        if let count = entry.outputCharacterCount {
                            detailsRow(title: "Output Length", value: "\(count) chars")
                        }
                        if let errorMessage = entry.errorMessage, !errorMessage.isEmpty {
                            detailsRow(title: "Error", value: errorMessage)
                        }
                    }
                }

                Text("Log Events")
                    .font(.headline)

                if entry.logs.isEmpty {
                    Text("No logs available.")
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(entry.logs.reversed()) { event in
                            HStack(alignment: .top, spacing: 8) {
                                Text(formattedTime(event.timestamp))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 80, alignment: .leading)

                                Text(event.level.rawValue.uppercased())
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(color(for: event.level))
                                    .frame(width: 55, alignment: .leading)

                                Text(event.message)
                                    .font(.caption)
                                    .textSelection(.enabled)

                                Spacer(minLength: 0)
                            }
                        }
                    }
                }
            }
        }
    }

    private func statusDot(for status: TranscriptionDiagnosticsEntry.Status) -> some View {
        Circle()
            .fill(color(for: status))
            .frame(width: 8, height: 8)
    }

    private func detailsRow(title: String, value: String) -> some View {
        HStack(alignment: .top) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .font(.caption)
        }
    }

    private func formattedTimestamp(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .standard)
    }

    private func formattedTime(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .standard)
    }

    private func color(for status: TranscriptionDiagnosticsEntry.Status) -> Color {
        switch status {
        case .pending:
            return .orange
        case .succeeded:
            return .green
        case .failed:
            return .red
        case .cancelled:
            return .gray
        }
    }

    private func color(for level: TranscriptionDiagnosticsEntry.LogLevel) -> Color {
        switch level {
        case .info:
            return .secondary
        case .warning:
            return .orange
        case .error:
            return .red
        }
    }

    private func exportDiagnostics(_ format: DiagnosticsExportFormat) {
        let entries = filteredHistoryEntries
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
            "retained_audio_filename",
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

            return [
                entry.id.uuidString,
                entry.status.rawValue,
                ISO8601DateFormatter().string(from: entry.createdAt),
                ISO8601DateFormatter().string(from: entry.updatedAt),
                entry.sourceAudioFilename,
                entry.retainedAudioFilename ?? "",
                String(entry.promptProvided),
                String(entry.retryCount),
                entry.outputCharacterCount.map(String.init) ?? "",
                entry.errorMessage ?? "",
                entry.transcriptText ?? "",
                logs
            ].map { csvEscaped($0) }.joined(separator: ",")
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
