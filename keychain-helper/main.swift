import Foundation
import Security

// This executable is reused byte-for-byte on ordinary app updates. It runs only
// for a credential operation, accepts only our signed parent, and then exits.
func execute(_ request: KeychainRequest) -> KeychainResponse {
    guard ["openai-api-key", "elevenlabs-api-key"].contains(request.account),
          ["read", "save", "delete"].contains(request.operation) else {
        return KeychainResponse(status: errSecParam)
    }
    guard SecKeychainSetUserInteractionAllowed(request.allowInteraction) == errSecSuccess else {
        return KeychainResponse(status: errSecInteractionNotAllowed)
    }
    var query: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "oddlynew.notchtalk",
        kSecAttrAccount as String: request.account
    ]
#if KEYCHAIN_BRIDGE_TEST
    // Test builds exclusively target a disposable, non-default keychain.
    guard let path = ProcessInfo.processInfo.environment["NOTCHTALK_TEST_KEYCHAIN"] else {
        return KeychainResponse(status: errSecParam)
    }
    var keychain: SecKeychain?
    guard SecKeychainOpen(path, &keychain) == errSecSuccess, let keychain else {
        return KeychainResponse(status: errSecNoSuchKeychain)
    }
    query[kSecUseKeychain as String] = keychain
    query[kSecMatchSearchList as String] = [keychain]
#endif
    switch request.operation {
    case "read":
        query[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return KeychainResponse(status: status, value: status == errSecSuccess ? result as? Data : nil)
    case "save":
        guard let value = request.value, !value.isEmpty, value.count <= 16_384 else {
            return KeychainResponse(status: errSecParam)
        }
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: value] as CFDictionary)
        if status != errSecItemNotFound { return KeychainResponse(status: status) }
        query.removeValue(forKey: kSecMatchSearchList as String)
        query[kSecValueData as String] = value
        return KeychainResponse(status: SecItemAdd(query as CFDictionary, nil))
    default:
        let status = SecItemDelete(query as CFDictionary)
        return KeychainResponse(status: status == errSecItemNotFound ? errSecSuccess : status)
    }
}

// Disable legacy file-based Keychain UI process-wide before any Keychain query.
SecKeychainSetUserInteractionAllowed(false)
do {
    try KeychainPeer.validateParent()
    var data = Data()
    while let chunk = try FileHandle.standardInput.read(upToCount: 4_096), !chunk.isEmpty {
        data.append(chunk)
        guard data.count <= 32_768 else { exit(2) }
    }
    let request = try JSONDecoder().decode(KeychainRequest.self, from: data)
    let response = execute(request)
    try FileHandle.standardOutput.write(contentsOf: JSONEncoder().encode(response))
} catch {
    // No keys, request payloads, or error descriptions reach stdout/stderr.
    exit(1)
}
