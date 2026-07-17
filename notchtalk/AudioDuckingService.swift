//
//  AudioDuckingService.swift
//  notchtalk
//

import CoreAudio
import Foundation

@MainActor
final class AudioDuckingService {
    static let shared = AudioDuckingService()

    private struct VolumeSnapshot {
        let deviceID: AudioObjectID
        let element: AudioObjectPropertyElement
        let originalVolume: Float32
        let duckedVolume: Float32
    }

    private var snapshots: [VolumeSnapshot] = []

    private init() {}

    func beginDucking() {
        guard snapshots.isEmpty,
              let deviceID = defaultOutputDeviceID() else {
            return
        }

        let controls = volumeControls(for: deviceID)
        guard !controls.isEmpty else {
            return
        }

        snapshots = controls.compactMap { element in
            guard let originalVolume = readVolume(deviceID: deviceID, element: element) else {
                return nil
            }

            let duckedVolume = targetVolume(for: originalVolume)
            guard duckedVolume < originalVolume else {
                return nil
            }

            guard setVolume(duckedVolume, deviceID: deviceID, element: element) else {
                return nil
            }

            return VolumeSnapshot(
                deviceID: deviceID,
                element: element,
                originalVolume: originalVolume,
                duckedVolume: duckedVolume
            )
        }
    }

    func endDucking() {
        defer {
            snapshots = []
        }

        for snapshot in snapshots {
            guard let currentVolume = readVolume(deviceID: snapshot.deviceID, element: snapshot.element) else {
                continue
            }

            // If the user changed volume while recording, keep their explicit choice.
            guard abs(currentVolume - snapshot.duckedVolume) <= 0.03 else {
                continue
            }

            _ = setVolume(snapshot.originalVolume, deviceID: snapshot.deviceID, element: snapshot.element)
        }
    }

    private func defaultOutputDeviceID() -> AudioObjectID? {
        var deviceID = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            &size,
            &deviceID
        )

        guard status == noErr, deviceID != kAudioObjectUnknown else {
            return nil
        }

        return deviceID
    }

    private func volumeControls(for deviceID: AudioObjectID) -> [AudioObjectPropertyElement] {
        if isVolumeSettable(deviceID: deviceID, element: kAudioObjectPropertyElementMain) {
            return [kAudioObjectPropertyElementMain]
        }

        return [1, 2].filter { element in
            isVolumeSettable(deviceID: deviceID, element: element)
        }
    }

    private func isVolumeSettable(deviceID: AudioObjectID, element: AudioObjectPropertyElement) -> Bool {
        var address = volumeAddress(element: element)

        guard AudioObjectHasProperty(deviceID, &address) else {
            return false
        }

        var isSettable = DarwinBoolean(false)
        let status = AudioObjectIsPropertySettable(deviceID, &address, &isSettable)
        return status == noErr && isSettable.boolValue
    }

    private func readVolume(deviceID: AudioObjectID, element: AudioObjectPropertyElement) -> Float32? {
        var address = volumeAddress(element: element)
        var volume: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)

        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &volume)
        guard status == noErr else {
            return nil
        }

        return min(1, max(0, volume))
    }

    private func setVolume(
        _ volume: Float32,
        deviceID: AudioObjectID,
        element: AudioObjectPropertyElement
    ) -> Bool {
        var address = volumeAddress(element: element)
        var volume = min(1, max(0, volume))
        let size = UInt32(MemoryLayout<Float32>.size)

        let status = AudioObjectSetPropertyData(deviceID, &address, 0, nil, size, &volume)
        return status == noErr
    }

    private func targetVolume(for originalVolume: Float32) -> Float32 {
        guard originalVolume > 0.12 else {
            return originalVolume
        }

        return max(0.05, originalVolume * 0.35)
    }

    private func volumeAddress(element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyVolumeScalar,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: element
        )
    }
}
