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
    var startHoldDelay: Double {
        didSet { UserDefaults.standard.set(startHoldDelay, forKey: "startHoldDelay") }
    }
    var finishHoldDelay: Double {
        didSet { UserDefaults.standard.set(finishHoldDelay, forKey: "finishHoldDelay") }
    }
    var sendWithEnter: Bool {
        didSet { UserDefaults.standard.set(sendWithEnter, forKey: "sendWithEnter") }
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
    var elevenLabsSpeakerLibraryRecognitionEnabled: Bool {
        didSet {
            UserDefaults.standard.set(
                elevenLabsSpeakerLibraryRecognitionEnabled,
                forKey: "elevenLabsSpeakerLibraryRecognitionEnabled"
            )
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
        let defaults = UserDefaults.standard
        self.startHoldDelay = min(2, max(0.2, defaults.object(forKey: "startHoldDelay") as? Double ?? 0.8))
        self.finishHoldDelay = min(2, max(0.2, defaults.object(forKey: "finishHoldDelay") as? Double ?? 0.8))
        self.sendWithEnter = defaults.object(forKey: "sendWithEnter") as? Bool
            ?? (defaults.bool(forKey: "submitAfterContinuous") || defaults.bool(forKey: "submitAfterHold"))
        defaults.removeObject(forKey: "submitAfterContinuous")
        defaults.removeObject(forKey: "submitAfterHold")
        self.autoPasteEnabled = UserDefaults.standard.bool(forKey: "autoPasteEnabled")
        self.elevenLabsSpeakerRecognitionEnabled = UserDefaults.standard.bool(forKey: "elevenLabsSpeakerRecognitionEnabled")
        self.elevenLabsSpeakerLibraryRecognitionEnabled = UserDefaults.standard.bool(
            forKey: "elevenLabsSpeakerLibraryRecognitionEnabled"
        )
        self.hasOpenAIAPIKey = KeychainService.hasAPIKey(for: .openAI)
        self.hasElevenLabsAPIKey = KeychainService.hasAPIKey(for: .elevenLabs)
        defaults.set(self.sendWithEnter, forKey: "sendWithEnter")
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
