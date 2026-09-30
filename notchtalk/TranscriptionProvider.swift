//
//  TranscriptionProvider.swift
//  notchtalk
//

import Foundation

enum TranscriptionProvider: String, CaseIterable, Codable, Identifiable, Sendable {
    case openAI
    case elevenLabs
    // The raw value is from the first test build; saved settings and history already hold it.
    case parakeet = "phonon"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAI:
            return "OpenAI"
        case .elevenLabs:
            return "ElevenLabs"
        case .parakeet:
            return "Parakeet"
        }
    }

    var apiKeyAccount: String {
        switch self {
        case .openAI:
            return "openai-api-key"
        case .elevenLabs:
            return "elevenlabs-api-key"
        case .parakeet:
            return "parakeet-unused"
        }
    }

    /// A recording can go out: the provider's key is saved, or Parakeet is installed on this Mac.
    nonisolated var isReady: Bool {
        self == .parakeet ? ParakeetTranscriptionService.isInstalled : KeychainService.hasAPIKey(for: self)
    }

    nonisolated var notReadyMessage: String {
        self == .parakeet ? "Install Parakeet" : "No API key"
    }
}
