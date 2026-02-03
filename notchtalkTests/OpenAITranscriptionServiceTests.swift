import Foundation
import Testing
@testable import notchtalk

struct OpenAITranscriptionServiceTests {
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
}
