//
//  OpenAITranscriptionService.swift
//  notchtalk
//

import Foundation

actor OpenAITranscriptionService {
    typealias UploadFunction = @Sendable (_ request: URLRequest, _ bodyURL: URL) async throws -> (Data, URLResponse)
    typealias APIKeyProvider = @Sendable () -> String?
    typealias RetryHandler = @MainActor @Sendable (_ retryAttempt: Int, _ totalRetries: Int) async -> Void

    private let endpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
    private let model = "gpt-4o-transcribe"
    private let requestTimeout: TimeInterval = 120
    private let maxTimeoutRetries: Int
    private let retryDelay: Duration
    private let upload: UploadFunction
    private let apiKeyProvider: APIKeyProvider

    init(
        maxTimeoutRetries: Int = 3,
        retryDelay: Duration = .milliseconds(500),
        apiKeyProvider: @escaping APIKeyProvider = { KeychainService.getAPIKey() },
        upload: @escaping UploadFunction = { request, bodyURL in
            try await URLSession.shared.upload(for: request, fromFile: bodyURL)
        }
    ) {
        self.maxTimeoutRetries = max(0, maxTimeoutRetries)
        self.retryDelay = retryDelay
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
        onRetry: RetryHandler? = nil
    ) async throws -> String {
        guard let apiKey = apiKeyProvider() else {
            throw TranscriptionError.noAPIKey
        }

        let boundary = UUID().uuidString
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = requestTimeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let bodyURL = try createMultipartBodyFile(
            audioURL: audioURL,
            filename: audioURL.lastPathComponent,
            model: model,
            prompt: prompt,
            boundary: boundary
        )
        defer {
            try? FileManager.default.removeItem(at: bodyURL)
        }

        for attempt in 0...maxTimeoutRetries {
            do {
                let (data, response) = try await upload(request, bodyURL)

                guard let httpResponse = response as? HTTPURLResponse else {
                    throw TranscriptionError.invalidResponse
                }

                if httpResponse.statusCode != 200 {
                    if shouldRetryForTimeout(statusCode: httpResponse.statusCode) {
                        if attempt < maxTimeoutRetries {
                            await onRetry?(attempt + 1, maxTimeoutRetries)
                            try await Task.sleep(for: retryDelay)
                            continue
                        }
                        throw TranscriptionError.timeout
                    }

                    if let errorResponse = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
                        throw TranscriptionError.apiError(errorResponse.error.message)
                    }
                    throw TranscriptionError.httpError(httpResponse.statusCode)
                }

                let result = try JSONDecoder().decode(TranscriptionResponse.self, from: data)
                return result.text
            } catch {
                if shouldRetryForTimeout(error: error), attempt < maxTimeoutRetries {
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

    private func shouldRetryForTimeout(statusCode: Int) -> Bool {
        statusCode == 408 || statusCode == 504
    }

    private func shouldRetryForTimeout(error: Error) -> Bool {
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
