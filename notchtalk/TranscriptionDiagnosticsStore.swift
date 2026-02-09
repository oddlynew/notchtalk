//
//  TranscriptionDiagnosticsStore.swift
//  notchtalk
//

import Foundation

struct TranscriptionDiagnosticsEntry: Identifiable, Codable {
    enum Status: String, Codable {
        case pending
        case succeeded
        case failed
        case cancelled
    }

    enum LogLevel: String, Codable {
        case info
        case warning
        case error
    }

    struct LogEvent: Identifiable, Codable {
        let id: UUID
        let timestamp: Date
        let level: LogLevel
        let message: String

        init(id: UUID = UUID(), timestamp: Date = Date(), level: LogLevel, message: String) {
            self.id = id
            self.timestamp = timestamp
            self.level = level
            self.message = message
        }
    }

    let id: UUID
    let createdAt: Date
    var updatedAt: Date
    var status: Status
    var sourceAudioFilename: String
    var promptProvided: Bool
    var retryCount: Int
    var outputCharacterCount: Int?
    var errorMessage: String?
    var transcriptText: String?
    var retainedAudioFilename: String?
    var logs: [LogEvent]

    init(
        id: UUID = UUID(),
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        status: Status,
        sourceAudioFilename: String,
        promptProvided: Bool,
        retryCount: Int = 0,
        outputCharacterCount: Int? = nil,
        errorMessage: String? = nil,
        transcriptText: String? = nil,
        retainedAudioFilename: String? = nil,
        logs: [LogEvent] = []
    ) {
        self.id = id
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.status = status
        self.sourceAudioFilename = sourceAudioFilename
        self.promptProvided = promptProvided
        self.retryCount = retryCount
        self.outputCharacterCount = outputCharacterCount
        self.errorMessage = errorMessage
        self.transcriptText = transcriptText
        self.retainedAudioFilename = retainedAudioFilename
        self.logs = logs
    }
}

@MainActor
@Observable
final class TranscriptionDiagnosticsStore {
    static let shared = TranscriptionDiagnosticsStore()

    private(set) var entries: [TranscriptionDiagnosticsEntry] = []

    private let maxEntries = 250
    // Metrics logging can add several lines per attempt; keep enough history to diagnose tail latency.
    private let maxLogsPerEntry = 200
    private let fileManager = FileManager.default
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private var storageURL: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return appSupport
            .appendingPathComponent("notchtalk", isDirectory: true)
            .appendingPathComponent("transcription_diagnostics.json")
    }

    private var retainedAudioDirectoryURL: URL {
        storageURL
            .deletingLastPathComponent()
            .appendingPathComponent("retained_audio", isDirectory: true)
    }

    private init() {
        loadFromDisk()
    }

    func startTranscription(audioURL: URL, prompt: String?) -> UUID {
        let now = Date()
        let id = UUID()

        let entry = TranscriptionDiagnosticsEntry(
            id: id,
            createdAt: now,
            updatedAt: now,
            status: .pending,
            sourceAudioFilename: audioURL.lastPathComponent,
            promptProvided: !(prompt?.isEmpty ?? true),
            logs: [
                .init(level: .info, message: "Transcription created"),
                .init(level: .info, message: "Request queued")
            ]
        )

        entries.insert(entry, at: 0)
        trimIfNeeded()
        persistToDisk()
        return id
    }

    func log(_ message: String, level: TranscriptionDiagnosticsEntry.LogLevel = .info, for id: UUID) {
        mutateEntry(id) { entry in
            entry.logs.append(.init(level: level, message: message))
            if entry.logs.count > maxLogsPerEntry {
                entry.logs.removeFirst(entry.logs.count - maxLogsPerEntry)
            }
        }
    }

    func registerRetry(attempt: Int, total: Int, for id: UUID) {
        mutateEntry(id) { entry in
            entry.retryCount = max(entry.retryCount, attempt)
            entry.logs.append(.init(level: .warning, message: "Retry \(attempt)/\(total) scheduled"))
            if entry.logs.count > maxLogsPerEntry {
                entry.logs.removeFirst(entry.logs.count - maxLogsPerEntry)
            }
        }
    }

    func markSucceeded(for id: UUID, transcriptText: String, outputCharacterCount: Int) {
        mutateEntry(id) { entry in
            entry.status = .succeeded
            entry.transcriptText = transcriptText
            entry.outputCharacterCount = outputCharacterCount
            entry.errorMessage = nil
            entry.logs.append(.init(level: .info, message: "Transcription succeeded"))
            if entry.logs.count > maxLogsPerEntry {
                entry.logs.removeFirst(entry.logs.count - maxLogsPerEntry)
            }
        }
    }

    func markFailed(for id: UUID, message: String) {
        mutateEntry(id) { entry in
            entry.status = .failed
            entry.errorMessage = message
            entry.logs.append(.init(level: .error, message: "Transcription failed: \(message)"))
            if entry.logs.count > maxLogsPerEntry {
                entry.logs.removeFirst(entry.logs.count - maxLogsPerEntry)
            }
        }
    }

    func prepareForManualRetry(for id: UUID) {
        mutateEntry(id) { entry in
            entry.status = .pending
            entry.errorMessage = nil
            entry.retryCount = 0
            entry.outputCharacterCount = nil
            entry.transcriptText = nil
            entry.logs.append(.init(level: .info, message: "Manual re-transcribe requested"))
            if entry.logs.count > maxLogsPerEntry {
                entry.logs.removeFirst(entry.logs.count - maxLogsPerEntry)
            }
        }
    }

    func markCancelled(for id: UUID, reason: String) {
        mutateEntry(id) { entry in
            entry.status = .cancelled
            entry.errorMessage = reason
            entry.logs.append(.init(level: .warning, message: "Cancelled: \(reason)"))
            if entry.logs.count > maxLogsPerEntry {
                entry.logs.removeFirst(entry.logs.count - maxLogsPerEntry)
            }
        }
    }

    func clearAll() {
        for entry in entries {
            if let retainedURL = retainedAudioURL(for: entry.id) {
                try? fileManager.removeItem(at: retainedURL)
            }
        }
        entries.removeAll()
        persistToDisk()
    }

    func retainedAudioURL(for id: UUID) -> URL? {
        guard let entry = entries.first(where: { $0.id == id }) else {
            return nil
        }
        guard let filename = entry.retainedAudioFilename, !filename.isEmpty else {
            return nil
        }
        return retainedAudioDirectoryURL.appendingPathComponent(filename)
    }

    func retainAudioForManualRetry(sourceURL: URL, for id: UUID) {
        let fileExtension = sourceURL.pathExtension.isEmpty ? "m4a" : sourceURL.pathExtension
        let destinationURL = retainedAudioDirectoryURL.appendingPathComponent("\(id.uuidString).\(fileExtension)")

        do {
            try fileManager.createDirectory(at: retainedAudioDirectoryURL, withIntermediateDirectories: true)

            if fileManager.fileExists(atPath: destinationURL.path) {
                try? fileManager.removeItem(at: destinationURL)
            }

            do {
                try fileManager.moveItem(at: sourceURL, to: destinationURL)
            } catch {
                // Fallback to copy+remove if move fails.
                try fileManager.copyItem(at: sourceURL, to: destinationURL)
                try? fileManager.removeItem(at: sourceURL)
            }

            mutateEntry(id) { entry in
                entry.retainedAudioFilename = destinationURL.lastPathComponent
                entry.logs.append(.init(level: .warning, message: "Retained audio locally for manual retry"))
                if entry.logs.count > maxLogsPerEntry {
                    entry.logs.removeFirst(entry.logs.count - maxLogsPerEntry)
                }
            }
        } catch {
            mutateEntry(id) { entry in
                entry.logs.append(.init(level: .error, message: "Failed to retain audio for retry: \(error.localizedDescription)"))
                if entry.logs.count > maxLogsPerEntry {
                    entry.logs.removeFirst(entry.logs.count - maxLogsPerEntry)
                }
            }
        }
    }

    func clearRetainedAudio(for id: UUID) {
        if let retainedURL = retainedAudioURL(for: id) {
            try? fileManager.removeItem(at: retainedURL)
        }
        mutateEntry(id) { entry in
            entry.retainedAudioFilename = nil
        }
    }

    private func mutateEntry(_ id: UUID, _ mutate: (inout TranscriptionDiagnosticsEntry) -> Void) {
        guard let index = entries.firstIndex(where: { $0.id == id }) else {
            return
        }

        mutate(&entries[index])
        entries[index].updatedAt = Date()
        persistToDisk()
    }

    private func trimIfNeeded() {
        if entries.count > maxEntries {
            entries.removeLast(entries.count - maxEntries)
        }
    }

    private func loadFromDisk() {
        guard let data = try? Data(contentsOf: storageURL) else {
            return
        }

        guard let decoded = try? decoder.decode([TranscriptionDiagnosticsEntry].self, from: data) else {
            return
        }

        entries = decoded.sorted { $0.createdAt > $1.createdAt }
        trimIfNeeded()
    }

    private func persistToDisk() {
        let directoryURL = storageURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            let data = try encoder.encode(entries)
            try data.write(to: storageURL, options: .atomic)
        } catch {
            NSLog("Failed to persist diagnostics: \(error.localizedDescription)")
        }
    }
}
