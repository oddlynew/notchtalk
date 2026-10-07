//
//  TranscriptsView.swift
//  notchtalk
//

import AppKit
import SwiftUI

/// Everything Notchtalk transcribed, newest first: dictations, ambient recalls, calls, dropped
/// files and voice memos in one list. Voice memos not transcribed yet sit in it with a Transcribe button.
@MainActor
struct TranscriptsView: View {
    enum Filter: String, CaseIterable, Identifiable {
        case all = "All"
        case dictation = "Dictation"
        case voiceMemos = "Voice Memos"
        case files = "Files"
        case calls = "Calls"

        var id: Self { self }
    }

    /// Where an entry came from, read from the label each path gives it.
    enum Source {
        case dictation, ambient, voiceMemo, file, call

        init(_ entry: TranscriptionDiagnosticsEntry) {
            let label = entry.label ?? ""
            if label.hasPrefix(VoiceMemoLibrary.labelPrefix) { self = .voiceMemo }
            else if label.hasPrefix("File: ") { self = .file }
            else if label.hasPrefix("Call, ") { self = .call }
            else if label.hasPrefix("Ambient, ") { self = .ambient }
            else { self = .dictation }
        }

        var icon: String {
            switch self {
            case .dictation: "mic"
            case .ambient: "ear"
            case .voiceMemo: "waveform"
            case .file: "doc"
            case .call: "phone"
            }
        }

        func matches(_ filter: Filter) -> Bool {
            switch filter {
            case .all: true
            case .dictation: self == .dictation || self == .ambient
            case .voiceMemos: self == .voiceMemo
            case .files: self == .file
            case .calls: self == .call
            }
        }
    }

    private enum Item: Identifiable {
        case entry(TranscriptionDiagnosticsEntry)
        case memo(VoiceMemo)

        var id: String {
            switch self {
            case .entry(let entry): entry.id.uuidString
            case .memo(let memo): memo.id
            }
        }

        var date: Date {
            switch self {
            case .entry(let entry): entry.createdAt
            case .memo(let memo): memo.date
            }
        }
    }

    private let store = TranscriptionDiagnosticsStore.shared
    private let library = VoiceMemoLibrary.shared
    @State private var filter: Filter = .all
    @State private var searchText = ""
    @State private var expandedID: String?
    @State private var detailsEntry: TranscriptionDiagnosticsEntry?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FileDropZone().padding(.horizontal, 18).padding(.top, 14)
            HStack(spacing: 6) {
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass").foregroundStyle(NotchtalkStyle.muted)
                    TextField("Search", text: $searchText).textFieldStyle(.plain)
                }
                .font(.system(size: 11))
                .padding(.horizontal, 10).padding(.vertical, 4)
                .background(NotchtalkStyle.chip, in: RoundedRectangle(cornerRadius: 7))
                .frame(width: 150)
                Spacer(minLength: 8)
                HStack(spacing: 6) {
                    ForEach(Filter.allCases) { option in
                        Button(option.rawValue) { filter = option }
                            .buttonStyle(FilterChipStyle(selected: filter == option))
                    }
                }
            }
            .padding(.horizontal, 18).padding(.top, 12).padding(.bottom, 6)
            content
        }
        .foregroundStyle(NotchtalkStyle.ink)
        .onAppear {
            store.purgeExpiredRetainedAudio()
            library.reload()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in library.reload() }
        .sheet(item: $detailsEntry) { entry in
            EntryDetailsView(entryID: entry.id) { detailsEntry = nil }
        }
    }

    @ViewBuilder private var content: some View {
        let items = filteredItems
        if filter == .voiceMemos && library.accessDenied {
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
        } else if items.isEmpty {
            ContentUnavailableView(
                searchText.isEmpty ? "Nothing here yet" : "No matches",
                systemImage: searchText.isEmpty ? "text.bubble" : "magnifyingglass",
                description: Text(searchText.isEmpty ? "Recordings, voice memos and dropped files appear here once they are transcribed." : "Nothing contains “\(searchText)”.")
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: []) {
                    ForEach(days(of: items), id: \.day) { group in
                        Text(dayTitle(group.day))
                            .font(.system(size: 10, weight: .semibold)).textCase(.uppercase).tracking(0.5).foregroundStyle(NotchtalkStyle.muted)
                            .padding(.horizontal, 8).padding(.top, 10).padding(.bottom, 4)
                        ForEach(group.items) { item in
                            row(item)
                        }
                    }
                }
                .padding(.horizontal, 10).padding(.top, 4).padding(.bottom, 14)
            }
        }
    }

    // MARK: Rows

    @ViewBuilder private func row(_ item: Item) -> some View {
        switch item {
        case .entry(let entry): EntryRow(entry: entry, expanded: expandedID == item.id, toggle: { toggle(item.id) }, showDetails: { detailsEntry = entry })
        case .memo(let memo): MemoRow(memo: memo)
        }
    }

    private func toggle(_ id: String) {
        expandedID = expandedID == id ? nil : id
    }

    // MARK: Data

    private var filteredItems: [Item] {
        let needle = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        let entries = store.entries.filter { entry in
            guard Source(entry).matches(filter) else { return false }
            guard !needle.isEmpty else { return true }
            return [entry.transcriptText, entry.label, entry.errorMessage, entry.sourceAudioFilename]
                .compactMap { $0?.lowercased() }
                .contains { $0.contains(needle) }
        }
        var items = entries.map(Item.entry)
        if filter == .all || filter == .voiceMemos {
            let known = Set(store.entries.map(\.sourceAudioFilename))
            items += library.memos
                .filter { !library.transcribed.contains($0.id) && !known.contains($0.id) }
                .filter { needle.isEmpty || $0.title.lowercased().contains(needle) }
                .map(Item.memo)
        }
        return items.sorted { $0.date > $1.date }
    }

    private func days(of items: [Item]) -> [(day: Date, items: [Item])] {
        let calendar = Calendar.current
        var groups: [(day: Date, items: [Item])] = []
        for item in items {
            let day = calendar.startOfDay(for: item.date)
            if groups.last?.day == day {
                groups[groups.count - 1].items.append(item)
            } else {
                groups.append((day, [item]))
            }
        }
        return groups
    }

    private func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(date: .abbreviated, time: .omitted)
    }
}

/// One transcript: what it says, when, how it ended and with which model; Copy and Transcribe again
/// on the row itself. A click opens the whole text.
@MainActor
private struct EntryRow: View {
    let entry: TranscriptionDiagnosticsEntry
    let expanded: Bool
    let toggle: () -> Void
    let showDetails: () -> Void
    private let store = TranscriptionDiagnosticsStore.shared
    private let manager = NotchStateManager.shared
    @State private var copied = false
    @State private var hovered = false

    var body: some View {
        let source = TranscriptsView.Source(entry)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                SourceTile(icon: source.icon)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13)).lineLimit(1).truncationMode(.tail)
                    HStack(spacing: 8) {
                        Text(entry.createdAt, format: .dateTime.hour().minute())
                        EntryStatusLabel(status: entry.status)
                        if let model = entry.modelDescription, entry.status != .recording {
                            Text("·   \(model)").font(.system(size: 10)).opacity(0.7)
                        }
                    }
                    .font(.system(size: 11)).foregroundStyle(NotchtalkStyle.muted)
                }
                Spacer(minLength: 8)
                actions
            }
            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    Text(entry.transcriptText?.isEmpty == false ? entry.transcriptText! : (entry.errorMessage ?? "No transcript"))
                        .font(.system(size: 12)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Details and logs ›", action: showDetails)
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(NotchtalkStyle.muted)
                }
                .padding(10)
                .background(NotchtalkStyle.sheet, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(NotchtalkStyle.line))
                .padding(.leading, 40)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 9)
        .background(.black.opacity(expanded || hovered ? 0.03 : 0), in: RoundedRectangle(cornerRadius: 9))
        .contentShape(Rectangle())
        .onTapGesture(perform: toggle)
        .onHover { hovered = $0 }
    }

    private var title: String {
        if let text = entry.transcriptText?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
            if let label = entry.label, TranscriptsView.Source(entry) == .voiceMemo || TranscriptsView.Source(entry) == .file {
                return "\(label) · \(firstLine)"
            }
            return firstLine
        }
        return entry.label ?? "Recording from \(entry.createdAt.formatted(date: .omitted, time: .shortened))"
    }

    @ViewBuilder private var actions: some View {
        let busy = manager.state == .recording || manager.state == .processing
        let hasAudio = store.retainedAudioURL(for: entry.id) != nil
        let text = entry.transcriptText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        HStack(spacing: 6) {
            Button {
                ClipboardService.copy(entry.transcriptText ?? "")
                copied = true
                Task {
                    try? await Task.sleep(for: .seconds(1.5))
                    copied = false
                }
            } label: {
                Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
            }
            .buttonStyle(QuietButtonStyle(size: .mini))
            .disabled(text.isEmpty)
            Button {
                manager.retranscribe(diagnosticsID: entry.id, reason: "Transcribe again from the app")
            } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 12)).frame(width: 28, height: 28)
                    .background(NotchtalkStyle.chip, in: RoundedRectangle(cornerRadius: 7))
                    .contentShape(RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .disabled(busy || !hasAudio || entry.status == .recording || entry.status == .pending)
            .help(hasAudio ? "Transcribe again" : "The audio is kept for 24 hours and is gone now")
            .accessibilityLabel("Transcribe again")
        }
    }
}

/// A voice memo Notchtalk has not transcribed yet.
@MainActor
private struct MemoRow: View {
    let memo: VoiceMemo
    private let library = VoiceMemoLibrary.shared

    var body: some View {
        HStack(spacing: 12) {
            SourceTile(icon: "waveform")
            VStack(alignment: .leading, spacing: 2) {
                Text("Voice memo · \(memo.title)").font(.system(size: 13)).lineLimit(1)
                HStack(spacing: 8) {
                    Text(memo.date, format: .dateTime.hour().minute())
                    if let duration = memo.duration {
                        Text(Duration.seconds(duration), format: .time(pattern: duration >= 3600 ? .hourMinuteSecond : .minuteSecond))
                    }
                    Text("Not transcribed").fontWeight(.medium)
                }
                .font(.system(size: 11)).foregroundStyle(NotchtalkStyle.muted)
            }
            Spacer(minLength: 8)
            if library.preparing.contains(memo.id) {
                ProgressView().controlSize(.small)
            } else {
                Button("Transcribe") { library.transcribe(memo) }
                    .buttonStyle(QuietButtonStyle(prominent: true, size: .mini))
                    .disabled(FileDrop.shared.isBusy || !SettingsManager.shared.transcriptionProvider.isReady)
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 9)
    }
}

/// Where an entry came from, as a small tile at the start of its row.
private struct SourceTile: View {
    let icon: String

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 13)).foregroundStyle(NotchtalkStyle.ink)
            .frame(width: 28, height: 28).background(NotchtalkStyle.chip, in: RoundedRectangle(cornerRadius: 8))
    }
}

/// The filter choices on the right of the search field.
private struct FilterChipStyle: ButtonStyle {
    let selected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(selected ? NotchtalkStyle.panel : NotchtalkStyle.ink)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(selected ? NotchtalkStyle.ink : NotchtalkStyle.chip, in: Capsule())
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Capsule())
    }
}

/// Provider, attempts, the audio and the log of one entry, behind "Details and logs".
@MainActor
struct EntryDetailsView: View {
    let entryID: UUID
    let close: () -> Void
    private let store = TranscriptionDiagnosticsStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Details and logs").font(.title3.weight(.semibold))
                Spacer()
                Button("Done", action: close).keyboardShortcut(.defaultAction)
            }
            if let entry = store.entries.first(where: { $0.id == entryID }) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        GroupBox {
                            VStack(alignment: .leading, spacing: 8) {
                                row("Status", entry.status.rawValue.capitalized)
                                if let label = entry.label { row("Source", label) }
                                row("Created", entry.createdAt.formatted(date: .abbreviated, time: .standard))
                                row("Updated", entry.updatedAt.formatted(date: .abbreviated, time: .standard))
                                row("Model", entry.modelDescription ?? "Unknown")
                                if entry.provider == .elevenLabs {
                                    row("Speaker Recognition", entry.speakerRecognitionEnabled == true ? "Enabled" : "Disabled")
                                }
                                row("Prompt", entry.promptProvided ? "Included" : "None")
                                row("Retries", "\(entry.retryCount)")
                                row("Audio File", entry.sourceAudioFilename)
                                row("Retained Audio", entry.retainedAudioFilename == nil ? "None" : "Available")
                                if let expiresAt = entry.retainedAudioExpiresAt {
                                    row("Audio Expires", expiresAt.formatted(date: .abbreviated, time: .standard))
                                }
                                if let count = entry.outputCharacterCount { row("Output Length", "\(count) chars") }
                                if let errorMessage = entry.errorMessage, !errorMessage.isEmpty { row("Error", errorMessage) }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        Text("Log Events").font(.headline)
                        if entry.logs.isEmpty {
                            Text("No logs available.").foregroundStyle(.secondary)
                        } else {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(entry.logs.reversed()) { event in
                                    HStack(alignment: .top, spacing: 8) {
                                        Text(event.timestamp.formatted(date: .omitted, time: .standard))
                                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                            .frame(width: 80, alignment: .leading)
                                        Text(event.level.rawValue.uppercased())
                                            .font(.caption2.weight(.bold)).foregroundStyle(color(for: event.level))
                                            .frame(width: 55, alignment: .leading)
                                        Text(event.message).font(.caption).textSelection(.enabled)
                                        Spacer(minLength: 0)
                                    }
                                }
                            }
                        }
                    }
                }
            } else {
                ContentUnavailableView("This entry is gone", systemImage: "trash")
            }
        }
        .padding(20)
        .frame(width: 560, height: 520)
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(title).font(.caption).foregroundStyle(.secondary).frame(width: 120, alignment: .leading)
            Text(value).font(.caption).textSelection(.enabled)
        }
    }

    private func color(for level: TranscriptionDiagnosticsEntry.LogLevel) -> Color {
        switch level {
        case .info: .secondary
        case .warning: .orange
        case .error: .red
        }
    }
}
