//
//  LocalTranscriptionService.swift
//  notchtalk
//

import Foundation
import Observation

/// A speech model that transcribes on this Mac. Installing downloads uv, a Python runtime, the
/// model's engine and the model into its own folder in Application Support.
enum LocalModel: String, Sendable {
    /// NVIDIA Parakeet-TDT 0.6B v3 (CC BY 4.0, 25 European languages) through mlx-audio.
    case parakeet
    /// Phonon-2 by Fermion Research (CC BY 4.0), a 2-bit build of Parakeet: small and fast, but it
    /// garbles German.
    case phonon2

    var name: String {
        switch self {
        case .parakeet: "Parakeet"
        case .phonon2: "Phonon-2"
        }
    }

    // Full precision on purpose: the 2-bit Phonon-2 build of this model garbled German.
    private static let parakeetRepo = "mlx-community/parakeet-tdt-0.6b-v3"
    private static let parakeetRevision = "ed2b7e8c15f9aaa0b5772e2efb986255eaef7e15"
    private static let phononRepo = "FermionResearch/Phonon-2"

    /// The direct dependencies, pinned to the versions tested with the model.
    fileprivate var packages: String {
        switch self {
        case .parakeet:
            "mlx==0.32.3 mlx-audio==0.5.7"
        case .phonon2:
            "fermion-research==0.2.3 mlx==0.32.3 mlx-audio==0.5.7 mlx-lm==0.31.3 soundfile==0.14.0 scipy==1.18.1 zstandard==0.25.0"
        }
    }

    fileprivate var download: String {
        switch self {
        case .parakeet:
            """
            echo "Downloading Parakeet (2.3 GB)"
            venv/bin/python -c 'import huggingface_hub, sys; huggingface_hub.snapshot_download(sys.argv[1], revision=sys.argv[2])' \
              \(Self.parakeetRepo) \(Self.parakeetRevision) > /dev/null
            """
        case .phonon2:
            """
            echo "Downloading Phonon-2 (164 MB)"
            venv/bin/fermion transcribe --download-only --model \(Self.phononRepo) placeholder.wav > /dev/null
            """
        }
    }

    /// Python that loads the model once and defines `transcribe(path) -> str`.
    fileprivate var loader: String {
        switch self {
        case .parakeet:
            """
            from mlx_audio.stt.utils import load_model
            model = load_model("\(Self.parakeetRepo)", revision="\(Self.parakeetRevision)")
            def transcribe(path): return model.generate(path).text
            """
        case .phonon2:
            // fermion 0.2.3 has no public speech API; these are the calls `fermion transcribe` makes.
            """
            from fermion._speech import backends, fetch
            from fermion.transcribe import _resolve
            repo, key, pin, _ = _resolve("\(Self.phononRepo)")
            engine = backends.resolve("notchtalk")
            speech = backends.load(engine, fetch.ensure(repo, key, pin), profile=key, backend=pin["backend"], quiet=True)
            def transcribe(path): return speech.transcribe_detailed(path).triple()[0]
            """
        }
    }

    @MainActor var installer: LocalModelInstaller {
        switch self {
        case .parakeet: .parakeet
        case .phonon2: .phonon2
        }
    }

    var service: LocalTranscriptionService {
        switch self {
        case .parakeet: .parakeet
        case .phonon2: .phonon2
        }
    }

    nonisolated var root: URL {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: self == .parakeet ? "notchtalk/parakeet" : "notchtalk/phonon", directoryHint: .isDirectory)
    }

    nonisolated var isInstalled: Bool { FileManager.default.fileExists(atPath: root.appending(path: "installed").path) }
}

@MainActor
@Observable
final class LocalModelInstaller {
    static let parakeet = LocalModelInstaller(.parakeet)
    static let phonon2 = LocalModelInstaller(.phonon2)

    enum State: Equatable {
        case notInstalled
        case installing(String)
        case installed
        case failed(String)
    }

    let model: LocalModel
    private(set) var state: State

    private init(_ model: LocalModel) {
        self.model = model
        state = model.isInstalled ? .installed : .notInstalled
    }

    var isInstalled: Bool { state == .installed }

    /// Picks up a folder deleted or installed outside the app.
    func refresh() {
        if case .installing = state { return }
        state = model.isInstalled ? .installed : .notInstalled
    }

    func install() {
        if case .installing = state { return }
        state = .installing("Starting")
        Task {
            do {
                try await model.service.install { [model] step in
                    Task { @MainActor in
                        let installer = model.installer
                        if case .installing = installer.state { installer.state = .installing(step) }
                    }
                }
                state = .installed
                LocalTranscriptionService.follow()
            } catch {
                state = .failed(error.localizedDescription)
            }
        }
    }
}

actor LocalTranscriptionService {
    typealias LogHandler = @MainActor @Sendable (_ message: String, _ level: TranscriptionDiagnosticsEntry.LogLevel) async -> Void

    static let parakeet = LocalTranscriptionService(.parakeet)
    static let phonon2 = LocalTranscriptionService(.phonon2)

    struct Reply: Decodable, Sendable {
        struct Failure: Decodable, Sendable { let message: String }
        let text: String?
        let error: Failure?
    }

    let model: LocalModel
    private var server: Process?
    private var ready: Task<URL, Error>?
    private var token = ""
    // A provider switch mid-transcription stops the server once the running uploads finish.
    private var inFlight = 0
    private var stopWhenIdle = false

    private init(_ model: LocalModel) {
        self.model = model
    }

    /// Starts the model server so the first transcription does not wait for it.
    func prewarm() async {
        stopWhenIdle = false
        _ = try? await baseURL()
    }

    /// Keeps the selected model's server warm and stops the other one.
    // ponytail: the warm server holds up to 3 GB for as long as its model is selected; an idle
    // timeout would bring back the 10 s cold start on the next short recording.
    // Reads the selection at each step, so an older call that resumes late follows the newer one.
    nonisolated static func follow() {
        Task { @MainActor in
            for model in [LocalModel.parakeet, .phonon2] where SettingsManager.shared.transcriptionProvider.localModel != model {
                await model.service.shutdown()
            }
            if let model = SettingsManager.shared.transcriptionProvider.localModel, model.isInstalled {
                await model.service.prewarm()
            }
        }
    }

    func shutdown() {
        // Also covers a transcription that captured this model before the switch and starts later.
        stopWhenIdle = true
        if inFlight == 0 { stop() }
    }

    func transcribe(audioURL: URL, onLog: LogHandler? = nil) async throws -> String {
        inFlight += 1
        defer {
            inFlight -= 1
            if inFlight == 0, stopWhenIdle { stop() }
        }
        let wavURL = FileManager.default.temporaryDirectory.appending(path: "notchtalk_local_\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: wavURL) }
        // The models read 16 kHz mono; recordings and memos are AAC.
        try await Self.run("/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", audioURL.path, wavURL.path])

        let base = try await baseURL()
        var request = URLRequest(url: base, timeoutInterval: 600)
        request.httpMethod = "POST"
        request.setValue("audio/wav", forHTTPHeaderField: "Content-Type")
        request.setValue(token, forHTTPHeaderField: "X-Notchtalk-Token")
        let started = Date()
        let (data, response) = try await URLSession.shared.upload(for: request, fromFile: wavURL)
        guard let http = response as? HTTPURLResponse else { throw TranscriptionError.invalidResponse }

        let reply = try? JSONDecoder().decode(Reply.self, from: data)
        guard http.statusCode == 200, let text = reply?.text else {
            throw reply?.error.map { TranscriptionError.apiError($0.message) } ?? TranscriptionError.httpError(http.statusCode)
        }
        await onLog?(String(format: "\(model.name) transcribed on this Mac in %.1f s", Date().timeIntervalSince(started)), .info)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TranscriptionError.emptyTranscript }
        return trimmed
    }

    private func baseURL() async throws -> URL {
        // A start in flight is awaited, not replaced: its process may not exist yet. A failed start
        // fails all its waiters; the next call starts again.
        while let current = ready {
            let url: URL
            do { url = try await current.value } catch {
                if ready == current { ready = nil }
                throw error
            }
            if ready == current {
                if server?.isRunning == true { return url }
                break
            }
            // shutdown() stopped the start this caller waited on; only a transcription restarts it.
            guard ready != nil else { throw CancellationError() }
        }
        stop()
        let task = Task { try await launch() }
        ready = task
        do { return try await task.value } catch {
            if ready == task { ready = nil }
            throw error
        }
    }

    private func launch() async throws -> URL {
        guard model.isInstalled else { throw TranscriptionError.apiError("\(model.name) is not installed") }
        let port = Int.random(in: 20_000...60_000)
        // Another local service may hold the port; only our server echoes this token.
        let token = UUID().uuidString
        self.token = token
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        // The wrapper stops the server when Notchtalk exits, also after a crash.
        process.arguments = ["-c", """
            "$ROOT/venv/bin/python" "$ROOT/server.py" \(port) \(token) & child=$!
            trap 'kill $child 2>/dev/null' EXIT
            while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null && kill -0 $child 2>/dev/null; do sleep 2; done
            """]
        process.environment = environment.merging(["HF_HUB_OFFLINE": "1"]) { $1 }
        try Data((model.loader + "\n" + Self.serverScript).utf8).write(to: model.root.appending(path: "server.py"))
        let log = model.root.appending(path: "server.log")
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
            if let (data, _) = try? await URLSession.shared.data(from: base), data == Data(token.utf8) {
                return base
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        process.terminate()
        if server === process { server = nil }
        throw TranscriptionError.apiError("\(model.name) did not start, see \(log.path)")
    }

    private func stop() {
        server?.terminate()
        server = nil
        ready = nil
    }

    // MARK: Install

    private nonisolated var environment: [String: String] {
        let root = model.root.path
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

    /// Each `echo` line becomes the step shown in Settings.
    private nonisolated var installScript: String {
        """
        set -euo pipefail
        # Quitting Notchtalk mid-install stops the download too.
        ( trap '' TERM; while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 2; done
          pkill -TERM -P $$; kill -TERM $$ ) & watcher=$!
        trap 'kill -9 $watcher 2>/dev/null' EXIT
        [ "$(uname -m)" = arm64 ] || { echo "\(model.name) needs a Mac with Apple silicon" >&2; exit 1; }
        mkdir -p "$ROOT/bin" && cd "$ROOT"
        if [ ! -x bin/uv ]; then
          echo "Downloading uv"
          curl -fsSL https://github.com/astral-sh/uv/releases/download/0.12.10/uv-aarch64-apple-darwin.tar.gz \
            | tar xz -C bin --strip-components 1
        fi
        echo "Installing Python"
        bin/uv venv -q --allow-existing --managed-python --python 3.12 venv
        echo "Installing the speech engine"
        bin/uv pip install -q --python venv/bin/python \(model.packages)
        \(model.download)
        bin/uv cache clean -q
        touch installed
        """
    }

    /// Serves the loader's `transcribe`: `POST /` (a 16 kHz wav body) answers `{"text"}`, `GET /`
    /// answers the launch token. One request decodes at a time.
    private static let serverScript = """
        import json, sys, tempfile, threading
        from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

        lock = threading.Lock()

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                data = sys.argv[2].encode()
                self.send_response(200)
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def do_POST(self):
                if self.headers["X-Notchtalk-Token"] != sys.argv[2]:
                    return self.reply(403, {"error": {"message": "wrong token"}})
                body = self.rfile.read(int(self.headers["Content-Length"]))
                try:
                    with tempfile.NamedTemporaryFile(suffix=".wav") as f, lock:
                        f.write(body)
                        f.flush()
                        self.reply(200, {"text": transcribe(f.name)})
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

    nonisolated func install(onStep: @escaping @Sendable (String) -> Void) async throws {
        try FileManager.default.createDirectory(at: model.root, withIntermediateDirectories: true)
        try await Self.run("/bin/bash", ["-c", installScript], environment: environment, onLine: onStep)
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
                    // A cancel between the check and run() found nothing to terminate.
                    if Task.isCancelled { process.terminate() }
                } catch { continuation.resume(throwing: error) }
            }
        } onCancel: {
            // terminate() on a process that never launched raises an Objective-C exception.
            if process.isRunning { process.terminate() }
        }
    }
}
