import Foundation
import Testing
@testable import notchtalk

@MainActor
struct TranscriptionDiagnosticsStoreTests {
    @Test("Cancelled recordings remain available for manual transcription")
    func cancelledRecordingIsRetained() throws {
        let testDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchtalk_cancelled_recording_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: testDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testDirectory) }

        let store = TranscriptionDiagnosticsStore(
            storageURL: testDirectory.appendingPathComponent("diagnostics.json")
        )
        let sourceURL = testDirectory.appendingPathComponent("cancelled.m4a")
        try Data("CANCELLED_AUDIO".utf8).write(to: sourceURL)

        let id = store.startRecording(
            audioURL: sourceURL,
            provider: .elevenLabs,
            speakerRecognitionEnabled: true
        )
        let retainedURL = try #require(store.retainAudio(sourceURL: sourceURL, for: id))
        store.markCancelled(for: id, reason: "Escape confirmed by second press")

        let entry = try #require(store.entries.first)
        #expect(entry.status == .cancelled)
        #expect(entry.provider == .elevenLabs)
        #expect(entry.speakerRecognitionEnabled == true)
        #expect(FileManager.default.fileExists(atPath: retainedURL.path))
        #expect(store.retainedAudioURL(for: id) == retainedURL)
    }

    @Test("History cap never removes recordings before their retention deadline")
    func historyCapPreservesUnexpiredAudio() throws {
        let testDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchtalk_history_cap_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: testDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testDirectory) }

        let now = Date()
        let store = TranscriptionDiagnosticsStore(
            storageURL: testDirectory.appendingPathComponent("diagnostics.json"),
            maxEntries: 2,
            retentionInterval: 60,
            now: now
        )

        for index in 0..<3 {
            let sourceURL = testDirectory.appendingPathComponent("recording_\(index).m4a")
            try Data("AUDIO_\(index)".utf8).write(to: sourceURL)
            let id = store.startTranscription(audioURL: sourceURL, prompt: nil)
            store.markSucceeded(for: id, transcriptText: "Transcript \(index)", outputCharacterCount: 12)
            _ = try #require(store.retainAudio(sourceURL: sourceURL, for: id, now: now))
        }

        #expect(store.entries.count == 3)
        #expect(store.entries.allSatisfy { $0.retainedAudioFilename != nil })

        store.purgeExpiredRetainedAudio(now: now.addingTimeInterval(61))

        #expect(store.entries.count == 2)
        #expect(store.entries.allSatisfy { $0.retainedAudioFilename == nil })
    }

    @Test("Retained recordings are purged at their deadline without another app event")
    func retainedRecordingIsPurgedAutomatically() async throws {
        let testDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchtalk_scheduled_retention_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: testDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testDirectory) }

        let store = TranscriptionDiagnosticsStore(
            storageURL: testDirectory.appendingPathComponent("diagnostics.json"),
            retentionInterval: 0.05
        )
        let sourceAudioURL = testDirectory.appendingPathComponent("recording.m4a")
        try Data("AUDIO".utf8).write(to: sourceAudioURL)
        let id = store.startTranscription(audioURL: sourceAudioURL, prompt: nil)
        let retainedURL = try #require(store.retainAudio(sourceURL: sourceAudioURL, for: id))

        try await Task.sleep(for: .milliseconds(150))

        #expect(!FileManager.default.fileExists(atPath: retainedURL.path))
        #expect(store.entries.first?.retainedAudioFilename == nil)
    }

    @Test("Manual re-transcription preserves the previous successful transcript until replacement succeeds")
    func manualRetryPreservesTranscript() throws {
        let testDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchtalk_retry_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: testDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testDirectory) }

        let store = TranscriptionDiagnosticsStore(
            storageURL: testDirectory.appendingPathComponent("diagnostics.json")
        )
        let audioURL = testDirectory.appendingPathComponent("recording.m4a")
        try Data("AUDIO".utf8).write(to: audioURL)
        let id = store.startTranscription(audioURL: audioURL, prompt: nil)
        store.markSucceeded(for: id, transcriptText: "original transcript", outputCharacterCount: 19)

        store.prepareForManualRetry(for: id)

        let entry = try #require(store.entries.first)
        #expect(entry.status == .pending)
        #expect(entry.transcriptText == "original transcript")
        #expect(entry.outputCharacterCount == 19)
        #expect(entry.provider == .openAI)

        store.markSucceeded(
            for: id,
            transcriptText: "replacement transcript",
            outputCharacterCount: 22,
            provider: .elevenLabs,
            speakerRecognitionEnabled: true,
            promptProvided: false
        )

        let replacedEntry = try #require(store.entries.first)
        #expect(replacedEntry.provider == .elevenLabs)
        #expect(replacedEntry.speakerRecognitionEnabled == true)
        #expect(replacedEntry.transcriptText == "replacement transcript")
    }

    @Test("Retained recordings are deleted after the configured retention window")
    func retainedRecordingExpires() throws {
        let testDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchtalk_retention_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: testDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testDirectory) }

        let storageURL = testDirectory.appendingPathComponent("transcription_diagnostics.json")
        let now = Date()
        let store = TranscriptionDiagnosticsStore(
            storageURL: storageURL,
            retentionInterval: 60,
            now: now
        )

        let sourceAudioURL = testDirectory.appendingPathComponent("recording.m4a")
        try Data("AUDIO".utf8).write(to: sourceAudioURL)
        let id = store.startTranscription(
            audioURL: sourceAudioURL,
            prompt: nil,
            provider: .elevenLabs,
            speakerRecognitionEnabled: true
        )

        store.retainAudio(sourceURL: sourceAudioURL, for: id, now: now)
        let retainedURL = try #require(store.retainedAudioURL(for: id))
        #expect(FileManager.default.fileExists(atPath: retainedURL.path))
        #expect(store.entries.first?.provider == .elevenLabs)
        #expect(store.entries.first?.speakerRecognitionEnabled == true)

        store.purgeExpiredRetainedAudio(now: now.addingTimeInterval(61))

        #expect(!FileManager.default.fileExists(atPath: retainedURL.path))
        #expect(store.entries.first?.retainedAudioFilename == nil)
        #expect(store.entries.first?.retainedAudioExpiresAt == nil)
    }
}
