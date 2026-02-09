import Foundation
import Testing
@testable import notchtalk

struct OpenAITranscriptionServiceTests {
    actor AttemptCounter {
        private var value = 0

        func increment() -> Int {
            value += 1
            return value
        }

        func current() -> Int {
            value
        }
    }

    private func isModel(_ model: String, in bodyURL: URL) throws -> Bool {
        let bodyText = String(decoding: try Data(contentsOf: bodyURL), as: UTF8.self)
        let needle = "Content-Disposition: form-data; name=\"model\"\r\n\r\n\(model)\r\n"
        return bodyText.contains(needle)
    }

    actor RetryEvents {
        private var values: [(Int, Int)] = []

        func append(attempt: Int, total: Int) {
            values.append((attempt, total))
        }

        func snapshot() -> [(Int, Int)] {
            values
        }
    }

    @Test("Transcribe throws no API key when missing")
    func transcribeThrowsNoAPIKeyWhenMissing() async throws {
        let service = OpenAITranscriptionService(apiKeyProvider: { nil })

        let audioURL = try makeTemporaryAudioFile(contents: Data("NO_API_KEY_AUDIO".utf8))
        defer {
            try? FileManager.default.removeItem(at: audioURL)
        }

        do {
            _ = try await service.transcribe(audioURL: audioURL, prompt: nil)
            Issue.record("Expected TranscriptionError.noAPIKey")
        } catch let error as TranscriptionError {
            if case .noAPIKey = error {
                // Expected
            } else {
                Issue.record("Expected TranscriptionError.noAPIKey, got \(error)")
            }
        } catch {
            Issue.record("Expected TranscriptionError.noAPIKey, got \(error)")
        }
    }

    @Test("Multipart body includes prompt and audio payload")
    func multipartBodyIncludesPromptAndAudioPayload() async throws {
        let service = OpenAITranscriptionService()
        let boundary = "boundary-test-prompt"

        let audioData = Data("FAKE_AUDIO_SAMPLE".utf8)
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio_\(UUID().uuidString).m4a")
        try audioData.write(to: audioURL)
        defer {
            try? FileManager.default.removeItem(at: audioURL)
        }

        let bodyURL = try await service.createMultipartBodyFileForTesting(
            audioURL: audioURL,
            filename: "sample.m4a",
            model: "gpt-4o-transcribe",
            prompt: "be concise",
            boundary: boundary
        )
        defer {
            try? FileManager.default.removeItem(at: bodyURL)
        }

        let bodyData = try Data(contentsOf: bodyURL)
        let bodyText = String(decoding: bodyData, as: UTF8.self)

        #expect(bodyText.contains("Content-Disposition: form-data; name=\"model\""))
        #expect(bodyText.contains("gpt-4o-transcribe"))
        #expect(bodyText.contains("Content-Disposition: form-data; name=\"response_format\""))
        #expect(bodyText.contains("json"))
        #expect(bodyText.contains("Content-Disposition: form-data; name=\"prompt\""))
        #expect(bodyText.contains("be concise"))
        #expect(bodyText.contains("name=\"file\"; filename=\"sample.m4a\""))
        #expect(bodyData.range(of: audioData) != nil)
        #expect(bodyText.hasSuffix("--\(boundary)--\r\n"))
    }

    @Test("Multipart body omits prompt field when prompt is nil")
    func multipartBodyOmitsPromptFieldWhenPromptIsNil() async throws {
        let service = OpenAITranscriptionService()
        let boundary = "boundary-test-no-prompt"

        let audioData = Data("AUDIO_WITHOUT_PROMPT".utf8)
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio_\(UUID().uuidString).m4a")
        try audioData.write(to: audioURL)
        defer {
            try? FileManager.default.removeItem(at: audioURL)
        }

        let bodyURL = try await service.createMultipartBodyFileForTesting(
            audioURL: audioURL,
            filename: "sample.m4a",
            model: "gpt-4o-transcribe",
            prompt: nil,
            boundary: boundary
        )
        defer {
            try? FileManager.default.removeItem(at: bodyURL)
        }

        let bodyText = String(decoding: try Data(contentsOf: bodyURL), as: UTF8.self)

        #expect(!bodyText.contains("Content-Disposition: form-data; name=\"prompt\""))
    }

    @Test("Multipart body omits prompt field when prompt is empty")
    func multipartBodyOmitsPromptFieldWhenPromptIsEmpty() async throws {
        let service = OpenAITranscriptionService()
        let boundary = "boundary-test-empty-prompt"

        let audioData = Data("AUDIO_EMPTY_PROMPT".utf8)
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio_\(UUID().uuidString).m4a")
        try audioData.write(to: audioURL)
        defer {
            try? FileManager.default.removeItem(at: audioURL)
        }

        let bodyURL = try await service.createMultipartBodyFileForTesting(
            audioURL: audioURL,
            filename: "sample.m4a",
            model: "gpt-4o-transcribe",
            prompt: "",
            boundary: boundary
        )
        defer {
            try? FileManager.default.removeItem(at: bodyURL)
        }

        let bodyText = String(decoding: try Data(contentsOf: bodyURL), as: UTF8.self)
        #expect(!bodyText.contains("Content-Disposition: form-data; name=\"prompt\""))
    }

    @Test("Multipart body preserves large payload without truncation")
    func multipartBodyPreservesLargePayloadWithoutTruncation() async throws {
        let service = OpenAITranscriptionService()
        let boundary = "boundary-test-large"

        let audioData = Data((0..<220_000).map { UInt8($0 % 251) })
        let audioURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio_\(UUID().uuidString).m4a")
        try audioData.write(to: audioURL)
        defer {
            try? FileManager.default.removeItem(at: audioURL)
        }

        let bodyURL = try await service.createMultipartBodyFileForTesting(
            audioURL: audioURL,
            filename: "large.m4a",
            model: "gpt-4o-transcribe",
            prompt: nil,
            boundary: boundary
        )
        defer {
            try? FileManager.default.removeItem(at: bodyURL)
        }

        let bodyData = try Data(contentsOf: bodyURL)
        let trailer = Data("\r\n--\(boundary)--\r\n".utf8)

        #expect(bodyData.range(of: audioData) != nil)
        #expect(Data(bodyData.suffix(trailer.count)) == trailer)
    }

    @Test("Transcribe retries timeout failures before succeeding")
    func transcribeRetriesTimeoutFailuresBeforeSucceeding() async throws {
        let attempts = AttemptCounter()
        let retryEvents = RetryEvents()
        let service = OpenAITranscriptionService(
            maxTimeoutRetries: 3,
            retryDelay: .milliseconds(1),
            apiKeyProvider: { "test-api-key" },
            upload: { _, _, _ in
                let attempt = await attempts.increment()
                if attempt < 3 {
                    throw URLError(.timedOut)
                }

                let data = Data(#"{"text":"hello world"}"#.utf8)
                let response = HTTPURLResponse(
                    url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (data, response)
            }
        )

        let audioURL = try makeTemporaryAudioFile(contents: Data("TIMEOUT_RETRY_AUDIO".utf8))
        defer {
            try? FileManager.default.removeItem(at: audioURL)
        }

        let transcription = try await service.transcribe(
            audioURL: audioURL,
            prompt: nil,
            onRetry: { attempt, totalRetries in
                await retryEvents.append(attempt: attempt, total: totalRetries)
            }
        )

        #expect(transcription == "hello world")
        #expect(await attempts.current() == 3)
        let events = await retryEvents.snapshot()
        #expect(events.count == 2)
        #expect(events[0].0 == 1)
        #expect(events[0].1 == 3)
        #expect(events[1].0 == 2)
        #expect(events[1].1 == 3)
    }

    @Test("Transcribe retries on HTTP timeout status codes")
    func transcribeRetriesOnHTTPTimeoutStatusCodes() async throws {
        let attempts = AttemptCounter()
        let retryEvents = RetryEvents()

        let service = OpenAITranscriptionService(
            maxTimeoutRetries: 2,
            retryDelay: .milliseconds(1),
            apiKeyProvider: { "test-api-key" },
            upload: { request, _, _ in
                let attempt = await attempts.increment()
                let status = attempt == 1 ? 504 : 200
                let data = Data(#"{"text":"ok"}"#.utf8)
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: status,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (data, response)
            }
        )

        let audioURL = try makeTemporaryAudioFile(contents: Data("HTTP_TIMEOUT_AUDIO".utf8))
        defer {
            try? FileManager.default.removeItem(at: audioURL)
        }

        let transcription = try await service.transcribe(
            audioURL: audioURL,
            prompt: nil,
            onRetry: { attempt, totalRetries in
                await retryEvents.append(attempt: attempt, total: totalRetries)
            }
        )

        #expect(transcription == "ok")
        #expect(await attempts.current() == 2)
        let events = await retryEvents.snapshot()
        #expect(events.count == 1)
        #expect(events[0].0 == 1)
        #expect(events[0].1 == 2)
    }

    @Test("Transcribe gives up after max timeout retries")
    func transcribeGivesUpAfterMaxTimeoutRetries() async throws {
        let attempts = AttemptCounter()
        let service = OpenAITranscriptionService(
            maxTimeoutRetries: 3,
            retryDelay: .milliseconds(1),
            apiKeyProvider: { "test-api-key" },
            upload: { _, _, _ in
                _ = await attempts.increment()
                throw URLError(.timedOut)
            }
        )

        let audioURL = try makeTemporaryAudioFile(contents: Data("MAX_TIMEOUT_AUDIO".utf8))
        defer {
            try? FileManager.default.removeItem(at: audioURL)
        }

        do {
            _ = try await service.transcribe(audioURL: audioURL, prompt: nil)
            Issue.record("Expected timeout error after retries")
        } catch let error as TranscriptionError {
            if case .timeout = error {
                // Expected
            } else {
                Issue.record("Expected timeout error, got \(error)")
            }
        } catch {
            Issue.record("Expected TranscriptionError.timeout, got \(error)")
        }

        #expect(await attempts.current() == 4)
    }

    @Test("Transcribe does not retry non-timeout failures")
    func transcribeDoesNotRetryNonTimeoutFailures() async throws {
        let attempts = AttemptCounter()
        let service = OpenAITranscriptionService(
            maxTimeoutRetries: 3,
            retryDelay: .milliseconds(1),
            apiKeyProvider: { "test-api-key" },
            upload: { _, _, _ in
                _ = await attempts.increment()
                throw URLError(.notConnectedToInternet)
            }
        )

        let audioURL = try makeTemporaryAudioFile(contents: Data("NON_TIMEOUT_AUDIO".utf8))
        defer {
            try? FileManager.default.removeItem(at: audioURL)
        }

        do {
            _ = try await service.transcribe(audioURL: audioURL, prompt: nil)
            Issue.record("Expected notConnectedToInternet error")
        } catch let error as URLError {
            #expect(error.code == .notConnectedToInternet)
        } catch {
            Issue.record("Expected URLError.notConnectedToInternet, got \(error)")
        }

        #expect(await attempts.current() == 1)
    }

    @Test("Transcribe maps JSON error payloads to apiError")
    func transcribeMapsJSONErrorPayloadsToAPIError() async throws {
        let service = OpenAITranscriptionService(
            maxTimeoutRetries: 0,
            retryDelay: .milliseconds(1),
            apiKeyProvider: { "test-api-key" },
            upload: { request, _, _ in
                let data = Data(#"{"error":{"message":"bad request","type":"invalid_request_error","code":null}}"#.utf8)
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 400,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (data, response)
            }
        )

        let audioURL = try makeTemporaryAudioFile(contents: Data("API_ERROR_AUDIO".utf8))
        defer {
            try? FileManager.default.removeItem(at: audioURL)
        }

        do {
            _ = try await service.transcribe(audioURL: audioURL, prompt: nil)
            Issue.record("Expected TranscriptionError.apiError")
        } catch let error as TranscriptionError {
            if case .apiError(let message) = error {
                #expect(message == "bad request")
            } else {
                Issue.record("Expected TranscriptionError.apiError, got \(error)")
            }
        } catch {
            Issue.record("Expected TranscriptionError.apiError, got \(error)")
        }
    }

    @Test("Transcribe maps non-JSON error payloads to httpError")
    func transcribeMapsNonJSONErrorPayloadsToHTTPError() async throws {
        let service = OpenAITranscriptionService(
            maxTimeoutRetries: 0,
            retryDelay: .milliseconds(1),
            apiKeyProvider: { "test-api-key" },
            upload: { request, _, _ in
                let data = Data("Internal Server Error".utf8)
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 500,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (data, response)
            }
        )

        let audioURL = try makeTemporaryAudioFile(contents: Data("HTTP_ERROR_AUDIO".utf8))
        defer {
            try? FileManager.default.removeItem(at: audioURL)
        }

        do {
            _ = try await service.transcribe(audioURL: audioURL, prompt: nil)
            Issue.record("Expected TranscriptionError.httpError")
        } catch let error as TranscriptionError {
            if case .httpError(let code) = error {
                #expect(code == 500)
            } else {
                Issue.record("Expected TranscriptionError.httpError, got \(error)")
            }
        } catch {
            Issue.record("Expected TranscriptionError.httpError, got \(error)")
        }
    }

    @Test("Transcribe throws invalidResponse for non-HTTP responses")
    func transcribeThrowsInvalidResponseForNonHTTPResponses() async throws {
        let service = OpenAITranscriptionService(
            maxTimeoutRetries: 0,
            retryDelay: .milliseconds(1),
            apiKeyProvider: { "test-api-key" },
            upload: { request, _, _ in
                let response = URLResponse(
                    url: request.url!,
                    mimeType: "application/json",
                    expectedContentLength: 0,
                    textEncodingName: nil
                )
                return (Data(), response)
            }
        )

        let audioURL = try makeTemporaryAudioFile(contents: Data("INVALID_RESPONSE_AUDIO".utf8))
        defer {
            try? FileManager.default.removeItem(at: audioURL)
        }

        do {
            _ = try await service.transcribe(audioURL: audioURL, prompt: nil)
            Issue.record("Expected TranscriptionError.invalidResponse")
        } catch let error as TranscriptionError {
            if case .invalidResponse = error {
                // Expected
            } else {
                Issue.record("Expected TranscriptionError.invalidResponse, got \(error)")
            }
        } catch {
            Issue.record("Expected TranscriptionError.invalidResponse, got \(error)")
        }
    }

    @Test("Fallback returns but primary wins if it finishes within grace")
    func fallbackReturnsButPrimaryWinsIfItFinishesWithinGrace() async throws {
        let fallbackModel = "fallback-model"

        let service = OpenAITranscriptionService(
            maxTimeoutRetries: 0,
            retryDelay: .milliseconds(1),
            fallbackModel: fallbackModel,
            fallbackGraceSeconds: 0.25,
            hedgeDelayCalculator: { _ in 0.01 },
            apiKeyProvider: { "test-api-key" },
            upload: { request, bodyURL, _ in
                if try isModel(fallbackModel, in: bodyURL) {
                    try await Task.sleep(for: .milliseconds(10))
                    let data = Data(#"{"text":"fallback"}"#.utf8)
                    let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                    return (data, response)
                }

                // Primary
                try await Task.sleep(for: .milliseconds(30))
                let data = Data(#"{"text":"primary"}"#.utf8)
                let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
                return (data, response)
            }
        )

        let audioURL = try makeTemporaryAudioFile(contents: Data("FALLBACK_GRACE_AUDIO".utf8))
        defer {
            try? FileManager.default.removeItem(at: audioURL)
        }

        let transcription = try await service.transcribe(audioURL: audioURL, prompt: nil, audioDuration: 0.1)
        #expect(transcription == "primary")
    }

    @Test("Transcribe fails fast for local connectivity errors even with fallback configured")
    func transcribeFailsFastForLocalConnectivityErrorsEvenWithFallbackConfigured() async throws {
        let attempts = AttemptCounter()
        let fallbackModel = "fallback-model"

        let service = OpenAITranscriptionService(
            maxTimeoutRetries: 0,
            retryDelay: .milliseconds(1),
            fallbackModel: fallbackModel,
            hedgeDelayCalculator: { _ in 0 }, // start fallback immediately
            apiKeyProvider: { "test-api-key" },
            upload: { request, bodyURL, _ in
                _ = await attempts.increment()
                if try isModel(fallbackModel, in: bodyURL) {
                    try await Task.sleep(for: .milliseconds(50))
                    let data = Data(#"{"text":"fallback"}"#.utf8)
                    let response = HTTPURLResponse(
                        url: request.url!,
                        statusCode: 200,
                        httpVersion: nil,
                        headerFields: nil
                    )!
                    return (data, response)
                }

                try await Task.sleep(for: .milliseconds(10))
                throw URLError(.notConnectedToInternet)
            }
        )

        let audioURL = try makeTemporaryAudioFile(contents: Data("CONNECTIVITY_AUDIO".utf8))
        defer {
            try? FileManager.default.removeItem(at: audioURL)
        }

        do {
            _ = try await service.transcribe(audioURL: audioURL, prompt: nil, audioDuration: 0.1)
            Issue.record("Expected URLError.notConnectedToInternet")
        } catch let error as URLError {
            #expect(error.code == .notConnectedToInternet)
        } catch {
            Issue.record("Expected URLError.notConnectedToInternet, got \(error)")
        }

        // Primary + fallback likely started, but we should have failed quickly before fallback could win.
        #expect(await attempts.current() >= 1)
    }

    private func makeTemporaryAudioFile(contents: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio_\(UUID().uuidString).m4a")
        try contents.write(to: url)
        return url
    }
}
