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
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 80),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = false

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
            guard let self else { return }
            Task { @MainActor [weak self] in
                self?.updatePosition()
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
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

    func updateVisibility() {
        if stateManager.state == .idle {
            hide()
        } else {
            show()
        }
    }

    private func updatePosition() {
        guard let panel = panel else { return }

        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let screenFrame = screen?.frame,
              let visibleFrame = screen?.visibleFrame else { return }

        let panelWidth: CGFloat = 400
        let panelHeight: CGFloat = 80

        let menuBarHeight = screenFrame.height - visibleFrame.height - visibleFrame.origin.y + screenFrame.origin.y
        let notchOffset: CGFloat = 8

        let x = screenFrame.midX - panelWidth / 2
        let y = screenFrame.maxY - menuBarHeight - panelHeight + notchOffset

        panel.setFrame(NSRect(x: x, y: y, width: panelWidth, height: panelHeight), display: true)
    }
}
