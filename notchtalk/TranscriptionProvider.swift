//
//  TranscriptionProvider.swift
//  notchtalk
//

import Foundation

enum TranscriptionProvider: String, CaseIterable, Codable, Identifiable, Sendable {
    case openAI
    case elevenLabs

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openAI:
            return "OpenAI"
        case .elevenLabs:
            return "ElevenLabs"
        }
    }

    var apiKeyAccount: String {
        switch self {
        case .openAI:
            return "openai-api-key"
        case .elevenLabs:
            return "elevenlabs-api-key"
        }
    }
}
