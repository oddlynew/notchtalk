//
//  NotchState.swift
//  notchtalk
//

import SwiftUI

enum AppState: Equatable, Sendable {
    case idle
    case recording
    case processing
    case done
    case error(String)
}

@MainActor
@Observable
final class NotchStateManager {
    var state: AppState = .idle
    var audioLevel: CGFloat = 0.0
    var recordingDuration: TimeInterval = 0

    private var recordingTask: Task<Void, Never>?
    private var processingTask: Task<Void, Never>?

    func toggle() {
        switch state {
        case .idle:
            startRecording()
        case .recording:
            stopRecording()
        case .processing:
            break
        case .done, .error:
            reset()
        }
    }

    func startRecording() {
        state = .recording
        recordingDuration = 0
        SoundManager.shared.playStartSound()

        recordingTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                recordingDuration += 0.1
                audioLevel = CGFloat.random(in: 0.1...1.0)
            }
        }
    }

    func stopRecording() {
        recordingTask?.cancel()
        recordingTask = nil
        state = .processing
        SoundManager.shared.playStopSound()

        processingTask = Task {
            try? await Task.sleep(for: .seconds(5))

            guard !Task.isCancelled else { return }

            ClipboardService.copy("hello world")
            state = .done

            try? await Task.sleep(for: .seconds(1.2))

            guard !Task.isCancelled else { return }
            reset()
        }
    }

    func cancel() {
        recordingTask?.cancel()
        recordingTask = nil
        processingTask?.cancel()
        processingTask = nil
        reset()
    }

    func reset() {
        state = .idle
        audioLevel = 0
        recordingDuration = 0
    }

    func retry() {
        if case .error = state {
            stopRecording()
        }
    }
}
