# Notchtalk

Minimal macOS menu bar dictation: press a key, speak, get a transcription pasted at your cursor (without overwriting your clipboard) or copied to the clipboard.

This exists because I got tired of paid dictation wrappers (SuperWhisper, Spokenly, etc.) that felt expensive (often ~$12/month) for comparatively little gain. In a world where you can bring your own API key, I wanted the simplest possible app that talks directly to the OpenAI transcription API, uses a sane default model, and is reliable about retries/timeouts.

Notchtalk is intentionally small. It is not planned to be paid, and it is likely not going to be distributed via an app store. The expected workflow is: clone, build in Xcode, sign it with your own Apple account, and run it.

## What It Does

- Lives in the macOS menu bar (MenuBarExtra).
- Global hotkey:
  - Tap **Right Command (⌘)** to start recording.
  - Tap **Right Command (⌘)** again to stop and transcribe.
  - Click the **pause button** in the pill to pause and resume a running recording.
  - Press **Esc** to cancel a recording immediately. A transcription still running after 10 seconds shows retry and cancel buttons in the pill. Cancelled audio remains available in History for 24 hours.
- Shows a small “pill” UI near the notch/screen center while active.
- Lets you choose OpenAI, ElevenLabs Scribe v2, or Parakeet or Phonon-2 on this Mac as the transcription provider.
- Stores provider API keys separately in the macOS Keychain.
- Can add speaker labels to ElevenLabs transcripts using optional speaker recognition.
- Lets you set an optional “transcription prompt”.
- Copies the transcription to the clipboard, or auto-pastes at your cursor without overwriting your clipboard (simulated Cmd+V).
- Keeps local transcription history (text + per-run diagnostics) and can export JSON/CSV.

## Models

Notchtalk keeps provider choices intentionally small:

- OpenAI primary: `gpt-4o-transcribe`
- OpenAI fallback (hedged): `gpt-4o-mini-transcribe`
- ElevenLabs: `scribe_v2`, with optional speaker diarization
- Parakeet (`nvidia/parakeet-tdt-0.6b-v3` via `mlx-community`, CC BY 4.0, 25 European languages): runs locally on Apple silicon, no key, audio stays on the Mac
- Phonon-2 (`FermionResearch/Phonon-2`, CC BY 4.0): a 164 MB 2-bit build of the same model, as fast but it garbles German; also local

There is a provider picker, but no model picker. The goal is “works well by default” rather than “a huge dropdown”.

## Requirements

- macOS `26.2+` (current Xcode project deployment target)
- Xcode (recent enough to build for macOS 26)
- An API key for the selected provider (usage is billed by OpenAI or ElevenLabs; Notchtalk does not add any subscription layer), or none for Parakeet and Phonon-2
- Permissions:
  - Microphone (to record)
  - Accessibility (for the global hotkey event tap and for auto-paste)

## Build And Run (Xcode)

1. Clone the repo.
2. Open `notchtalk.xcodeproj` in Xcode.
3. Set up signing (required to run a local app build):
   - Xcode: **Settings...** -> **Accounts** -> add your Apple ID.
   - Project navigator -> select the `notchtalk` target -> **Signing & Capabilities**:
     - Set **Team** to your (Personal) Team.
     - If needed, change the **Bundle Identifier** to something unique.
4. Select the `notchtalk` scheme and run.
5. When prompted, grant Microphone permission. If the hotkey does not work, grant Accessibility permission.
6. Open **Settings...** from the menu bar icon, choose a provider, and paste its API key. For Parakeet or Phonon-2, click **Download and install** instead.

## Build A Release And Install To /Applications

Notchtalk is not notarized by default. On another machine, Gatekeeper may block an unsigned/unnotarized app. For personal use on your own Mac, a local signed build via Xcode is the intended path.

### Option A: Archive In Xcode

1. Product -> Archive
2. Export a macOS App
3. Move the exported `.app` to `/Applications`

### Option B: Command Line Build (useful for agents)

If you already configured signing in Xcode once, you can build from the CLI:

```bash
xcodebuild \
  -project notchtalk.xcodeproj \
  -scheme notchtalk \
  -configuration Release \
  -destination 'platform=macOS' \
  build
```

Then copy the built app into Applications (path will vary by DerivedData location):

```bash
cp -R /path/to/DerivedData/Build/Products/Release/notchtalk.app /Applications/
```

If you want to distribute builds to other people, you will generally need Apple Developer Program membership, a Developer ID Application certificate, and notarization. (That’s outside the scope of this repo right now.)

### Command Line Tools Only

For a local build with Apple Command Line Tools, stable ad-hoc signing, installation to `/Applications`, and launch:

```bash
./script/build_and_run.sh
```

Use `./script/build_and_run.sh --verify` to launch and verify that the process stays running.

## Usage

- Tap Right Command (⌘) to start/stop recording.
- While transcribing, you will see “Transcribing” or “Retrying (n/N)” in the pill UI.
- On success, if **Auto-paste** is enabled, Notchtalk pastes at your cursor and shows “Pasted!” (your clipboard is restored immediately after).
- If **Auto-paste** is disabled, Notchtalk copies the transcription to the clipboard and shows “Copied!”.

## Parakeet And Phonon-2 On This Mac

Settings -> Provider -> **Parakeet** -> **Download and install** fetches everything once into `~/Library/Application Support/notchtalk/parakeet` (about 2.8 GB): uv, a Python 3.12 runtime, `mlx-audio` and the 2.3 GB model. It is the full-precision model; the 2-bit Phonon-2 build of the same model garbles German. **Phonon-2** installs the same way into `notchtalk/phonon` (about 1.4 GB, with Fermion's `fermion-research` engine and the 164 MB model). Nothing else on the Mac is touched; deleting a folder uninstalls that model. Needs Apple silicon.

Notchtalk then runs a small model server on 127.0.0.1 and keeps the selected model warm (about 3 GB of memory for Parakeet, 2.5 GB for Phonon-2) for as long as it is the provider: it starts when Notchtalk launches or you pick the model, and stops when you pick another provider or quit. A warm transcription takes about 0.1 s; a cold start about 10 s. The server log is `server.log` in the same folder.

## Voice Memos

History & settings -> Voice Memos lists the recordings of Apple's Voice Memos app (synced from your iPhone via iCloud) newest first. **Transcribe** sends one with the selected provider; the transcript lands in History and on the clipboard, and the memo stays in the list with a check. **Show transcript** opens it in History while History still keeps the entry. Spatial Audio recordings from recent iPhones (`.qta`) are listed too; their stereo track is sent as `.m4a`. Notchtalk only reads Apple's files.

macOS protects that folder, so Notchtalk needs Full Disk Access once: System Settings -> Privacy & Security -> Full Disk Access -> turn on `notchtalk`, then quit and reopen it. The stable signing identity keeps the grant across rebuilds.

## Dropping A File

Open History & settings -> History and drag an audio or video file (m4a, mp3, wav, aiff, mp4, mov and anything else macOS plays) onto the drop zone at the top, or click **Choose File…**. The zone shows reading, transcribing and the result. The file goes the same way as a voice memo: the selected provider, the same retries and timeouts, an entry in History and the transcript on the clipboard, never pasted. Its sound is sent as `.m4a`; your file stays where it is.

## Recording Calls

Turn on **Record calls** in the menu or under Settings -> Calls (off by default). From then on, every call that runs on this Mac is recorded on both sides: iPhone calls taken or placed on the Mac through Continuity, and FaceTime calls. Notchtalk notices the call by itself: it starts as soon as Apple's call process reads the microphone and ends 4 seconds after it lets go, so there is no shortcut to press. While it records, the pill at the bottom of the screen shows a red dot with **Recording call** and the call's clock, and the menu bar icon turns into a phone.

When the call ends, your microphone and the other side are mixed into one track and go the way of a voice memo: the selected provider, an entry in History labelled "Call, N min", the transcript on the clipboard, and the audio kept for 24 hours. A call that ends while you are dictating, or while a dropped file or voice memo is on its way, waits until that is done, then goes the same way. Turning the setting off during a call or quitting discards that call; until the call ends, both sides live only in memory.

The other side comes from a Core Audio process tap on Apple's call processes (`avconferenced`, `TelephonyUtilities`, FaceTime, Phone), which needs the system audio permission once: turning the setting on asks for it; otherwise System Settings -> Privacy & Security -> Screen & System Audio Recording -> turn on `notchtalk`. Without it the tap hears silence, the call keeps only your side, and the menu says so. Calls on the iPhone itself, without the Mac, are not recorded.

`scripts/verify_call_capture.swift` plays a quiet test tone and checks that the app's tap hears exactly that process (needs the system audio permission for the terminal, takes about 5 seconds):

```bash
swiftc -parse-as-library -O scripts/verify_call_capture.swift notchtalk/ProcessTap.swift notchtalk/AmbientRecorder.swift -o .build/verify_call && .build/verify_call
```

## History & Diagnostics

Settings -> History shows recordings from their start onward, including the stop/cancel trigger, transcript text, and per-run log events such as retries and errors. Exports:

- JSON (machine-readable)
- CSV (easy to inspect in a spreadsheet)

Diagnostics are stored locally under:

- `~/Library/Application Support/notchtalk/transcription_diagnostics.json`

## Privacy Notes

- OpenAI and ElevenLabs API keys are stored separately in the macOS Keychain.
- Audio is recorded locally, written to an `.m4a`, and uploaded only to the provider selected in Settings.
- Transcription history (text + metadata + logs) is stored locally; it is not uploaded anywhere by Notchtalk.
- Completed and cancelled recordings are retained locally for 24 hours to allow manual re-transcription, then deleted automatically.
- ElevenLabs speaker recognition sends `diarize=true` and formats returned speaker IDs as readable speaker-labelled paragraphs. The optional library setting also sends `use_speaker_library=true` so ElevenLabs can match speakers registered in the workspace.

## Development

### Run Tests

```bash
xcodebuild test \
  -project notchtalk.xcodeproj \
  -scheme notchtalk \
  -destination 'platform=macOS'
```

### Benchmarking Script

There is a small reliability/latency benchmark script for the OpenAI transcription endpoint:

```bash
OPENAI_API_KEY=... ./scripts/benchmark_transcriptions.sh --runs 20 --model gpt-4o-transcribe
```

## Contributing

Issues and pull requests are welcome, especially around:

- making builds more portable across macOS versions
- robustness around permissions and error states
- improving the signing/notarization story for reproducible installs

### Menu and shortcut

The menu bar panel offers **Copy latest** for the most recent successful attempt in the current app run. Starting another attempt immediately disables it; failure, cancellation, or an empty result never falls back to an older transcript. History remains available separately.

A provider response with no text is shown as **No speech detected** and recorded as a failed attempt, with the audio retained for retry. It never pastes, clears the clipboard, or sends Enter. Check the selected macOS input device and its input volume when this happens repeatedly.

### Ambient mode

For the moments you forgot to record. Turn on **Ambient** in the menu or in Settings, and Notchtalk keeps listening into a rolling window of the last 5, 10 or 20 minutes (default 10). When something worth keeping was just said, ask for it:

- Menu: **Transcribe last 2 / 5 / 10 / 20 min** (up to the window length). The result goes to the clipboard, because the open menu holds the keyboard focus.
- Double-tap **right Option (⌥)**: transcribes the whole window and delivers it like a recording (paste at the cursor with Auto-paste, otherwise the clipboard). Never sends Enter. Can be turned off in Settings.

The recall uses the selected provider with the same retries and timeouts as a normal recording. It shows up in History labelled "Ambient, N min", and its audio is retained for 24 hours like every other recording.

Normal recording, pause, Escape and every shortcut work exactly as before while ambient mode runs. Ambient capture uses its own audio engine next to the recorder; macOS lets both read the microphone at the same time.

Privacy: the window lives only in memory as 16 kHz mono audio (about 18 MB for 10 minutes). Nothing is written to disk or sent anywhere until you ask for a transcript. Turning ambient mode off or quitting discards it at once. The menu bar icon turns into an ear while ambient mode listens, and the macOS microphone indicator stays on. With AirPods or another Bluetooth headset as input, ambient mode listens through the built-in microphone instead, so the headset does not drop into call quality.

`scripts/verify_ambient_capture.swift` checks parallel capture, idle cost, encoding and discarding against the app's own code (needs microphone permission for the terminal, plays and shows nothing, takes about 40 seconds):

```bash
swiftc -parse-as-library -O scripts/verify_ambient_capture.swift notchtalk/AmbientRecorder.swift -o .build/verify_ambient && .build/verify_ambient
```

### Pausing a recording

A running recording can be paused and resumed without ending it. Click the pause button on the right of the pill. The pill turns amber, shows "Paused" and freezes the clock; the paused time never enters the audio, so the transcript is one continuous text without it. Pause is deliberately mouse only: every keyboard gesture is already taken, and the keys keep their meaning.

Right Command and Escape keep their behaviour while paused: right Command finishes the recording (the audio recorded so far is transcribed, no need to resume first), Escape cancels it. The button is not offered while a right Command finish gesture is running, because that gesture is already committed to ending the recording.

The pill takes mouse clicks only while it actually offers a button (recording, or transcription slow enough to show retry and cancel). In every other state the panel stays click-through, so it never blocks what is behind it.

`scripts/verify_pause_audio.swift` checks the assumption this rests on (needs microphone permission, takes about 15 seconds):

```bash
swift scripts/verify_pause_audio.swift
```

Press right Command to start recording immediately. Release within 300 ms (the default) to keep recording; press again to finish. Hold beyond that threshold and release to finish instead. Escape cancels. Combining the key with other keys cancels the shortcut gesture.

### Sending with Enter

**Auto-send on release** controls the default for hold recordings. It is off on a fresh installation; existing saved choices are preserved. The recording bar shows “Release to send” or “Release to transcribe”.

For a one-recording exception, hold Escape while still holding right Command:
- Release Escape first: cancel the recording on Escape release.
- Release right Command first: finish and transcribe without sending. Releasing Escape afterwards does nothing, including while transcription is running.
- This override never changes the saved default. Escape pressed after transcription begins does nothing.

Escape pressed during recording belongs exclusively to NotchTalk: the foreground app receives neither the press, its repeats, nor its release. This also applies to a late release after Command has started transcription. Outside a recording, a new Escape press works normally in the foreground app.

To finish continuous recording, press right Command again. Release before the background progress fills to transcribe without sending, or hold until full to finish and send. Holding Escape abandons this countdown and uses the release-order behavior above.

Start and finish thresholds are separately adjustable from 200–2000 ms in 50 ms steps (defaults: 300 ms start, 300 ms finish; saved custom values are preserved). Enter/Return is not a recording shortcut. Failed/cancelled transcription never sends; manual retries/history do not inherit send intent. Sending pastes before simulating Enter, including when Auto-paste is disabled.

### Non-hold finish modes

Settings → Behavior → **Non-hold mode** defaults to **Click to end, then toggle Enter** when no preference is saved; existing selections are preserved. This mode lets you click once to record and press briefly again to transcribe with Enter off. Holding the finish press fills the progress bar and ends with Enter on, using the same configurable hold-to-send duration. While transcription is pending, further recording-shortcut presses toggle Enter for that run only. Enabling Enter also enables pasting for that run. Every new recording starts with Enter off in this mode; hold-to-record keeps its existing release behavior. Setting changes apply to the next recording.

Recordings shorter than 500 ms never send Enter, including after shortcut toggles or retries. This uses the audio recorder's duration rather than the displayed timer; exactly 500 ms remains eligible.

### Local signing and Keychain updates

Local builds use **NotchTalk Local Development** in your login keychain, or `NOTCHTALK_SIGNING_IDENTITY` to select another certificate. A self-signed certificate alone does not prevent Keychain prompts: macOS partitions its access by executable hash.

`NotchTalkKeychain` is a small credential helper reused byte-for-byte across ordinary app rebuilds. Only this helper reads, saves, or deletes the two NotchTalk API keys. It verifies the parent app's identifier and signing certificate; the app verifies the helper in return. Requests and responses travel over private pipes, never command-line arguments or files. The helper exits after each request, with no background polling or service. Manual builds sign both executables with hardened runtime; Xcode retains its existing runtime and sandbox settings.

Startup checks only whether keys exist, without reading their values. On the first actual credential use after adopting the helper, macOS may ask to authorize **NotchTalkKeychain** for each existing provider key. Choose **Always Allow** in that macOS dialog. Normal UI/app updates then retain the same helper hash. Changing helper source, certificate, or architecture is a credential-component update and may require a new approval; the build reports this instead of silently promising otherwise. Existing API keys and their ACLs are not deleted or broadly opened.

The build reuses a verified helper from `.build/keychain-helper` or the installed app if its source fingerprint matches. It signs the outer app without re-signing the helper, and verifies before and after installation. Missing certificates fail before replacement. For Xcode, first prepare `dist` with `NOTCHTALK_SIGNING_IDENTITY=<same identity as Xcode> ./script/build_and_run.sh --build-only`; its sandboxed build phase verifies and embeds that helper. Self-signed builds are local development builds, not notarized distribution.

Run `./script/test_keychain_helper.sh` for a no-dialog regression check. It creates only dummy credentials in a temporary, non-default keychain, replaces the calling app with a genuinely different binary, proves access through the unchanged helper, rejects an unrelated signed client, and deletes the fixture. It never requests real API keys. `./script/build_and_run.sh --build-only` builds without installation.
