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
    static let folder = ProcessInfo.processInfo.environment["NOTCHTALK_VOICE_MEMOS_FOLDER"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers/group.com.apple.VoiceMemos.shared/Recordings", isDirectory: true)
    private static let transcribedKey = "transcribedVoiceMemos"

    private(set) var memos: [VoiceMemo] = []
    /// False when macOS privacy blocks the folder; Full Disk Access for Notchtalk lifts it.
    private(set) var accessDenied = false
    private(set) var transcribed = Set(UserDefaults.standard.stringArray(forKey: VoiceMemoLibrary.transcribedKey) ?? [])

    var open: [VoiceMemo] { memos.filter { !transcribed.contains($0.id) } }

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
        // Without a readable database every file is listed; with it, Recently Deleted drops out.
        let metadata = Self.readMetadata()
        memos = files.compactMap { url in
            let row = metadata?[url.lastPathComponent]
            if metadata != nil, row == nil { return nil }
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

    func markTranscribed(_ memo: VoiceMemo) {
        transcribed.insert(memo.id)
        UserDefaults.standard.set(Array(transcribed), forKey: Self.transcribedKey)
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
            label: "Voice memo: \(memo.title)"
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
            allowPaste: false,
            onSuccess: { [weak self] in self?.markTranscribed(memo) }
        )
    }

    /// Title, date and duration per recording filename from Voice Memos' database, without the
    /// recordings in Recently Deleted. Reads a private copy (with its write-ahead log) so SQLite
    /// never touches Apple's files; nil when unreadable.
    private static func readMetadata() -> [String: (title: String?, date: Date, duration: TimeInterval?)]? {
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
        let sql = "SELECT ZPATH, NULLIF(ZENCRYPTEDTITLE, ''), ZDATE, ZDURATION FROM ZCLOUDRECORDING WHERE ZEVICTIONDATE IS NULL"
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            return nil
        }
        var rows: [String: (title: String?, date: Date, duration: TimeInterval?)] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let path = sqlite3_column_text(statement, 0) else { continue }
            let title = sqlite3_column_text(statement, 1).map { String(cString: $0) }
            let date = Date(timeIntervalSinceReferenceDate: sqlite3_column_double(statement, 2))
            let duration = sqlite3_column_type(statement, 3) == SQLITE_NULL ? nil : sqlite3_column_double(statement, 3)
            rows[URL(fileURLWithPath: String(cString: path)).lastPathComponent] = (title, date, duration)
        }
        return rows
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
                    "All voice memos transcribed",
                    systemImage: "checkmark.circle",
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
            if latest?.status == .pending {
                ProgressView().controlSize(.small)
            } else {
                Button("Transcribe") { library.transcribe(memo) }
                    .disabled(notch.state == .recording || notch.state == .processing || !SettingsManager.shared.hasAPIKey)
            }
        }
        .padding(.vertical, 4)
    }
}
