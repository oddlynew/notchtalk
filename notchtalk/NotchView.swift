//
//  NotchView.swift
//  notchtalk
//

import SwiftUI

struct NotchView: View {
    let stateManager: NotchStateManager

    private var isActive: Bool {
        stateManager.state != .idle
    }

    var body: some View {
        VStack {
            if isActive {
                pillContent
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(
                        Capsule()
                            .fill(.black)
                            .shadow(color: .black.opacity(0.3), radius: 10, y: 5)
                    )
                    .transition(.move(edge: .top).combined(with: .opacity))
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(.spring(duration: 0.3, bounce: 0.2), value: isActive)
        .animation(.spring(duration: 0.2), value: stateManager.state)
    }

    @ViewBuilder
    private var pillContent: some View {
        switch stateManager.state {
        case .idle:
            EmptyView()

        case .recording:
            HStack(spacing: 12) {
                // Red pulsing dot
                Circle()
                    .fill(.red)
                    .frame(width: 8, height: 8)
                    .modifier(PulseModifier())

                // Timer
                Text(Duration.seconds(stateManager.recordingDuration), format: .time(pattern: .minuteSecond))
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white)
                    .monospacedDigit()
                    .contentTransition(.numericText())

                // Visualizer
                AudioVisualizerView(level: stateManager.audioLevel)
                    .frame(width: 60, height: 16)
            }

        case .processing:
            HStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                    .tint(.white)

                AnimatedDotsText(text: "Transcribing")
            }

        case .done:
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)

                Text("Copied!")
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
        let base = 0.3 + (1.0 - distance) * 0.5
        let variation = sin(Double(index) * 1.5 + level * 8) * 0.3 + 0.7
        return max(4, min(14, base * level * variation * 14))
    }
}

struct AnimatedDotsText: View {
    let text: String
    @State private var dotCount = 0
    @State private var task: Task<Void, Never>?

    var body: some View {
        Text("\(text)\(String(repeating: ".", count: dotCount))")
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: 100, alignment: .center)
            .onAppear {
                task = Task {
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(400))
                        guard !Task.isCancelled else { return }
                        dotCount = (dotCount + 1) % 4
                    }
                }
            }
            .onDisappear {
                task?.cancel()
                task = nil
            }
    }
}
