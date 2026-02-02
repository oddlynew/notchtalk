//
//  SoundManager.swift
//  notchtalk
//

import AppKit

@MainActor
final class SoundManager {
    static let shared = SoundManager()

    private init() {}

    func playStartSound() {
        NSSound.beep()
    }

    func playStopSound() {
        Task {
            try? await Task.sleep(for: .milliseconds(50))
            NSSound.beep()
        }
    }

    func playErrorSound() {
        NSSound.beep()
    }
}
