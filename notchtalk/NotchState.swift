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
    private let audioRecorder = AudioRecorder()
    private let transcriptionService = OpenAITranscriptionService()
    private var currentRecordingURL: URL?

    init() {
        audioRecorder.onAudioLevelUpdate = { [weak self] level in
            self?.audioLevel = level
        }
    }

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
        guard KeychainService.hasAPIKey else {
            state = .error("No API key")
            SettingsWindowController.show()

            Task {
                try? await Task.sleep(for: .seconds(2))
                reset()
            }
            return
        }

        state = .recording
        recordingDuration = 0
        SoundManager.shared.playStartSound()

        recordingTask = Task {
            do {
                currentRecordingURL = try await audioRecorder.startRecording()

                // Update duration timer
                while !Task.isCancelled && audioRecorder.isRecording {
                    try? await Task.sleep(for: .milliseconds(100))
                    recordingDuration += 0.1
                }
            } catch {
                await MainActor.run {
                    self.state = .error("Mic error")
                    SoundManager.shared.playErrorSound()
                }
            }
        }
    }

    func stopRecording() {
        recordingTask?.cancel()
        recordingTask = nil

        guard let recordingURL = audioRecorder.stopRecording() else {
            state = .error("No recording")
            return
        }

        currentRecordingURL = recordingURL
        state = .processing
        SoundManager.shared.playStopSound()

        processingTask = Task {
            do {
                let prompt = SettingsManager.shared.transcriptionPrompt.isEmpty
                    ? nil
                    : SettingsManager.shared.transcriptionPrompt

                let transcription = try await transcriptionService.transcribe(
                    audioURL: recordingURL,
                    prompt: prompt
                )

                guard !Task.isCancelled else { return }

                // Copy to clipboard and optionally paste
                if SettingsManager.shared.autoPasteEnabled {
                    ClipboardService.copyAndPaste(transcription)
                } else {
                    ClipboardService.copy(transcription)
                }

                state = .done

                // Clean up the recording file
                audioRecorder.deleteRecording(at: recordingURL)

                try? await Task.sleep(for: .seconds(1.2))

                guard !Task.isCancelled else { return }
                reset()
            } catch {
                guard !Task.isCancelled else { return }

                let errorMessage: String
                if let transcriptionError = error as? TranscriptionError {
                    switch transcriptionError {
                    case .noAPIKey:
                        errorMessage = "No API key"
                    case .apiError(let message):
                        // Truncate long error messages
                        errorMessage = String(message.prefix(20))
                    default:
                        errorMessage = "API error"
                    }
                } else {
                    errorMessage = "Failed"
                }

                state = .error(errorMessage)
                SoundManager.shared.playErrorSound()

                // Clean up on error too
                if let url = currentRecordingURL {
                    audioRecorder.deleteRecording(at: url)
                }

                try? await Task.sleep(for: .seconds(3))

                guard !Task.isCancelled else { return }
                reset()
            }
        }
    }

    func cancel() {
        recordingTask?.cancel()
        recordingTask = nil
        processingTask?.cancel()
        processingTask = nil
        audioRecorder.cancelRecording()
        reset()
    }

    func reset() {
        state = .idle
        audioLevel = 0
        recordingDuration = 0
        currentRecordingURL = nil
    }

    func retry() {
        if case .error = state {
            stopRecording()
        }
    }
}
