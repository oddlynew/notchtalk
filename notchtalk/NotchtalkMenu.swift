import SwiftUI

@MainActor
struct NotchtalkMenu: View {
    let controller: AppController

    var body: some View {
        MenuContent(
            hasAccessibilityPermission: controller.hasAccessibilityPermission,
            hasMicrophonePermission: controller.hasMicrophonePermission,
            openAccessibilitySettings: controller.openAccessibilitySettings,
            requestMicrophonePermission: controller.requestMicrophonePermission,
            showAbout: controller.showAbout
        )
    }
}

/// The menu bar panel, on plain values so it renders without starting the app.
@MainActor
struct MenuContent: View {
    let hasAccessibilityPermission: Bool
    let hasMicrophonePermission: Bool
    let openAccessibilitySettings: () -> Void
    let requestMicrophonePermission: () -> Void
    let showAbout: () -> Void
    private let manager = NotchStateManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "waveform").font(.title2).foregroundStyle(NotchtalkStyle.accent)
                    .frame(width: 40, height: 40).background(NotchtalkStyle.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Notchtalk").font(.system(size: 17, weight: .semibold))
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            if !hasAccessibilityPermission {
                Button("Allow keyboard access", systemImage: "keyboard", action: openAccessibilitySettings)
            }
            if !hasMicrophonePermission {
                Button("Allow microphone", systemImage: "mic", action: requestMicrophonePermission)
            }
            LatestTranscriptCard()
            AmbientRow(hasMicrophonePermission: hasMicrophonePermission)
            Divider()
            HStack {
                Button("Open App", systemImage: "macwindow") { SettingsWindowController.show() }
                    .keyboardShortcut(",")
                Spacer()
                Menu {
                    Button("About Notchtalk", action: showAbout)
                    Button("Quit Notchtalk") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 22)
            }.buttonStyle(QuietButtonStyle()).font(.caption)
        }
        .padding(20).frame(width: 330)
        .tint(NotchtalkStyle.accent)
    }

    private var status: String {
        switch manager.state {
        case .idle: return "Ready when you are"
        case .recording: return "Listening…"
        case .processing: return "Transcribing…"
        case .done: return "Transcript ready"
        case .error: return "Something went wrong"
        }
    }
}

/// The newest History entry and how it ended, with the one or two things to do next.
@MainActor
struct LatestTranscriptCard: View {
    private let manager = NotchStateManager.shared
    private let store = TranscriptionDiagnosticsStore.shared
    @State private var copiedID: UUID?

    static let cornerRadius: CGFloat = 12

    var body: some View {
        let entry = store.entries.first
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text("Latest transcript").foregroundStyle(.secondary)
                if let entry {
                    Text("·").foregroundStyle(.tertiary)
                    EntryStatusLabel(status: entry.status)
                }
            }
            .font(.system(size: 11, weight: .medium))
            Text(message(for: entry))
                .font(.system(size: 12)).foregroundStyle(entry?.status == .succeeded ? .primary : .secondary)
                .lineSpacing(3).lineLimit(3).frame(minHeight: 42, alignment: .topLeading).frame(maxWidth: .infinity, alignment: .leading)
            if let entry { actions(for: entry) }
        }
        .padding(14)
        .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: Self.cornerRadius))
        .overlay(RoundedRectangle(cornerRadius: Self.cornerRadius).strokeBorder(.primary.opacity(0.055)))
    }

    @ViewBuilder private func actions(for entry: TranscriptionDiagnosticsEntry) -> some View {
        let idle = manager.state != .recording && manager.state != .processing
        let hasAudio = store.retainedAudioURL(for: entry.id) != nil
        HStack(spacing: 8) {
            switch entry.status {
            case .succeeded:
                Button("Retry", systemImage: "arrow.clockwise") { retry(entry) }
                    .buttonStyle(QuietButtonStyle())
                    .disabled(!idle || !hasAudio)
                Button { copy(entry) } label: {
                    Label(copiedID == entry.id ? "Copied" : "Copy", systemImage: copiedID == entry.id ? "checkmark" : "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(QuietButtonStyle(prominent: true))
            case .failed:
                Button { retry(entry) } label: {
                    Label("Retry", systemImage: "arrow.clockwise").frame(maxWidth: .infinity)
                }
                .buttonStyle(QuietButtonStyle(prominent: true))
                .disabled(!idle || !hasAudio)
            case .cancelled:
                Button("Resume", systemImage: "play.fill") { manager.resume(diagnosticsID: entry.id) }
                    .buttonStyle(QuietButtonStyle())
                    .disabled(!idle || !hasAudio)
                Button { retry(entry) } label: {
                    Label("Transcribe", systemImage: "waveform").frame(maxWidth: .infinity)
                }
                .buttonStyle(QuietButtonStyle(prominent: true))
                .disabled(!idle || !hasAudio)
            case .recording, .pending:
                Button {} label: {
                    Label("Copy", systemImage: "doc.on.doc").frame(maxWidth: .infinity)
                }
                .buttonStyle(QuietButtonStyle())
                .disabled(true)
            }
        }
    }

    private func message(for entry: TranscriptionDiagnosticsEntry?) -> String {
        guard let entry else { return "Nothing transcribed yet" }
        let subject = entry.label ?? "the recording from \(entry.createdAt.formatted(date: .omitted, time: .shortened))"
        switch entry.status {
        case .succeeded:
            let text = entry.transcriptText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return text.isEmpty ? "No speech in \(subject)" : text
        case .failed: return "Couldn't transcribe \(subject). Details are in the app."
        case .cancelled: return "You cancelled \(subject)."
        case .recording: return "Recording…"
        case .pending: return "\(manager.processingStatusText) \(subject)…"
        }
    }

    private func copy(_ entry: TranscriptionDiagnosticsEntry) {
        guard let text = entry.transcriptText, !text.isEmpty else { return }
        ClipboardService.copy(text)
        copiedID = entry.id
    }

    /// The menu holds the keyboard focus, so a paste would land in it: the transcript goes to the clipboard.
    private func retry(_ entry: TranscriptionDiagnosticsEntry) {
        manager.retranscribe(diagnosticsID: entry.id, reason: "Retry from the menu", allowPaste: false)
    }
}

/// Ambient on one low line: the switch, and the recall lengths that fit the window kept in Settings.
@MainActor
struct AmbientRow: View {
    let hasMicrophonePermission: Bool
    @Bindable private var settings = SettingsManager.shared
    private let ambient = AmbientRecorder.shared
    private let manager = NotchStateManager.shared

    var body: some View {
        HStack(spacing: 6) {
            Toggle("Ambient", isOn: $settings.ambientEnabled)
                .toggleStyle(.switch).controlSize(.mini).labelsHidden()
            Text("Ambient").font(.system(size: 12))
            if settings.ambientEnabled && !ambient.isRunning {
                Circle().fill(.orange).frame(width: 6, height: 6)
                    .help(hasMicrophonePermission ? "Not listening, the microphone did not start" : "Needs microphone access")
                    .accessibilityLabel(hasMicrophonePermission ? "Not listening, the microphone did not start" : "Needs microphone access")
            }
            Spacer(minLength: 8)
            HStack(spacing: 2) {
                ForEach(AmbientRecorder.recallChoices.filter { $0 <= settings.ambientWindowMinutes }, id: \.self) { minutes in
                    Button("\(minutes) min") { manager.transcribeAmbient(minutes: minutes, allowPaste: false) }
                        .buttonStyle(QuietButtonStyle(compact: true, horizontalPadding: 4))
                        .accessibilityLabel("Transcribe the last \(minutes) minutes")
                }
            }
            .disabled(!settings.ambientEnabled || !ambient.isRunning || manager.state == .recording || manager.state == .processing)
        }
        .lineLimit(1)
        // Inset by the card's corner radius, so the row lines up with the rounding above it.
        .padding(.horizontal, LatestTranscriptCard.cornerRadius)
    }
}

/// A coloured dot and one word for where an entry stands.
struct EntryStatusLabel: View {
    let status: TranscriptionDiagnosticsEntry.Status

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(title).foregroundStyle(color)
        }
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        switch status {
        case .recording: "Recording"
        case .pending: "Transcribing"
        case .succeeded: "Done"
        case .failed: "Failed"
        case .cancelled: "Cancelled"
        }
    }

    private var color: Color {
        switch status {
        case .recording: .red
        case .pending: NotchtalkStyle.accent
        case .succeeded: .green
        case .failed: .red
        case .cancelled: .secondary
        }
    }
}
