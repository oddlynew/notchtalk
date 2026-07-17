import Foundation
import Testing
@testable import notchtalk

struct ElevenLabsTranscriptionServiceTests {
    actor RequestCapture {
        private(set) var apiKey: String?
        private(set) var bodyText = ""

        func record(request: URLRequest, bodyURL: URL) throws {
            apiKey = request.value(forHTTPHeaderField: "xi-api-key")
            bodyText = String(decoding: try Data(contentsOf: bodyURL), as: UTF8.self)
        }
    }

    @Test("Transcribe throws no API key when ElevenLabs key is missing")
    func transcribeThrowsWithoutAPIKey() async throws {
        let service = ElevenLabsTranscriptionService(apiKeyProvider: { nil })
        let audioURL = try makeTemporaryAudioFile(contents: Data("NO_KEY".utf8))
        defer { try? FileManager.default.removeItem(at: audioURL) }

        do {
            _ = try await service.transcribe(audioURL: audioURL, diarize: false)
            Issue.record("Expected TranscriptionError.noAPIKey")
        } catch let error as TranscriptionError {
            guard case .noAPIKey = error else {
                Issue.record("Expected noAPIKey, got \(error)")
                return
            }
        }
    }

    @Test("ElevenLabs request includes Scribe v2 and diarization fields")
    func requestIncludesExpectedFields() async throws {
        let capture = RequestCapture()
        let responseJSON = #"""
        {
          "text": "Hello there. Hi!",
          "words": [
            {"text":"Hello", "type":"word", "speaker_id":"speaker_0"},
            {"text":" there.", "type":"word", "speaker_id":"speaker_0"},
            {"text":" ", "type":"spacing", "speaker_id":"speaker_0"},
            {"text":"Hi!", "type":"word", "speaker_id":"speaker_1"}
          ]
        }
        """#

        let service = ElevenLabsTranscriptionService(
            apiKeyProvider: { "eleven-test-key" },
            upload: { request, bodyURL in
                try await capture.record(request: request, bodyURL: bodyURL)
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
                return (Data(responseJSON.utf8), response)
            }
        )
        let audioURL = try makeTemporaryAudioFile(contents: Data("AUDIO".utf8))
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let transcript = try await service.transcribe(audioURL: audioURL, diarize: true)

        #expect(transcript == "Speaker 1: Hello there.\n\nSpeaker 2: Hi!")
        let capturedAPIKey = await capture.apiKey
        #expect(capturedAPIKey == "eleven-test-key")
        let body = await capture.bodyText
        #expect(body.contains("name=\"model_id\"\r\n\r\nscribe_v2"))
        #expect(body.contains("name=\"diarize\"\r\n\r\ntrue"))
        #expect(body.contains("name=\"timestamps_granularity\"\r\n\r\nword"))
        #expect(body.contains("name=\"file\"; filename=\""))
    }

    @Test("Speaker recognition off returns the provider's plain transcript")
    func plainTranscriptWithoutDiarization() {
        let response = ElevenLabsTranscriptionService.TranscriptionResponse(
            text: "A plain transcript.",
            words: [
                .init(text: "Ignored", type: "word", speakerID: "speaker_0")
            ]
        )

        let transcript = ElevenLabsTranscriptionService.formattedTranscript(from: response, diarize: false)
        #expect(transcript == "A plain transcript.")
    }

    private func makeTemporaryAudioFile(contents: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("elevenlabs_test_\(UUID().uuidString).m4a")
        try contents.write(to: url)
        return url
    }
}
