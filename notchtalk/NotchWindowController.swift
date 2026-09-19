//
//  NotchWindowController.swift
//  notchtalk
//

import Cocoa
import SwiftUI

@MainActor
final class NotchWindowController {
    private var panel: NSPanel?
    private var screenParametersObserver: NSObjectProtocol?
    private let stateManager: NotchStateManager
#if DEBUG
    private(set) var screenParametersNotificationCountForTesting = 0
#endif

    init(stateManager: NotchStateManager) {
        self.stateManager = stateManager
    }

    deinit {
        if let screenParametersObserver {
            NotificationCenter.default.removeObserver(screenParametersObserver)
        }
    }

    func setup() {
        guard panel == nil else {
            updatePosition()
            return
        }

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.panelWidth, height: Self.panelHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        // Clicks are taken only while the pill actually offers a button.
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none

        let hostingView = NSHostingView(rootView: NotchView(stateManager: stateManager))
        hostingView.frame = panel.contentView?.bounds ?? .zero
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView

        self.panel = panel

        screenParametersObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
#if DEBUG
                self?.screenParametersNotificationCountForTesting += 1
#endif
                self?.updatePosition()
            }
        }
    }

    /// A panel that takes clicks also blocks them, so it only does that when a button is there.
    func setInteractive(_ interactive: Bool) {
        panel?.ignoresMouseEvents = !interactive
    }

    func show() {
        updatePosition()
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    // The panel takes clicks for the pause button, so it hugs the widest pill (260 pt)
    // and keeps only enough margin for its shadow. Anything wider would swallow
    // clicks meant for whatever sits behind it.
    private static let panelWidth: CGFloat = 276
    private static let panelHeight: CGFloat = 48

    private func updatePosition() {
        guard let panel else { return }

        // Use the main screen (the one with keyboard focus) or fall back to first screen
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }

        let panelWidth = Self.panelWidth
        let panelHeight = Self.panelHeight

        // Prefer the camera-notch center when available; fall back to screen center.
        let centerX = notchCenterX(for: screen)

        // Position near the bottom with a subtle inset from screen edge.
        let bottomMargin: CGFloat = 10
        let bottomY = screen.frame.minY + screen.safeAreaInsets.bottom + bottomMargin

        let frame = NSRect(x: centerX - panelWidth / 2, y: bottomY, width: panelWidth, height: panelHeight)
        let alignedFrame = screen.backingAlignedRect(
            frame,
            options: [.alignMinXNearest, .alignMinYNearest, .alignWidthNearest, .alignHeightNearest]
        )
        panel.setFrame(alignedFrame, display: true)
    }

    private func notchCenterX(for screen: NSScreen) -> CGFloat {
        guard
            let leftArea = screen.auxiliaryTopLeftArea,
            let rightArea = screen.auxiliaryTopRightArea,
            !leftArea.isEmpty,
            !rightArea.isEmpty
        else {
            return screen.frame.midX
        }

        return (leftArea.maxX + rightArea.minX) / 2
    }
}

#if DEBUG
extension NotchWindowController {
    var panelIdentifierForTesting: ObjectIdentifier? {
        panel.map(ObjectIdentifier.init)
    }

    var hasScreenParametersObserverForTesting: Bool {
        screenParametersObserver != nil
    }
}
#endif
