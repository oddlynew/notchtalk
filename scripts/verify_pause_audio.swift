#!/usr/bin/env swift
//
// Checks the one assumption pause/resume rests on: AVAudioRecorder keeps writing
// into the same file on resume, so paused time never reaches the audio.
//
// Needs microphone permission and takes about 15 seconds:
//   swift scripts/verify_pause_audio.swift
//

import AVFoundation
import Foundation

let settings: [String: Any] = [
    AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
    AVSampleRateKey: 16000,
    AVNumberOfChannelsKey: 1,
    AVEncoderAudioQualityKey: AVAudioQuality.medium.rawValue,
    AVEncoderBitRateKey: 48000
]

func makeRecorder(_ name: String) throws -> (AVAudioRecorder, URL) {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
    try? FileManager.default.removeItem(at: url)
    let recorder = try AVAudioRecorder(url: url, settings: settings)
    recorder.prepareToRecord()
    return (recorder, url)
}

func duration(of url: URL) -> Double {
    guard let file = try? AVAudioFile(forReading: url) else { return -1 }
    return Double(file.length) / file.fileFormat.sampleRate
}

func expect(_ condition: Bool, _ message: String) {
    guard condition else {
        print("FAIL: \(message)")
        exit(1)
    }
}

// 1. Pause, resume, stop: 7 seconds of wall clock hold 4 seconds of audio.
let (resumed, resumedURL) = try makeRecorder("notchtalk_pause_resume.m4a")
resumed.record()
Thread.sleep(forTimeInterval: 2)
let beforePause = resumed.currentTime
resumed.pause()
Thread.sleep(forTimeInterval: 3)
let afterPause = resumed.currentTime
expect(afterPause - beforePause < 0.2, "currentTime advanced while paused")
expect(resumed.record(), "resume failed")
Thread.sleep(forTimeInterval: 2)
resumed.stop()
let resumedDuration = duration(of: resumedURL)
print(String(format: "pause + resume: %.2f s of audio from 7.00 s of wall clock", resumedDuration))
expect(resumedDuration > 3.4 && resumedDuration < 4.6, "resumed file should hold about 4 s")

// 2. Stopping while paused still finalises a usable file.
let (stopped, stoppedURL) = try makeRecorder("notchtalk_pause_stop.m4a")
stopped.record()
Thread.sleep(forTimeInterval: 2)
stopped.pause()
Thread.sleep(forTimeInterval: 2)
stopped.stop()
let stoppedDuration = duration(of: stoppedURL)
print(String(format: "stop while paused: %.2f s of audio from 4.00 s of wall clock", stoppedDuration))
expect(stoppedDuration > 1.4 && stoppedDuration < 2.6, "file stopped while paused should hold about 2 s")

print("PASS: paused time stays out of the audio")
