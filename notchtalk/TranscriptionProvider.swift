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
    case phonon2 = "phonon-2"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAI:
            return "OpenAI"
        case .elevenLabs:
            return "ElevenLabs"
        case .parakeet, .phonon2:
            return localModel!.name
        }
    }

    var apiKeyAccount: String {
        switch self {
        case .openAI:
            return "openai-api-key"
        case .elevenLabs:
            return "elevenlabs-api-key"
        case .parakeet, .phonon2:
            return "\(rawValue)-unused"
        }
    }

    /// The one model this provider always uses, or nil when it varies per run (OpenAI falls back to a smaller one).
    nonisolated var fixedModel: String? {
        switch self {
        case .openAI: nil
        case .elevenLabs: ElevenLabsTranscriptionService.model
        case .parakeet, .phonon2: localModel!.modelID
        }
    }

    /// The model that transcribes on this Mac, or nil for a cloud provider.
    nonisolated var localModel: LocalModel? {
        switch self {
        case .openAI, .elevenLabs: nil
        case .parakeet: .parakeet
        case .phonon2: .phonon2
        }
    }

    /// A recording can go out: the provider's key is saved, or its model is installed on this Mac.
    nonisolated var isReady: Bool {
        localModel?.isInstalled ?? KeychainService.hasAPIKey(for: self)
    }

    nonisolated var notReadyMessage: String {
        localModel.map { "Install \($0.name)" } ?? "No API key"
    }
}
