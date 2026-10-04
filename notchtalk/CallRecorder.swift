//
//  CallRecorder.swift
//  notchtalk
//

import AVFoundation
import CoreAudio
import Foundation

/// Records the calls held on this Mac while call mode is on: iPhone calls through Continuity and FaceTime.
/// A call is under way while one of Apple's call processes reads the microphone. The other side comes
/// from a Core Audio process tap on those processes, this side from the microphone. When the call ends,
/// both are mixed into one track and transcribed like a voice memo.
@MainActor
@Observable
final class CallRecorder {
    static let shared = CallRecorder()
    /// The processes that carry Continuity and FaceTime calls, as CallNotes (github.com/michaelczesun/callnotes) records them.
    nonisolated static let callProcesses: Set<String> = [
        "com.apple.avconferenced", "com.apple.TelephonyUtilities", "com.apple.FaceTime", "com.apple.Phone"
    ]
    /// A route change or a short gap in the microphone must not split one call in two.
    static let hangUpGrace: Duration = .seconds(4)
    static let tapProblem = "The last call has only your side. To record the other side, allow Notchtalk under System Settings → Privacy & Security → Screen & System Audio Recording."
    static let micProblem = "The last call has only the other side. The microphone didn't start; check that it's connected and allowed for Notchtalk."
    /// A tap without the system audio permission hears only silence, but so does one on a caller who never spoke.
    static let silentProblem = "The other side of the last call was silent. If they spoke, allow Notchtalk under System Settings → Privacy & Security → Screen & System Audio Recording."

    /// Set while a call is being recorded.
    private(set) var startedAt: Date?
    /// Shown in the menu when calls can only be recorded from the microphone.
    private(set) var problem: String?
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    @ObservationIgnored private var micEngine: AVAudioEngine?
    @ObservationIgnored private var tap: ProcessTap?
    // ponytail: both sides stay in memory, about 115 MB per hour each; stream to disk if calls run for hours.
    // Not observed: an observed array is copied whole on every append.
    @ObservationIgnored private var mic: [Int16] = []
    @ObservationIgnored private var remote: [Int16] = []
    /// Bumped by every stop, so samples queued before it never land in the next call.
    @ObservationIgnored private var session = 0
    /// Samples of silence in front of the other side: its tap starts after the microphone.
    @ObservationIgnored private var remoteLead = 0
    /// The last finished call on its way to History; the next one waits for it.
    @ObservationIgnored private var handOff: Task<Void, Never>?

    var isRecording: Bool { startedAt != nil }

    /// Turning call mode off during a call discards that call.
    func update(enabled: Bool) {
        guard enabled else {
            watchTask?.cancel()
            watchTask = nil
            problem = nil
            stopCapture()
            return
        }
        guard watchTask == nil else { return }
        // Asks for the system audio permission now rather than in the middle of the first call.
        ProcessTap.requestPermission()
        watchTask = Task { [weak self] in
            var quietSince: ContinuousClock.Instant?
            while !Task.isCancelled {
                guard let self else { return }
                let processes = ProcessTap.audioProcesses().filter { Self.callProcesses.contains($0.bundleID) }
                if processes.contains(where: \.readsMicrophone) {
                    quietSince = nil
                    if !self.isRecording { self.start(tapping: processes.map(\.id)) }
                } else if self.isRecording {
                    let since = quietSince ?? .now
                    quietSince = since
                    if ContinuousClock.now - since >= Self.hangUpGrace { self.finish() }
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func start(tapping processes: [AudioObjectID]) {
        session += 1
        let session = session
        startedAt = Date()
        problem = nil
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        if format.sampleRate > 0, let convert = AmbientRecorder.makeConverter(from: format) {
            input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
                guard let samples = convert(buffer) else { return }
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { CallRecorder.shared.append(samples, remote: false, session: session) }
                }
            }
            do {
                try engine.start()
                micEngine = engine
            } catch {
                input.removeTap(onBus: 0)
                problem = Self.micProblem
                NSLog("Call: microphone failed to start: \(error.localizedDescription)")
            }
        } else {
            problem = Self.micProblem
            NSLog("Call: the microphone has no usable format")
        }
        let micStarted = DispatchTime.now().uptimeNanoseconds
        do {
            tap = try ProcessTap(processes: processes) { samples in
                DispatchQueue.main.async {
                    MainActor.assumeIsolated { CallRecorder.shared.append(samples, remote: true, session: session) }
                }
            }
            if micEngine != nil {
                let elapsed = DispatchTime.now().uptimeNanoseconds - micStarted
                remoteLead = Int(elapsed) * AmbientBuffer.sampleRate / 1_000_000_000
            }
        } catch {
            problem = Self.tapProblem
            NSLog("Call: process tap failed: \(error)")
        }
    }

    private func append(_ samples: [Int16], remote isRemote: Bool, session: Int) {
        guard session == self.session else { return }
        if isRemote { remote += samples } else { mic += samples }
    }

    private func finish() {
        guard let startedAt else { return }
        if problem == nil, !remote.contains(where: { $0 != 0 }) { problem = Self.silentProblem }
        let (mic, remote) = (mic, Array(repeating: 0, count: remote.isEmpty ? 0 : remoteLead) + remote)
        stopCapture()
        guard !mic.isEmpty || !remote.isEmpty else {
            NSLog("Call: nothing was recorded")
            return
        }
        let seconds = Double(max(mic.count, remote.count)) / Double(AmbientBuffer.sampleRate)
        let name = FileManager.default.temporaryDirectory
            .appendingPathComponent("notchtalk_call_\(Int(startedAt.timeIntervalSince1970)).m4a")
        let previous = handOff
        handOff = Task {
            // People often dictate right after hanging up; the call waits its turn instead of failing, in memory,
            // so a quit while it waits leaves nothing behind. Calls queue behind each other the same way.
            // Busy also covers a dropped file or voice memo still being read, so the call never overtakes one.
            @MainActor func waitForTurn() async {
                while FileDrop.shared.isBusy { try? await Task.sleep(for: .seconds(1)) }
            }
            await previous?.value
            await waitForTurn()
            await AudioFileTranscription.run(
                source: name,
                label: "Call, \(Int((seconds / 60).rounded(.up))) min",
                reason: "Call ended after \(Int(seconds)) s",
                duration: seconds
            ) { url in
                // Mixing an hour of audio takes a moment, so it stays off the main thread.
                try await Task.detached { try AmbientRecorder.encode(Self.mix(mic, remote), to: url) }.value
                // Something may have started while mixing; run starts the transcription right after this returns.
                await waitForTurn()
            }
        }
    }

    private func stopCapture() {
        session += 1
        AmbientRecorder.retire(micEngine)
        micEngine = nil
        tap?.stop()
        tap = nil
        mic = []
        remote = []
        remoteLead = 0
        startedAt = nil
    }

    /// Both sides as one track; the caller lines them up, so sample i of each is the same moment.
    nonisolated static func mix(_ a: [Int16], _ b: [Int16]) -> [Int16] {
        (0..<max(a.count, b.count)).map { i in
            Int16(clamping: Int32(i < a.count ? a[i] : 0) + Int32(i < b.count ? b[i] : 0))
        }
    }
}
