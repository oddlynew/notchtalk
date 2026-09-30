//
//  TranscriptionProvider.swift
//  notchtalk
//

import Foundation

enum TranscriptionProvider: String, CaseIterable, Codable, Identifiable, Sendable {
    case openAI
    case elevenLabs
    case phonon

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAI:
            return "OpenAI"
        case .elevenLabs:
            return "ElevenLabs"
        case .phonon:
            return "Phonon-2"
        }
    }

    var apiKeyAccount: String {
        switch self {
        case .openAI:
            return "openai-api-key"
        case .elevenLabs:
            return "elevenlabs-api-key"
        case .phonon:
            return "phonon-unused"
        }
    }

    /// A recording can go out: the provider's key is saved, or Phonon-2 is installed on this Mac.
    nonisolated var isReady: Bool {
        self == .phonon ? PhononTranscriptionService.isInstalled : KeychainService.hasAPIKey(for: self)
    }

    nonisolated var notReadyMessage: String {
        self == .phonon ? "Install Phonon-2" : "No API key"
    }
}
