//
//  OpenAITranscriptionService.swift
//  notchtalk
//

import Foundation

actor OpenAITranscriptionService {
    typealias UploadFunction = @Sendable (_ request: URLRequest, _ bodyURL: URL, _ delegate: URLSessionTaskDelegate?) async throws -> (Data, URLResponse)
    typealias APIKeyProvider = @Sendable () -> String?
    typealias RetryHandler = @MainActor @Sendable (_ retryAttempt: Int, _ totalRetries: Int) async -> Void
    typealias LogHandler = @MainActor @Sendable (_ message: String, _ level: TranscriptionDiagnosticsEntry.LogLevel) async -> Void
    typealias HedgeDelayCalculator = @Sendable (_ audioDuration: TimeInterval) -> TimeInterval

    private static let primaryModelName = "gpt-4o-transcribe"
    private static let retryableHTTPStatusCodes: Set<Int> = [408, 429, 500, 502, 503, 504]
    private let endpoint = URL(string: "https://api.openai.com/v1/audio/transcriptions")!
    private let model = OpenAITranscriptionService.primaryModelName
    private let fallbackModel: String?
    private let uploadNoProgressTimeoutSeconds: TimeInterval
    private let requestTimeoutCeiling: TimeInterval
    private let overallTimeoutCeiling: TimeInterval
    private let overallTimeoutFloor: TimeInterval
    private let overallTimeoutMultiplier: Double
    private let maxTimeoutRetries: Int
    private let retryDelay: Duration
    private let retryMaxDelay: Duration
    private let retryJitterFraction: Double
    private let randomDouble: @Sendable () -> Double
    private let metricsSlowThresholdSeconds: TimeInterval
    private let hedgeDelayCalculator: HedgeDelayCalculator
    private let fallbackGraceSeconds: TimeInterval
    private let upload: UploadFunction
    private let apiKeyProvider: APIKeyProvider
    private var inFlightNetworkRequests = 0

    init(
        maxTimeoutRetries: Int = 3,
        retryDelay: Duration = .milliseconds(500),
        retryMaxDelay: Duration = .seconds(4),
        retryJitterFraction: Double = 0.2,
        overallTimeoutFloor: TimeInterval = 60,
        overallTimeoutCeiling: TimeInterval = 120,
        overallTimeoutMultiplier: Double = 2.0,
        fallbackModel: String? = nil,
        uploadNoProgressTimeoutSeconds: TimeInterval = 6,
        requestTimeoutCeiling: TimeInterval = 180,
        metricsSlowThresholdSeconds: TimeInterval = 8,
        fallbackGraceSeconds: TimeInterval = 2,
        hedgeDelayCalculator: @escaping HedgeDelayCalculator = { duration in
            // Transcription latency tends to be mostly constant; use duration only as a weak signal,
            // and cap aggressively so we start a hedge request promptly when tail latency happens.
            let dynamic = 7 + (duration * 0.2)
            return min(20, max(8, dynamic))
        },
        apiKeyProvider: @escaping APIKeyProvider = { KeychainService.getAPIKey() },
        randomDouble: @escaping @Sendable () -> Double = { Double.random(in: 0...1) },
        upload: @escaping UploadFunction = { request, bodyURL, delegate in
            // Use an isolated ephemeral session per request to reduce the chance of hitting a stale/broken
            // reused connection (observed as proto=h3 with 0B sent/recv in diagnostics).
            let config = URLSessionConfiguration.ephemeral
            config.waitsForConnectivity = false
            config.timeoutIntervalForRequest = request.timeoutInterval
            config.timeoutIntervalForResource = request.timeoutInterval

            let session = URLSession(configuration: config)
            defer {
                session.finishTasksAndInvalidate()
            }
            return try await session.upload(for: request, fromFile: bodyURL, delegate: delegate)
        }
    ) {
        self.maxTimeoutRetries = max(0, maxTimeoutRetries)
        self.retryDelay = retryDelay
        self.retryMaxDelay = retryMaxDelay
        self.retryJitterFraction = max(0, min(1, retryJitterFraction))
        self.overallTimeoutCeiling = max(0, overallTimeoutCeiling)
        self.overallTimeoutFloor = max(0, min(overallTimeoutFloor, overallTimeoutCeiling))
        self.overallTimeoutMultiplier = max(0, overallTimeoutMultiplier)
        self.uploadNoProgressTimeoutSeconds = max(0, uploadNoProgressTimeoutSeconds)
        self.requestTimeoutCeiling = max(5, requestTimeoutCeiling)
        self.metricsSlowThresholdSeconds = max(0, metricsSlowThresholdSeconds)
        self.fallbackGraceSeconds = max(0, fallbackGraceSeconds)
        self.hedgeDelayCalculator = hedgeDelayCalculator
        let normalizedFallback = fallbackModel?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let normalizedFallback, !normalizedFallback.isEmpty, normalizedFallback != Self.primaryModelName {
            self.fallbackModel = normalizedFallback
        } else {
            self.fallbackModel = nil
        }
        self.upload = upload
        self.apiKeyProvider = apiKeyProvider
        self.randomDouble = randomDouble
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

    private final class TaskMetricsCollector: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var _metrics: URLSessionTaskMetrics?
        private var _sentRequestBodyBytes: Int64 = 0

        var metrics: URLSessionTaskMetrics? {
            lock.lock()
            defer { lock.unlock() }
            return _metrics
        }

        var sentRequestBodyBytes: Int64 {
            lock.lock()
            defer { lock.unlock() }
            return _sentRequestBodyBytes
        }

        var hasSentAnyRequestBodyBytes: Bool {
            sentRequestBodyBytes > 0
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
            lock.lock()
            _metrics = metrics
            lock.unlock()
        }

        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            didSendBodyData bytesSent: Int64,
            totalBytesSent: Int64,
            totalBytesExpectedToSend: Int64
        ) {
            guard bytesSent > 0 || totalBytesSent > 0 else {
                return
            }

            lock.lock()
            _sentRequestBodyBytes = max(_sentRequestBodyBytes, totalBytesSent)
            lock.unlock()
        }
    }

    private func incrementInFlightRequests() -> Int {
        inFlightNetworkRequests += 1
        return inFlightNetworkRequests
    }

    private func decrementInFlightRequests() -> Int {
        inFlightNetworkRequests = max(0, inFlightNetworkRequests - 1)
        return inFlightNetworkRequests
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

        let audioBytes = fileSizeBytes(at: audioURL)
        let estimatedAudioDuration = max(
            0,
            audioDuration
                ?? estimateAudioDurationFromFileSize(audioURL: audioURL)
                ?? 20
        )
        let overallBudget = overallTimeoutBudget(forEstimatedAudioDuration: estimatedAudioDuration)
        let baseHedgeDelay = hedgeDelay(forAudioDuration: estimatedAudioDuration)

        if let audioBytes {
            await onLog?(
                "Audio file \(audioURL.lastPathComponent) (\(audioURL.pathExtension.lowercased())) size=\(formatBytes(audioBytes)); duration_est=\(Int(round(estimatedAudioDuration)))s",
                .info
            )
        } else {
            await onLog?(
                "Audio file \(audioURL.lastPathComponent) (\(audioURL.pathExtension.lowercased())); duration_est=\(Int(round(estimatedAudioDuration)))s",
                .info
            )
        }
        await onLog?(
            "Timeout budget overall=\(Int(round(overallBudget)))s; hedge-after \(Int(round(baseHedgeDelay)))s; url_timeout=\(Int(round(requestTimeoutCeiling)))s",
            .info
        )
        if let fallbackModel {
            await onLog?("Fallback model configured: \(fallbackModel)", .info)
        }

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

        let overallStart = Date()
        let totalAttempts = maxTimeoutRetries + 1
        for attempt in 0...maxTimeoutRetries {
            do {
                let elapsedOverall = Date().timeIntervalSince(overallStart)
                let remainingOverall = overallBudget - elapsedOverall
                if remainingOverall <= 0 {
                    await onLog?("Overall timeout budget exceeded after \(Int(round(elapsedOverall)))s", .error)
                    throw TranscriptionError.timeout
                }

                var hedgeAfter = hedgeDelayForAttempt(
                    attempt: attempt,
                    baseHedgeDelay: baseHedgeDelay
                )
                var attemptDeadline = attemptDeadlineForAttempt(
                    attempt: attempt,
                    baseHedgeDelay: baseHedgeDelay
                )
                attemptDeadline = min(attemptDeadline, remainingOverall)
                hedgeAfter = min(hedgeAfter, max(0, attemptDeadline - 1))
                await onLog?(
                    "Attempt \(attempt + 1)/\(totalAttempts): hedge fallback after \(Int(round(hedgeAfter)))s; attempt-deadline \(Int(round(attemptDeadline)))s; remaining_overall \(Int(round(remainingOverall)))s",
                    .info
                )

                let raceResult: RaceResult
                if let fallbackBodyContext {
                    raceResult = try await transcribeWithFallbackHedge(
                        primaryRequestTemplate: requestTemplate,
                        primaryBodyURL: bodyURL,
                        primaryModel: model,
                        fallbackBodyContext: fallbackBodyContext,
                        hedgeAfter: hedgeAfter,
                        attemptDeadline: attemptDeadline,
                        onLog: onLog
                    )
                    if raceResult.model != model {
                        await onLog?(
                            "Using fallback model result from \(raceResult.model)",
                            .warning
                        )
                    }
                } else {
                    let text = try await transcribeWithAttemptDeadline(
                        requestTemplate: requestTemplate,
                        bodyURL: bodyURL,
                        modelName: model,
                        attemptDeadline: attemptDeadline,
                        onLog: onLog
                    )
                    raceResult = RaceResult(model: model, text: text)
                }

                return raceResult.text
            } catch {
                if Task.isCancelled {
                    throw error
                }

                await onLog?("Request failed with error: \(error.localizedDescription)", .error)
                if shouldRetry(error: error), attempt < maxTimeoutRetries {
                    await onRetry?(attempt + 1, maxTimeoutRetries)

                    let retryAttempt = attempt + 1
                    let delay = retryDelayForRetryAttempt(retryAttempt)
                    await onLog?(
                        "Retry \(retryAttempt)/\(maxTimeoutRetries) in \(formatDuration(delay)) (reason=\(retryReason(error)))",
                        .warning
                    )
                    try await Task.sleep(for: delay)
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

    private enum HedgeControlError: Error {
        case fallbackGraceElapsed
    }

    private struct AttemptTaggedError: Error {
        enum Kind: String {
            case primary
            case fallback
            case attemptDeadline
            case fallbackGrace
        }

        let kind: Kind
        let model: String?
        let underlying: Error
    }

    private func makeRequestID(prefix: String) -> String {
        let token = UUID().uuidString.split(separator: "-").first.map(String.init) ?? UUID().uuidString
        return "\(prefix)-\(token)"
    }

    private func formatSeconds(_ seconds: TimeInterval) -> String {
        String(format: "%.3f", seconds)
    }

    private func formatDuration(_ duration: Duration) -> String {
        let components = duration.components
        let seconds = Double(components.seconds) + (Double(components.attoseconds) / 1e18)
        return String(format: "%.3fs", max(0, seconds))
    }

    private func diffMilliseconds(_ start: Date?, _ end: Date?) -> String? {
        guard let start, let end else {
            return nil
        }
        let ms = max(0, end.timeIntervalSince(start) * 1000)
        return "\(Int(round(ms)))ms"
    }

    private func formatBytes(_ bytes: Int64) -> String {
        if bytes < 0 {
            return "\(bytes)B"
        }
        if bytes < 1_024 {
            return "\(bytes)B"
        }
        if bytes < 1_024 * 1_024 {
            return String(format: "%.1fKB", Double(bytes) / 1_024)
        }
        return String(format: "%.1fMB", Double(bytes) / (1_024 * 1_024))
    }

    private func fileSizeBytes(at url: URL) -> Int64? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]) else {
            return nil
        }
        guard let size = values.fileSize, size > 0 else {
            return nil
        }
        return Int64(size)
    }

    private func overallTimeoutBudget(forEstimatedAudioDuration duration: TimeInterval) -> TimeInterval {
        let scaled = duration * overallTimeoutMultiplier
        let clamped = max(overallTimeoutFloor, scaled)
        return min(overallTimeoutCeiling, clamped)
    }

    private func durationSeconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + (Double(components.attoseconds) / 1e18)
    }

    private func retryDelayForRetryAttempt(_ retryAttempt: Int) -> Duration {
        let base = max(0, durationSeconds(retryDelay))
        let maxDelay = max(0, durationSeconds(retryMaxDelay))
        let exponent = max(0, retryAttempt - 1)
        let raw = base * pow(2.0, Double(exponent))
        let capped = min(raw, maxDelay > 0 ? maxDelay : raw)

        let jitter = 1.0 + ((randomDouble() * 2.0 - 1.0) * retryJitterFraction)
        let finalSeconds = max(0, capped * max(0, jitter))
        return .milliseconds(Int(round(finalSeconds * 1000)))
    }

    private func retryReason(_ error: Error) -> String {
        if shouldRetryForTimeout(error: error) {
            return "timeout"
        }
        if let transcriptionError = error as? TranscriptionError {
            switch transcriptionError {
            case .httpError(let code):
                return "http_\(code)"
            default:
                return "transcription_error"
            }
        }
        if let urlError = error as? URLError {
            return "url_\(urlError.code)"
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return "nsurl_\(nsError.code)"
        }
        return "other"
    }

    private func isRetryableTransportError(_ urlError: URLError) -> Bool {
        switch urlError.code {
        case .timedOut,
             .networkConnectionLost,
             .dnsLookupFailed,
             .cannotFindHost,
             .cannotConnectToHost,
             .secureConnectionFailed:
            return true
        default:
            return false
        }
    }

    private func shouldRetry(error: Error) -> Bool {
        if shouldRetryForTimeout(error: error) {
            return true
        }

        if let transcriptionError = error as? TranscriptionError {
            switch transcriptionError {
            case .httpError(let code):
                return Self.retryableHTTPStatusCodes.contains(code)
            default:
                return false
            }
        }

        if let urlError = error as? URLError {
            return isRetryableTransportError(urlError)
        }

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return isRetryableTransportError(URLError(URLError.Code(rawValue: nsError.code)))
        }

        return false
    }

    private func isCancellationError(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        if let urlError = error as? URLError {
            return urlError.code == .cancelled
        }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == URLError.cancelled.rawValue
    }

    private func logMetrics(
        _ metrics: URLSessionTaskMetrics,
        requestID: String,
        modelName: String,
        onLog: LogHandler?
    ) async {
        await onLog?(
            "[\(requestID)] Metrics (\(modelName)): total=\(formatSeconds(metrics.taskInterval.duration))s redirects=\(metrics.redirectCount) tx=\(metrics.transactionMetrics.count)",
            .info
        )

        for (index, tx) in metrics.transactionMetrics.enumerated() {
            var parts: [String] = []

            if let proto = tx.networkProtocolName {
                parts.append("proto=\(proto)")
            }
            parts.append("reused=\(tx.isReusedConnection)")
            parts.append("proxy=\(tx.isProxyConnection)")
            parts.append("fetch=\(tx.resourceFetchType)")

            if let dns = diffMilliseconds(tx.domainLookupStartDate, tx.domainLookupEndDate) {
                parts.append("dns=\(dns)")
            }
            if let connect = diffMilliseconds(tx.connectStartDate, tx.connectEndDate) {
                parts.append("connect=\(connect)")
            }
            if let tls = diffMilliseconds(tx.secureConnectionStartDate, tx.secureConnectionEndDate) {
                parts.append("tls=\(tls)")
            }
            if let request = diffMilliseconds(tx.requestStartDate, tx.requestEndDate) {
                parts.append("request=\(request)")
            }

            // "TTFB" here is "time from requestStartDate to responseStartDate" (includes upload+server queue).
            if let ttfb = diffMilliseconds(tx.requestStartDate, tx.responseStartDate) {
                parts.append("ttfb=\(ttfb)")
            }
            if let response = diffMilliseconds(tx.responseStartDate, tx.responseEndDate) {
                parts.append("response=\(response)")
            }

            parts.append("sent=\(formatBytes(tx.countOfRequestBodyBytesSent))")
            parts.append("recv=\(formatBytes(tx.countOfResponseBodyBytesReceived))")

            await onLog?("[\(requestID)] Tx\(index) " + parts.joined(separator: " "), .info)
        }
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

    private func transcribeWithAttemptDeadline(
        requestTemplate: URLRequest,
        bodyURL: URL,
        modelName: String,
        attemptDeadline: TimeInterval,
        onLog: LogHandler? = nil
    ) async throws -> String {
        let requestID = makeRequestID(prefix: "P")

        let outcome = await withTaskGroup(
            of: Result<String, Error>.self,
            returning: Result<String, Error>.self
        ) { group in
            group.addTask {
                do {
                    let text = try await self.transcribeSingleModel(
                        requestTemplate: requestTemplate,
                        bodyURL: bodyURL,
                        modelName: modelName,
                        requestID: requestID,
                        onLog: onLog
                    )
                    return .success(text)
                } catch {
                    return .failure(AttemptTaggedError(kind: .primary, model: modelName, underlying: error))
                }
            }

            group.addTask {
                do {
                    try await Task.sleep(for: .seconds(attemptDeadline))
                    await onLog?(
                        "[\(requestID)] Attempt deadline reached after \(Int(round(attemptDeadline)))s (\(modelName))",
                        .warning
                    )
                    return .failure(AttemptTaggedError(kind: .attemptDeadline, model: modelName, underlying: TranscriptionError.timeout))
                } catch {
                    return .failure(AttemptTaggedError(kind: .attemptDeadline, model: modelName, underlying: error))
                }
            }

            while let result = await group.next() {
                switch result {
                case .success(let text):
                    group.cancelAll()
                    return .success(text)
                case .failure(let error):
                    group.cancelAll()
                    if let tagged = error as? AttemptTaggedError {
                        return .failure(tagged.underlying)
                    }
                    return .failure(error)
                }
            }

            return .failure(URLError(.unknown))
        }

        return try outcome.get()
    }

    private func transcribeWithFallbackHedge(
        primaryRequestTemplate: URLRequest,
        primaryBodyURL: URL,
        primaryModel: String,
        fallbackBodyContext: BodyContext,
        hedgeAfter: TimeInterval,
        attemptDeadline: TimeInterval,
        onLog: LogHandler? = nil
    ) async throws -> RaceResult {
        let primaryRequestID = makeRequestID(prefix: "P")
        let fallbackRequestID = makeRequestID(prefix: "F")

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
                        requestID: primaryRequestID,
                        onLog: onLog
                    )
                    return .success(RaceResult(model: primaryModel, text: text))
                } catch {
                    return .failure(AttemptTaggedError(kind: .primary, model: primaryModel, underlying: error))
                }
            }

            group.addTask {
                do {
                    if hedgeAfter > 0 {
                        try await Task.sleep(for: .seconds(hedgeAfter))
                    }
                    await onLog?(
                        "[\(fallbackRequestID)] Hedge starting fallback request (\(fallbackBodyContext.model)) after \(Int(round(hedgeAfter)))s",
                        .warning
                    )
                    let text = try await self.transcribeSingleModel(
                        requestTemplate: fallbackBodyContext.requestTemplate,
                        bodyURL: fallbackBodyContext.bodyURL,
                        modelName: fallbackBodyContext.model,
                        requestID: fallbackRequestID,
                        onLog: onLog
                    )
                    return .success(RaceResult(model: fallbackBodyContext.model, text: text))
                } catch {
                    return .failure(AttemptTaggedError(kind: .fallback, model: fallbackBodyContext.model, underlying: error))
                }
            }

            group.addTask {
                do {
                    try await Task.sleep(for: .seconds(attemptDeadline))
                    await onLog?(
                        "[\(primaryRequestID)] Attempt deadline reached after \(Int(round(attemptDeadline)))s (primary=\(primaryModel))",
                        .warning
                    )
                    return .failure(AttemptTaggedError(kind: .attemptDeadline, model: primaryModel, underlying: TranscriptionError.timeout))
                } catch {
                    return .failure(AttemptTaggedError(kind: .attemptDeadline, model: primaryModel, underlying: error))
                }
            }

            var fallbackResult: RaceResult?
            var primaryFinished = false
            var fallbackFinished = false
            var graceTimerAdded = false
            var primaryError: Error?
            var fallbackError: Error?
            var lastError: Error?

            while let result = await group.next() {
                switch result {
                case .success(let raceResult):
                    if raceResult.model == primaryModel {
                        group.cancelAll()
                        return .success(raceResult)
                    }

                    if fallbackResult == nil {
                        fallbackResult = raceResult
                        if !graceTimerAdded {
                            graceTimerAdded = true
                            await onLog?(
                                "[\(fallbackRequestID)] Fallback returned before primary; waiting up to \(Int(round(fallbackGraceSeconds)))s for primary",
                                .warning
                            )
                            group.addTask {
                                do {
                                    try await Task.sleep(for: .seconds(self.fallbackGraceSeconds))
                                    return .failure(
                                        AttemptTaggedError(
                                            kind: .fallbackGrace,
                                            model: nil,
                                            underlying: HedgeControlError.fallbackGraceElapsed
                                        )
                                    )
                                } catch {
                                    return .failure(AttemptTaggedError(kind: .fallbackGrace, model: nil, underlying: error))
                                }
                            }
                        }
                    }
                    fallbackFinished = true

                case .failure(let error):
                    let tagged = error as? AttemptTaggedError
                    let kind = tagged?.kind
                    let underlying = tagged?.underlying ?? error
                    lastError = underlying

                    switch kind {
                    case .primary:
                        primaryFinished = true
                        primaryError = underlying

                        if let fallbackResult {
                            group.cancelAll()
                            return .success(fallbackResult)
                        }

                        // Fail fast for obvious local connectivity issues (fallback won't help).
                        if isLikelyLocalConnectivityError(underlying) {
                            group.cancelAll()
                            return .failure(underlying)
                        }

                    case .fallback:
                        fallbackFinished = true
                        fallbackError = underlying

                    case .fallbackGrace:
                        if let fallbackResult {
                            group.cancelAll()
                            return .success(fallbackResult)
                        }

                    case .attemptDeadline:
                        if let fallbackResult {
                            group.cancelAll()
                            return .success(fallbackResult)
                        }
                        group.cancelAll()
                        return .failure(TranscriptionError.timeout)

                    case .none:
                        break
                    }

                    if primaryFinished, fallbackFinished {
                        group.cancelAll()
                        if let fallbackResult {
                            return .success(fallbackResult)
                        }

                        let sawTimeout = [primaryError, fallbackError].compactMap { $0 }.contains(where: shouldRetryForTimeout)
                        if sawTimeout {
                            return .failure(TranscriptionError.timeout)
                        }

                        return .failure(primaryError ?? fallbackError ?? underlying)
                    }
                }
            }

            if let fallbackResult {
                return .success(fallbackResult)
            }
            return .failure(lastError ?? URLError(.unknown))
        }

        return try outcome.get()
    }

    private func transcribeSingleModel(
        requestTemplate: URLRequest,
        bodyURL: URL,
        modelName: String,
        requestID: String,
        onLog: LogHandler? = nil
    ) async throws -> String {
        var request = requestTemplate
        request.timeoutInterval = requestTimeoutCeiling

        let metricsCollector = TaskMetricsCollector()
        let uploadNoProgressTimeoutSeconds = self.uploadNoProgressTimeoutSeconds
        let upload = self.upload
        let inFlightAtStart = incrementInFlightRequests()
        let startTime = Date()
        let bodyBytes = fileSizeBytes(at: bodyURL)

        await onLog?(
            "[\(requestID)] Sending request to OpenAI transcription API (\(modelName)); inFlight=\(inFlightAtStart); url_timeout=\(Int(round(request.timeoutInterval)))s; body=\(bodyBytes.map(formatBytes) ?? "?")",
            .info
        )

        let (data, response): (Data, URLResponse)
        do {
            let noProgressTimeout = min(
                uploadNoProgressTimeoutSeconds,
                max(0, request.timeoutInterval - 1)
            )

            (data, response) = try await withThrowingTaskGroup(
                of: (Data, URLResponse).self,
                returning: (Data, URLResponse).self
            ) { group in
                group.addTask {
                    try await upload(request, bodyURL, metricsCollector)
                }

                if noProgressTimeout > 0 {
                    group.addTask {
                        try await Task.sleep(for: .seconds(noProgressTimeout))

                        // If we're still at 0B sent, we're almost certainly stuck in connection setup
                        // (seen as proto=h3 with 0B sent/recv). Cancel quickly and let retry logic
                        // start a fresh attempt.
                        if !metricsCollector.hasSentAnyRequestBodyBytes {
                            await onLog?(
                                "[\(requestID)] No upload progress (sent=0B) after \(Int(round(noProgressTimeout)))s (\(modelName)); cancelling attempt",
                                .warning
                            )
                            throw TranscriptionError.timeout
                        }

                        while !Task.isCancelled {
                            try await Task.sleep(for: .seconds(1))
                        }
                        throw CancellationError()
                    }
                }

                do {
                    guard let first = try await group.next() else {
                        throw URLError(.unknown)
                    }
                    group.cancelAll()
                    return first
                } catch {
                    group.cancelAll()
                    throw error
                }
            }
        } catch {
            let elapsed = Date().timeIntervalSince(startTime)
            let inFlightAfter = decrementInFlightRequests()

            let isCancellation = isCancellationError(error)
            await onLog?(
                "[\(requestID)] Request \(isCancellation ? "cancelled" : "failed") after \(formatSeconds(elapsed))s; inFlight=\(inFlightAfter); error=\(error.localizedDescription)",
                isCancellation ? .warning : .error
            )
            if let metrics = metricsCollector.metrics, (!isCancellation || elapsed >= metricsSlowThresholdSeconds) {
                await logMetrics(metrics, requestID: requestID, modelName: modelName, onLog: onLog)
            }
            throw error
        }

        let elapsed = Date().timeIntervalSince(startTime)
        let inFlightAfter = decrementInFlightRequests()
        await onLog?(
            "[\(requestID)] Request completed in \(formatSeconds(elapsed))s; inFlight=\(inFlightAfter)",
            .info
        )
        if let metrics = metricsCollector.metrics, elapsed >= metricsSlowThresholdSeconds {
            await logMetrics(metrics, requestID: requestID, modelName: modelName, onLog: onLog)
        }

        guard let httpResponse = response as? HTTPURLResponse else {
            throw TranscriptionError.invalidResponse
        }

        await onLog?("[\(requestID)] Received HTTP \(httpResponse.statusCode) (\(modelName))", .info)

        if httpResponse.statusCode != 200 {
            if shouldRetryForTimeout(statusCode: httpResponse.statusCode) {
                await onLog?("[\(requestID)] Timeout status code \(httpResponse.statusCode) (\(modelName))", .warning)
                throw TranscriptionError.timeout
            }

            if Self.retryableHTTPStatusCodes.contains(httpResponse.statusCode) {
                let serverMessage = (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.error.message
                if let serverMessage, !serverMessage.isEmpty {
                    await onLog?("[\(requestID)] Retryable HTTP \(httpResponse.statusCode) (\(modelName)): \(serverMessage)", .warning)
                } else {
                    await onLog?("[\(requestID)] Retryable HTTP \(httpResponse.statusCode) (\(modelName))", .warning)
                }
                throw TranscriptionError.httpError(httpResponse.statusCode)
            }

            if let errorResponse = try? JSONDecoder().decode(ErrorResponse.self, from: data) {
                throw TranscriptionError.apiError(errorResponse.error.message)
            }
            throw TranscriptionError.httpError(httpResponse.statusCode)
        }

        let result = try JSONDecoder().decode(TranscriptionResponse.self, from: data)
        return result.text
    }

    private func hedgeDelay(forAudioDuration duration: TimeInterval) -> TimeInterval {
        hedgeDelayCalculator(duration)
    }

    private func hedgeDelayForAttempt(attempt: Int, baseHedgeDelay: TimeInterval) -> TimeInterval {
        // First attempt: wait based on the audio duration heuristic.
        if attempt == 0 {
            return min(requestTimeoutCeiling, baseHedgeDelay)
        }

        // Retries: hedge quickly.
        return min(6, max(2, baseHedgeDelay * 0.25))
    }

    private func attemptDeadlineForAttempt(attempt: Int, baseHedgeDelay: TimeInterval) -> TimeInterval {
        // Decouple "when to hedge" from "when to retry":
        // - hedge early
        // - allow a wider overall attempt deadline before declaring a timeout
        if attempt == 0 {
            // Give the primary request time to finish in most real-world conditions
            // while still allowing hedging to kick in for tail latency.
            let firstAttemptDeadline = max(35, baseHedgeDelay + 25)
            return min(requestTimeoutCeiling, firstAttemptDeadline)
        }

        let retryFloor: TimeInterval = 45
        let widenedRetryBudget = max(retryFloor, baseHedgeDelay * 2.0) + (Double(attempt - 1) * 15)
        return min(requestTimeoutCeiling, max(widenedRetryBudget, baseHedgeDelay + 25))
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

    private func isLikelyLocalConnectivityError(_ error: Error) -> Bool {
        let urlError: URLError?
        if let direct = error as? URLError {
            urlError = direct
        } else {
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain {
                urlError = URLError(URLError.Code(rawValue: nsError.code))
            } else {
                urlError = nil
            }
        }

        guard let urlError else {
            return false
        }

        switch urlError.code {
        case .notConnectedToInternet,
             .networkConnectionLost,
             .dnsLookupFailed,
             .cannotFindHost,
             .cannotConnectToHost,
             .internationalRoamingOff,
             .dataNotAllowed:
            return true
        default:
            return false
        }
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
        let mimeType = mimeTypeForAudioFile(at: audioURL)

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
            outputHandle.writeString("Content-Type: \(mimeType)\r\n\r\n")
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

    private func mimeTypeForAudioFile(at url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "m4a":
            return "audio/m4a"
        case "mp3":
            return "audio/mpeg"
        case "wav":
            return "audio/wav"
        case "aac":
            return "audio/aac"
        case "mp4":
            return "audio/mp4"
        case "caf":
            return "audio/x-caf"
        default:
            return "application/octet-stream"
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
