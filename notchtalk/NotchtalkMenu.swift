import SwiftUI

@MainActor
struct NotchtalkMenu: View {
    let controller: AppController
    private let manager = NotchStateManager.shared
    @State private var copied = false
    @Bindable private var settings = SettingsManager.shared

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
            VStack(alignment: .leading, spacing: 10) {
                Text("Latest transcript").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Text(manager.latestTranscript ?? "Nothing to copy yet")
                    .font(.system(size: 12)).foregroundStyle(manager.latestTranscript == nil ? .secondary : .primary)
                    .lineSpacing(3).lineLimit(3).frame(minHeight: 42, alignment: .topLeading).frame(maxWidth: .infinity, alignment: .leading)
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
            .padding(14).background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(0.055)))
            Toggle("Send with Enter", isOn: $settings.sendWithEnter)
                .toggleStyle(.switch).controlSize(.mini).font(.system(size: 12))
            VStack(spacing: 9) {
                shortcut("Press right ⌘", detail: "Start recording")
                shortcut("Release before \(Int(settings.startHoldDelay * 1000)) ms", detail: "Keep recording")
                shortcut("Hold beyond \(Int(settings.startHoldDelay * 1000)) ms", detail: "Release to finish")
                shortcut("Hold again · \(Int(settings.finishHoldDelay * 1000)) ms", detail: "Finish & send")
                shortcut("Esc", detail: "Cancel")
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
        .onChange(of: manager.latestTranscript) { _, _ in copied = false }
    }
    private func shortcut(_ key: String, detail: String) -> some View {
        HStack {
            Text(key).fontWeight(.medium)
            Spacer()
            Text(detail).foregroundStyle(.secondary)
        }.font(.system(size: 11))
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
