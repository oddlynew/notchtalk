//
//  TranscriptionJobs.swift
//  notchtalk
//

import Foundation

/// Transcriptions started in the app or the menu: Transcribe on a voice memo, Retry on an entry, a
/// dropped file, a call, a recall from the menu. Each starts at once as its own job on its own History
/// entry and finishes on its own, next to the others and to the shortcut's recording, which stays one
/// at a time in NotchStateManager. A provider's rate limit shows as that job's error, with its Retry.
@MainActor
@Observable
final class TranscriptionJobs {
    static let shared = TranscriptionJobs()

    private struct Job {
        let id: UUID
        let audioDuration: TimeInterval?
        let copyWhenDone: Bool
    }

    private var running: Set<UUID> = []
    private let store = TranscriptionDiagnosticsStore.shared

    /// Transcribes the entry's retained audio. `copyWhenDone` puts the text on the clipboard: right
    /// for a single action like a drop, wrong for a list where several finish in any order.
    func transcribe(_ id: UUID, audioDuration: TimeInterval? = nil, reason: String, copyWhenDone: Bool = false) {
        guard !running.contains(id) else { return }
        running.insert(id)
        store.prepareForManualRetry(for: id, reason: reason)
        let job = Job(id: id, audioDuration: audioDuration, copyWhenDone: copyWhenDone)
        Task {
            await run(job)
            running.remove(id)
        }
    }

    private func run(_ job: Job) async {
        guard let audio = store.retainedAudioURL(for: job.id), FileManager.default.fileExists(atPath: audio.path) else {
            store.markFailed(for: job.id, message: "The audio is gone; Notchtalk keeps it for 24 hours")
            return
        }
        let provider = SettingsManager.shared.transcriptionProvider
        guard provider.isReady else {
            store.markFailed(for: job.id, message: provider.localModel != nil ? provider.notReadyMessage : "No API key for \(provider.displayName)")
            return
        }
        let speakerRecognitionEnabled = provider == .elevenLabs && SettingsManager.shared.elevenLabsSpeakerRecognitionEnabled
        let prompt = provider == .openAI && !SettingsManager.shared.transcriptionPrompt.isEmpty
            ? SettingsManager.shared.transcriptionPrompt
            : nil
        let id = job.id
        store.log("Uploading audio payload", for: id)
        do {
            let (text, model) = try await NotchStateManager.shared.transcribe(
                audioURL: audio,
                prompt: prompt,
                provider: provider,
                speakerRecognitionEnabled: speakerRecognitionEnabled,
                audioDuration: job.audioDuration,
                onRetry: { attempt, total in TranscriptionDiagnosticsStore.shared.registerRetry(attempt: attempt, total: total, for: id) },
                onLog: { message, level in TranscriptionDiagnosticsStore.shared.log(message, level: level, for: id) }
            )
            store.markSucceeded(
                for: id,
                transcriptText: text,
                outputCharacterCount: text.count,
                provider: provider,
                model: model,
                speakerRecognitionEnabled: speakerRecognitionEnabled,
                promptProvided: prompt != nil
            )
            VoiceMemoLibrary.shared.rememberTranscribed(id)
            if job.copyWhenDone, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                ClipboardService.copy(text)
            }
        } catch {
            store.markFailed(for: id, message: error.localizedDescription)
        }
    }
}
