import SwiftUI

/// Muted sage for controls; neutral surfaces carry the visual hierarchy.
enum NotchtalkStyle {
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.48, green: 0.59, blue: 0.55, alpha: 1)
            : NSColor(srgbRed: 0.29, green: 0.40, blue: 0.36, alpha: 1)
    })
    static let recording = Color(red: 0.55, green: 0.66, blue: 0.60)
}

struct QuietButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        QuietButtonBody(configuration: configuration, enabled: isEnabled, reduceMotion: reduceMotion)
    }
    private struct QuietButtonBody: View {
        let configuration: Configuration
        let enabled: Bool
        let reduceMotion: Bool
        @State private var hovered = false
        var body: some View {
            configuration.label
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(enabled ? Color.primary : Color.secondary.opacity(0.55))
                .padding(.horizontal, 12).padding(.vertical, 9)
                .background(Color.primary.opacity(enabled && configuration.isPressed ? 0.10 : enabled && hovered ? 0.07 : 0.035), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(enabled ? 0.09 : 0.04)))
                .contentShape(RoundedRectangle(cornerRadius: 8))
                .onHover { hovered = $0 }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: configuration.isPressed)
        }
    }
}
