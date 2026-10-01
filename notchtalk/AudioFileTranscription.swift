//
//  AudioFileTranscription.swift
//  notchtalk
//

import AppKit
import AVFoundation
import Foundation
import UniformTypeIdentifiers

/// Transcribes an audio file like ambient recall: a History entry that owns a copy of the audio,
/// then the shared re-transcribe path with the selected provider. Voice memos and dropped files
/// both come through here. The transcript lands in History and on the clipboard, never pasted.
@MainActor
enum AudioFileTranscription {
    /// `prepare` writes the audio to send as .m4a at the URL it gets. Returns the History entry.
    @discardableResult
    static func run(
        source: URL,
        label: String,
        reason: String,
        duration: TimeInterval?,
        prepare: (URL) async throws -> Void
    ) async -> UUID {
        let notch = NotchStateManager.shared
        let store = TranscriptionDiagnosticsStore.shared
        // retainAudio moves its source, so it gets a copy and the original file stays put.
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("notchtalk_file_\(UUID().uuidString).m4a")
        var readError: Error?
        do {
            try await prepare(copy)
        } catch {
            readError = error
        }
        // The entry starts only now, so it records the provider that sends and a quit during
        // the export leaves nothing pending.
        let provider = SettingsManager.shared.transcriptionProvider
        let id = store.startTranscription(
            audioURL: source,
            prompt: nil,
            provider: provider,
            speakerRecognitionEnabled: provider == .elevenLabs
                && SettingsManager.shared.elevenLabsSpeakerRecognitionEnabled,
            label: label
        )
        func fail(_ message: String) -> UUID {
            try? FileManager.default.removeItem(at: copy)
            store.markFailed(for: id, message: message)
            return id
        }
        if let readError {
            return fail("Could not read the audio: \(readError.localizedDescription)")
        }
        guard notch.state != .recording, notch.state != .processing else {
            return fail("Notchtalk was busy with another recording; transcribe the file again")
        }
        // The notch's own missing-key path would leave this entry pending.
        guard provider.isReady else {
            return fail(provider.localModel != nil ? provider.notReadyMessage : "No API key for \(provider.displayName)")
        }
        guard store.retainAudio(sourceURL: copy, for: id) != nil else {
            return fail("Could not keep a copy of the audio")
        }
        notch.retranscribe(diagnosticsID: id, audioDuration: duration, reason: reason, allowPaste: false)
        return id
    }

    /// Writes the sound of any file AVFoundation plays (m4a, mp3, wav, aiff, a video's audio track)
    /// as .m4a, the format every provider takes and the recorder writes. m4a is copied as it is.
    static func exportAudio(of source: URL, to destination: URL) async throws {
        switch source.pathExtension.lowercased() {
        case "m4a":
            return try FileManager.default.copyItem(at: source, to: destination)
        case "qta":
            // A Spatial Audio voice memo dragged out of Finder goes the way the Voice Memos list sends it.
            return try await VoiceMemoLibrary.exportStereoTrack(of: source, to: destination)
        default:
            break
        }
        let asset = AVURLAsset(url: source)
        guard try await !asset.loadTracks(withMediaType: .audio).isEmpty else {
            throw CocoaError(.fileReadCorruptFile)
        }
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw CocoaError(.fileWriteUnknown)
        }
        export.outputURL = destination
        export.outputFileType = .m4a
        await export.export()
        if let error = export.error { throw error }
        guard export.status == .completed else { throw CocoaError(.fileWriteUnknown) }
    }

    nonisolated static func isAudioOrVideo(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .audiovisualContent) == true
    }
}

/// A file dropped on the Latest transcript card or the menu bar icon, and what became of it.
@MainActor
@Observable
final class FileDrop {
    static let shared = FileDrop()

    enum Status: Equatable {
        case idle
        case reading(String)
        case transcribing(String)
        case failed(String)
    }

    /// Set by the menu panel; the menu bar icon opens it only when it is closed.
    var menuOpen = false
    private var name = ""
    private var reading = false
    private var entryID: UUID?
    private var rejection: String?

    var status: Status {
        if let rejection { return .failed(rejection) }
        if reading { return .reading(name) }
        guard let entryID, let entry = TranscriptionDiagnosticsStore.shared.entries.first(where: { $0.id == entryID }) else {
            return .idle
        }
        switch entry.status {
        case .recording, .pending: return .transcribing(name)
        case .succeeded, .cancelled: return .idle
        // History keeps the details; the menu says it in plain words.
        case .failed: return .failed("Couldn't transcribe \(name). Details are in History.")
        }
    }

    var isBusy: Bool {
        let notch = NotchStateManager.shared.state
        return reading || !VoiceMemoLibrary.shared.preparing.isEmpty || notch == .recording || notch == .processing
    }

    /// Takes the first dropped file. Returns false when nothing was started.
    @discardableResult
    func transcribe(_ urls: [URL]) -> Bool {
        rejection = nil
        guard let url = urls.first else { return false }
        guard urls.count == 1 else { return reject("Drop one file at a time.") }
        guard AudioFileTranscription.isAudioOrVideo(url) else {
            return reject("\(url.lastPathComponent) has no sound to transcribe. Try an audio or video file.")
        }
        guard !isBusy else { return reject("Notchtalk is busy. Drop the file again when it's done.") }
        name = url.lastPathComponent
        entryID = nil
        reading = true
        Task {
            let duration = try? await AVURLAsset(url: url).load(.duration).seconds
            entryID = await AudioFileTranscription.run(
                source: url,
                label: "File: \(url.lastPathComponent)",
                reason: "Dropped file \(url.lastPathComponent)",
                duration: duration.flatMap { $0.isFinite ? $0 : nil }
            ) { try await AudioFileTranscription.exportAudio(of: url, to: $0) }
            reading = false
        }
        return true
    }

    private func reject(_ message: String) -> Bool {
        rejection = message
        return false
    }
}

/// Spring loading for the menu bar icon: dragging a file onto it opens the panel, so the file can
/// land on Latest transcript; dropping right on the icon transcribes it as well.
@MainActor
final class StatusItemDropTarget: NSObject, NSWindowDelegate, NSDraggingDestination {
    static let shared = StatusItemDropTarget()
    private weak var window: NSWindow?

    /// The status window appears only after launch finishes, so this looks for it a few times.
    func install() {
        Task {
            for _ in 0..<50 where window == nil {
                // MenuBarExtra keeps its status item in an NSStatusBarWindow that has no delegate of its own.
                if let window = NSApp.windows.first(where: { $0.className == "NSStatusBarWindow" }) {
                    guard window.delegate == nil else { return }
                    window.registerForDraggedTypes([.fileURL])
                    window.delegate = self
                    self.window = window
                    return
                }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if !FileDrop.shared.menuOpen, let button = window?.contentView?.firstButton {
            button.performClick(nil)
        }
        return .copy
    }

    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return FileDrop.shared.transcribe(urls)
    }
}

private extension NSView {
    var firstButton: NSButton? {
        self as? NSButton ?? subviews.lazy.compactMap(\.firstButton).first
    }
}
