//
//  AudioRecorder.swift
//  notchtalk
//

import AVFoundation
import Foundation

/// Records through AVAudioEngine pinned to one microphone, chosen at start: with AirPods or another
/// Bluetooth headset as default input that is the built-in one, so the headset keeps playing in full
/// quality instead of dropping into call mode. A device change mid-recording never moves the input.
@MainActor
final class AudioRecorder: NSObject {
    private var engine: AVAudioEngine?
    private var recordingURL: URL?
    private var smoothedLevel: CGFloat = 0
    private var session = 0
    private var writtenFrames: AVAudioFramePosition = 0
    private var output: Output?

    /// Holds the file the tap writes; releasing it finishes the .m4a.
    private final class Output: @unchecked Sendable {
        var file: AVAudioFile?
        init(_ file: AVAudioFile) { self.file = file }
    }

    var onAudioLevelUpdate: ((CGFloat) -> Void)?

    var recordedDuration: TimeInterval { Double(writtenFrames) / 16000 }

    var isRecording: Bool {
        engine?.isRunning ?? false
    }

    /// The engine keeps writing into the same file on resume, so paused time never enters the audio.
    func pause() {
        engine?.pause()
        smoothedLevel = 0
        onAudioLevelUpdate?(0)
    }

    /// False keeps the caller paused rather than pretending to capture audio.
    /// With no recorder yet, a pause that never reached one is simply dropped.
    func resume() -> Bool {
        guard let engine else { return true }
        return (try? engine.start()) != nil
    }

    func startRecording() async throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "notchtalk_recording_\(Date().timeIntervalSince1970).m4a"
        let url = tempDir.appendingPathComponent(fileName)

        // 16kHz mono AAC is optimal for speech transcription (Whisper is trained on 16kHz)
        // Medium quality ~48kbps keeps file sizes small while maintaining speech clarity
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
            AVEncoderBitRateKey: 48000
        ]

        let engine = AVAudioEngine()
        let input = engine.inputNode
        if let device = AmbientRecorder.recordingInputDevice() {
            AmbientRecorder.pin(input, to: device)
        }
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, let convert = AmbientRecorder.makeConverter(from: inputFormat) else {
            AmbientRecorder.retire(engine)
            throw CocoaError(.fileWriteUnknown)
        }
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatInt16, interleaved: true)
        session += 1
        let output = Output(file)
        input.installTap(onBus: 0, bufferSize: 1024, format: inputFormat, block: Self.makeTap(convert: convert, output: output, recorder: self, session: session))
        do {
            try engine.start()
        } catch {
            AmbientRecorder.retire(engine)
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        self.engine = engine
        self.output = output
        recordingURL = url
        writtenFrames = 0
        smoothedLevel = 0
        return url
    }

    func stopRecording() -> URL? {
        finish()
        smoothedLevel = 0
        let url = recordingURL
        recordingURL = nil
        return url
    }

    func cancelRecording() {
        finish()
        smoothedLevel = 0
        if let url = recordingURL {
            try? FileManager.default.removeItem(at: url)
        }
        recordingURL = nil
    }

    /// Stops the engine first, so no tap writes any more, then releases the file, which completes it.
    private func finish() {
        session += 1
        AmbientRecorder.retire(engine)
        engine = nil
        output?.file = nil
        output = nil
    }

    /// Runs on the engine's thread: writes 16 kHz mono and reports the level and length on the main actor.
    private nonisolated static func makeTap(
        convert: @escaping (AVAudioPCMBuffer) -> [Int16]?,
        output: Output,
        recorder: AudioRecorder,
        session: Int
    ) -> AVAudioNodeTapBlock {
        { [weak recorder] input, _ in
            guard let file = output.file, let samples = convert(input), !samples.isEmpty,
                  let pcm = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(samples.count)),
                  let channel = pcm.int16ChannelData?[0] else { return }
            samples.withUnsafeBufferPointer { channel.update(from: $0.baseAddress!, count: samples.count) }
            pcm.frameLength = AVAudioFrameCount(samples.count)
            do { try file.write(from: pcm) } catch { NSLog("Recording: could not write audio: \(error.localizedDescription)") }
            var sum: Float = 0
            var peak: Float = 0
            for sample in samples {
                let value = abs(Float(sample) / Float(Int16.max))
                sum += value * value
                peak = max(peak, value)
            }
            let averagePower = 20 * log10(max(sqrt(sum / Float(samples.count)), 1e-8))
            let peakPower = 20 * log10(max(peak, 1e-8))
            let frames = file.length
            DispatchQueue.main.async { [weak recorder] in
                MainActor.assumeIsolated {
                    guard let recorder, recorder.session == session else { return }
                    recorder.writtenFrames = frames
                    recorder.updateAudioLevel(averagePower: averagePower, peakPower: peakPower)
                }
            }
        }
    }

    private func updateAudioLevel(averagePower: Float, peakPower: Float) {
        guard isRecording else { return }

        // Convert dB to linear scale (0.0 to 1.0)
        // Average power typically ranges from -160 (silence) to 0 (max).
        // We combine average/peak and boost low-end response so quiet speech still animates.
        let effectivePower = max(averagePower, peakPower - 12.0)
        let minDb: Float = -65.0
        let maxDb: Float = 0.0
        let normalizedValue = max(0, min(1, (effectivePower - minDb) / (maxDb - minDb)))
        let boostedLevel = CGFloat(pow(Double(normalizedValue), 0.45))
        let smoothing: CGFloat = boostedLevel > smoothedLevel ? 0.55 : 0.30
        smoothedLevel += (boostedLevel - smoothedLevel) * smoothing

        onAudioLevelUpdate?(smoothedLevel)
    }

}
