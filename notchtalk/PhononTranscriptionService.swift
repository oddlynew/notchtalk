//
//  PhononTranscriptionService.swift
//  notchtalk
//

import Foundation
import Observation

/// Phonon-2 by Fermion Research (CC BY 4.0) transcribes on this Mac. Installing downloads uv, a
/// Python runtime with the `fermion` package and the 164 MB model into Application Support.
@MainActor
@Observable
final class PhononInstaller {
    static let shared = PhononInstaller()

    enum State: Equatable {
        case notInstalled
        case installing(String)
        case installed
        case failed(String)
    }

    private(set) var state: State = PhononTranscriptionService.isInstalled ? .installed : .notInstalled

    var isInstalled: Bool { state == .installed }

    func install() {
        if case .installing = state { return }
        state = .installing("Starting")
        Task {
            do {
                try await PhononTranscriptionService.install { step in
                    Task { @MainActor in
                        let installer = PhononInstaller.shared
                        if case .installing = installer.state { installer.state = .installing(step) }
                    }
                }
                state = .installed
                await PhononTranscriptionService.shared.prewarm()
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }
}

actor PhononTranscriptionService {
    typealias LogHandler = @MainActor @Sendable (_ message: String, _ level: TranscriptionDiagnosticsEntry.LogLevel) async -> Void

    static let shared = PhononTranscriptionService()

    nonisolated static let root = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "notchtalk/phonon", directoryHint: .isDirectory)
    private nonisolated static let marker = root.appending(path: "installed")
    nonisolated static var isInstalled: Bool { FileManager.default.fileExists(atPath: marker.path) }

    private static let model = "FermionResearch/Phonon-2"
    private static let idleShutdown: Duration = .seconds(15 * 60)

    struct Reply: Decodable, Sendable {
        struct Failure: Decodable, Sendable { let message: String }
        let text: String?
        let error: Failure?
    }

    private var server: Process?
    private var ready: Task<URL, Error>?
    private var idleStop: Task<Void, Never>?

    /// Starts the model server so the first transcription does not wait for it.
    func prewarm() async {
        _ = try? await baseURL()
        scheduleIdleStop()
    }

    func transcribe(audioURL: URL, onLog: LogHandler? = nil) async throws -> String {
        let wavURL = FileManager.default.temporaryDirectory.appending(path: "notchtalk_phonon_\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: wavURL) }
        // The server reads wav, flac, ogg and aiff; recordings and memos are AAC.
        try await Self.run("/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", audioURL.path, wavURL.path])

        let base = try await baseURL()
        defer { scheduleIdleStop() }
        let boundary = UUID().uuidString
        var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"audio.wav\"\r\nContent-Type: audio/wav\r\n\r\n".utf8)
        body.append(try Data(contentsOf: wavURL))
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))

        var request = URLRequest(url: base.appending(path: "v1/audio/transcriptions"), timeoutInterval: 600)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        let started = Date()
        let (data, response) = try await URLSession.shared.upload(for: request, from: body)
        guard let http = response as? HTTPURLResponse else { throw TranscriptionError.invalidResponse }

        let reply = try? JSONDecoder().decode(Reply.self, from: data)
        guard http.statusCode == 200, let text = reply?.text else {
            throw reply?.error.map { TranscriptionError.apiError($0.message) } ?? TranscriptionError.httpError(http.statusCode)
        }
        await onLog?(String(format: "Phonon-2 transcribed on this Mac in %.1f s", Date().timeIntervalSince(started)), .info)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TranscriptionError.emptyTranscript }
        return trimmed
    }

    private func baseURL() async throws -> URL {
        idleStop?.cancel()
        if let ready, server?.isRunning == true, let url = try? await ready.value { return url }
        stop()
        let task = Task { try await launch() }
        ready = task
        return try await task.value
    }

    private func launch() async throws -> URL {
        guard Self.isInstalled else { throw TranscriptionError.apiError("Phonon-2 is not installed") }
        let port = Int.random(in: 20_000...60_000)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        // The wrapper stops the server when Notchtalk exits, also after a crash.
        process.arguments = ["-c", """
            "$ROOT/venv/bin/fermion" serve --model \(Self.model) --port \(port) & child=$!
            trap 'kill $child 2>/dev/null' EXIT
            while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null && kill -0 $child 2>/dev/null; do sleep 2; done
            """]
        process.environment = Self.environment
        let log = Self.root.appending(path: "server.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        server = process

        let base = URL(string: "http://127.0.0.1:\(port)")!
        // A cold start loads Python and the model in about 15 s; the first run also compiles shaders.
        for _ in 0..<240 {
            guard process.isRunning else { break }
            if let (_, response) = try? await URLSession.shared.data(from: base.appending(path: "health")),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                return base
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        stop()
        throw TranscriptionError.apiError("Phonon-2 did not start, see \(log.path)")
    }

    private func stop() {
        server?.terminate()
        server = nil
        ready = nil
    }

    private func scheduleIdleStop() {
        idleStop?.cancel()
        // ponytail: the warm server holds about 2.5 GB, so it stops after 15 idle minutes; the next
        // recording starts it again while the user speaks.
        idleStop = Task {
            try? await Task.sleep(for: Self.idleShutdown)
            guard !Task.isCancelled else { return }
            stop()
        }
    }

    // MARK: Install

    private nonisolated static var environment: [String: String] {
        let root = root.path
        return [
            "ROOT": root,
            "HOME": NSHomeDirectory(),
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "UV_CACHE_DIR": root + "/uv-cache",
            "UV_PYTHON_INSTALL_DIR": root + "/python",
            "FERMION_CACHE_DIR": root + "/models",
            "HF_HOME": root + "/hf",
            "HF_HUB_DISABLE_TELEMETRY": "1",
        ]
    }

    /// Each `echo` line becomes the step shown in Settings. Versions are pinned so a reinstall
    /// gets the same runtime.
    private static let installScript = """
        set -euo pipefail
        [ "$(uname -m)" = arm64 ] || { echo "Phonon-2 needs a Mac with Apple silicon" >&2; exit 1; }
        mkdir -p "$ROOT/bin" && cd "$ROOT"
        if [ ! -x bin/uv ]; then
          echo "Downloading uv"
          curl -fsSL https://github.com/astral-sh/uv/releases/download/0.12.10/uv-aarch64-apple-darwin.tar.gz \
            | tar xz -C bin --strip-components 1
        fi
        echo "Installing Python"
        bin/uv venv -q --allow-existing --managed-python --python 3.12 venv
        echo "Installing the speech engine"
        bin/uv pip install -q --python venv/bin/python \
          fermion-research==0.2.3 mlx mlx-audio mlx-lm soundfile scipy zstandard
        echo "Downloading Phonon-2 (164 MB)"
        venv/bin/fermion transcribe --download-only --model \(model) placeholder.wav > /dev/null
        bin/uv cache clean -q
        touch installed
        """

    nonisolated static func install(onStep: @escaping @Sendable (String) -> Void) async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try await run("/bin/bash", ["-c", installScript], environment: environment, onLine: onStep)
    }

    /// Runs a tool to completion; a failure carries the last line it wrote to stderr.
    private nonisolated static func run(
        _ tool: String,
        _ arguments: [String],
        environment: [String: String]? = nil,
        onLine: (@Sendable (String) -> Void)? = nil
    ) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        if let environment { process.environment = environment }
        // stderr goes to a file: a full pipe would stall a chatty installer.
        let errorLog = FileManager.default.temporaryDirectory.appending(path: "notchtalk_\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: errorLog.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: errorLog) }
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = try FileHandle(forWritingTo: errorLog)
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let chunk = String(decoding: handle.availableData, as: UTF8.self)
            for line in chunk.split(separator: "\n") { onLine?(String(line)) }
        }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                process.terminationHandler = { process in
                    stdout.fileHandleForReading.readabilityHandler = nil
                    guard process.terminationStatus != 0 else { return continuation.resume() }
                    let message = (try? String(contentsOf: errorLog, encoding: .utf8))?
                        .split(separator: "\n").last.map(String.init)
                        ?? "\((tool as NSString).lastPathComponent) failed with status \(process.terminationStatus)"
                    continuation.resume(throwing: TranscriptionError.apiError(message))
                }
                do { try process.run() } catch { continuation.resume(throwing: error) }
            }
        } onCancel: {
            process.terminate()
        }
    }
}
