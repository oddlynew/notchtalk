//
//  SettingsManager.swift
//  notchtalk
//

import SwiftUI

@MainActor
@Observable
final class SettingsManager {
    static let shared = SettingsManager()

    private(set) var hasOpenAIAPIKey: Bool = false
    private(set) var hasElevenLabsAPIKey: Bool = false
    var transcriptionProvider: TranscriptionProvider {
        didSet {
            UserDefaults.standard.set(transcriptionProvider.rawValue, forKey: "transcriptionProvider")
        }
    }
    var transcriptionPrompt: String {
        didSet {
            UserDefaults.standard.set(transcriptionPrompt, forKey: "transcriptionPrompt")
        }
    }
    var autoPasteEnabled: Bool {
        didSet {
            UserDefaults.standard.set(autoPasteEnabled, forKey: "autoPasteEnabled")
        }
    }
    var elevenLabsSpeakerRecognitionEnabled: Bool {
        didSet {
            UserDefaults.standard.set(elevenLabsSpeakerRecognitionEnabled, forKey: "elevenLabsSpeakerRecognitionEnabled")
        }
    }

    var hasAPIKey: Bool {
        hasAPIKey(for: transcriptionProvider)
    }

    private init() {
        let savedProvider = UserDefaults.standard.string(forKey: "transcriptionProvider")
            .flatMap(TranscriptionProvider.init(rawValue:))
        self.transcriptionProvider = savedProvider ?? .openAI
        self.transcriptionPrompt = UserDefaults.standard.string(forKey: "transcriptionPrompt") ?? ""
        self.autoPasteEnabled = UserDefaults.standard.bool(forKey: "autoPasteEnabled")
        self.elevenLabsSpeakerRecognitionEnabled = UserDefaults.standard.bool(forKey: "elevenLabsSpeakerRecognitionEnabled")
        self.hasOpenAIAPIKey = KeychainService.hasAPIKey(for: .openAI)
        self.hasElevenLabsAPIKey = KeychainService.hasAPIKey(for: .elevenLabs)
    }

    func hasAPIKey(for provider: TranscriptionProvider) -> Bool {
        switch provider {
        case .openAI:
            return hasOpenAIAPIKey
        case .elevenLabs:
            return hasElevenLabsAPIKey
        }
    }

    func saveAPIKey(_ apiKey: String, for provider: TranscriptionProvider? = nil) throws {
        let provider = provider ?? transcriptionProvider
        try KeychainService.saveAPIKey(apiKey, for: provider)
        setHasAPIKey(true, for: provider)
    }

    func deleteAPIKey(for provider: TranscriptionProvider? = nil) throws {
        let provider = provider ?? transcriptionProvider
        try KeychainService.deleteAPIKey(for: provider)
        setHasAPIKey(false, for: provider)
    }

    private func setHasAPIKey(_ hasKey: Bool, for provider: TranscriptionProvider) {
        switch provider {
        case .openAI:
            hasOpenAIAPIKey = hasKey
        case .elevenLabs:
            hasElevenLabsAPIKey = hasKey
        }
    }
}
