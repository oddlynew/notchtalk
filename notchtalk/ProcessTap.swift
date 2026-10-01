//
//  ProcessTap.swift
//  notchtalk
//

import AVFoundation
import CoreAudio
import Foundation

/// A Core Audio process tap (macOS 14.2) read through a private aggregate device.
/// The Command Line Tools SDK this app builds with predates the tap API, so its pieces are looked up at run time.
final class ProcessTap {
    struct AudioProcess {
        let id: AudioObjectID
        let bundleID: String
        let readsMicrophone: Bool
    }

    private typealias CreateTap = @convention(c) (UnsafeMutableRawPointer, UnsafeMutablePointer<AudioObjectID>) -> OSStatus
    private typealias DestroyTap = @convention(c) (AudioObjectID) -> OSStatus
    private static let createTap = symbol("AudioHardwareCreateProcessTap", as: CreateTap.self)
    private static let destroyTap = symbol("AudioHardwareDestroyProcessTap", as: DestroyTap.self)

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var deviceID = AudioObjectID(kAudioObjectUnknown)
    private var ioProc: AudioDeviceIOProcID?
    private let queue = DispatchQueue(label: "oddlynew.notchtalk.calltap")

    /// `deliver` gets the processes' sound as 16 kHz mono samples, on a background queue.
    init(processes: [AudioObjectID], deliver: @escaping ([Int16]) -> Void) throws {
        tapID = try Self.makeTap(processes: processes, exclusive: false)
        do {
            try startDevice(deliver: deliver)
        } catch {
            stop()
            throw error
        }
    }

    /// Creating a tap is what asks for the system audio permission. Without it a tap still works but hears silence.
    static func requestPermission() {
        guard let tap = try? makeTap(processes: [], exclusive: true) else { return }
        _ = destroyTap?(tap)
    }

    func stop() {
        let (tapID, deviceID, ioProc) = (tapID, deviceID, ioProc)
        self.tapID = AudioObjectID(kAudioObjectUnknown)
        self.deviceID = AudioObjectID(kAudioObjectUnknown)
        self.ioProc = nil
        // Core Audio can deadlock when the device is destroyed right after it stops, so this waits a moment, off the main thread.
        DispatchQueue.global().async {
            if let ioProc {
                AudioDeviceStop(deviceID, ioProc)
                usleep(150_000)
                AudioDeviceDestroyIOProcID(deviceID, ioProc)
            }
            if deviceID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(deviceID) }
            if tapID != kAudioObjectUnknown { _ = Self.destroyTap?(tapID) }
        }
    }

    static func audioProcesses() -> [AudioProcess] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = address(fourCC("prs#"))
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.map { id in
            var bundleAddress = Self.address(fourCC("pbid"))
            var bundleID: Unmanaged<CFString>?
            var bundleSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            let bundleStatus = withUnsafeMutablePointer(to: &bundleID) {
                AudioObjectGetPropertyData(id, &bundleAddress, 0, nil, &bundleSize, $0)
            }
            var inputAddress = Self.address(fourCC("piri"))
            var input: UInt32 = 0
            var inputSize = UInt32(MemoryLayout<UInt32>.size)
            AudioObjectGetPropertyData(id, &inputAddress, 0, nil, &inputSize, &input)
            return AudioProcess(
                id: id,
                bundleID: bundleStatus == noErr ? (bundleID?.takeRetainedValue() as String?) ?? "" : "",
                readsMicrophone: input != 0
            )
        }
    }

    private static func makeTap(processes: [AudioObjectID], exclusive: Bool) throws -> AudioObjectID {
        guard let createTap, let type = NSClassFromString("CATapDescription") as? NSObject.Type else {
            throw CocoaError(.featureUnsupported)
        }
        let description = type.init()
        description.setValue(processes.map { NSNumber(value: $0) }, forKey: "processes")
        description.setValue(exclusive, forKey: "exclusive")
        description.setValue(true, forKey: "mixdown")
        description.setValue(true, forKey: "mono")
        description.setValue(true, forKey: "private")
        description.setValue("Notchtalk call", forKey: "name")
        var tap = AudioObjectID(kAudioObjectUnknown)
        let status = createTap(Unmanaged.passUnretained(description).toOpaque(), &tap)
        guard status == noErr, tap != kAudioObjectUnknown else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        return tap
    }

    private func startDevice(deliver: @escaping ([Int16]) -> Void) throws {
        var tapUIDAddress = Self.address(Self.fourCC("tuid"))
        var tapUID: Unmanaged<CFString>?
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var formatAddress = Self.address(Self.fourCC("tfmt"))
        var description = AudioStreamBasicDescription()
        var formatSize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard withUnsafeMutablePointer(to: &tapUID, { AudioObjectGetPropertyData(tapID, &tapUIDAddress, 0, nil, &uidSize, $0) }) == noErr,
              let tapUID = tapUID?.takeRetainedValue() as String?,
              AudioObjectGetPropertyData(tapID, &formatAddress, 0, nil, &formatSize, &description) == noErr,
              let format = AVAudioFormat(streamDescription: &description),
              let convert = AmbientRecorder.makeConverter(from: format),
              let outputUID = Self.defaultOutputUID() else {
            throw CocoaError(.fileReadUnknown)
        }
        // The tap only runs on a clock, and the output device it plays to gives it one.
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Notchtalk call",
            kAudioAggregateDeviceUIDKey: "oddlynew.notchtalk.call.\(UUID().uuidString)",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            "tapautostart": true,
            "taps": [["uid": tapUID, "drift": true]]
        ]
        var status = AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &deviceID)
        guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        status = AudioDeviceCreateIOProcIDWithBlock(&ioProc, deviceID, queue) { _, inputData, _, _, _ in
            // The tap's buffer comes after any input streams of the output device.
            let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inputData))
            guard let tapBuffer = buffers.last, tapBuffer.mData != nil else { return }
            var list = AudioBufferList(mNumberBuffers: 1, mBuffers: tapBuffer)
            guard let pcm = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: &list, deallocator: nil),
                  let samples = convert(pcm) else { return }
            deliver(samples)
        }
        guard status == noErr, let ioProc else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        status = AudioDeviceStart(deviceID, ioProc)
        guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    private static func defaultOutputUID() -> String? {
        var address = address(kAudioHardwarePropertyDefaultOutputDevice)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return nil }
        var uidAddress = Self.address(kAudioDevicePropertyDeviceUID)
        var uid: Unmanaged<CFString>?
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &uid) { AudioObjectGetPropertyData(device, &uidAddress, 0, nil, &uidSize, $0) }
        return status == noErr ? uid?.takeRetainedValue() as String? : nil
    }

    private static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private static func fourCC(_ code: String) -> AudioObjectPropertySelector {
        code.utf8.reduce(0) { $0 << 8 | AudioObjectPropertySelector($1) }
    }

    private static func symbol<T>(_ name: String, as type: T.Type) -> T? {
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), name).map { unsafeBitCast($0, to: type) }
    }
}
