import Foundation
import Security

@main struct Client {
    static func main() throws {
        SecKeychainSetUserInteractionAllowed(false)
        let args = CommandLine.arguments
        let path = args[2]
        let helper = URL(fileURLWithPath: args[3])
        let command = args[1]
        if command == "setup" {
            let password = "disposable-nonsecret-fixture"
            var keychain: SecKeychain?
            var originalList: CFArray?
            guard SecKeychainCopySearchList(&originalList) == 0 else { exit(2) }
            let status = password.withCString { SecKeychainCreate(path, UInt32(password.utf8.count), $0, false, nil, &keychain) }
            if let originalList { SecKeychainSetSearchList(originalList) }
            guard status == 0 else { print("fixture-create", status); exit(2) }
        }
        if command == "cleanup" {
            var keychain: SecKeychain?
            guard SecKeychainOpen(path, &keychain) == 0, let keychain else { exit(2) }
            let status = SecKeychainDelete(keychain)
            guard status == 0 else { print("fixture-delete", status); exit(2) }
            print("PASS: fixture removed")
            return
        }
        let request = KeychainRequest(operation: command == "setup" ? "save" : "read",
                                      account: "openai-api-key", value: command == "setup" ? Data("nonsecret-fixture".utf8) : nil)
        try KeychainPeer.validateHelper(at: helper)
        let child = Process()
        child.executableURL = helper
        child.environment = ["NOTCHTALK_TEST_KEYCHAIN": path]
        let input = Pipe(), output = Pipe()
        child.standardInput = input
        child.standardOutput = output
        child.standardError = FileHandle.nullDevice
        try child.run()
        try input.fileHandleForWriting.write(contentsOf: JSONEncoder().encode(request))
        try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        child.waitUntilExit()
        if command == "denied" {
            guard child.terminationStatus != 0 && data.isEmpty else { fatalError("untrusted client accepted") }
            print("PASS: wrong client identity denied")
            return
        }
        guard child.terminationStatus == 0 else { print("helper rejected client"); exit(2) }
        let response = try JSONDecoder().decode(KeychainResponse.self, from: data)
        guard response.status == 0 else { print("keychain status", response.status); exit(2) }
        if command != "setup" { guard response.value == Data("nonsecret-fixture".utf8) else { exit(2) } }
#if SECOND_BUILD
        print("PASS: changed app binary reads through unchanged helper without UI")
#else
        print("PASS: first app build")
#endif
    }
}
