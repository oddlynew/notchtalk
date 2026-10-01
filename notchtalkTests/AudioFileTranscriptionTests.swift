import AVFoundation
import Testing
@testable import notchtalk

struct AudioFileTranscriptionTests {
    @Test func takesAudioAndVideoButNotOtherFiles() {
        for name in ["a.m4a", "a.mp3", "a.wav", "a.aiff", "a.mov", "a.mp4", "a.qta"] {
            #expect(AudioFileTranscription.isAudioOrVideo(URL(fileURLWithPath: name)), "\(name)")
        }
        for name in ["a.txt", "a.pdf", "a.png", "a"] {
            #expect(!AudioFileTranscription.isAudioOrVideo(URL(fileURLWithPath: name)), "\(name)")
        }
    }

    @MainActor @Test func aRejectedDropEndsTheHoverShowsAgainOnTheNextDropAndSettles() {
        let drop = FileDrop.shared
        drop.hovering = true
        let pdf = URL(fileURLWithPath: "/tmp/notes.pdf")
        #expect(!drop.transcribe([pdf]))
        #expect(!drop.hovering)
        #expect(drop.status == .failed("notes.pdf has no sound to transcribe. Try an audio or video file."))
        let attempts = drop.attempts
        drop.transcribe([pdf])
        #expect(drop.attempts == attempts + 1)
        drop.settle()
        #expect(drop.status == .idle)
    }

    @Test func exportsWavAsM4AWithTheSameLength() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let wav = folder.appendingPathComponent("tone.wav")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000)!
        buffer.frameLength = 16_000
        for i in 0..<16_000 { buffer.floatChannelData![0][i] = sin(Float(i) * 0.1) * 0.3 }
        try AVAudioFile(forWriting: wav, settings: format.settings).write(from: buffer)

        let m4a = folder.appendingPathComponent("out.m4a")
        try await AudioFileTranscription.exportAudio(of: wav, to: m4a)

        let asset = AVURLAsset(url: m4a)
        #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)
        #expect(abs(try await asset.load(.duration).seconds - 1) < 0.1)
    }
}
