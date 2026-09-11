//
//  KeychainService.swift
//  notchtalk
//

import Foundation
import Security

enum KeychainService: Sendable {
    private nonisolated static let serviceName = "oddlynew.notchtalk"

    private nonisolated static func call(_ request: KeychainRequest) -> KeychainResponse {
        guard let url = Bundle.main.url(forAuxiliaryExecutable: "NotchTalkKeychain") else {
            return KeychainResponse(status: errSecNotAvailable)
        }
        do {
            try KeychainPeer.validateHelper(at: url)
            let process = Process()
            process.executableURL = url
            let input = Pipe(), output = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            defer {
                try? input.fileHandleForWriting.close()
                try? output.fileHandleForReading.close()
                if process.isRunning { process.terminate() }
            }
            try input.fileHandleForWriting.write(contentsOf: JSONEncoder().encode(request))
            try input.fileHandleForWriting.close()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return KeychainResponse(status: errSecNotAvailable) }
            return try JSONDecoder().decode(KeychainResponse.self, from: data)
        } catch {
            return KeychainResponse(status: errSecNotAvailable)
        }
    }

    nonisolated static func saveAPIKey(_ apiKey: String, for provider: TranscriptionProvider = .openAI) throws {
        let response = call(KeychainRequest(operation: "save", account: provider.apiKeyAccount,
                                           value: Data(apiKey.utf8), allowInteraction: true))
        guard response.status == errSecSuccess else { throw KeychainError.saveFailed(response.status) }
    }

    nonisolated static func getAPIKey(for provider: TranscriptionProvider = .openAI) -> String? {
        let response = call(KeychainRequest(operation: "read", account: provider.apiKeyAccount, allowInteraction: true))
        guard response.status == errSecSuccess, let data = response.value else { return nil }
        return String(data: data, encoding: .utf8)
    }

    nonisolated static func deleteAPIKey(for provider: TranscriptionProvider = .openAI) throws {
        let response = call(KeychainRequest(operation: "delete", account: provider.apiKeyAccount, allowInteraction: true))
        guard response.status == errSecSuccess else { throw KeychainError.deleteFailed(response.status) }
    }

    nonisolated static var hasAPIKey: Bool { hasAPIKey(for: .openAI) }

    nonisolated static func hasAPIKey(for provider: TranscriptionProvider) -> Bool {
        // Startup/settings need existence only, never decrypted data or a password prompt.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: provider.apiKeyAccount,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

}

enum KeychainError: LocalizedError {
    case saveFailed(OSStatus)
    case deleteFailed(OSStatus)

    var errorDescription: String? {
        switch self {
        case .saveFailed(let status):
            return "Failed to save to Keychain: \(status)"
        case .deleteFailed(let status):
            return "Failed to delete from Keychain: \(status)"
        }
    }
}
