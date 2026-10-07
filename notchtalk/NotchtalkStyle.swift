import SwiftUI

/// The palette of the approved redesign mockup, light and dark.
enum NotchtalkStyle {
    static let accent = dynamic(light: rgb(0x6b5cff), dark: rgb(0x8b7dff))
    static let accentSoft = dynamic(light: rgb(0x6b5cff, 0.10), dark: rgb(0x8b7dff, 0.18))
    static let panel = dynamic(light: rgb(0xffffff), dark: rgb(0x2a2a2d))
    /// The expanded transcript sits on this, one step off the panel.
    static let sheet = dynamic(light: rgb(0xffffff), dark: rgb(0x1f1f22))
    static let ink = dynamic(light: rgb(0x1d1d1f), dark: rgb(0xf2f2f7))
    static let muted = dynamic(light: rgb(0x6e6e73), dark: rgb(0xa1a1a6))
    static let line = dynamic(light: rgb(0x000000, 0.09), dark: rgb(0xffffff, 0.10))
    static let chip = dynamic(light: rgb(0x000000, 0.05), dark: rgb(0xffffff, 0.08))
    static let switchOff = dynamic(light: rgb(0xc7c7cc), dark: rgb(0x5a5a5e))
    static let selectedSegment = dynamic(light: rgb(0xffffff), dark: rgb(0x48484c))
    static let ok = Color(nsColor: rgb(0x2f9e5b))
    static let bad = Color(nsColor: rgb(0xd64545))
    static let recording = Color(red: 0.55, green: 0.66, blue: 0.60)
    static let paused = Color(red: 0.95, green: 0.78, blue: 0.42)

    private static func rgb(_ hex: Int, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat(hex >> 16 & 0xff) / 255, green: CGFloat(hex >> 8 & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
    }

    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

/// The mockup's button: a soft chip, or the accent for the one action a view leads with.
struct QuietButtonStyle: ButtonStyle {
    enum Size {
        /// 12 pt, 7 × 10 padding.
        case regular
        /// 11 pt, 5 × 8 padding, for rows.
        case mini
        /// 11 pt, 1 × 4 padding, for a row of small choices.
        case tiny
    }

    var prominent = false
    var size: Size = .regular
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        QuietButtonBody(configuration: configuration, enabled: isEnabled, prominent: prominent, size: size)
    }

    private struct QuietButtonBody: View {
        let configuration: Configuration
        let enabled: Bool
        let prominent: Bool
        let size: Size
        @State private var hovered = false

        var body: some View {
            let radius: CGFloat = size == .tiny ? 6 : 8
            configuration.label
                .labelStyle(GapLabelStyle())
                .font(.system(size: size == .regular ? 12 : 11))
                .foregroundStyle(prominent ? Color.white : NotchtalkStyle.ink)
                .padding(.horizontal, size == .regular ? 10 : size == .mini ? 8 : 4)
                .padding(.vertical, size == .regular ? 7 : size == .mini ? 5 : 1)
                .background(prominent ? AnyShapeStyle(NotchtalkStyle.accent) : AnyShapeStyle(NotchtalkStyle.chip), in: RoundedRectangle(cornerRadius: radius))
                .overlay(RoundedRectangle(cornerRadius: radius).fill(.black.opacity(configuration.isPressed ? 0.10 : hovered && enabled ? 0.04 : 0)))
                .opacity(enabled ? 1 : 0.4)
                .contentShape(RoundedRectangle(cornerRadius: radius))
                .onHover { hovered = $0 }
        }
    }
}

/// Icon and title 6 pt apart, as in the mockup's buttons.
private struct GapLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon
            configuration.title
        }
    }
}

/// The mockup's segmented control: a chip track with a raised white segment.
struct SegmentedChoice<Value: Hashable>: View {
    let options: [(value: Value, title: String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.value) { option in
                Button { selection = option.value } label: {
                    Text(option.title)
                        .font(.system(size: 11))
                        .foregroundStyle(NotchtalkStyle.ink)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(selection == option.value ? NotchtalkStyle.selectedSegment : .clear, in: RoundedRectangle(cornerRadius: 5))
                        .shadow(color: .black.opacity(selection == option.value ? 0.12 : 0), radius: 1, y: 1)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == option.value ? .isSelected : [])
            }
        }
        .padding(2)
        .background(NotchtalkStyle.chip, in: RoundedRectangle(cornerRadius: 7))
    }
}

/// The mockup's small switch: 26 × 15, the accent when on.
struct MiniSwitch: View {
    let title: String
    @Binding var isOn: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button { isOn.toggle() } label: {
            Capsule()
                .fill(isOn ? NotchtalkStyle.accent : NotchtalkStyle.switchOff)
                .frame(width: 26, height: 15)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle().fill(.white).frame(width: 11, height: 11).padding(2)
                        .shadow(color: .black.opacity(0.15), radius: 0.5, y: 0.5)
                }
                .animation(.easeOut(duration: 0.12), value: isOn)
                .opacity(isEnabled ? 1 : 0.4)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation { Toggle(title, isOn: $isOn) }
    }
}
