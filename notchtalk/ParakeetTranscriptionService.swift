//
//  ParakeetTranscriptionService.swift
//  notchtalk
//

import Foundation
import Observation

/// NVIDIA Parakeet-TDT 0.6B v3 (CC BY 4.0, 25 European languages) transcribes on this Mac through
/// mlx-audio. Installing downloads uv, a Python runtime with mlx-audio and the 2.3 GB model into
/// Application Support.
@MainActor
@Observable
final class ParakeetInstaller {
    static let shared = ParakeetInstaller()

    enum State: Equatable {
        case notInstalled
        case installing(String)
        case installed
        case failed(String)
    }

    private(set) var state: State = ParakeetTranscriptionService.isInstalled ? .installed : .notInstalled

    var isInstalled: Bool { state == .installed }

    /// Picks up a folder deleted or installed outside the app.
    func refresh() {
        if case .installing = state { return }
        state = ParakeetTranscriptionService.isInstalled ? .installed : .notInstalled
    }

    func install() {
        if case .installing = state { return }
        state = .installing("Starting")
        Task {
            do {
                try await ParakeetTranscriptionService.install { step in
                    Task { @MainActor in
                        let installer = ParakeetInstaller.shared
                        if case .installing = installer.state { installer.state = .installing(step) }
                    }
                }
                state = .installed
                await ParakeetTranscriptionService.shared.prewarm()
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }
}

actor ParakeetTranscriptionService {
    typealias LogHandler = @MainActor @Sendable (_ message: String, _ level: TranscriptionDiagnosticsEntry.LogLevel) async -> Void

    static let shared = ParakeetTranscriptionService()

    nonisolated static let root = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appending(path: "notchtalk/parakeet", directoryHint: .isDirectory)
    private nonisolated static let marker = root.appending(path: "installed")
    nonisolated static var isInstalled: Bool { FileManager.default.fileExists(atPath: marker.path) }

    // Full precision on purpose: the 2-bit Phonon-2 build of this model garbled German.
    private static let model = "mlx-community/parakeet-tdt-0.6b-v3"
    private static let revision = "ed2b7e8c15f9aaa0b5772e2efb986255eaef7e15"

    struct Reply: Decodable, Sendable {
        struct Failure: Decodable, Sendable { let message: String }
        let text: String?
        let error: Failure?
    }

    private var server: Process?
    private var ready: Task<URL, Error>?

    /// Starts the model server so the first transcription does not wait for it.
    func prewarm() async {
        _ = try? await baseURL()
    }

    /// Keeps the server warm while Parakeet is the provider and stops it otherwise.
    // ponytail: the warm server holds about 3 GB for as long as Parakeet is selected; an idle
    // timeout would bring back the 10 s cold start on the next short recording.
    nonisolated static func follow(_ provider: TranscriptionProvider) {
        Task {
            if provider == .parakeet, isInstalled { await shared.prewarm() } else { await shared.shutdown() }
        }
    }

    func shutdown() {
        stop()
    }

    func transcribe(audioURL: URL, onLog: LogHandler? = nil) async throws -> String {
        let wavURL = FileManager.default.temporaryDirectory.appending(path: "notchtalk_parakeet_\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: wavURL) }
        // The model reads 16 kHz mono; recordings and memos are AAC.
        try await Self.run("/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", audioURL.path, wavURL.path])

        let base = try await baseURL()
        var request = URLRequest(url: base, timeoutInterval: 600)
        request.httpMethod = "POST"
        request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        let started = Date()
        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: wavURL)
        guard let http = response as? HTTPURLResponse else { throw TranscriptionError.invalidResponse }

        let reply = try? JSONDecoder().decode(Reply.self, from: data)
        guard http.statusCode == 200, let text = reply?.text else {
            throw reply?.error.map { TranscriptionError.apiError($0.message) } ?? TranscriptionError.httpError(http.statusCode)
        }
        await onLog?(String(format: "Parakeet transcribed on this Mac in %.1f s", Date().timeIntervalSince(started)), .info)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TranscriptionError.emptyTranscript }
        return trimmed
    }

    private func baseURL() async throws -> URL {
        // A start in flight is awaited, not replaced: its process may not exist yet. After a failed
        // start only the first waiter launches again; the others await that replacement.
        while let current = ready {
            if let url = try? await current.value, server?.isRunning == true { return url }
            if ready == current { break }
        }
        stop()
        let task = Task { try await launch() }
        ready = task
        return try await task.value
    }

    private func launch() async throws -> URL {
        guard Self.isInstalled else { throw TranscriptionError.apiError("Parakeet is not installed") }
        let port = Int.random(in: 20_000...60_000)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        // The wrapper stops the server when Notchtalk exits, also after a crash.
        process.arguments = ["-c", """
            "$ROOT/venv/bin/python" "$ROOT/server.py" \(port) & child=$!
            trap 'kill $child 2>/dev/null' EXIT
            while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null && kill -0 $child 2>/dev/null; do sleep 2; done
            """]
        process.environment = Self.environment.merging(["HF_HUB_OFFLINE": "1"]) { $1 }
        try Data(Self.serverScript.utf8).write(to: Self.root.appending(path: "server.py"))
        let log = Self.root.appending(path: "server.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        process.standardOutput = handle
        process.standardError = handle
        try process.run()
        server = process

        let base = URL(string: "http://127.0.0.1:\(port)")!
        // A cold start loads Python and the model in about 10 s.
        for _ in 0..<240 {
            guard process.isRunning else { break }
            if let (_, response) = try? await URLSession.shared.data(from: base),
               (response as? HTTPURLResponse)?.statusCode == 200 {
                return base
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        // `ready` stays on this failed start so concurrent waiters can tell it apart from a retry.
        process.terminate()
        if server === process { server = nil }
        throw TranscriptionError.apiError("Parakeet did not start, see \(log.path)")
    }

    private func stop() {
        server?.terminate()
        server = nil
        ready = nil
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
            "HF_HOME": root + "/hf",
            "HF_HUB_DISABLE_TELEMETRY": "1",
        ]
    }

    /// Each `echo` line becomes the step shown in Settings. The direct dependencies and the model
    /// revision are pinned to the versions tested here.
    private static let installScript = """
        set -euo pipefail
        # Quitting Notchtalk mid-install stops the download too.
        ( trap '' TERM; while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 2; done
          pkill -TERM -P $$; kill -TERM $$ ) & watcher=$!
        trap 'kill -9 $watcher 2>/dev/null' EXIT
        [ "$(uname -m)" = arm64 ] || { echo "Parakeet needs a Mac with Apple silicon" >&2; exit 1; }
        mkdir -p "$ROOT/bin" && cd "$ROOT"
        if [ ! -x bin/uv ]; then
          echo "Downloading uv"
          curl -fsSL https://github.com/astral-sh/uv/releases/download/0.12.10/uv-aarch64-apple-darwin.tar.gz \
            | tar xz -C bin --strip-components 1
        fi
        echo "Installing Python"
        bin/uv venv -q --allow-existing --managed-python --python 3.12 venv
        echo "Installing the speech engine"
        bin/uv pip install -q --python venv/bin/python mlx==0.32.3 mlx-audio==0.5.7
        echo "Downloading Parakeet (2.3 GB)"
        venv/bin/python -c 'import huggingface_hub, sys; huggingface_hub.snapshot_download(sys.argv[1], revision=sys.argv[2])' \
          \(model) \(revision) > /dev/null
        bin/uv cache clean -q
        touch installed
        """

    /// Loads the model once and answers `POST /` (a 16 kHz wav body) with `{"text"}` and `GET /`
    /// with 200. One request decodes at a time.
    private static let serverScript = """
        import json, sys, tempfile, threading
        from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
        from mlx_audio.stt.utils import load_model

        model = load_model("\(model)", revision="\(revision)")
        lock = threading.Lock()

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                self.reply(200, {"ok": True})

            def do_POST(self):
                body = self.rfile.read(int(self.headers["Content-Length"]))
                try:
                    with tempfile.NamedTemporaryFile(suffix=".wav") as f, lock:
                        f.write(body)
                        f.flush()
                        self.reply(200, {"text": model.generate(f.name).text})
                except Exception as error:
                    self.reply(500, {"error": {"message": str(error)}})

            def reply(self, status, payload):
                data = json.dumps(payload).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def log_message(self, *args):
                pass

        ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
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
                do {
                    try Task.checkCancellation()
                    try process.run()
                } catch { continuation.resume(throwing: error) }
            }
        } onCancel: {
            // terminate() on a process that never launched raises an Objective-C exception.
            if process.isRunning { process.terminate() }
        }
    }
}
