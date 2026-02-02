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
        panel.level = .screenSaver
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
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

    private func updatePosition() {
        guard let panel else { return }

        let screen = screenWithNotch() ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }

        let screenFrame = screen.frame
        let panelWidth: CGFloat = 400
        let panelHeight: CGFloat = 80

        let notchInfo = notchGeometry(for: screen)

        let x = screenFrame.minX + notchInfo.centerX - panelWidth / 2
        let y = screenFrame.maxY - notchInfo.topInset - panelHeight + 6

        panel.setFrame(NSRect(x: x, y: y, width: panelWidth, height: panelHeight), display: true)
    }

    private func screenWithNotch() -> NSScreen? {
        for screen in NSScreen.screens {
            if screen.safeAreaInsets.top > 0 {
                return screen
            }
        }
        return nil
    }

    private func notchGeometry(for screen: NSScreen) -> (centerX: CGFloat, topInset: CGFloat, notchWidth: CGFloat) {
        let hasNotch = screen.safeAreaInsets.top > 0
        let screenWidth = screen.frame.width

        if hasNotch {
            let topInset = screen.safeAreaInsets.top

            if let leftArea = screen.auxiliaryTopLeftArea,
               let rightArea = screen.auxiliaryTopRightArea {
                let notchLeft = leftArea.maxX
                let notchRight = rightArea.minX
                let notchWidth = notchRight - notchLeft
                let notchCenterX = notchLeft + notchWidth / 2
                return (notchCenterX, topInset, notchWidth)
            }

            return (screenWidth / 2, topInset, 200)
        }

        let menuBarHeight: CGFloat = NSApp.mainMenu?.menuBarHeight ?? 24
        return (screenWidth / 2, menuBarHeight, 0)
    }
}
