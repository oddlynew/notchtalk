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

/// A file dropped on the notch, and what became of it.
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

    /// A file hovers over the notch.
    var hovering = false
    /// Counts drops, so the notch shows the same rejection again for a second drop.
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
        // History keeps the details; the notch says it in plain words.
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
        hovering = false
        attempts += 1
        rejection = nil
        guard let url = urls.first else { return false }
        guard urls.count == 1 else { return reject("Drop one file at a time.") }
        guard AudioFileTranscription.isAudioOrVideo(url) else {
            return reject("\(url.lastPathComponent) has no sound to transcribe. Try an audio or video file.")
        }
        guard !isBusy else { return reject("Notchtalk is busy. Drop the file again when it's done.") }
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
                duration: duration.flatMap { $0.isFinite ? $0 : nil }
            ) { try await AudioFileTranscription.exportAudio(of: url, to: $0) }
            reading = false
        }
        return true
    }

    func transcribe(_ sender: NSDraggingInfo) -> Bool {
        transcribe(sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? [])
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

/// The notch takes a file dragged from anywhere, with no window to keep open: on every screen a
/// clear window the size of the notch waits above the menu bar, or a short strip at its middle on
/// a screen without a notch. The one under the file opens into a drop zone and then shows how the
/// file fares until a few seconds after the result. The menu bar icon takes no drop: on macOS 26
/// its status window never receives drag events.
@MainActor
@Observable
final class NotchDropTarget {
    static let shared = NotchDropTarget()

    private(set) var isOpen = false
    /// The frame of the screen whose notch opens.
    private(set) var activeScreen: CGRect = .zero
    @ObservationIgnored private var panels: [(screen: NSScreen, panel: NSPanel)] = []
    @ObservationIgnored private var screenObserver: NSObjectProtocol?
    @ObservationIgnored private var shown: (status: FileDrop.Status, attempts: Int) = (.idle, 0)
    @ObservationIgnored private var showsResult = false
    @ObservationIgnored private var resultTask: Task<Void, Never>?
    @ObservationIgnored private var closeTask: Task<Void, Never>?
    /// Set while the left button is down, the only time a file can be dragged.
    @ObservationIgnored private var takesMouse = false

    private static let openSize = CGSize(width: 360, height: 84)

    func install() {
        makePanels()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor [weak self] in self?.makePanels() } }
        // The windows let clicks through to the menu bar until a drag may have started in another app.
        NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { _ in
            Task { @MainActor in NotchDropTarget.shared.mouseDragged() }
        }
        observe()
    }

    private func mouseDragged() {
        guard !takesMouse else { return }
        setTakesMouse(true)
        Task {
            // A short poll, so a click right after the release already reaches the menu bar.
            while NSEvent.pressedMouseButtons & 1 != 0 { try? await Task.sleep(for: .milliseconds(30)) }
            setTakesMouse(false)
        }
    }

    private func setTakesMouse(_ takes: Bool) {
        takesMouse = takes
        panels.forEach { $0.panel.ignoresMouseEvents = !takes }
    }

    /// A file hovers over the notch of this screen.
    func hover(on screen: NSScreen?) {
        if let screen { activeScreen = screen.frame }
        FileDrop.shared.hovering = true
    }

    private func makePanels() {
        panels.forEach { $0.panel.close() }
        panels = NSScreen.screens.map { screen in
            let notch = Self.notch(of: screen)
            let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isFloatingPanel = true
            panel.isReleasedWhenClosed = false
            // Above the menu bar, which sits at .mainMenu.
            panel.level = .statusBar
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.hidesOnDeactivate = false
            panel.animationBehavior = .none
            panel.ignoresMouseEvents = !takesMouse
            let container = NotchDropView.Container(frame: .zero)
            let hosting = NSHostingView(rootView: NotchDropView(target: self, screen: screen.frame, notchHeight: notch.height))
            hosting.autoresizingMask = [.width, .height]
            container.addSubview(hosting)
            panel.contentView = container
            panel.orderFrontRegardless()
            return (screen, panel)
        }
        if !panels.contains(where: { $0.screen.frame == activeScreen }) {
            activeScreen = (NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main)?.frame ?? .zero
        }
        place()
    }

    private func observe() {
        let drop = FileDrop.shared
        withObservationTracking { _ = (drop.status, drop.run, drop.hovering, drop.attempts, activeScreen) } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observe() }
        }
        update()
    }

    private func update() {
        let drop = FileDrop.shared
        drop.freeze()
        let status = drop.status
        if status != shown.status || drop.attempts != shown.attempts {
            shown = (status, drop.attempts)
            resultTask?.cancel()
            switch status {
            case .done, .failed:
                showsResult = true
                resultTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(4))
                    guard !Task.isCancelled, let self else { return }
                    showsResult = false
                    FileDrop.shared.settle()
                    update()
                }
            default:
                showsResult = false
            }
        }
        let working = switch status {
        case .reading, .transcribing: true
        default: false
        }
        setOpen(drop.hovering || working || showsResult)
    }

    private func setOpen(_ open: Bool) {
        if open {
            closeTask?.cancel()
            if !isOpen { isOpen = true }
            place()
        } else if isOpen {
            isOpen = false
            // The window shrinks after the closing animation, which it would cut off.
            closeTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled else { return }
                self?.place()
            }
        }
    }

    private func place() {
        for (screen, panel) in panels {
            let notch = Self.notch(of: screen)
            let size = isOpen && screen.frame == activeScreen
                ? CGSize(width: max(Self.openSize.width, notch.width), height: notch.height + Self.openSize.height)
                : notch.size
            panel.setFrame(NSRect(x: notch.midX - size.width / 2, y: screen.frame.maxY - size.height, width: size.width, height: size.height), display: true)
        }
    }

    /// The notch, or a short strip at the top middle of a screen without one.
    private static func notch(of screen: NSScreen) -> NSRect {
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea, !left.isEmpty, !right.isEmpty {
            return NSRect(x: left.maxX, y: 0, width: right.minX - left.maxX, height: screen.safeAreaInsets.top)
        }
        // ponytail: the strip covers the middle of the menu bar, where status items rarely reach.
        return NSRect(x: screen.frame.midX - 90, y: 0, width: 180, height: NSStatusBar.system.thickness)
    }
}

/// The drop zone that hangs from the notch, and the status of the dropped file.
@MainActor
struct NotchDropView: View {
    let target: NotchDropTarget
    let screen: CGRect
    let notchHeight: CGFloat
    private let drop = FileDrop.shared
    private let manager = NotchStateManager.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isOpen: Bool { target.isOpen && target.activeScreen == screen }

    var body: some View {
        // The window server sends drags through fully clear pixels, so the waiting window and the
        // hovered zone keep a trace of color. Around a shown result the window stays fully clear.
        Color.black.opacity(!isOpen || drop.hovering ? 0.01 : 0)
            .overlay(alignment: .top) {
                if isOpen {
                    box.transition(reduceMotion ? .opacity : .scale(scale: 0.5, anchor: .top).combined(with: .opacity))
                }
            }
            .animation(reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.3, bounce: 0.2), value: isOpen)
    }

    private var box: some View {
        let shape = UnevenRoundedRectangle(bottomLeadingRadius: 22, bottomTrailingRadius: 22)
        return HStack(spacing: 10) {
            icon.font(.system(size: 18)).frame(width: 22)
            Text(message).font(.system(size: 12, weight: .medium)).lineLimit(2).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 22).padding(.top, notchHeight + 12).padding(.bottom, 16)
        .background(.black, in: shape)
        .overlay {
            if drop.hovering {
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(NotchtalkStyle.accent, style: StrokeStyle(lineWidth: 1.5, dash: [6, 4]))
                    .padding(.top, notchHeight + 4).padding([.horizontal, .bottom], 8)
            }
        }
        .accessibilityElement(children: .combine)
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
            case .done: Image(systemName: "doc.on.clipboard").foregroundStyle(Color(red: 0.64, green: 0.86, blue: 0.72))
            case .failed: Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
            case .idle: Image(systemName: "arrow.down.doc").foregroundStyle(NotchtalkStyle.accent)
            }
        }
    }

    private var message: String {
        if drop.hovering { return drop.isBusy ? "Busy, drop again in a moment" : "Drop to transcribe" }
        switch drop.status {
        case .idle: return "Drop to transcribe"
        case .reading(let name): return "Reading \(name)"
        case .transcribing(let name): return "\(manager.processingStatusText) \(name)"
        case .done(let name): return "Transcript of \(name) copied"
        case .failed(let message): return message
        }
    }

    final class Container: NSView {
        override init(frame: NSRect) {
            super.init(frame: frame)
            registerForDraggedTypes([.fileURL])
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
            NotchDropTarget.shared.hover(on: window?.screen)
            return .copy
        }

        override func draggingExited(_ sender: NSDraggingInfo?) { FileDrop.shared.hovering = false }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool { FileDrop.shared.transcribe(sender) }
    }
}
