import SwiftUI

@MainActor
struct NotchtalkMenu: View {
    let controller: AppController
    private let manager = NotchStateManager.shared
    @Bindable private var settings = SettingsManager.shared
    private let ambient = AmbientRecorder.shared
    private let drop = FileDrop.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Image(systemName: "waveform").font(.title2).foregroundStyle(NotchtalkStyle.accent)
                    .frame(width: 40, height: 40).background(NotchtalkStyle.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Notchtalk").font(.system(size: 17, weight: .semibold))
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            if !controller.hasAccessibilityPermission {
                Button("Allow keyboard access", systemImage: "keyboard") { controller.openAccessibilitySettings() }
            }
            if !controller.hasMicrophonePermission {
                Button("Allow microphone", systemImage: "mic") { controller.requestMicrophonePermission() }
            }
            LatestTranscriptCard()
            Toggle("Auto-send on release", isOn: $settings.sendWithEnter)
                .toggleStyle(.switch).controlSize(.mini).font(.system(size: 12))
            Toggle("Ambient", isOn: $settings.ambientEnabled)
                .toggleStyle(.switch).controlSize(.mini).font(.system(size: 12))
            if settings.ambientEnabled {
                VStack(alignment: .leading, spacing: 8) {
                    Text(ambientStatus).font(.caption).foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        Text("Transcribe last").font(.system(size: 11))
                        ForEach(AmbientRecorder.recallChoices.filter { $0 <= settings.ambientWindowMinutes }, id: \.self) { minutes in
                            Button("\(minutes) min") { manager.transcribeAmbient(minutes: minutes, allowPaste: false) }
                                .buttonStyle(QuietButtonStyle())
                                .disabled(manager.state == .recording || manager.state == .processing)
                        }
                    }
                }
            }
            VStack(spacing: 9) {
                shortcut("Press right ⌘", detail: "Start recording")
                shortcut("Release before \(Int(settings.startHoldDelay * 1000)) ms", detail: "Keep recording")
                shortcut("Hold beyond \(Int(settings.startHoldDelay * 1000)) ms", detail: "Release to finish")
                shortcut("Hold again · \(Int(settings.finishHoldDelay * 1000)) ms", detail: "Finish & send")
                shortcut("Click ⏸ in the pill", detail: "Pause & resume")
                shortcut("Release Esc first", detail: "Cancel")
                shortcut("Hold Esc, release ⌘", detail: "Transcribe only")
                if settings.ambientEnabled && settings.ambientHotKeyEnabled {
                    shortcut("Double-tap right ⌥", detail: "Last \(settings.ambientWindowMinutes) min")
                }
            }
            Divider()
            HStack {
                Button("History & settings", systemImage: "slider.horizontal.3") { SettingsWindowController.show() }
                    .keyboardShortcut(",")
                Spacer()
                Menu {
                    Button("About Notchtalk") { controller.showAbout() }
                    Button("Quit Notchtalk") { NSApplication.shared.terminate(nil) }.keyboardShortcut("q")
                } label: { Image(systemName: "ellipsis") }.menuStyle(.borderlessButton).frame(width: 22)
            }.buttonStyle(QuietButtonStyle()).font(.caption)
        }
        .padding(20).frame(width: 330)
        .tint(NotchtalkStyle.accent)
        .onAppear { drop.menuOpen = true }
        .onDisappear { drop.menuOpen = false }
    }
    private func shortcut(_ key: String, detail: String) -> some View {
        HStack {
            Text(key).fontWeight(.medium)
            Spacer()
            Text(detail).foregroundStyle(.secondary)
        }.font(.system(size: 11))
    }
    private var ambientStatus: String {
        guard ambient.isRunning else {
            return controller.hasMicrophonePermission ? "Not listening, the microphone did not start" : "Needs microphone access"
        }
        return "Listening. Keeps the last \(settings.ambientWindowMinutes) min, only on this Mac."
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

/// Shows the latest transcript and takes a dropped audio or video file, which goes the way of a voice memo.
@MainActor
struct LatestTranscriptCard: View {
    private let manager = NotchStateManager.shared
    private let drop = FileDrop.shared
    @State private var copied = false
    @State var dropTargeted = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Latest transcript").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            Text(manager.latestTranscript ?? "Nothing to copy yet")
                .font(.system(size: 12)).foregroundStyle(manager.latestTranscript == nil ? .secondary : .primary)
                .lineSpacing(3).lineLimit(3).frame(minHeight: 42, alignment: .topLeading).frame(maxWidth: .infinity, alignment: .leading)
            dropSlot
            Button {
                guard let text = manager.latestTranscript else { return }
                ClipboardService.copy(text)
                copied = true
            } label: {
                Label(copied ? "Copied" : "Copy latest", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(QuietButtonStyle())
            .disabled(manager.latestTranscript == nil)
        }
        .padding(14)
        .background(dropTargeted ? AnyShapeStyle(NotchtalkStyle.accent.opacity(0.10)) : AnyShapeStyle(.primary.opacity(0.025)), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(dropTargeted ? AnyShapeStyle(NotchtalkStyle.accent) : AnyShapeStyle(.primary.opacity(0.055)), lineWidth: dropTargeted ? 1.5 : 1))
        .overlay {
            if dropTargeted {
                VStack(spacing: 6) {
                    Image(systemName: "arrow.down.doc.fill").font(.system(size: 22))
                    Text(drop.isBusy ? "Busy, drop again in a moment" : "Drop to transcribe").font(.system(size: 12, weight: .semibold))
                }
                .foregroundStyle(NotchtalkStyle.accent)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(NotchtalkStyle.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(NotchtalkStyle.accent, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
                .transition(.opacity)
            }
        }
        .scaleEffect(dropTargeted && !reduceMotion ? 1.02 : 1)
        .animation(reduceMotion ? .easeOut(duration: 0.12) : .spring(duration: 0.28, bounce: 0.25), value: dropTargeted)
        .dropDestination(for: URL.self) { urls, _ in
            drop.transcribe(urls)
        } isTargeted: { dropTargeted = $0 }
        .onChange(of: manager.latestTranscript) { _, _ in copied = false }
    }
    /// A quiet dashed slot that says the card takes files; it shows reading, progress and failures too.
    @ViewBuilder private var dropSlot: some View {
        let status = drop.status
        HStack(spacing: 8) {
            switch status {
            case .idle:
                Image(systemName: "arrow.down.doc").foregroundStyle(.secondary)
                Text("Drop an audio or video file to transcribe").foregroundStyle(.secondary)
            case .reading(let name), .transcribing(let name):
                if reduceMotion {
                    Image(systemName: "hourglass").foregroundStyle(NotchtalkStyle.accent)
                } else {
                    ProgressView().controlSize(.mini)
                }
                Text(status == .reading(name) ? "Reading \(name)" : "\(manager.processingStatusText) \(name)")
                    .lineLimit(1).truncationMode(.middle)
            case .failed(let message):
                Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                Text(message).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 10).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.primary.opacity(0.12), style: StrokeStyle(lineWidth: 1, dash: [4, 3])))
        .accessibilityElement(children: .combine)
    }
}
