//
//  OpenAITranscriptionService.swift
//  notchtalk
//

import Foundation

actor OpenAITranscriptionService {
    typealias UploadFunction = @Sendable (_ request: URLRequest, _ bodyURL: URL) async throws -> (Data, URLResponse)
    typealias APIKeyProvider = @Sendable () -> String?
    typealias RetryHandler = @MainActor @Sendable (_ retryAttempt: Int, _ totalRetries: Int) async -> Void
    typealias LogHandler = @MainActor @Sendable (_ message: String, _ level: TranscriptionDiagnosticsEntry.LogLevel) async -> Void

    private static let primaryModelName = "gpt-4o-transcribe"
    private let endpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
    private let model = OpenAITranscriptionService.primaryModelName
    private let fallbackModel: String?
    private let requestTimeoutCeiling: TimeInterval = 120
    private let maxTimeoutRetries: Int
    private let retryDelay: Duration
    private let upload: UploadFunction
    private let apiKeyProvider: APIKeyProvider

    init(
        maxTimeoutRetries: Int = 3,
        retryDelay: Duration = .milliseconds(500),
        fallbackModel: String? = nil,
        apiKeyProvider: @escaping APIKeyProvider = { KeychainService.getAPIKey() },
        upload: @escaping UploadFunction = { request, bodyURL in
            try await URLSession.shared.upload(for: request, fromFile: bodyURL)
        }
    ) {
        self.maxTimeoutRetries = max(0, maxTimeoutRetries)
        self.retryDelay = retryDelay
        let normalizedFallback = fallbackModel?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalizedFallback, !normalizedFallback.isEmpty, normalizedFallback != Self.primaryModelName {
            self.fallbackModel = normalizedFallback
        } else {
            self.fallbackModel = nil
        }
        self.upload = upload
        self.apiKeyProvider = apiKeyProvider
    }

    struct TranscriptionResponse: Decodable {
        let text: String
    }

    struct ErrorResponse: Decodable {
        let error: ErrorDetail

        struct ErrorDetail: Decodable {
            let message: String
            let type: String?
            let code: String?
        }
    }

    func transcribe(
        audioURL: URL,
        prompt: String?,
        audioDuration: TimeInterval? = nil,
        onRetry: RetryHandler? = nil,
        onLog: LogHandler? = nil
    ) async throws -> String {
        guard let apiKey = apiKeyProvider() else {
            throw TranscriptionError.noAPIKey
        }

        let estimatedAudioDuration = max(
            0,
            audioDuration
                ?? estimateAudioDurationFromFileSize(audioURL: audioURL)
                ?? 20
        )
        let baseAttemptTimeout = timeoutBudget(forAudioDuration: estimatedAudioDuration)
        await onLog?(
            "Estimated audio duration \(Int(round(estimatedAudioDuration)))s; first-attempt timeout \(Int(round(baseAttemptTimeout)))s",
            .info
        )

        let primaryBoundary = UUID().uuidString
        let requestTemplate = makeRequestTemplate(apiKey: apiKey, boundary: primaryBoundary)
        let bodyURL = try createMultipartBodyFile(
            audioURL: audioURL,
            filename: audioURL.lastPathComponent,
            model: model,
            prompt: prompt,
            boundary: primaryBoundary
        )
        let fallbackBodyContext = try createFallbackBodyContext(
            audioURL: audioURL,
            prompt: prompt,
            filename: audioURL.lastPathComponent,
            apiKey: apiKey
        )

        defer {
            try? FileManager.default.removeItem(at: bodyURL)
            if let fallbackBodyContext {
                try? FileManager.default.removeItem(at: fallbackBodyContext.bodyURL)
            }
        }

        var shouldRaceFallback = false

        for attempt in 0...maxTimeoutRetries {
            do {
                let attemptTimeout = timeoutBudgetForAttempt(
                    attempt: attempt,
                    baseAttemptTimeout: baseAttemptTimeout
                )
                await onLog?(
                    "Attempt \(attempt + 1)/\(maxTimeoutRetries + 1): force-timeout after \(Int(round(attemptTimeout)))s",
                    .info
                )

                let text: String
                if shouldRaceFallback, let fallbackBodyContext {
                    await onLog?(
                        "Primary timed out previously; racing \(model) vs \(fallbackBodyContext.model)",
                        .warning
                    )
                    let raceResult = try await transcribeInParallelRace(
                        primaryRequestTemplate: requestTemplate,
                        primaryBodyURL: bodyURL,
                        primaryModel: model,
                        fallbackRequestTemplate: fallbackBodyContext.requestTemplate,
                        fallbackBodyURL: fallbackBodyContext.bodyURL,
                        fallbackModel: fallbackBodyContext.model,
                        timeoutSeconds: attemptTimeout,
                        onLog: onLog
                    )
                    if raceResult.model != model {
                        await onLog?(
                            "Using fallback model result from \(raceResult.model)",
                            .warning
                        )
                    }
                    text = raceResult.text
                } else {
                    text = try await transcribeSingleModel(
                        requestTemplate: requestTemplate,
                        bodyURL: bodyURL,
                        modelName: model,
                        timeoutSeconds: attemptTimeout,
                        onLog: onLog
                    )
                }

                return text
            } catch {
                await onLog?("Request failed with error: \(error.localizedDescription)", .error)
                if shouldRetryForTimeout(error: error), attempt < maxTimeoutRetries {
                    shouldRaceFallback = true
                    await onRetry?(attempt + 1, maxTimeoutRetries)
                    try await Task.sleep(for: retryDelay)
                    continue
                }

                if shouldRetryForTimeout(error: error) {
                    throw TranscriptionError.timeout
                }

                throw error
            }
        }

        throw TranscriptionError.timeout
    }

    private struct BodyContext {
        let model: String
        let requestTemplate: URLRequest
        let bodyURL: URL
    }

    private struct RaceResult {
        let model: String
        let text: String
    }

    private func makeRequestTemplate(apiKey: String, boundary: String) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        return request
    }

    private func createFallbackBodyContext(
        audioURL: URL,
        prompt: String?,
        filename: String,
        apiKey: String
    ) throws -> BodyContext? {
        guard let fallbackModel else {
            return nil
        }

        let boundary = UUID().uuidString
        let requestTemplate = makeRequestTemplate(apiKey: apiKey, boundary: boundary)
        let bodyURL = try createMultipartBodyFile(
            audioURL: audioURL,
            filename: filename,
            model: fallbackModel,
            prompt: prompt,
            boundary: boundary
        )

        return BodyContext(
            model: fallbackModel,
            requestTemplate: requestTemplate,
            bodyURL: bodyURL
        )
    }

    private func transcribeSingleModel(
        requestTemplate: URLRequest,
        bodyURL: URL,
        modelName: String,
        timeoutSeconds: TimeInterval,
        onLog: LogHandler? = nil
    ) async throws -> String {
        var request = requestTemplate
        request.timeoutInterval = min(requestTimeoutCeiling, timeoutSeconds + 5)

        await onLog?("Sending request to OpenAI transcription API (\(modelName))", .info)
        let (data, response) = try await uploadWithForcedTimeout(
            request: request,
            bodyURL: bodyURL,
            timeoutSeconds: timeoutSeconds
        )

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranscriptionError.invalidResponse
        }

        await onLog?("Received HTTP \(httpResponse.statusCode) (\(modelName))", .info)

        if httpResponse.statusCode != 200 {
            if shouldRetryForTimeout(statusCode: httpResponse.statusCode) {
                await onLog?("Timeout status code \(httpResponse.statusCode) (\(modelName))", .warning)
                throw TranscriptionError.timeout
            }

            if let errorResponse = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
                throw TranscriptionError.apiError(errorResponse.error.message)
            }
            throw TranscriptionError.httpError(httpResponse.statusCode)
        }

        let result = try JSONDecoder().decode(TranscriptionResponse.self, from: data)
        return result.text
    }

    private func transcribeInParallelRace(
        primaryRequestTemplate: URLRequest,
        primaryBodyURL: URL,
        primaryModel: String,
        fallbackRequestTemplate: URLRequest,
        fallbackBodyURL: URL,
        fallbackModel: String,
        timeoutSeconds: TimeInterval,
        onLog: LogHandler? = nil
    ) async throws -> RaceResult {
        let outcome = await withTaskGroup(
            of: Result<RaceResult, Error>.self,
            returning: Result<RaceResult, Error>.self
        ) { group in
            group.addTask {
                do {
                    let text = try await self.transcribeSingleModel(
                        requestTemplate: primaryRequestTemplate,
                        bodyURL: primaryBodyURL,
                        modelName: primaryModel,
                        timeoutSeconds: timeoutSeconds,
                        onLog: onLog
                    )
                    return .success(RaceResult(model: primaryModel, text: text))
                } catch {
                    return .failure(error)
                }
            }

            group.addTask {
                do {
                    let text = try await self.transcribeSingleModel(
                        requestTemplate: fallbackRequestTemplate,
                        bodyURL: fallbackBodyURL,
                        modelName: fallbackModel,
                        timeoutSeconds: timeoutSeconds,
                        onLog: onLog
                    )
                    return .success(RaceResult(model: fallbackModel, text: text))
                } catch {
                    return .failure(error)
                }
            }

            var sawTimeout = false
            var lastError: Error?

            while let result = await group.next() {
                switch result {
                case .success(let raceResult):
                    group.cancelAll()
                    return .success(raceResult)
                case .failure(let error):
                    if shouldRetryForTimeout(error: error) {
                        sawTimeout = true
                    }
                    lastError = error
                }
            }

            if sawTimeout {
                return .failure(TranscriptionError.timeout)
            }
            return .failure(lastError ?? URLError(.unknown))
        }

        return try outcome.get()
    }

    private func timeoutBudget(forAudioDuration duration: TimeInterval) -> TimeInterval {
        // Aggressive heuristic:
        // - short clips fail fast to trigger retries quickly
        // - longer clips still get more time
        // - bounded to avoid hanging requests
        let dynamic = 7 + (duration * 0.2)
        return min(45, max(8, dynamic))
    }

    private func timeoutBudgetForAttempt(attempt: Int, baseAttemptTimeout: TimeInterval) -> TimeInterval {
        // Keep the first attempt fast, but give retries a much wider budget so
        // transient backend slowness does not deterministically fail every retry.
        if attempt == 0 {
            return min(requestTimeoutCeiling, baseAttemptTimeout)
        }

        let retryFloor: TimeInterval = 55
        let widenedRetryBudget = max(retryFloor, baseAttemptTimeout * 2.5) + (Double(attempt - 1) * 20)
        return min(requestTimeoutCeiling, widenedRetryBudget)
    }

    private func estimateAudioDurationFromFileSize(audioURL: URL) -> TimeInterval? {
        guard
            let values = try? audioURL.resourceValues(forKeys: [.fileSizeKey]),
            let fileSize = values.fileSize,
            fileSize > 0
        else {
            return nil
        }

        // Recorder uses ~48kbps AAC (~6KB/s); this keeps heuristics available even without explicit duration.
        return Double(fileSize) / 6_000
    }

    private func uploadWithForcedTimeout(
        request: URLRequest,
        bodyURL: URL,
        timeoutSeconds: TimeInterval
    ) async throws -> (Data, URLResponse) {
        let upload = self.upload

        return try await withThrowingTaskGroup(of: (Data, URLResponse).self) { group in
            group.addTask {
                try await upload(request, bodyURL)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(timeoutSeconds))
                throw URLError(.timedOut)
            }

            defer {
                group.cancelAll()
            }

            guard let firstResult = try await group.next() else {
                throw URLError(.unknown)
            }
            return firstResult
        }
    }

    private func shouldRetryForTimeout(statusCode: Int) -> Bool {
        statusCode == 408 || statusCode == 504
    }

    private func shouldRetryForTimeout(error: Error) -> Bool {
        if let transcriptionError = error as? TranscriptionError, case .timeout = transcriptionError {
            return true
        }

        if let urlError = error as? URLError {
            return urlError.code == .timedOut
        }

        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == URLError.timedOut.rawValue
    }

    private func createMultipartBodyFile(
        audioURL: URL,
        filename: String,
        model: String,
        prompt: String?,
        boundary: String
    ) throws -> URL {
        let fileManager = FileManager.default
        let bodyURL = fileManager.temporaryDirectory.appendingPathComponent("notchtalk_multipart_\(UUID().uuidString).tmp")
        fileManager.createFile(atPath: bodyURL.path, contents: nil)

        let outputHandle = try FileHandle(forWritingTo: bodyURL)

        do {
            outputHandle.writeString("--\(boundary)\r\n")
            outputHandle.writeString("Content-Disposition: form-data; name=\"model\"\r\n\r\n")
            outputHandle.writeString("\(model)\r\n")

            outputHandle.writeString("--\(boundary)\r\n")
            outputHandle.writeString("Content-Disposition: form-data; name=\"response_format\"\r\n\r\n")
            outputHandle.writeString("json\r\n")

            if let prompt = prompt, !prompt.isEmpty {
                outputHandle.writeString("--\(boundary)\r\n")
                outputHandle.writeString("Content-Disposition: form-data; name=\"prompt\"\r\n\r\n")
                outputHandle.writeString("\(prompt)\r\n")
            }

            outputHandle.writeString("--\(boundary)\r\n")
            outputHandle.writeString("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n")
            outputHandle.writeString("Content-Type: audio/m4a\r\n\r\n")
            try appendFile(at: audioURL, to: outputHandle)
            outputHandle.writeString("\r\n")
            outputHandle.writeString("--\(boundary)--\r\n")
            try outputHandle.close()
            return bodyURL
        } catch {
            try? outputHandle.close()
            try? fileManager.removeItem(at: bodyURL)
            throw error
        }
    }

    private func appendFile(at fileURL: URL, to outputHandle: FileHandle) throws {
        let inputHandle = try FileHandle(forReadingFrom: fileURL)
        defer {
            try? inputHandle.close()
        }

        let chunkSize = 64 * 1024
        while true {
            let chunk = try inputHandle.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty {
                break
            }
            outputHandle.write(chunk)
        }
    }
}

#if DEBUG
extension OpenAITranscriptionService {
    func createMultipartBodyFileForTesting(
        audioURL: URL,
        filename: String,
        model: String,
        prompt: String?,
        boundary: String
    ) throws -> URL {
        try createMultipartBodyFile(
            audioURL: audioURL,
            filename: filename,
            model: model,
            prompt: prompt,
            boundary: boundary
        )
    }
}
#endif

extension FileHandle {
    fileprivate nonisolated func writeString(_ string: String) {
        if let data = string.data(using: .utf8) {
            write(data)
        }
    }
}

enum TranscriptionError: LocalizedError {
    case noAPIKey
    case invalidResponse
    case timeout
    case httpError(Int)
    case apiError(String)

    var errorDescription: String? {
        switch self {
        case .noAPIKey:
            return "No API key configured"
        case .invalidResponse:
            return "Invalid response from server"
        case .timeout:
            return "Transcription timed out"
        case .httpError(let code):
            return "HTTP error: \(code)"
        case .apiError(let message):
            return message
        }
    }
}
