//
//  AudioFileTranscription.swift
//  notchtalk
//

import AppKit
import AVFoundation
import Foundation
import SwiftUI
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
        copyWhenDone: Bool = false,
        prepare: (URL) async throws -> Void
    ) async -> UUID {
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
        // Kept before anything else can fail: a call recording exists nowhere else, so History can retry it.
        guard store.retainAudio(sourceURL: copy, for: id) != nil else {
            return fail("Could not keep a copy of the audio")
        }
        TranscriptionQueue.shared.transcribe(id, audioDuration: duration, reason: reason, copyWhenDone: copyWhenDone)
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

    /// Writes `first` followed by `second` as one .m4a. Returns the length of `first`.
    static func join(_ first: URL, _ second: URL, to destination: URL) async throws -> TimeInterval {
        let composition = AVMutableComposition()
        guard let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw CocoaError(.fileWriteUnknown)
        }
        var cursor = CMTime.zero
        var firstDuration = CMTime.zero
        for url in [first, second] {
            let asset = AVURLAsset(url: url)
            guard let source = try await asset.loadTracks(withMediaType: .audio).first else { throw CocoaError(.fileReadCorruptFile) }
            let duration = try await asset.load(.duration)
            try track.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: source, at: cursor)
            if url == first { firstDuration = duration }
            cursor = cursor + duration
        }
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw CocoaError(.fileWriteUnknown)
        }
        export.outputURL = destination
        export.outputFileType = .m4a
        await export.export()
        if let error = export.error { throw error }
        guard export.status == .completed else { throw CocoaError(.fileWriteUnknown) }
        return firstDuration.seconds
    }

    /// The files behind dropped items. A Finder file comes as its URL. Voice Memos, Mail or Safari
    /// only promise a file, so its audio is copied to a temporary file first, which the system
    /// deletes in time.
    nonisolated static func droppedFiles(_ providers: [NSItemProvider]) async -> [URL] {
        var urls: [URL] = []
        for provider in providers {
            if let url = await fileURL(of: provider) {
                urls.append(url)
            } else if let url = await promisedFile(of: provider) {
                urls.append(url)
            }
        }
        return urls
    }

    private nonisolated static func fileURL(of provider: NSItemProvider) async -> URL? {
        guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else { return nil }
        return await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                let url = (item as? URL) ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                continuation.resume(returning: url.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil })
            }
        }
    }

    private nonisolated static func promisedFile(of provider: NSItemProvider) async -> URL? {
        guard let type = provider.registeredTypeIdentifiers.first(where: { UTType($0)?.conforms(to: .audiovisualContent) == true }) else { return nil }
        return await withCheckedContinuation { continuation in
            // The file only lives while this handler runs.
            provider.loadFileRepresentation(forTypeIdentifier: type) { file, _ in
                guard let file else { return continuation.resume(returning: nil) }
                let copy = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                    .appendingPathComponent(provider.suggestedName.map { $0.hasSuffix(".\(file.pathExtension)") ? $0 : "\($0).\(file.pathExtension)" } ?? file.lastPathComponent)
                do {
                    try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try FileManager.default.copyItem(at: file, to: copy)
                    continuation.resume(returning: copy)
                } catch {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    nonisolated static func isAudioOrVideo(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .audiovisualContent) == true
    }
}

/// A file dropped on or chosen in the app window, and what became of it.
@MainActor
@Observable
final class FileDrop {
    static let shared = FileDrop()

    enum Status: Equatable {
        case idle
        case reading(String)
        case transcribing(String)
        case done(String)
        case failed(String)
    }

    /// A file hovers over the drop zone.
    var hovering = false
    /// Counts drops.
    private(set) var attempts = 0
    private var name = ""
    private var reading = false
    private var entryID: UUID?
    private var rejection: String?
    /// How the dropped file's own run ended, kept apart from later retries of its History entry.
    private var outcome: Status?

    var status: Status {
        if let rejection { return .failed(rejection) }
        if reading { return .reading(name) }
        return run
    }

    /// The dropped file's own run, also while a rejection covers it.
    var run: Status { outcome ?? entry.map(status(of:)) ?? .idle }

    private var entry: TranscriptionDiagnosticsEntry? {
        entryID.flatMap { id in TranscriptionDiagnosticsStore.shared.entries.first { $0.id == id } }
    }

    private func status(of entry: TranscriptionDiagnosticsEntry) -> Status {
        switch entry.status {
        case .recording, .pending: return .transcribing(name)
        case .succeeded: return .done(name)
        case .cancelled: return .idle
        // History keeps the details; the drop zone says it in plain words.
        case .failed: return .failed("Couldn't transcribe \(name). Details are in History.")
        }
    }

    /// A drop is still being read. Transcribing runs in the queue and blocks nothing.
    var isBusy: Bool { reading }

    /// Takes the first dropped file. Returns false when nothing was started.
    @discardableResult
    func transcribe(_ urls: [URL]) -> Bool {
        hovering = false
        attempts += 1
        rejection = nil
        guard let url = urls.first else { return reject("Couldn't read the dropped file. Try Choose File… instead.") }
        guard urls.count == 1 else { return reject("Drop one file at a time.") }
        guard AudioFileTranscription.isAudioOrVideo(url) else {
            return reject("\(url.lastPathComponent) has no sound to transcribe. Try an audio or video file.")
        }
        guard !isBusy else { return reject("Still reading the last file. Drop again in a moment.") }
        name = url.lastPathComponent
        entryID = nil
        outcome = nil
        reading = true
        Task {
            let duration = try? await AVURLAsset(url: url).load(.duration).seconds
            entryID = await AudioFileTranscription.run(
                source: url,
                label: "File: \(url.lastPathComponent)",
                reason: "Dropped file \(url.lastPathComponent)",
                duration: duration.flatMap { $0.isFinite ? $0 : nil },
                copyWhenDone: true
            ) { try await AudioFileTranscription.exportAudio(of: url, to: $0) }
            reading = false
        }
        return true
    }

    /// Stops following the History entry once its run ends, so a retry from History, which may
    /// paste instead of copy, is not reported as this drop.
    func freeze() {
        guard let entry, entry.status != .recording, entry.status != .pending else { return }
        outcome = status(of: entry)
        entryID = nil
    }

    /// Forgets the shown rejection, or else the shown result. A run behind a rejection shows next.
    func settle() {
        if rejection != nil { rejection = nil } else { outcome = nil }
    }

    private func reject(_ message: String) -> Bool {
        rejection = message
        return false
    }
}


/// The drop zone in the app window: takes one audio or video file dragged onto it or chosen in an
/// open panel, then shows how it fares until a few seconds after the result.
@MainActor
struct FileDropZone: View {
    private let drop = FileDrop.shared
    private let manager = NotchStateManager.shared
    @State private var choosing = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 12) {
            icon.font(.system(size: 20)).frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(message).font(.system(size: 13, weight: .semibold)).foregroundStyle(NotchtalkStyle.ink)
                    .lineLimit(2).truncationMode(.middle)
                if drop.status == .idle && !drop.hovering {
                    Text("m4a, mp3, wav, mp4, mov and more. The transcript lands here and on the clipboard.")
                        .font(.system(size: 11)).foregroundStyle(NotchtalkStyle.muted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button("Choose file…") { choosing = true }.buttonStyle(QuietButtonStyle())
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(NotchtalkStyle.accent.opacity(drop.hovering ? 0.10 : 0.03), in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(drop.hovering ? NotchtalkStyle.accent : NotchtalkStyle.ink.opacity(0.18), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
        }
        .onDrop(of: [.fileURL, .audiovisualContent], isTargeted: Binding { drop.hovering } set: { drop.hovering = $0 }) { providers in
            Task { drop.transcribe(await AudioFileTranscription.droppedFiles(providers)) }
            return true
        }
        .fileImporter(isPresented: $choosing, allowedContentTypes: [.audiovisualContent]) { result in
            if case .success(let url) = result { drop.transcribe([url]) }
        }
        // A retry from History, which may paste instead of copy, is not this drop.
        .onChange(of: drop.run, initial: true) { drop.freeze() }
        .task(id: drop.status) {
            switch drop.status {
            case .done, .failed:
                try? await Task.sleep(for: .seconds(4))
                if !Task.isCancelled { drop.settle() }
            default: break
            }
        }
    }

    @ViewBuilder private var icon: some View {
        if drop.hovering {
            Image(systemName: "arrow.down.doc.fill").foregroundStyle(NotchtalkStyle.accent)
        } else {
            switch drop.status {
            case .reading, .transcribing:
                if reduceMotion {
                    Image(systemName: "hourglass").foregroundStyle(NotchtalkStyle.accent)
                } else {
                    ProgressView().controlSize(.small)
                }
            case .done: Image(systemName: "doc.on.clipboard").foregroundStyle(NotchtalkStyle.accent)
            case .failed: Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
            case .idle: Image(systemName: "arrow.down.doc").foregroundStyle(NotchtalkStyle.accent)
            }
        }
    }

    private var message: String {
        if drop.hovering { return drop.isBusy ? "Busy, drop again in a moment" : "Drop to transcribe" }
        switch drop.status {
        case .idle: return "Drop an audio or video file"
        case .reading(let name): return "Reading \(name)"
        case .transcribing(let name): return "\(manager.processingStatusText) \(name)"
        case .done(let name): return "Transcript of \(name) copied"
        case .failed(let message): return message
        }
    }
}
