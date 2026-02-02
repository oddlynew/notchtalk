//
//  ClipboardService.swift
//  notchtalk
//

import AppKit

enum ClipboardService {
    @MainActor
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
