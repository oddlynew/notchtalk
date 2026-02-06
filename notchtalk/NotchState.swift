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
    var retryAttempt: Int?
    var totalRetries = 0

    var processingStatusText: String {
        if let retryAttempt, totalRetries > 0 {
            return "Retrying (\(retryAttempt)/\(totalRetries))"
        }
        return "Transcribing"
    }

    private var recordingTask: Task<Void, Never>?
    private var processingTask: Task<Void, Never>?
    private let audioRecorder = AudioRecorder()
    private let transcriptionService = OpenAITranscriptionService(fallbackModel: "gpt-4o-mini-transcribe")
    private let diagnosticsStore = TranscriptionDiagnosticsStore.shared
    private var currentRecordingURL: URL?
    private var activeDiagnosticsID: UUID?

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
        let capturedRecordingDuration = recordingDuration
        state = .processing
        retryAttempt = nil
        totalRetries = 0
        SoundManager.shared.playStopSound()

        let prompt = SettingsManager.shared.transcriptionPrompt.isEmpty
            ? nil
            : SettingsManager.shared.transcriptionPrompt
        let diagnosticsID = diagnosticsStore.startTranscription(audioURL: recordingURL, prompt: prompt)
        activeDiagnosticsID = diagnosticsID
        diagnosticsStore.log("Uploading audio payload", for: diagnosticsID)

        processingTask = Task {
            do {
                let transcription = try await transcriptionService.transcribe(
                    audioURL: recordingURL,
                    prompt: prompt,
                    audioDuration: capturedRecordingDuration,
                    onRetry: { [weak self] attempt, totalRetries in
                        self?.retryAttempt = attempt
                        self?.totalRetries = totalRetries
                        self?.diagnosticsStore.registerRetry(attempt: attempt, total: totalRetries, for: diagnosticsID)
                    },
                    onLog: { [weak self] message, level in
                        self?.diagnosticsStore.log(message, level: level, for: diagnosticsID)
                    }
                )

                guard !Task.isCancelled else { return }

                diagnosticsStore.markSucceeded(for: diagnosticsID, outputCharacterCount: transcription.count)

                // Copy to clipboard and optionally paste
                if SettingsManager.shared.autoPasteEnabled {
                    ClipboardService.copyAndPaste(transcription)
                } else {
                    ClipboardService.copy(transcription)
                }

                state = .done

                // Clean up the recording file
                audioRecorder.deleteRecording(at: recordingURL)
                activeDiagnosticsID = nil

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
                    case .timeout:
                        errorMessage = "Timed out"
                    case .apiError(let message):
                        // Truncate long error messages
                        errorMessage = String(message.prefix(20))
                    default:
                        errorMessage = "API error"
                    }
                } else {
                    errorMessage = "Failed"
                }

                diagnosticsStore.markFailed(for: diagnosticsID, message: error.localizedDescription)

                state = .error(errorMessage)
                SoundManager.shared.playErrorSound()

                // Clean up on error too
                if let url = currentRecordingURL {
                    audioRecorder.deleteRecording(at: url)
                }

                activeDiagnosticsID = nil

                try? await Task.sleep(for: .seconds(3))

                guard !Task.isCancelled else { return }
                reset()
            }
        }
    }

    func cancel() {
        if let activeDiagnosticsID {
            diagnosticsStore.markCancelled(for: activeDiagnosticsID, reason: "Cancelled by user")
            self.activeDiagnosticsID = nil
        }

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
        retryAttempt = nil
        totalRetries = 0
        currentRecordingURL = nil
    }

    func retry() {
        if case .error = state {
            stopRecording()
        }
    }
}
