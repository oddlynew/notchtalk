//
//  ClipboardService.swift
//  notchtalk
//

import AppKit
import Carbon

enum ClipboardService {
    private static let transientMarkerType = NSPasteboard.PasteboardType("com.notchtalk.transientPasteToken")

    private struct PasteboardSnapshot {
        struct Item {
            let representations: [(type: NSPasteboard.PasteboardType, data: Data)]
        }

        let items: [Item]

        static func capture(from pasteboard: NSPasteboard) -> PasteboardSnapshot {
            let capturedItems: [Item] = (pasteboard.pasteboardItems ?? []).map { item in
                var representations: [(type: NSPasteboard.PasteboardType, data: Data)] = []
                for type in item.types {
                    if let data = item.data(forType: type) {
                        representations.append((type: type, data: data))
                        continue
                    }
                    if let string = item.string(forType: type), let data = string.data(using: .utf8) {
                        representations.append((type: type, data: data))
                    }
                }
                return Item(representations: representations)
            }
            return PasteboardSnapshot(items: capturedItems)
        }

        func restore(to pasteboard: NSPasteboard) {
            pasteboard.clearContents()

            guard !items.isEmpty else {
                return
            }

            let restoredItems: [NSPasteboardItem] = items.map { snapshotItem in
                let item = NSPasteboardItem()
                for representation in snapshotItem.representations {
                    _ = item.setData(representation.data, forType: representation.type)
                }
                return item
            }
            _ = pasteboard.writeObjects(restoredItems)
        }
    }

    @MainActor
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @MainActor
    static func copyAndPaste(_ text: String) {
        pastePreservingClipboard(text)
    }

    @MainActor
    static func pastePreservingClipboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        let snapshot = PasteboardSnapshot.capture(from: pasteboard)
        let token = UUID().uuidString

        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setString(token, forType: transientMarkerType)

        pasteboard.clearContents()
        pasteboard.writeObjects([item])

        // Wait for the pasteboard to update, then simulate Cmd+V, then restore the user's clipboard.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            simulatePaste()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                // Avoid clobbering the user's clipboard if it changed after we set our transient value.
                if pasteboardContainsTransientToken(token, in: pasteboard) {
                    snapshot.restore(to: pasteboard)
                }
            }
        }
    }

    private static func pasteboardContainsTransientToken(_ token: String, in pasteboard: NSPasteboard) -> Bool {
        guard let items = pasteboard.pasteboardItems else {
            return false
        }
        return items.contains { item in
            item.string(forType: transientMarkerType) == token
        }
    }

    private static func simulatePaste() {
        // Key code for 'V' is 9
        let vKeyCode: CGKeyCode = 9

        // Create key down event with Command modifier
        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: vKeyCode, keyDown: true) else { return }
        keyDown.flags = .maskCommand

        // Create key up event with Command modifier
        guard let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: vKeyCode, keyDown: false) else { return }
        keyUp.flags = .maskCommand

        // Post the events
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}
