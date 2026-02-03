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
    private var smoothedLevel: CGFloat = 0

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

        smoothedLevel = 0
        startLevelMonitoring()

        return url
    }

    func stopRecording() -> URL? {
        stopLevelMonitoring()
        audioRecorder?.stop()
        smoothedLevel = 0
        let url = recordingURL
        audioRecorder = nil
        return url
    }

    func cancelRecording() {
        stopLevelMonitoring()
        audioRecorder?.stop()
        smoothedLevel = 0
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
        let peakPower = recorder.peakPower(forChannel: 0)

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

    func deleteRecording(at url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
