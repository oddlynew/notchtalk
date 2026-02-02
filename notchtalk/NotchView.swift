//
//  NotchView.swift
//  notchtalk
//

import SwiftUI

struct NotchView: View {
    let stateManager: NotchStateManager

    private var pillSize: CGSize {
        switch stateManager.state {
        case .idle:
            CGSize(width: 140, height: 26)
        case .recording:
            CGSize(width: 340, height: 54)
        case .processing:
            CGSize(width: 300, height: 44)
        case .done:
            CGSize(width: 220, height: 36)
        case .error:
            CGSize(width: 280, height: 44)
        }
    }

    var body: some View {
        content
            .padding(.horizontal, 16)
            .frame(width: pillSize.width, height: pillSize.height)
            .background {
                RoundedRectangle(cornerRadius: pillSize.height / 2)
                    .fill(.black.opacity(0.85))
                    .glassEffect()
                    .shadow(color: .black.opacity(0.4), radius: 20, x: 0, y: 8)
            }
            .contentTransition(.opacity)
            .animation(.spring(duration: 0.22, bounce: 0.25), value: stateManager.state)
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
        Image(systemName: "mic.fill")
            .font(.system(size: 12))
            .foregroundStyle(.white.opacity(0.5))
    }
}

struct RecordingView: View {
    let audioLevel: CGFloat
    let duration: TimeInterval

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(.red)
                .frame(width: 10, height: 10)
                .shadow(color: .red.opacity(0.6), radius: 4)
                .phaseAnimator([false, true]) { content, phase in
                    content.opacity(phase ? 1.0 : 0.4)
                } animation: { _ in
                    .easeInOut(duration: 0.5)
                }

            Text("Recording")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)

            AudioVisualizerView(level: audioLevel)
                .frame(width: 120, height: 24)

            Text(Duration.seconds(duration), format: .time(pattern: .minuteSecond))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.7))
                .monospacedDigit()
                .contentTransition(.numericText())
        }
    }
}

struct AudioVisualizerView: View {
    let level: CGFloat
    private let barCount = 16

    var body: some View {
        TimelineView(.animation(minimumInterval: 1/30)) { _ in
            HStack(spacing: 2) {
                ForEach(0..<barCount, id: \.self) { index in
                    Capsule()
                        .fill(.white.opacity(0.85))
                        .frame(width: 3, height: barHeight(for: index))
                }
            }
        }
    }

    private func barHeight(for index: Int) -> CGFloat {
        let center = CGFloat(barCount) / 2.0
        let distance = abs(CGFloat(index) - center) / center
        let baseHeight = 0.2 + (1.0 - distance) * 0.3
        let variation = CGFloat.random(in: 0.7...1.3)
        return max(4, min(20, baseHeight * level * variation * 20))
    }
}

struct ProcessingView: View {
    @State private var dotCount = 0

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .tint(.white)

            Text("Transcribing\(String(repeating: ".", count: dotCount))")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 110, alignment: .leading)
                .contentTransition(.numericText())
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
                .font(.system(size: 16))
                .foregroundStyle(.green)
                .symbolEffect(.bounce, options: .nonRepeating)

            Text("Copied")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)

            Text("⌘V to paste")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }
}

struct ErrorView: View {
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 14))
                .foregroundStyle(.orange)
                .symbolEffect(.pulse.wholeSymbol, options: .repeating)

            Text(message)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
        }
    }
}
