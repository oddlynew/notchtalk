//
//  ElevenLabsTranscriptionService.swift
//  notchtalk
//

import Foundation

actor ElevenLabsTranscriptionService {
    typealias UploadFunction = @Sendable (_ request: URLRequest, _ bodyURL: URL) async throws -> (Data, URLResponse)
    typealias APIKeyProvider = @Sendable () -> String?
    typealias RetryHandler = @MainActor @Sendable (_ retryAttempt: Int, _ totalRetries: Int) async -> Void
    typealias LogHandler = @MainActor @Sendable (_ message: String, _ level: TranscriptionDiagnosticsEntry.LogLevel) async -> Void

    private static let model = "scribe_v2"
    private static let retryableHTTPStatusCodes: Set<Int> = [408, 429, 500, 502, 503, 504]
    private let endpoint = URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!
    private let maxRetries: Int
    private let retryDelay: Duration
    private let retryMaxDelaySeconds: TimeInterval
    private let randomDouble: @Sendable () -> Double
    private let apiKeyProvider: APIKeyProvider
    private let upload: UploadFunction

    init(
        maxRetries: Int = 2,
        retryDelay: Duration = .milliseconds(500),
        retryMaxDelaySeconds: TimeInterval = 30,
        randomDouble: @escaping @Sendable () -> Double = { Double.random(in: 0...1) },
        apiKeyProvider: @escaping APIKeyProvider = { KeychainService.getAPIKey(for: .elevenLabs) },
        upload: @escaping UploadFunction = { request, bodyURL in
            let configuration = URLSessionConfiguration.ephemeral
            configuration.waitsForConnectivity = false
            configuration.timeoutIntervalForRequest = request.timeoutInterval
            configuration.timeoutIntervalForResource = request.timeoutInterval

            let session = URLSession(configuration: configuration)
            defer { session.finishTasksAndInvalidate() }
            return try await session.upload(for: request, fromFile: bodyURL)
        }
    ) {
        self.maxRetries = max(0, maxRetries)
        self.retryDelay = retryDelay
        self.retryMaxDelaySeconds = max(0, retryMaxDelaySeconds)
        self.randomDouble = randomDouble
        self.apiKeyProvider = apiKeyProvider
        self.upload = upload
    }

    struct TranscriptionResponse: Decodable, Sendable {
        let text: String
        let words: [Word]?

        struct Word: Decodable, Sendable {
            let text: String
            let type: String?
            let speakerID: String?

            enum CodingKeys: String, CodingKey {
                case text
                case type
                case speakerID = "speaker_id"
            }
        }
    }

    func transcribe(
        audioURL: URL,
        diarize: Bool,
        onRetry: RetryHandler? = nil,
        onLog: LogHandler? = nil
    ) async throws -> String {
        guard let apiKey = apiKeyProvider() else {
            throw TranscriptionError.noAPIKey
        }

        let boundary = UUID().uuidString
        let bodyURL = try createMultipartBodyFile(
            audioURL: audioURL,
            filename: audioURL.lastPathComponent,
            diarize: diarize,
            boundary: boundary
        )
        defer { try? FileManager.default.removeItem(at: bodyURL) }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 300
        request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        await onLog?("ElevenLabs model=\(Self.model); speaker_recognition=\(diarize)", .info)

        for attempt in 0...maxRetries {
            do {
                let (data, response) = try await upload(request, bodyURL)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw TranscriptionError.invalidResponse
                }

                guard (200...299).contains(httpResponse.statusCode) else {
                    let error = TranscriptionError.apiError(apiErrorMessage(from: data))
                    if Self.retryableHTTPStatusCodes.contains(httpResponse.statusCode), attempt < maxRetries {
                        let delay = retryDelayForAttempt(attempt + 1, response: httpResponse)
                        await onRetry?(attempt + 1, maxRetries)
                        await onLog?(
                            "ElevenLabs retry \(attempt + 1)/\(maxRetries) after HTTP \(httpResponse.statusCode) in \(formatDuration(delay))",
                            .warning
                        )
                        try await Task.sleep(for: delay)
                        continue
                    }
                    throw error
                }

                let transcriptionResponse = try JSONDecoder().decode(TranscriptionResponse.self, from: data)
                return Self.formattedTranscript(from: transcriptionResponse, diarize: diarize)
            } catch {
                if Task.isCancelled {
                    throw error
                }

                if shouldRetry(error), attempt < maxRetries {
                    let delay = retryDelayForAttempt(attempt + 1)
                    await onRetry?(attempt + 1, maxRetries)
                    await onLog?(
                        "ElevenLabs retry \(attempt + 1)/\(maxRetries) in \(formatDuration(delay)): \(error.localizedDescription)",
                        .warning
                    )
                    try await Task.sleep(for: delay)
                    continue
                }
                throw error
            }
        }

        throw TranscriptionError.timeout
    }

    nonisolated static func formattedTranscript(from response: TranscriptionResponse, diarize: Bool) -> String {
        guard diarize, let words = response.words, !words.isEmpty else {
            return response.text
        }

        var speakerNumbers: [String: Int] = [:]
        var nextSpeakerNumber = 1
        var segments: [(speaker: String, text: String)] = []
        var currentSpeaker: String?
        var currentText = ""

        func appendCurrentSegment() {
            guard let currentSpeaker else { return }
            let text = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            segments.append((currentSpeaker, text))
        }

        for word in words {
            let speaker = word.speakerID ?? currentSpeaker ?? "speaker_0"
            let hasVisibleText = !word.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

            if let existingSpeaker = currentSpeaker, speaker != existingSpeaker, hasVisibleText {
                appendCurrentSegment()
                currentText = ""
                currentSpeaker = speaker
            } else if currentSpeaker == nil {
                currentSpeaker = speaker
            }

            currentText += word.text
        }
        appendCurrentSegment()

        guard !segments.isEmpty else {
            return response.text
        }

        return segments.map { segment in
            let number: Int
            if let existing = speakerNumbers[segment.speaker] {
                number = existing
            } else {
                number = nextSpeakerNumber
                speakerNumbers[segment.speaker] = number
                nextSpeakerNumber += 1
            }
            return "Speaker \(number): \(segment.text)"
        }
        .joined(separator: "\n\n")
    }

    private func shouldRetry(_ error: Error) -> Bool {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .networkConnectionLost, .dnsLookupFailed, .cannotFindHost, .cannotConnectToHost:
                return true
            default:
                return false
            }
        }
        return false
    }

    private func retryDelayForAttempt(_ attempt: Int, response: HTTPURLResponse? = nil) -> Duration {
        if let retryAfter = response?.value(forHTTPHeaderField: "Retry-After"),
           let seconds = TimeInterval(retryAfter), seconds >= 0 {
            return .milliseconds(Int(round(min(seconds, retryMaxDelaySeconds) * 1_000)))
        }

        let baseSeconds = durationSeconds(retryDelay)
        let exponent = max(0, attempt - 1)
        let exponentialSeconds = baseSeconds * pow(2, Double(exponent))
        let cappedSeconds = min(exponentialSeconds, retryMaxDelaySeconds)
        let jitterMultiplier = 0.8 + (max(0, min(1, randomDouble())) * 0.4)
        return .milliseconds(Int(round(cappedSeconds * jitterMultiplier * 1_000)))
    }

    private func durationSeconds(_ duration: Duration) -> TimeInterval {
        let components = duration.components
        return TimeInterval(components.seconds) + (TimeInterval(components.attoseconds) / 1e18)
    }

    private func formatDuration(_ duration: Duration) -> String {
        String(format: "%.2fs", durationSeconds(duration))
    }

    private func apiErrorMessage(from data: Data) -> String {
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let detail = object["detail"] as? String {
                return detail
            }
            if let detail = object["detail"] as? [String: Any], let message = detail["message"] as? String {
                return message
            }
        }
        return String(data: data, encoding: .utf8) ?? "ElevenLabs request failed"
    }

    private func createMultipartBodyFile(
        audioURL: URL,
        filename: String,
        diarize: Bool,
        boundary: String
    ) throws -> URL {
        let bodyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchtalk_elevenlabs_\(UUID().uuidString).multipart")
        guard FileManager.default.createFile(atPath: bodyURL.path, contents: nil) else {
            throw TranscriptionError.invalidResponse
        }

        let handle = try FileHandle(forWritingTo: bodyURL)
        do {
            try appendField(name: "model_id", value: Self.model, boundary: boundary, to: handle)
            try appendField(name: "diarize", value: diarize ? "true" : "false", boundary: boundary, to: handle)
            try appendField(name: "tag_audio_events", value: "false", boundary: boundary, to: handle)
            try appendField(name: "timestamps_granularity", value: diarize ? "word" : "none", boundary: boundary, to: handle)

            try handle.write(contentsOf: Data("--\(boundary)\r\n".utf8))
            try handle.write(contentsOf: Data("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".utf8))
            try handle.write(contentsOf: Data("Content-Type: \(mimeType(for: audioURL))\r\n\r\n".utf8))

            let input = try FileHandle(forReadingFrom: audioURL)
            defer { try? input.close() }
            while let data = try input.read(upToCount: 1_048_576), !data.isEmpty {
                try handle.write(contentsOf: data)
            }

            try handle.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
            try handle.close()
            return bodyURL
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: bodyURL)
            throw error
        }
    }

    private func appendField(name: String, value: String, boundary: String, to handle: FileHandle) throws {
        let field = "--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n"
        try handle.write(contentsOf: Data(field.utf8))
    }

    private func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "m4a", "mp4":
            return "audio/mp4"
        case "wav":
            return "audio/wav"
        case "mp3":
            return "audio/mpeg"
        default:
            return "application/octet-stream"
        }
    }
}

#if DEBUG
extension ElevenLabsTranscriptionService {
    func createMultipartBodyFileForTesting(
        audioURL: URL,
        filename: String,
        diarize: Bool,
        boundary: String
    ) throws -> URL {
        try createMultipartBodyFile(
            audioURL: audioURL,
            filename: filename,
            diarize: diarize,
            boundary: boundary
        )
    }
}
#endif
