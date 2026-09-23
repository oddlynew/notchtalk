//
//  AmbientRecorder.swift
//  notchtalk
//

import AppKit
import AVFoundation
import Foundation

/// Rolling window of 16 kHz mono audio in memory. The newest samples overwrite the oldest,
/// so nothing older than the window exists anywhere, and nothing reaches the disk until a recall.
@MainActor
final class AmbientBuffer {
    static let sampleRate = 16_000

    private var samples: [Int16]
    private var writeIndex = 0
    private(set) var count = 0
    /// Bumped by `discard`, so samples a stopped tap already queued never land afterwards.
    private(set) var session = 0

    var capacity: Int { samples.count }
    var duration: TimeInterval { Double(count) / Double(Self.sampleRate) }

    init(capacity: Int) {
        samples = [Int16](repeating: 0, count: max(1, capacity))
    }

    func append(_ newSamples: [Int16]) {
        // Only the tail of an oversized chunk can survive; skip the rest.
        for sample in newSamples.suffix(capacity) {
            samples[writeIndex] = sample
            writeIndex = (writeIndex + 1) % capacity
        }
        count = min(capacity, count + newSamples.count)
    }

    /// The newest `n` samples in recording order, across the wrap point.
    func last(_ n: Int) -> [Int16] {
        let n = min(max(0, n), count)
        let start = (writeIndex - n + capacity) % capacity
        if start + n <= capacity {
            return Array(samples[start..<start + n])
        }
        return Array(samples[start...] + samples[..<(start + n - capacity)])
    }

    /// Keeps as much of the newest audio as the new window holds.
    func resize(capacity newCapacity: Int) {
        let tail = last(newCapacity)
        samples = [Int16](repeating: 0, count: max(1, newCapacity))
        count = 0
        writeIndex = 0
        append(tail)
    }

    func clear() {
        samples.withUnsafeMutableBufferPointer { $0.update(repeating: 0) }
        writeIndex = 0
        count = 0
    }

    /// Overwrites the audio before letting go of the memory, so none of it lingers.
    func discard() {
        clear()
        samples = [0]
        session += 1
    }
}

/// Listens continuously into an AmbientBuffer while ambient mode is on.
/// Runs its own AVAudioEngine next to the AVAudioRecorder of normal recordings:
/// macOS lets several clients read the same input device at once, so neither path waits for the other.
@MainActor
@Observable
final class AmbientRecorder {
    static let shared = AmbientRecorder()
    static let recallChoices = [2, 5, 10, 20]

    private(set) var isRunning = false
    // Holds memory only while listening; `update` sizes it to the window.
    let buffer = AmbientBuffer(capacity: 1)
    private var engine: AVAudioEngine?
    private var configurationObserver: NSObjectProtocol?
    private var sleepObserver: NSObjectProtocol?
    private var wanted = false
    private var retryTask: Task<Void, Never>?

    /// Starts, resizes, or stops (and discards) to match the settings.
    func update(enabled: Bool, windowMinutes: Int) {
        guard enabled, AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else {
            stop()
            return
        }
        let capacity = windowMinutes * 60 * AmbientBuffer.sampleRate
        if buffer.capacity != capacity { buffer.resize(capacity: capacity) }
        wanted = true
        if !isRunning { start() }
    }

    func stop() {
        wanted = false
        retryTask?.cancel()
        retryTask = nil
        stopEngine()
        buffer.discard()
    }

    private func start() {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0,
              let tap = Self.makeTap(from: inputFormat, into: buffer, session: buffer.session) else {
            NSLog("Ambient: no usable input format")
            retryLater()
            return
        }
        input.installTap(onBus: 0, bufferSize: 4096, format: inputFormat, block: tap)
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            NSLog("Ambient: engine failed to start: \(error.localizedDescription)")
            retryLater()
            return
        }
        self.engine = engine
        isRunning = true
        // A new input device (AirPods, unplugged mic) stops the engine; follow it and keep the window.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            // Apple: never tear the engine down inside this notification's handler, it can deadlock.
            Task { @MainActor [weak self] in
                guard let self, self.isRunning else { return }
                self.stopEngine()
                self.start()
            }
        }
        // The window counts samples, not time: audio from before a sleep would pass for "the last minutes".
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.buffer.clear() }
        }
    }

    /// No microphone yet (unplugged, or launched before it was connected): try again until one appears.
    private func retryLater() {
        retryTask?.cancel()
        retryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self, !Task.isCancelled, self.wanted, !self.isRunning else { return }
            self.start()
        }
    }

    private func stopEngine() {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
        configurationObserver = nil
        if let sleepObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver)
        }
        sleepObserver = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        isRunning = false
    }

    /// Built outside the main actor: AVAudioEngine calls the tap on its own thread.
    private nonisolated static func makeTap(
        from inputFormat: AVAudioFormat,
        into buffer: AmbientBuffer,
        session: Int
    ) -> AVAudioNodeTapBlock? {
        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(AmbientBuffer.sampleRate),
            channels: 1,
            interleaved: true
        ), let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            return nil
        }
        converter.downmix = true
        let ratio = targetFormat.sampleRate / inputFormat.sampleRate
        return { input, _ in
            let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio) + 32
            guard let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: capacity) else { return }
            var consumed = false
            var error: NSError?
            converter.convert(to: output, error: &error) { _, status in
                if consumed {
                    status.pointee = .noDataNow
                    return nil
                }
                consumed = true
                status.pointee = .haveData
                return input
            }
            guard error == nil, let channel = output.int16ChannelData?[0] else { return }
            let samples = Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    if buffer.session == session { buffer.append(samples) }
                }
            }
        }
    }

    /// Same format as a normal recording (16 kHz mono AAC at 48 kbps): ten minutes is about 3.6 MB.
    nonisolated static func encode(_ samples: [Int16], to url: URL) throws {
        guard let format = AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(AmbientBuffer.sampleRate),
            channels: 1,
            interleaved: true
        ), let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
           let channel = pcm.int16ChannelData?[0] else {
            throw CocoaError(.fileWriteUnknown)
        }
        samples.withUnsafeBufferPointer { source in
            channel.update(from: source.baseAddress!, count: samples.count)
        }
        pcm.frameLength = AVAudioFrameCount(samples.count)
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: AmbientBuffer.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
            AVEncoderBitRateKey: 48000
        ]
        // The file finishes writing when it is released at the end of this scope.
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatInt16, interleaved: true)
        try file.write(from: pcm)
    }
}
