import SwiftUI

@MainActor
struct NotchtalkMenu: View {
    let controller: AppController
    private let manager = NotchStateManager.shared
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(systemName: "waveform").font(.title2).foregroundStyle(.mint)
                    .frame(width: 40, height: 40).background(.mint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Notchtalk").font(.system(size: 18, weight: .semibold, design: .rounded))
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
                Text("LATEST TRANSCRIPT").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                Text(manager.latestTranscript ?? "Your next successful transcript will appear here.")
                    .font(.system(size: 12)).foregroundStyle(manager.latestTranscript == nil ? .secondary : .primary)
                    .lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
                Button {
                    guard let text = manager.latestTranscript else { return }
                    ClipboardService.copy(text)
                    copied = true
                } label: {
                    Label(copied ? "Copied" : "Copy latest", systemImage: copied ? "checkmark" : "doc.on.doc")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent).tint(.mint)
                .disabled(manager.latestTranscript == nil)
            }
            .padding(14).background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 14))
            VStack(spacing: 8) {
                shortcut("Press right ⌘", detail: "Start / stop instantly")
                shortcut("Release before 0.8s", detail: "Keep recording")
                shortcut("Hold beyond 0.8s", detail: "Release to finish")
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
            }.buttonStyle(.plain).font(.caption)
        }
        .padding(20).frame(width: 320)
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
