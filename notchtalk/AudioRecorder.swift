//
//  AudioRecorder.swift
//  notchtalk
//

import AVFoundation
import Foundation

@MainActor
final class AudioRecorder: NSObject {
    private var audioRecorder: AVAudioRecorder?
    private var levelTimer: Timer?
    private var recordingURL: URL?

    var onAudioLevelUpdate: ((CGFloat) -> Void)?

    var isRecording: Bool {
        audioRecorder?.isRecording ?? false
    }

    func startRecording() async throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "notchtalk_recording_\(Date().timeIntervalSince1970).m4a"
        let url = tempDir.appendingPathComponent(fileName)
        recordingURL = url

        // 16kHz mono AAC is optimal for speech transcription (Whisper is trained on 16kHz)
        // Medium quality ~48kbps keeps file sizes small while maintaining speech clarity
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
            AVEncoderBitRateKey: 48000
        ]

        audioRecorder = try AVAudioRecorder(url: url, settings: settings)
        audioRecorder?.isMeteringEnabled = true
        audioRecorder?.prepareToRecord()
        audioRecorder?.record()

        startLevelMonitoring()

        return url
    }

    func stopRecording() -> URL? {
        stopLevelMonitoring()
        audioRecorder?.stop()
        let url = recordingURL
        audioRecorder = nil
        return url
    }

    func cancelRecording() {
        stopLevelMonitoring()
        audioRecorder?.stop()
        if let url = recordingURL {
            try? FileManager.default.removeItem(at: url)
        }
        audioRecorder = nil
        recordingURL = nil
    }

    private func startLevelMonitoring() {
        levelTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateAudioLevel()
            }
        }
    }

    private func stopLevelMonitoring() {
        levelTimer?.invalidate()
        levelTimer = nil
    }

    private func updateAudioLevel() {
        guard let recorder = audioRecorder, recorder.isRecording else { return }

        recorder.updateMeters()
        let averagePower = recorder.averagePower(forChannel: 0)

        // Convert dB to linear scale (0.0 to 1.0)
        // Average power typically ranges from -160 (silence) to 0 (max)
        // We'll use -50 to 0 as our effective range
        let minDb: Float = -50.0
        let maxDb: Float = 0.0
        let normalizedValue = (averagePower - minDb) / (maxDb - minDb)
        let level = CGFloat(max(0, min(1, normalizedValue)))

        onAudioLevelUpdate?(level)
    }

    func deleteRecording(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
