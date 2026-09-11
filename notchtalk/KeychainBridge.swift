import Foundation
import Security
import CryptoKit

// Shared, deliberately small wire contract. Secrets only travel through private pipes.
struct KeychainRequest: Codable {
    let operation: String
    let account: String
    var value: Data? = nil
    var allowInteraction: Bool = false
}

struct KeychainResponse: Codable {
    let status: OSStatus
    var value: Data? = nil
}

enum KeychainPeer {
    static let appIdentifier = "oddlynew.notchtalk"
    static let helperIdentifier = "oddlynew.notchtalk.keychain"

    static func requirement(identifier: String) throws -> SecRequirement {
        var code: SecCode?
        var info: CFDictionary?
        var staticCode: SecStaticCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let info = info as? [String: Any],
              let certificates = info[kSecCodeInfoCertificates as String] as? [SecCertificate],
              let certificate = certificates.first else { throw PeerError.invalidSignature }
        let hash = Insecure.SHA1.hash(data: SecCertificateCopyData(certificate) as Data)
            .map { String(format: "%02x", $0) }.joined()
        var requirement: SecRequirement?
        let text = "identifier \"\(identifier)\" and certificate leaf = H\"\(hash)\""
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
              let requirement else { throw PeerError.invalidSignature }
        return requirement
    }

    static func validateHelper(at url: URL) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
              let code,
              SecStaticCodeCheckValidity(code, [], try requirement(identifier: helperIdentifier)) == errSecSuccess
        else { throw PeerError.invalidSignature }
    }

    static func validateParent() throws {
        let parent = getppid()
        guard parent > 1 else { throw PeerError.invalidSignature }
        var code: SecCode?
        let attributes = [kSecGuestAttributePid as String: parent] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess,
              let code,
              SecCodeCheckValidity(code, [], try requirement(identifier: appIdentifier)) == errSecSuccess,
              getppid() == parent else { throw PeerError.invalidSignature }
    }

    enum PeerError: Error { case invalidSignature }
}
