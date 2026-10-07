import SwiftUI

/// Muted sage for controls; neutral surfaces carry the visual hierarchy.
enum NotchtalkStyle {
    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.48, green: 0.59, blue: 0.55, alpha: 1)
            : NSColor(srgbRed: 0.29, green: 0.40, blue: 0.36, alpha: 1)
    })
    static let recording = Color(red: 0.55, green: 0.66, blue: 0.60)
    static let paused = Color(red: 0.95, green: 0.78, blue: 0.42)
}

struct QuietButtonStyle: ButtonStyle {
    /// Filled with the accent: the one action the surrounding view leads with.
    var prominent = false
    /// Low and tight, for a row of small choices.
    var compact = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    func makeBody(configuration: Configuration) -> some View {
        QuietButtonBody(configuration: configuration, enabled: isEnabled, reduceMotion: reduceMotion, prominent: prominent, compact: compact, dark: colorScheme == .dark)
    }
    private struct QuietButtonBody: View {
        let configuration: Configuration
        let enabled: Bool
        let reduceMotion: Bool
        let prominent: Bool
        let compact: Bool
        let dark: Bool
        @State private var hovered = false
        var body: some View {
            let radius: CGFloat = compact ? 6 : 8
            configuration.label
                .font(.system(size: compact ? 11 : 12, weight: .medium))
                // The dark accent is light, so its label turns dark to stay readable.
                .foregroundStyle(prominent && enabled ? (dark ? Color.black : Color.white) : enabled ? Color.primary : Color.secondary.opacity(0.55))
                .padding(.horizontal, compact ? 8 : 12).padding(.vertical, compact ? 2 : 9)
                .background(background, in: RoundedRectangle(cornerRadius: radius))
                .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder(Color.primary.opacity(prominent && enabled ? 0 : enabled ? 0.09 : 0.04)))
                .contentShape(RoundedRectangle(cornerRadius: radius))
                .onHover { hovered = $0 }
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hovered)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.1), value: configuration.isPressed)
        }

        private var background: Color {
            if prominent && enabled {
                return NotchtalkStyle.accent.opacity(configuration.isPressed ? 0.8 : hovered ? 0.9 : 1)
            }
            return Color.primary.opacity(enabled && configuration.isPressed ? 0.10 : enabled && hovered ? 0.07 : 0.035)
        }
    }
}
