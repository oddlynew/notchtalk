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

enum OutputDisposition: Equatable, Sendable {
    case copiedToClipboard
    case pastedToCursor
}

@MainActor
@Observable
final class NotchStateManager {
    static let shared = NotchStateManager()

    var state: AppState = .idle
    var audioLevel: CGFloat = 0.0
    var recordingDuration: TimeInterval = 0
    var retryAttempt: Int?
    var totalRetries = 0
    var lastOutputDisposition: OutputDisposition?
    var processingElapsed: TimeInterval = 0

    var processingStatusText: String {
        if let retryAttempt, totalRetries > 0 {
            return "Retrying (\(retryAttempt)/\(totalRetries))"
        }
        if processingElapsed >= 10 {
            return "Still transcribing"
        }
        return "Transcribing"
    }

    private var recordingTask: Task<Void, Never>?
    private var processingTask: Task<Void, Never>?
    private var processingTimerTask: Task<Void, Never>?
    private let audioRecorder = AudioRecorder()
    private let transcriptionService = OpenAITranscriptionService(fallbackModel: "gpt-4o-mini-transcribe")
    private let diagnosticsStore = TranscriptionDiagnosticsStore.shared
    private var currentRecordingURL: URL?
    private var currentRecordingDuration: TimeInterval?
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
        currentRecordingDuration = capturedRecordingDuration
        state = .processing
        retryAttempt = nil
        totalRetries = 0
        processingElapsed = 0
        SoundManager.shared.playStopSound()

        let prompt = SettingsManager.shared.transcriptionPrompt.isEmpty
            ? nil
            : SettingsManager.shared.transcriptionPrompt
        let diagnosticsID = diagnosticsStore.startTranscription(audioURL: recordingURL, prompt: prompt)
        activeDiagnosticsID = diagnosticsID
        diagnosticsStore.log("Uploading audio payload", for: diagnosticsID)
        startProcessingTimer()

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

                diagnosticsStore.markSucceeded(
                    for: diagnosticsID,
                    transcriptText: transcription,
                    outputCharacterCount: transcription.count
                )

                // Copy to clipboard and optionally paste
                if SettingsManager.shared.autoPasteEnabled {
                    lastOutputDisposition = .pastedToCursor
                    ClipboardService.pastePreservingClipboard(transcription)
                } else {
                    lastOutputDisposition = .copiedToClipboard
                    ClipboardService.copy(transcription)
                }

                state = .done

                // Clean up the recording file
                audioRecorder.deleteRecording(at: recordingURL)
                activeDiagnosticsID = nil
                stopProcessingTimer()

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
                stopProcessingTimer()

                if let url = currentRecordingURL {
                    if SettingsManager.shared.retainFailedRecordingsEnabled {
                        diagnosticsStore.retainAudioForManualRetry(sourceURL: url, for: diagnosticsID)
                    } else {
                        audioRecorder.deleteRecording(at: url)
                    }
                }

                activeDiagnosticsID = nil

                try? await Task.sleep(for: .seconds(3))

                guard !Task.isCancelled else { return }
                reset()
            }
        }
    }

    func retryProcessing() {
        guard case .processing = state else {
            return
        }
        guard let url = currentRecordingURL else {
            return
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            state = .error("Missing audio")
            SoundManager.shared.playErrorSound()
            Task {
                try? await Task.sleep(for: .seconds(2))
                reset()
            }
            return
        }
        guard let diagnosticsID = activeDiagnosticsID else {
            return
        }

        processingTask?.cancel()
        processingTask = nil

        retryAttempt = nil
        totalRetries = 0
        processingElapsed = 0
        diagnosticsStore.log("User requested retry; cancelling in-flight request", level: .warning, for: diagnosticsID)
        diagnosticsStore.prepareForManualRetry(for: diagnosticsID)
        diagnosticsStore.log("Uploading audio payload", for: diagnosticsID)
        startProcessingTimer()

        let prompt = SettingsManager.shared.transcriptionPrompt.isEmpty
            ? nil
            : SettingsManager.shared.transcriptionPrompt
        let capturedDuration = currentRecordingDuration

        processingTask = Task {
            do {
                let transcription = try await transcriptionService.transcribe(
                    audioURL: url,
                    prompt: prompt,
                    audioDuration: capturedDuration,
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

                diagnosticsStore.markSucceeded(
                    for: diagnosticsID,
                    transcriptText: transcription,
                    outputCharacterCount: transcription.count
                )

                if SettingsManager.shared.autoPasteEnabled {
                    lastOutputDisposition = .pastedToCursor
                    ClipboardService.pastePreservingClipboard(transcription)
                } else {
                    lastOutputDisposition = .copiedToClipboard
                    ClipboardService.copy(transcription)
                }

                state = .done
                audioRecorder.deleteRecording(at: url)
                activeDiagnosticsID = nil
                stopProcessingTimer()

                try? await Task.sleep(for: .seconds(1.2))

                guard !Task.isCancelled else { return }
                reset()
            } catch {
                guard !Task.isCancelled else { return }

                diagnosticsStore.markFailed(for: diagnosticsID, message: error.localizedDescription)
                state = .error("Failed")
                SoundManager.shared.playErrorSound()
                stopProcessingTimer()

                if SettingsManager.shared.retainFailedRecordingsEnabled {
                    diagnosticsStore.retainAudioForManualRetry(sourceURL: url, for: diagnosticsID)
                } else {
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
        stopProcessingTimer()
        reset()
    }

    func reset() {
        stopProcessingTimer()
        state = .idle
        audioLevel = 0
        recordingDuration = 0
        retryAttempt = nil
        totalRetries = 0
        processingElapsed = 0
        currentRecordingURL = nil
        currentRecordingDuration = nil
        lastOutputDisposition = nil
    }

    func retry() {
        if case .error = state {
            stopRecording()
        }
    }

    func retranscribe(diagnosticsID: UUID) {
        if case .recording = state {
            return
        }
        if case .processing = state {
            return
        }

        guard let retainedAudioURL = diagnosticsStore.retainedAudioURL(for: diagnosticsID) else {
            state = .error("No audio")
            SoundManager.shared.playErrorSound()
            Task {
                try? await Task.sleep(for: .seconds(2))
                reset()
            }
            return
        }

        if !FileManager.default.fileExists(atPath: retainedAudioURL.path) {
            state = .error("Missing audio")
            SoundManager.shared.playErrorSound()
            Task {
                try? await Task.sleep(for: .seconds(2))
                reset()
            }
            return
        }

        state = .processing
        retryAttempt = nil
        totalRetries = 0
        processingElapsed = 0
        currentRecordingURL = retainedAudioURL
        currentRecordingDuration = nil
        activeDiagnosticsID = diagnosticsID

        diagnosticsStore.prepareForManualRetry(for: diagnosticsID)
        diagnosticsStore.log("Uploading audio payload", for: diagnosticsID)
        startProcessingTimer()

        let prompt = SettingsManager.shared.transcriptionPrompt.isEmpty
            ? nil
            : SettingsManager.shared.transcriptionPrompt

        processingTask?.cancel()
        processingTask = Task {
            do {
                let transcription = try await transcriptionService.transcribe(
                    audioURL: retainedAudioURL,
                    prompt: prompt,
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

                diagnosticsStore.markSucceeded(
                    for: diagnosticsID,
                    transcriptText: transcription,
                    outputCharacterCount: transcription.count
                )

                if SettingsManager.shared.autoPasteEnabled {
                    lastOutputDisposition = .pastedToCursor
                    ClipboardService.pastePreservingClipboard(transcription)
                } else {
                    lastOutputDisposition = .copiedToClipboard
                    ClipboardService.copy(transcription)
                }

                state = .done
                diagnosticsStore.clearRetainedAudio(for: diagnosticsID)
                activeDiagnosticsID = nil
                stopProcessingTimer()

                try? await Task.sleep(for: .seconds(1.2))

                guard !Task.isCancelled else { return }
                reset()
            } catch {
                guard !Task.isCancelled else { return }

                diagnosticsStore.markFailed(for: diagnosticsID, message: error.localizedDescription)
                state = .error("Failed")
                SoundManager.shared.playErrorSound()
                activeDiagnosticsID = nil
                stopProcessingTimer()

                try? await Task.sleep(for: .seconds(3))

                guard !Task.isCancelled else { return }
                reset()
            }
        }
    }

    private func startProcessingTimer() {
        processingTimerTask?.cancel()
        processingTimerTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let start = Date()
            while !Task.isCancelled {
                guard case .processing = self.state else { break }
                self.processingElapsed = Date().timeIntervalSince(start)
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    private func stopProcessingTimer() {
        processingTimerTask?.cancel()
        processingTimerTask = nil
        processingElapsed = 0
    }
}
