//
//  NotchView.swift
//  notchtalk
//

import SwiftUI

struct NotchShape: Shape {
    var cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()

        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: rect.width, y: 0))
        path.addLine(to: CGPoint(x: rect.width, y: rect.height - cornerRadius))
        path.addQuadCurve(
            to: CGPoint(x: rect.width - cornerRadius, y: rect.height),
            control: CGPoint(x: rect.width, y: rect.height)
        )
        path.addLine(to: CGPoint(x: cornerRadius, y: rect.height))
        path.addQuadCurve(
            to: CGPoint(x: 0, y: rect.height - cornerRadius),
            control: CGPoint(x: 0, y: rect.height)
        )
        path.closeSubpath()

        return path
    }
}

struct NotchView: View {
    let stateManager: NotchStateManager

    private var pillSize: CGSize {
        switch stateManager.state {
        case .idle:
            CGSize(width: 200, height: 32)
        case .recording:
            CGSize(width: 340, height: 44)
        case .processing:
            CGSize(width: 280, height: 40)
        case .done:
            CGSize(width: 220, height: 36)
        case .error:
            CGSize(width: 280, height: 40)
        }
    }

    private var cornerRadius: CGFloat {
        switch stateManager.state {
        case .idle:
            return 16
        case .recording, .processing, .done, .error:
            return 22
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            content
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .frame(width: pillSize.width, height: pillSize.height)
                .background {
                    NotchShape(cornerRadius: cornerRadius)
                        .fill(.black)
                        .shadow(color: .black.opacity(0.5), radius: 15, x: 0, y: 10)
                }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .contentTransition(.opacity)
        .animation(.spring(duration: 0.25, bounce: 0.2), value: stateManager.state)
    }

    @ViewBuilder
    private var content: some View {
        switch stateManager.state {
        case .idle:
            IdleView()
        case .recording:
            RecordingView(audioLevel: stateManager.audioLevel, duration: stateManager.recordingDuration)
        case .processing:
            ProcessingView()
        case .done:
            DoneView()
        case .error(let message):
            ErrorView(message: message)
        }
    }
}

struct IdleView: View {
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "mic.fill")
                .font(.system(size: 12, weight: .medium))
            Text("Ready")
                .font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(.white.opacity(0.5))
    }
}

struct RecordingView: View {
    let audioLevel: CGFloat
    let duration: TimeInterval

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(.red)
                .frame(width: 8, height: 8)
                .shadow(color: .red.opacity(0.8), radius: 4)
                .phaseAnimator([false, true]) { content, phase in
                    content.opacity(phase ? 1.0 : 0.3)
                } animation: { _ in
                    .easeInOut(duration: 0.5)
                }

            AudioVisualizerView(level: audioLevel)
                .frame(width: 140, height: 20)

            Text(Duration.seconds(duration), format: .time(pattern: .minuteSecond))
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.8))
                .monospacedDigit()
                .contentTransition(.numericText())
        }
    }
}

struct AudioVisualizerView: View {
    let level: CGFloat
    private let barCount = 24

    var body: some View {
        TimelineView(.animation(minimumInterval: 1/30)) { _ in
            HStack(spacing: 2) {
                ForEach(0..<barCount, id: \.self) { index in
                    Capsule()
                        .fill(.white.opacity(0.9))
                        .frame(width: 2, height: barHeight(for: index))
                }
            }
        }
    }

    private func barHeight(for index: Int) -> CGFloat {
        let center = CGFloat(barCount) / 2.0
        let distance = abs(CGFloat(index) - center) / center
        let baseHeight = 0.3 + (1.0 - distance) * 0.4
        let variation = CGFloat.random(in: 0.6...1.4)
        return max(3, min(18, baseHeight * level * variation * 18))
    }
}

struct ProcessingView: View {
    @State private var dotCount = 0

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .tint(.white)

            Text("Transcribing\(String(repeating: ".", count: dotCount))")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 120, alignment: .leading)
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400))
                dotCount = (dotCount + 1) % 4
            }
        }
    }
}

struct DoneView: View {
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(.green)
                .symbolEffect(.bounce, options: .nonRepeating)

            Text("Copied")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)

            Text("⌘V")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.4))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(.white.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
        }
    }
}

struct ErrorView: View {
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 13))
                .foregroundStyle(.orange)
                .symbolEffect(.pulse.wholeSymbol, options: .repeating)

            Text(message)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
        }
    }
}
