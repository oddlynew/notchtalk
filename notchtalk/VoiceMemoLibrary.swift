//
//  VoiceMemoLibrary.swift
//  notchtalk
//

import Foundation
import SQLite3
import SwiftUI

struct VoiceMemo: Identifiable, Equatable {
    var id: String { url.lastPathComponent }
    let url: URL
    let title: String
    let date: Date
    let duration: TimeInterval?
}

/// Lists the recordings of Apple's Voice Memos app (synced from the iPhone via iCloud) and
/// remembers which ones Notchtalk transcribed. Apple's files are only read, never written.
@MainActor
@Observable
final class VoiceMemoLibrary {
    static let shared = VoiceMemoLibrary()

    /// NOTCHTALK_VOICE_MEMOS_FOLDER points a verification run at a fixture instead of Daniel's memos.
    static let folder = ProcessInfo.processInfo.environment["NOTCHTALK_VOICE_MEMOS_FOLDER"].flatMap { $0.isEmpty ? nil : $0 }.map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings", isDirectory: true)
    private static let transcribedKey = "transcribedVoiceMemos"
    private static let labelPrefix = "Voice memo: "

    private(set) var memos: [VoiceMemo] = []
    /// False when macOS privacy blocks the folder; Full Disk Access for Notchtalk lifts it.
    private(set) var accessDenied = false
    @ObservationIgnored private var folderWatch: DispatchSourceFileSystemObject?
    private(set) var transcribed = Set(UserDefaults.standard.stringArray(forKey: VoiceMemoLibrary.transcribedKey) ?? [])

    var open: [VoiceMemo] {
        memos.filter { !transcribed.contains($0.id) }
    }

    /// Called on every success of a re-transcription (this tab, a History retry, the notch's retry),
    /// so a memo stays done after History trims or clears the entry.
    func rememberTranscribed(_ entryID: UUID) {
        guard let entry = TranscriptionDiagnosticsStore.shared.entries.first(where: { $0.id == entryID }),
              entry.status == .succeeded,
              entry.label?.hasPrefix(Self.labelPrefix) == true,
              !transcribed.contains(entry.sourceAudioFilename) else { return }
        transcribed.insert(entry.sourceAudioFilename)
        UserDefaults.standard.set(Array(transcribed), forKey: Self.transcribedKey)
    }

    func reload() {
        let files: [URL]
        do {
            files = try FileManager.default.contentsOfDirectory(
                at: Self.folder,
                includingPropertiesForKeys: [.creationDateKey]
            ).filter { $0.pathExtension.lowercased() == "m4a" }
        } catch {
            accessDenied = (error as NSError).code != NSFileReadNoSuchFileError
            memos = []
            return
        }
        accessDenied = false
        watchFolder()
        // Files without a row (unreadable database, or iCloud still syncing it) are listed by date.
        let metadata = Self.readMetadata()
        memos = files.compactMap { url in
            let row = metadata?[url.lastPathComponent]
            if row?.deleted == true { return nil }
            let date = row?.date ?? (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
            return VoiceMemo(
                url: url,
                title: row?.title ?? date.formatted(date: .abbreviated, time: .shortened),
                date: date,
                duration: row?.duration
            )
        }
        .sorted { $0.date > $1.date }
    }

    /// Reloads when iCloud adds or removes a recording while Notchtalk stays in front.
    private func watchFolder() {
        guard folderWatch == nil else { return }
        let fd = Darwin.open(Self.folder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.reload() } }
        source.setCancelHandler { close(fd) }
        source.resume()
        folderWatch = source
    }

    /// Transcribes like ambient recall: a History entry that owns a copy of the audio, then the
    /// shared re-transcribe path. The transcript lands in History and on the clipboard, never pasted.
    func transcribe(_ memo: VoiceMemo) {
        let notch = NotchStateManager.shared
        guard notch.state != .recording, notch.state != .processing else { return }
        let store = TranscriptionDiagnosticsStore.shared
        let provider = SettingsManager.shared.transcriptionProvider
        let id = store.startTranscription(
            audioURL: memo.url,
            prompt: nil,
            provider: provider,
            speakerRecognitionEnabled: provider == .elevenLabs
                && SettingsManager.shared.elevenLabsSpeakerRecognitionEnabled,
            label: Self.labelPrefix + memo.title
        )
        // retainAudio moves its source, so it gets a copy (an APFS clone) and Apple's file stays put.
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("notchtalk_voicememo_\(id.uuidString).m4a")
        do {
            try FileManager.default.copyItem(at: memo.url, to: copy)
        } catch {
            store.markFailed(for: id, message: "Could not read the voice memo: \(error.localizedDescription)")
            return
        }
        guard store.retainAudio(sourceURL: copy, for: id) != nil else {
            try? FileManager.default.removeItem(at: copy)
            store.markFailed(for: id, message: "Could not keep a copy of the voice memo")
            return
        }
        notch.retranscribe(
            diagnosticsID: id,
            audioDuration: memo.duration,
            reason: "Voice memo \(memo.id)",
            allowPaste: false
        )
    }

    /// Title, date, duration and whether it sits in Recently Deleted, per recording filename, from
    /// Voice Memos' database. Reads a private copy (with its write-ahead log) so SQLite
    /// never touches Apple's files; nil when unreadable.
    private static func readMetadata() -> [String: (title: String?, date: Date, duration: TimeInterval?, deleted: Bool)]? {
        let fileManager = FileManager.default
        let copy = fileManager.temporaryDirectory.appendingPathComponent("notchtalk_voicememos_\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: copy) }
        do {
            try fileManager.createDirectory(at: copy, withIntermediateDirectories: true)
            for suffix in ["", "-wal", "-shm"] {
                let source = folder.appendingPathComponent("CloudRecordings.db\(suffix)")
                if fileManager.fileExists(atPath: source.path) {
                    try fileManager.copyItem(at: source, to: copy.appendingPathComponent("CloudRecordings.db\(suffix)"))
                }
            }
        } catch {
            return nil
        }

        var db: OpaquePointer?
        defer { sqlite3_close(db) }
        guard sqlite3_open_v2(copy.appendingPathComponent("CloudRecordings.db").path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK else {
            return nil
        }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        // ZENCRYPTEDTITLE holds the plain title the app shows; ZDATE counts seconds since 2001.
        let sql = "SELECT ZPATH, NULLIF(ZENCRYPTEDTITLE, ''), ZDATE, ZDURATION, ZEVICTIONDATE IS NOT NULL FROM ZCLOUDRECORDING"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        var rows: [String: (title: String?, date: Date, duration: TimeInterval?, deleted: Bool)] = [:]
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            defer { result = sqlite3_step(statement) }
            guard let path = sqlite3_column_text(statement, 0) else { continue }
            let title = sqlite3_column_text(statement, 1).map { String(cString: $0) }
            let date = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 2))
            let duration = sqlite3_column_type(statement, 3) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 3)
            rows[URL(fileURLWithPath: String(cString: path)).lastPathComponent] = (title, date, duration, sqlite3_column_int(statement, 4) != 0)
        }
        // A read that stops early would show deleted memos with wrong titles; list by file instead.
        return result == SQLITE_DONE ? rows : nil
    }
}

@MainActor
struct VoiceMemosView: View {
    private var library = VoiceMemoLibrary.shared
    private var diagnosticsStore = TranscriptionDiagnosticsStore.shared
    private var notch = NotchStateManager.shared

    var body: some View {
        Group {
            if library.accessDenied {
                ContentUnavailableView {
                    Label("Notchtalk can't see your voice memos", systemImage: "lock")
                } description: {
                    Text("macOS protects the Voice Memos folder. In System Settings, open Privacy & Security, then Full Disk Access, and turn on notchtalk. Then quit and reopen Notchtalk.")
                } actions: {
                    Button("Open Full Disk Access") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
                    }
                    Button("Try again") { library.reload() }
                }
            } else if library.open.isEmpty {
                ContentUnavailableView(
                    library.memos.isEmpty ? "No voice memos yet" : "All voice memos transcribed",
                    systemImage: library.memos.isEmpty ? "waveform" : "checkmark.circle",
                    description: Text("New recordings from your iPhone appear here once iCloud has synced them.")
                )
            } else {
                List(library.open) { memo in
                    row(memo)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onAppear { library.reload() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in library.reload() }
    }

    private func row(_ memo: VoiceMemo) -> some View {
        let latest = diagnosticsStore.entries.first { $0.sourceAudioFilename == memo.id }
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(memo.title).font(.headline).lineLimit(1)
                HStack(spacing: 10) {
                    Text(memo.date, format: .dateTime.day().month().year().hour().minute())
                    if let duration = memo.duration {
                        Text(Duration.seconds(duration), format: .time(pattern: duration >= 3600 ? .hourMinuteSecond : .minuteSecond))
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                if latest?.status == .failed, let error = latest?.errorMessage {
                    Text(error).font(.caption).foregroundStyle(.red).lineLimit(1)
                }
            }
            Spacer()
            // A pending entry that is not the running transcription was cut off by a quit; offer it again.
            if let latest, notch.state == .processing, notch.activeDiagnosticsID == latest.id {
                ProgressView().controlSize(.small)
            } else {
                Button("Transcribe") { library.transcribe(memo) }
                    .disabled(notch.state == .recording || notch.state == .processing || !SettingsManager.shared.hasAPIKey)
            }
        }
        .padding(.vertical, 4)
    }
}
