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

struct DoublePressConfirmationGate {
    private(set) var expiresAt: Date?

    mutating func registerPress(now: Date = Date(), interval: TimeInterval = 2.5) -> Bool {
        if let expiresAt, now <= expiresAt {
            self.expiresAt = nil
            return true
        }

        expiresAt = now.addingTimeInterval(interval)
        return false
    }

    mutating func reset() {
        expiresAt = nil
    }
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
    var cancelConfirmationRequested = false

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
    private var cancelConfirmationTask: Task<Void, Never>?
    private var cancelConfirmationGate = DoublePressConfirmationGate()
    private let audioRecorder = AudioRecorder()
    private let openAITranscriptionService = OpenAITranscriptionService(fallbackModel: "gpt-4o-mini-transcribe")
    private let elevenLabsTranscriptionService = ElevenLabsTranscriptionService()
    private let diagnosticsStore = TranscriptionDiagnosticsStore.shared
    private var currentRecordingURL: URL?
    private var currentRecordingDuration: TimeInterval?
    private var activeDiagnosticsID: UUID?

    init() {
        audioRecorder.onAudioLevelUpdate = { [weak self] level in
            self?.audioLevel = level
        }
    }

    func toggle(trigger: String = "programmatic") {
        switch state {
        case .idle:
            startRecording()
        case .recording:
            stopRecording(trigger: trigger)
        case .processing:
            break
        case .done, .error:
            reset()
        }
    }

    func startRecording() {
        let provider = SettingsManager.shared.transcriptionProvider
        guard KeychainService.hasAPIKey(for: provider) else {
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
        currentRecordingURL = nil
        activeDiagnosticsID = nil
        clearCancelConfirmation()
        AudioDuckingService.shared.beginDucking()
        SoundManager.shared.playStartSound()

        let speakerRecognitionEnabled = provider == .elevenLabs
            && SettingsManager.shared.elevenLabsSpeakerRecognitionEnabled

        recordingTask = Task {
            do {
                let recordingURL = try await audioRecorder.startRecording()
                currentRecordingURL = recordingURL
                activeDiagnosticsID = diagnosticsStore.startRecording(
                    audioURL: recordingURL,
                    provider: provider,
                    speakerRecognitionEnabled: speakerRecognitionEnabled
                )

                // Update duration timer
                while !Task.isCancelled && audioRecorder.isRecording {
                    try? await Task.sleep(for: .milliseconds(100))
                    recordingDuration += 0.1
                }
            } catch {
                await MainActor.run {
                    AudioDuckingService.shared.endDucking()
                    self.state = .error("Mic error")
                    SoundManager.shared.playErrorSound()
                }
            }
        }
    }

    func stopRecording(trigger: String = "programmatic") {
        clearCancelConfirmation()
        recordingTask?.cancel()
        recordingTask = nil

        guard let recordingURL = audioRecorder.stopRecording() else {
            AudioDuckingService.shared.endDucking()
            state = .error("No recording")
            return
        }
        AudioDuckingService.shared.endDucking()

        currentRecordingURL = recordingURL
        let capturedRecordingDuration = recordingDuration
        currentRecordingDuration = capturedRecordingDuration
        state = .processing
        retryAttempt = nil
        totalRetries = 0
        processingElapsed = 0
        SoundManager.shared.playStopSound()

        let provider = SettingsManager.shared.transcriptionProvider
        let speakerRecognitionEnabled = provider == .elevenLabs
            && SettingsManager.shared.elevenLabsSpeakerRecognitionEnabled
        let prompt = provider == .openAI && !SettingsManager.shared.transcriptionPrompt.isEmpty
            ? SettingsManager.shared.transcriptionPrompt
            : nil
        let diagnosticsID = activeDiagnosticsID ?? diagnosticsStore.startRecording(
            audioURL: recordingURL,
            provider: provider,
            speakerRecognitionEnabled: speakerRecognitionEnabled
        )
        diagnosticsStore.beginTranscription(
            for: diagnosticsID,
            prompt: prompt,
            provider: provider,
            speakerRecognitionEnabled: speakerRecognitionEnabled,
            stopTrigger: trigger,
            recordingDuration: capturedRecordingDuration
        )
        let transcriptionAudioURL = diagnosticsStore.retainAudio(
            sourceURL: recordingURL,
            for: diagnosticsID
        ) ?? recordingURL
        currentRecordingURL = transcriptionAudioURL
        activeDiagnosticsID = diagnosticsID
        diagnosticsStore.log("Uploading audio payload", for: diagnosticsID)
        startProcessingTimer()

        processingTask = Task {
            do {
                let transcription = try await transcribe(
                    audioURL: transcriptionAudioURL,
                    prompt: prompt,
                    provider: provider,
                    speakerRecognitionEnabled: speakerRecognitionEnabled,
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
                    outputCharacterCount: transcription.count,
                    provider: provider,
                    speakerRecognitionEnabled: speakerRecognitionEnabled,
                    promptProvided: prompt != nil
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

                retainRecordingIfNeeded(transcriptionAudioURL, diagnosticsID: diagnosticsID)
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
                    retainRecordingIfNeeded(url, diagnosticsID: diagnosticsID)
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
        let provider = SettingsManager.shared.transcriptionProvider
        let speakerRecognitionEnabled = provider == .elevenLabs
            && SettingsManager.shared.elevenLabsSpeakerRecognitionEnabled
        let prompt = provider == .openAI && !SettingsManager.shared.transcriptionPrompt.isEmpty
            ? SettingsManager.shared.transcriptionPrompt
            : nil
        diagnosticsStore.prepareForManualRetry(for: diagnosticsID)
        diagnosticsStore.log("Uploading audio payload", for: diagnosticsID)
        startProcessingTimer()

        let capturedDuration = currentRecordingDuration

        processingTask = Task {
            do {
                let transcription = try await transcribe(
                    audioURL: url,
                    prompt: prompt,
                    provider: provider,
                    speakerRecognitionEnabled: speakerRecognitionEnabled,
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
                    outputCharacterCount: transcription.count,
                    provider: provider,
                    speakerRecognitionEnabled: speakerRecognitionEnabled,
                    promptProvided: prompt != nil
                )

                if SettingsManager.shared.autoPasteEnabled {
                    lastOutputDisposition = .pastedToCursor
                    ClipboardService.pastePreservingClipboard(transcription)
                } else {
                    lastOutputDisposition = .copiedToClipboard
                    ClipboardService.copy(transcription)
                }

                state = .done
                retainRecordingIfNeeded(url, diagnosticsID: diagnosticsID)
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

                retainRecordingIfNeeded(url, diagnosticsID: diagnosticsID)

                activeDiagnosticsID = nil

                try? await Task.sleep(for: .seconds(3))

                guard !Task.isCancelled else { return }
                reset()
            }
        }
    }

    func requestEscapeCancel(now: Date = Date()) {
        guard state == .recording || state == .processing else { return }

        if cancelConfirmationGate.registerPress(now: now) {
            cancel(reason: "Escape confirmed by second press")
            return
        }

        cancelConfirmationRequested = true
        if let activeDiagnosticsID {
            diagnosticsStore.log(
                "Escape pressed once; waiting for second press before cancelling",
                level: .warning,
                for: activeDiagnosticsID
            )
        }

        cancelConfirmationTask?.cancel()
        let delay = max(0, cancelConfirmationGate.expiresAt?.timeIntervalSince(now) ?? 2.5)
        cancelConfirmationTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(delay))
            } catch {
                return
            }

            guard let self, self.cancelConfirmationRequested else { return }
            self.cancelConfirmationRequested = false
            self.cancelConfirmationGate.reset()
            self.cancelConfirmationTask = nil
            if let activeDiagnosticsID = self.activeDiagnosticsID {
                self.diagnosticsStore.log(
                    "Escape cancellation confirmation expired; recording continued",
                    for: activeDiagnosticsID
                )
            }
        }
    }

    func cancel(reason: String = "Cancel button") {
        let wasRecording = state == .recording
        clearCancelConfirmation()
        recordingTask?.cancel()
        recordingTask = nil
        processingTask?.cancel()
        processingTask = nil

        if wasRecording, let recordingURL = audioRecorder.stopRecording() {
            currentRecordingURL = recordingURL
            currentRecordingDuration = recordingDuration

            let provider = SettingsManager.shared.transcriptionProvider
            let speakerRecognitionEnabled = provider == .elevenLabs
                && SettingsManager.shared.elevenLabsSpeakerRecognitionEnabled
            let diagnosticsID = activeDiagnosticsID ?? diagnosticsStore.startRecording(
                audioURL: recordingURL,
                provider: provider,
                speakerRecognitionEnabled: speakerRecognitionEnabled
            )
            diagnosticsStore.log(
                "Recording cancelled after \(String(format: "%.2f", recordingDuration))s; trigger=\(reason)",
                level: .warning,
                for: diagnosticsID
            )
            retainRecordingIfNeeded(recordingURL, diagnosticsID: diagnosticsID)
            diagnosticsStore.markCancelled(for: diagnosticsID, reason: reason)
        } else {
            audioRecorder.cancelRecording()
            if let activeDiagnosticsID {
                diagnosticsStore.markCancelled(for: activeDiagnosticsID, reason: reason)
                if let currentRecordingURL {
                    retainRecordingIfNeeded(currentRecordingURL, diagnosticsID: activeDiagnosticsID)
                }
            }
        }

        activeDiagnosticsID = nil
        AudioDuckingService.shared.endDucking()
        stopProcessingTimer()
        reset()
    }

    func reset() {
        AudioDuckingService.shared.endDucking()
        stopProcessingTimer()
        state = .idle
        audioLevel = 0
        recordingDuration = 0
        retryAttempt = nil
        totalRetries = 0
        processingElapsed = 0
        clearCancelConfirmation()
        currentRecordingURL = nil
        currentRecordingDuration = nil
        lastOutputDisposition = nil
    }

    func retry() {
        if case .error = state {
            stopRecording(trigger: "retry_action")
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

        let provider = SettingsManager.shared.transcriptionProvider
        guard KeychainService.hasAPIKey(for: provider) else {
            state = .error("No API key")
            SettingsWindowController.show()
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

        let speakerRecognitionEnabled = provider == .elevenLabs
            && SettingsManager.shared.elevenLabsSpeakerRecognitionEnabled
        let prompt = provider == .openAI && !SettingsManager.shared.transcriptionPrompt.isEmpty
            ? SettingsManager.shared.transcriptionPrompt
            : nil
        diagnosticsStore.prepareForManualRetry(for: diagnosticsID)
        diagnosticsStore.log("Uploading audio payload", for: diagnosticsID)
        startProcessingTimer()

        processingTask?.cancel()
        processingTask = Task {
            do {
                let transcription = try await transcribe(
                    audioURL: retainedAudioURL,
                    prompt: prompt,
                    provider: provider,
                    speakerRecognitionEnabled: speakerRecognitionEnabled,
                    audioDuration: nil,
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
                    outputCharacterCount: transcription.count,
                    provider: provider,
                    speakerRecognitionEnabled: speakerRecognitionEnabled,
                    promptProvided: prompt != nil
                )

                if SettingsManager.shared.autoPasteEnabled {
                    lastOutputDisposition = .pastedToCursor
                    ClipboardService.pastePreservingClipboard(transcription)
                } else {
                    lastOutputDisposition = .copiedToClipboard
                    ClipboardService.copy(transcription)
                }

                state = .done
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

    private func transcribe(
        audioURL: URL,
        prompt: String?,
        provider: TranscriptionProvider,
        speakerRecognitionEnabled: Bool,
        audioDuration: TimeInterval?,
        onRetry: (@MainActor @Sendable (_ retryAttempt: Int, _ totalRetries: Int) async -> Void)?,
        onLog: (@MainActor @Sendable (_ message: String, _ level: TranscriptionDiagnosticsEntry.LogLevel) async -> Void)?
    ) async throws -> String {
        switch provider {
        case .openAI:
            return try await openAITranscriptionService.transcribe(
                audioURL: audioURL,
                prompt: prompt,
                audioDuration: audioDuration,
                onRetry: onRetry,
                onLog: onLog
            )
        case .elevenLabs:
            return try await elevenLabsTranscriptionService.transcribe(
                audioURL: audioURL,
                diarize: speakerRecognitionEnabled,
                useSpeakerLibrary: speakerRecognitionEnabled
                    && SettingsManager.shared.elevenLabsSpeakerLibraryRecognitionEnabled,
                onRetry: onRetry,
                onLog: onLog
            )
        }
    }

    private func retainRecordingIfNeeded(_ audioURL: URL, diagnosticsID: UUID) {
        if let retainedURL = diagnosticsStore.retainedAudioURL(for: diagnosticsID),
           retainedURL.standardizedFileURL == audioURL.standardizedFileURL {
            return
        }
        diagnosticsStore.retainAudio(sourceURL: audioURL, for: diagnosticsID)
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

    private func clearCancelConfirmation() {
        cancelConfirmationTask?.cancel()
        cancelConfirmationTask = nil
        cancelConfirmationGate.reset()
        cancelConfirmationRequested = false
    }
}
