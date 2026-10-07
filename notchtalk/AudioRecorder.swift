//
//  AudioRecorder.swift
//  notchtalk
//

import AVFoundation
import CoreAudio
import Foundation

/// Records straight from one microphone, chosen at start: with AirPods or another Bluetooth headset
/// as default input that is the built-in one, so the headset keeps playing in full quality instead of
/// dropping into call mode. A device change mid-recording never moves the input.
@MainActor
final class AudioRecorder: NSObject {
    private var microphone: Microphone?
    private var recordingURL: URL?
    private var smoothedLevel: CGFloat = 0
    private var session = 0
    private var writtenFrames: AVAudioFramePosition = 0

    var onAudioLevelUpdate: ((CGFloat) -> Void)?

    var recordedDuration: TimeInterval { Double(writtenFrames) / 16000 }

    var isRecording: Bool {
        microphone?.isRunning ?? false
    }

    /// The microphone keeps writing into the same file on resume, so paused time never enters the audio.
    func pause() {
        microphone?.pause()
        smoothedLevel = 0
        onAudioLevelUpdate?(0)
    }

    /// False keeps the caller paused rather than pretending to capture audio.
    /// With no recorder yet, a pause that never reached one is simply dropped.
    func resume() -> Bool {
        microphone?.resume() ?? true
    }

    func startRecording() async throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "notchtalk_recording_\(Date().timeIntervalSince1970).m4a"
        let url = tempDir.appendingPathComponent(fileName)

        guard let device = AmbientRecorder.recordingInputDevice() else { throw CocoaError(.fileReadNoSuchFile) }
        let writer = try Writer(url: url)
        session += 1
        let session = session
        do {
            microphone = try Microphone(device: device) { [weak self] samples in
                guard let (frames, averagePower, peakPower) = writer.write(samples) else { return }
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self, self.session == session else { return }
                        self.writtenFrames = frames
                        self.updateAudioLevel(averagePower: averagePower, peakPower: peakPower)
                    }
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        microphone?.writer = writer
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

    private func finish() {
        session += 1
        microphone?.stop()
        microphone = nil
    }

    /// Writes 16 kHz mono samples as AAC. Releasing it finishes the .m4a.
    final class Writer: @unchecked Sendable {
        private var file: AVAudioFile?

        init(url: URL) throws {
            // 16kHz mono AAC is optimal for speech transcription (Whisper is trained on 16kHz)
            // Medium quality ~48kbps keeps file sizes small while maintaining speech clarity
            let settings: [String: Any] = [
                AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
                AVSampleRateKey: 16000,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
                AVEncoderBitRateKey: 48000
            ]
            file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatInt16, interleaved: true)
        }

        /// Returns the frames written so far and the buffer's average and peak power in dB.
        func write(_ samples: [Int16]) -> (AVAudioFramePosition, Float, Float)? {
            guard let file, !samples.isEmpty,
                  let pcm = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(samples.count)),
                  let channel = pcm.int16ChannelData?[0] else { return nil }
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
            return (file.length, 20 * log10(max(sqrt(sum / Float(samples.count)), 1e-8)), 20 * log10(max(peak, 1e-8)))
        }

        func close() { file = nil }
    }

    /// An IO proc on the microphone device itself. AVAudioEngine cannot hold a non-default input:
    /// pinned to the built-in microphone while AirPods are the default, its tap kept the AirPods'
    /// 24 kHz format, failed to install and recorded nothing, and the engine fell back to the default.
    final class Microphone {
        private let device: AudioDeviceID
        private var ioProc: AudioDeviceIOProcID?
        private let queue = DispatchQueue(label: "oddlynew.notchtalk.microphone")
        private(set) var isRunning = false
        /// Closed after the last buffer, once the device has stopped.
        var writer: Writer?

        /// `deliver` gets the microphone as 16 kHz mono samples, on a background queue.
        init(device: AudioDeviceID, deliver: @escaping ([Int16]) -> Void) throws {
            self.device = device
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamFormat,
                mScope: kAudioObjectPropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var description = AudioStreamBasicDescription()
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &description) == noErr,
                  let format = AVAudioFormat(streamDescription: &description),
                  let convert = AmbientRecorder.makeConverter(from: format) else {
                throw CocoaError(.fileReadUnknown)
            }
            var status = AudioDeviceCreateIOProcIDWithBlock(&ioProc, device, queue) { _, inputData, _, _, _ in
                // The first input stream is the microphone; a device with more streams keeps the rest to itself.
                let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
                guard let first = buffers.first, first.mData != nil else { return }
                var list = AudioBufferList(mNumberBuffers: 1, mBuffers: first)
                guard let pcm = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: &list, deallocator: nil),
                      let samples = convert(pcm) else { return }
                deliver(samples)
            }
            guard status == noErr, let ioProc else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
            status = AudioDeviceStart(device, ioProc)
            guard status == noErr else {
                AudioDeviceDestroyIOProcID(device, ioProc)
                self.ioProc = nil
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
            }
            isRunning = true
        }

        func pause() {
            guard let ioProc, isRunning else { return }
            isRunning = AudioDeviceStop(device, ioProc) != noErr
        }

        func resume() -> Bool {
            guard let ioProc else { return false }
            if !isRunning { isRunning = AudioDeviceStart(device, ioProc) == noErr }
            return isRunning
        }

        /// Stops the device, lets the last buffer finish writing, then completes the file.
        func stop() {
            guard let ioProc else { return }
            AudioDeviceStop(device, ioProc)
            isRunning = false
            self.ioProc = nil
            let (device, writer) = (device, writer)
            queue.sync { writer?.close() }
            // Core Audio can deadlock when an IO proc goes right after its device stops, so this waits a moment.
            DispatchQueue.global().async {
                usleep(150_000)
                AudioDeviceDestroyIOProcID(device, ioProc)
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
