//
// Checks what ambient mode rests on, against the app's own AmbientRecorder:
// 1. a normal AVAudioRecorder recording and the ambient engine capture the microphone at the same time,
// 2. idle CPU and memory of the running ambient capture,
// 3. encoding a full 10 minute window for upload,
// 4. the built-in microphone path used while AirPods are the input,
// 5. turning ambient off discards the window.
//
// Needs microphone permission for the terminal (it never asks), plays nothing, shows nothing,
// and takes about 45 seconds:
//   swiftc -parse-as-library -O scripts/verify_ambient_capture.swift notchtalk/AmbientRecorder.swift -o .build/verify_ambient && .build/verify_ambient
//

import AVFoundation
import Foundation

@main
struct VerifyAmbientCapture {
    static func main() {
        MainActor.assumeIsolated { run() }
    }
}

func expect(_ condition: Bool, _ message: String) {
    guard condition else {
        print("FAIL: \(message)")
        exit(1)
    }
}

func wait(_ seconds: TimeInterval) {
    RunLoop.main.run(until: Date().addingTimeInterval(seconds))
}

func cpuSeconds() -> Double {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    let user = Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1e6
    let system = Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1e6
    return user + system
}

func footprintMB() -> Double {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
}

func rms(_ samples: [Int16]) -> Double {
    guard !samples.isEmpty else { return 0 }
    let sum = samples.reduce(0.0) { $0 + Double($1) * Double($1) }
    return (sum / Double(samples.count)).squareRoot()
}

@MainActor
func run() {
    expect(
        AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
        "the terminal has no microphone permission; this script never asks for it"
    )
    let baseline = footprintMB()
    let ambient = AmbientRecorder()
    ambient.update(enabled: true, windowMinutes: 10)
    expect(ambient.isRunning, "ambient engine did not start")
    wait(1)

    // 1. A normal recording alongside ambient capture.
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("notchtalk_ambient_parallel.m4a")
    try? FileManager.default.removeItem(at: url)
    let recorder = try! AVAudioRecorder(url: url, settings: [
        AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
        AVSampleRateKey: 16000,
        AVNumberOfChannelsKey: 1,
        AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
        AVEncoderBitRateKey: 48000
    ])
    recorder.isMeteringEnabled = true
    let heldBefore = ambient.buffer.duration
    expect(recorder.record(), "normal recording did not start while ambient runs")
    wait(5)
    recorder.updateMeters()
    let recorderPower = recorder.averagePower(forChannel: 0)
    recorder.stop()
    let recordedDuration = (try? AVAudioFile(forReading: url)).map { Double($0.length) / $0.fileFormat.sampleRate } ?? -1
    let ambientGain = ambient.buffer.duration - heldBefore
    let ambientLevel = rms(ambient.buffer.last(5 * AmbientBuffer.sampleRate))
    try? FileManager.default.removeItem(at: url)
    print(String(format: "parallel: normal recording %.2f s (level %.0f dB), ambient grew %.2f s (rms %.1f) in the same 5.00 s",
                 recordedDuration, recorderPower, ambientGain, ambientLevel))
    expect(recordedDuration > 4.5 && recordedDuration < 5.6, "normal recording should hold about 5 s")
    expect(ambientGain > 4.5 && ambientGain < 5.6, "ambient should keep capturing during the normal recording")
    expect(ambientLevel > 0, "ambient captured only digital silence")
    expect(ambient.isRunning, "ambient stopped when the normal recording ended")

    // 2. Idle cost of the running capture.
    let cpuStart = cpuSeconds()
    let wallStart = Date()
    wait(30)
    let cpuPercent = (cpuSeconds() - cpuStart) / Date().timeIntervalSince(wallStart) * 100
    let windowMB = Double(ambient.buffer.capacity * MemoryLayout<Int16>.size) / 1_048_576
    print(String(format: "idle: %.2f %% CPU over 30 s; buffer %.1f MB for 10 min (%.1f MB for 20 min); process footprint %.1f MB above start",
                 cpuPercent, windowMB, windowMB * 2, footprintMB() - baseline))
    expect(cpuPercent < 2, "idle CPU should stay under 2 %")
    expect(windowMB < 150, "a 10 minute window should stay under 150 MB")

    // 3. Encoding a full 10 minute window, as a recall would.
    let full = (0..<(10 * 60 * AmbientBuffer.sampleRate)).map { Int16(truncatingIfNeeded: ($0 * 7919) % 2000 - 1000) }
    let encodedURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("notchtalk_ambient_encode.m4a")
    try? FileManager.default.removeItem(at: encodedURL)
    let encodeStart = Date()
    do {
        try AmbientRecorder.encode(full, to: encodedURL)
    } catch {
        expect(false, "encoding failed: \(error.localizedDescription)")
    }
    let encodeSeconds = Date().timeIntervalSince(encodeStart)
    let sizeMB = Double((try? FileManager.default.attributesOfItem(atPath: encodedURL.path)[.size] as? Int) ?? 0) / 1_048_576
    let encodedDuration = (try? AVAudioFile(forReading: encodedURL)).map { Double($0.length) / $0.fileFormat.sampleRate } ?? -1
    try? FileManager.default.removeItem(at: encodedURL)
    print(String(format: "encode: 10 min window to %.2f MB m4a holding %.1f s in %.2f s", sizeMB, encodedDuration, encodeSeconds))
    expect(abs(encodedDuration - 600) < 1, "encoded file should hold 600 s")
    expect(sizeMB < 25, "upload must stay under the 25 MB provider limit")

    // 4. The built-in microphone path used while AirPods are the input.
    guard let builtIn = AmbientRecorder.builtInInputDevice() else {
        print("built-in microphone: none on this Mac, AirPods stay the ambient input")
        return finish(ambient)
    }
    let pinned = AVAudioEngine()
    AmbientRecorder.pin(pinned.inputNode, to: builtIn)
    let pinnedFormat = pinned.inputNode.outputFormat(forBus: 0)
    var pinnedFrames = 0
    pinned.inputNode.installTap(onBus: 0, bufferSize: 4096, format: pinnedFormat) { buffer, _ in
        DispatchQueue.main.async { pinnedFrames += Int(buffer.frameLength) }
    }
    expect((try? pinned.start()) != nil, "engine pinned to the built-in microphone did not start")
    wait(2)
    pinned.inputNode.removeTap(onBus: 0)
    pinned.stop()
    let bluetoothNow = AmbientRecorder.preferredInputDevice() != nil
    print(String(format: "built-in pin: device %u captured %.2f s at %.0f Hz; default input is Bluetooth now: %@",
                 builtIn, Double(pinnedFrames) / pinnedFormat.sampleRate, pinnedFormat.sampleRate, bluetoothNow ? "yes" : "no"))
    expect(pinnedFrames > 0, "engine pinned to the built-in microphone captured nothing")
    finish(ambient)
}

@MainActor
func finish(_ ambient: AmbientRecorder) {
    // 5. Off discards.
    ambient.update(enabled: false, windowMinutes: 10)
    expect(!ambient.isRunning && ambient.buffer.count == 0, "turning ambient off must discard the window")
    print("PASS: ambient capture runs beside normal recordings and stays within budget")
}
