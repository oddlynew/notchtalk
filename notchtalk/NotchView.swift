//
//  NotchView.swift
//  notchtalk
//

import SwiftUI

@MainActor
struct NotchView: View {
    let stateManager: NotchStateManager

    private var isActive: Bool {
        stateManager.state != .idle
    }

    private var contentWidth: CGFloat {
        switch stateManager.state {
        case .idle: return 184
        case .recording: return 184
        case .processing:
            return (stateManager.pendingSubmit ? 126 : 46)
                + (stateManager.processingControlsAvailable ? 48 : 0)
        case .done: return 88
        case .error: return 180
        }
    }

    var body: some View {
        VStack {
            Spacer()

            if isActive {
                pillContent
                    .frame(width: contentWidth, height: 20)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(
                        Capsule()
                            .fill(Color(red: 0.055, green: 0.075, blue: 0.075))
                            .overlay(alignment: .leading) {
                                GeometryReader { geometry in
                                    Rectangle()
                                        .fill(NotchtalkStyle.recording.opacity(0.30))
                                        .frame(width: geometry.size.width * min(1, max(0, stateManager.finishProgress ?? 0)))
                                }
                                .clipShape(Capsule())
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                            }
                            .overlay(Capsule().strokeBorder(.white.opacity(0.09), lineWidth: 1))
                            .overlay {
                                if stateManager.state == .processing {
                                    ProcessingBorderLight()
                                        .allowsHitTesting(false)
                                        .accessibilityHidden(true)
                                }
                            }
                            .shadow(color: .black.opacity(0.3), radius: 10, y: 5)
                    )
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .animation(.smooth(duration: 0.25), value: isActive)
        .animation(.easeInOut(duration: 0.32), value: contentWidth)
        .animation(.easeInOut(duration: 0.22), value: stateManager.state)
        .animation(.easeInOut(duration: 0.32), value: stateManager.pendingSubmit)
        .animation(.easeInOut(duration: 0.32), value: stateManager.processingControlsAvailable)
    }

    @ViewBuilder
    private var pillContent: some View {
        switch stateManager.state {
        case .idle:
            EmptyView()

        case .recording:
            RecordingContent(stateManager: stateManager)

        case .processing:
            HStack(spacing: 10) {
                Text(Duration.seconds(stateManager.recordingDuration), format: .time(pattern: .minuteSecond))
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
                    .monospacedDigit()

                if stateManager.pendingSubmit {
                    Text("Enter active")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color(red: 0.64, green: 0.86, blue: 0.72))
                        .fixedSize()
                        .help("Press the recording shortcut to turn off Enter for this transcription")
                        .transition(.opacity)
                }

                if stateManager.processingControlsAvailable {
                    Button {
                        stateManager.retryProcessing()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .foregroundStyle(.white.opacity(0.9))
                    }
                    .buttonStyle(.plain)
                    .help("Retry transcription")

                    Button {
                        stateManager.cancel()
                    } label: {
                        Image(systemName: "xmark")
                            .foregroundStyle(.white.opacity(0.9))
                    }
                    .buttonStyle(.plain)
                    .help("Cancel immediately")
                }
            }
            .accessibilityLabel("Transcribing")
            .accessibilityValue(stateManager.pendingSubmit ? "Enter active" : "Enter off")

        case .done:
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(NotchtalkStyle.recording)

                Text(stateManager.lastOutputDisposition == .pastedToCursor ? "Pasted!" : "Copied!")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
            }

        case .error(let message):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)

                Text(message)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
            }
        }
    }
}

// MARK: - Supporting Views

@MainActor
private struct RecordingContent: View {
    let stateManager: NotchStateManager

    var body: some View {
            HStack(spacing: 12) {
                // Recording indicator
                Circle()
                    .fill(NotchtalkStyle.recording)
                    .frame(width: 8, height: 8)
                    .modifier(PulseModifier())

                // Timer
                Text(Duration.seconds(stateManager.recordingDuration), format: .time(pattern: .minuteSecond))
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                    .contentTransition(.numericText())

                // Visualizer
                ZStack {
                    if let progress = stateManager.finishProgress {
                        Label("Enter", systemImage: "arrow.turn.down.left")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white)
                            .accessibilityLabel("Hold to send")
                            .accessibilityValue("\(Int(progress * 100)) percent")
                    } else if stateManager.isHoldRecording || stateManager.noSendForRecording {
                        Text(SettingsManager.shared.sendWithEnter && !stateManager.noSendForRecording ? "Release to send" : "Release to transcribe")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.white.opacity(0.85))
                    } else {
                        AudioVisualizerView(level: stateManager.audioLevel)
                    }
                }
                .frame(width: 110, height: 16)
            }

    }
}

struct PulseModifier: ViewModifier {
    @State private var isPulsing = false

    func body(content: Content) -> some View {
        content
            .opacity(isPulsing ? 1.0 : 0.4)
            .shadow(color: .red.opacity(isPulsing ? 0.6 : 0), radius: 4)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) {
                    isPulsing = true
                }
            }
            .onDisappear {
                isPulsing = false
            }
    }
}

struct AudioVisualizerView: View {
    let level: CGFloat
    private let barCount = 8

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<barCount, id: \.self) { index in
                Capsule()
                    .fill(.white.opacity(0.85))
                    .frame(width: 3, height: barHeight(for: index))
            }
        }
        .animation(.easeOut(duration: 0.1), value: level)
    }

    private func barHeight(for index: Int) -> CGFloat {
        // For even bar counts, center between the two middle bars (e.g. 3.5 for 0...7).
        let center = CGFloat(barCount - 1) / 2.0
        let distance = abs(CGFloat(index) - center) / center
        let base = 0.35 + (1.0 - distance) * 0.55
        let responseLevel = CGFloat(pow(Double(level), 0.45))
        let variation = sin(Double(index) * 1.8 + level * 12) * 0.45 + 0.85
        let minHeight: CGFloat = 2.0
        let maxHeight: CGFloat = 20.0
        let dynamicRange = maxHeight - minHeight
        let dynamicHeight = base * responseLevel * CGFloat(variation) * dynamicRange * 1.35
        return minHeight + min(dynamicRange, max(0, dynamicHeight))
    }
}

/// Core Animation moves the highlight without a SwiftUI timer or per-frame layout.
struct ProcessingBorderLight: NSViewRepresentable {
    func makeNSView(context: Context) -> BorderLightView { BorderLightView() }
    func updateNSView(_ nsView: BorderLightView, context: Context) {}

    final class BorderLightView: NSView {
        private let highlight = CAShapeLayer()
        private var previousSize: CGSize = .zero

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            highlight.fillColor = nil
            highlight.strokeColor = NSColor(srgbRed: 0.64, green: 0.86, blue: 0.72, alpha: 0.85).cgColor
            highlight.lineWidth = 1.5
            highlight.lineCap = .round
            layer?.addSublayer(highlight)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func layout() {
            super.layout()
            guard bounds.size != previousSize, bounds.height > 2 else { return }
            previousSize = bounds.size
            let rect = bounds.insetBy(dx: 1, dy: 1)
            let radius = rect.height / 2
            let perimeter = 2 * max(0, rect.width - rect.height) + 2 * .pi * radius
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            highlight.frame = bounds
            highlight.path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
            highlight.lineDashPattern = [NSNumber(value: perimeter * 0.2), NSNumber(value: perimeter * 0.8)]
            CATransaction.commit()
            // Preserve phase when the pill resizes, rather than restarting the light.
            let animation = CABasicAnimation(keyPath: "lineDashPhase")
            animation.fromValue = 0
            animation.toValue = -perimeter
            animation.duration = 2
            animation.repeatCount = .infinity
            animation.beginTime = 0.0001
            highlight.add(animation, forKey: "processing")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                highlight.removeAllAnimations()
                previousSize = .zero
            } else {
                needsLayout = true
            }
        }
    }
}
