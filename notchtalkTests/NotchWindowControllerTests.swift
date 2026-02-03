import AppKit
import Testing
@testable import notchtalk

@MainActor
struct NotchWindowControllerTests {
    @Test("setup is idempotent")
    func setupIsIdempotent() {
        let stateManager = NotchStateManager()
        let controller = NotchWindowController(stateManager: stateManager)

        controller.setup()
        let firstPanelIdentifier = controller.panelIdentifierForTesting

        #expect(firstPanelIdentifier != nil)
        #expect(controller.hasScreenParametersObserverForTesting)

        controller.setup()

        #expect(controller.panelIdentifierForTesting == firstPanelIdentifier)
        #expect(controller.hasScreenParametersObserverForTesting)
    }

    @Test("setup called twice still installs one screen observer")
    func setupCalledTwiceStillInstallsOneScreenObserver() async throws {
        let stateManager = NotchStateManager()
        let controller = NotchWindowController(stateManager: stateManager)

        controller.setup()
        controller.setup()

        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        try await Task.sleep(for: .milliseconds(50))

        #expect(controller.screenParametersNotificationCountForTesting == 1)
    }
}
