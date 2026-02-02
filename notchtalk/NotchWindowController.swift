//
//  NotchWindowController.swift
//  notchtalk
//

import Cocoa
import SwiftUI

@MainActor
final class NotchWindowController {
    private var panel: NSPanel?
    private let stateManager: NotchStateManager

    init(stateManager: NotchStateManager) {
        self.stateManager = stateManager
    }

    func setup() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 60),
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
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none

        let hostingView = NSHostingView(rootView: NotchView(stateManager: stateManager))
        hostingView.frame = panel.contentView?.bounds ?? .zero
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView

        self.panel = panel

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updatePosition()
            }
        }
    }

    func show() {
        updatePosition()
        panel?.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private func updatePosition() {
        guard let panel else { return }

        // Use the main screen (the one with keyboard focus) or fall back to first screen
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }

        let panelWidth: CGFloat = 300
        let panelHeight: CGFloat = 60

        // Prefer the camera-notch center when available; fall back to screen center.
        let centerX = notchCenterX(for: screen)

        // Position at top of screen, below menu bar/notch area
        let topY = screen.frame.maxY - screen.safeAreaInsets.top - panelHeight

        let frame = NSRect(x: centerX - panelWidth / 2, y: topY, width: panelWidth, height: panelHeight)
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
