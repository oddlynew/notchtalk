import Foundation
import Testing
@testable import notchtalk

struct TranscriptionEmptyResultTests {
    actor RequestCounter {
        var count = 0
        func increment() { count += 1 }
    }

    @Test("Both providers reject empty successful HTTP responses without retrying")
    func emptyResponsesFail() async throws {
        for provider in [TranscriptionProvider.openAI, .elevenLabs] {
            for text in ["", " \n\t "] {
                let counter = RequestCounter()
                do {
                    _ = try await transcribe(provider: provider, text: text, counter: counter)
                    Issue.record("An empty response must not enter the paste/send success path")
                } catch let error as TranscriptionError {
                    guard case .emptyTranscript = error else {
                        Issue.record("Expected emptyTranscript, got \(error)")
                        return
                    }
                    #expect(error.statusMessage == "No speech detected")
                }
                let requestCount = await counter.count
                #expect(requestCount == 1)
            }
        }
    }

    @Test("Both providers preserve nonempty speech and its formatting")
    func speechIsPreserved() async throws {
        for provider in [TranscriptionProvider.openAI, .elevenLabs] {
            let text = " Hallo, test test.\n"
            let counter = RequestCounter()
            let result = try await transcribe(provider: provider, text: text, counter: counter)
            #expect(result == text)
            let requestCount = await counter.count
            #expect(requestCount == 1)
        }
    }

    @Test("An empty primary cannot win over a valid fallback transcript")
    func emptyPrimaryAllowsFallback() async throws {
        let audio = FileManager.default.temporaryDirectory.appendingPathComponent("empty-hedge-\(UUID()).m4a")
        try Data("test-audio".utf8).write(to: audio)
        defer { try? FileManager.default.removeItem(at: audio) }

        for fallbackText in ["", "Hallo, test test."] {
            let counter = RequestCounter()
            let service = OpenAITranscriptionService(
                fallbackModel: "gpt-4o-mini-transcribe",
                fallbackGraceSeconds: 0,
                hedgeDelayCalculator: { _ in 0 },
                apiKeyProvider: { "fixture" },
                upload: { request, bodyURL, _ in
                    await counter.increment()
                    let body = String(decoding: try Data(contentsOf: bodyURL), as: UTF8.self)
                    let isFallback = body.contains("\r\ngpt-4o-mini-transcribe\r\n")
                    let response = try JSONSerialization.data(withJSONObject: ["text": isFallback ? fallbackText : ""])
                    return (response, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
                }
            )
            do {
                let result = try await service.transcribe(audioURL: audio, prompt: nil)
                #expect(!fallbackText.isEmpty)
                #expect(result == fallbackText)
            } catch let error as TranscriptionError {
                #expect(fallbackText.isEmpty)
                guard case .emptyTranscript = error else {
                    Issue.record("Expected emptyTranscript, got \(error)")
                    return
                }
            }
            let requestCount = await counter.count
            #expect(requestCount == 2)
        }
    }

    private func transcribe(provider: TranscriptionProvider, text: String, counter: RequestCounter) async throws -> String {
        let audio = FileManager.default.temporaryDirectory.appendingPathComponent("empty-result-\(UUID()).m4a")
        try Data("test-audio".utf8).write(to: audio)
        defer { try? FileManager.default.removeItem(at: audio) }
        let responseData = try JSONSerialization.data(withJSONObject: ["text": text])
        let upload: ElevenLabsTranscriptionService.UploadFunction = { request, _ in
            await counter.increment()
            return (responseData, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        switch provider {
        case .openAI:
            let service = OpenAITranscriptionService(apiKeyProvider: { "fixture" }, upload: { request, bodyURL, _ in
                try await upload(request, bodyURL)
            })
            return try await service.transcribe(audioURL: audio, prompt: nil)
        case .elevenLabs:
            let service = ElevenLabsTranscriptionService(apiKeyProvider: { "fixture" }, upload: upload)
            return try await service.transcribe(audioURL: audio, diarize: true)
        }
    }
}
