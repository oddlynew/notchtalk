//
//  SettingsManager.swift
//  notchtalk
//

import SwiftUI

@MainActor
@Observable
final class SettingsManager {
    static let shared = SettingsManager()

    var hasAPIKey: Bool = false
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
    var retainFailedRecordingsEnabled: Bool {
        didSet {
            UserDefaults.standard.set(retainFailedRecordingsEnabled, forKey: "retainFailedRecordingsEnabled")
        }
    }

    private init() {
        self.transcriptionPrompt = UserDefaults.standard.string(forKey: "transcriptionPrompt") ?? ""
        self.autoPasteEnabled = UserDefaults.standard.bool(forKey: "autoPasteEnabled")
        self.retainFailedRecordingsEnabled = (UserDefaults.standard.object(forKey: "retainFailedRecordingsEnabled") as? Bool) ?? true
        self.hasAPIKey = KeychainService.hasAPIKey
    }

    func saveAPIKey(_ apiKey: String) throws {
        try KeychainService.saveAPIKey(apiKey)
        hasAPIKey = true
    }

    func deleteAPIKey() throws {
        try KeychainService.deleteAPIKey()
        hasAPIKey = false
    }
}
