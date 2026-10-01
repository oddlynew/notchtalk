// Checks the call recorder's tap against the app's own code: a quiet test tone plays through afplay,
// and ProcessTap must hear it from that process alone. Needs the system audio permission for the terminal
// (System Settings → Privacy & Security → Screen & System Audio Recording) and takes about 5 seconds.
//
// swiftc -parse-as-library -O scripts/verify_call_capture.swift notchtalk/ProcessTap.swift notchtalk/AmbientRecorder.swift -o .build/verify_call && .build/verify_call

import AVFoundation
import CoreAudio
import Foundation

@main
struct VerifyCallCapture {
    static func main() async throws {
        check(!ProcessTap.audioProcesses().isEmpty, "Core Audio lists its audio processes")

        let tone = FileManager.default.temporaryDirectory.appendingPathComponent("notchtalk_verify_tone_\(UUID().uuidString).wav")
        try writeTone(to: tone, seconds: 4)
        defer { try? FileManager.default.removeItem(at: tone) }
        let player = Process()
        player.executableURL = URL(fileURLWithPath: "/usr/bin/afplay")
        player.arguments = ["-v", "0.05", tone.path]
        try player.run()
        defer { player.terminate() }

        var process: AudioObjectID?
        for _ in 0..<20 where process == nil {
            try await Task.sleep(for: .milliseconds(100))
            process = processObject(for: player.processIdentifier)
        }
        guard let process else { fail("afplay never showed up as an audio process") }

        let lock = NSLock()
        var samples: [Int16] = []
        let tap = try ProcessTap(processes: [process]) { chunk in
            lock.withLock { samples += chunk }
        }
        try await Task.sleep(for: .seconds(2))
        tap.stop()
        try await Task.sleep(for: .milliseconds(300))

        let heard = lock.withLock { samples }
        let peak = heard.map { abs(Int($0)) }.max() ?? 0
        print("Captured \(heard.count) samples in 2 s, peak \(peak)")
        check(heard.count > 24_000 && heard.count < 40_000, "the tap delivers 16 kHz audio")
        check(peak > 200, "the tap hears the test tone (no sound means the system audio permission is missing)")
        print("All checks passed")
    }

    static func writeTone(to url: URL, seconds: Double) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let frames = AVAudioFrameCount(48_000 * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for i in 0..<Int(frames) {
            buffer.floatChannelData![0][i] = 0.5 * sin(2 * .pi * 440 * Float(i) / 48_000)
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }

    static func processObject(for pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(
            mSelector: "id2p".utf8.reduce(0) { $0 << 8 | UInt32($1) },
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address,
            UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object
        )
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    static func check(_ condition: Bool, _ what: String) {
        if !condition { fail(what) }
        print("ok: \(what)")
    }

    static func fail(_ what: String) -> Never {
        print("FAILED: \(what)")
        exit(1)
    }
}
