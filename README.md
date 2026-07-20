# Notchtalk

Minimal macOS menu bar dictation: press a key, speak, get a transcription pasted at your cursor (without overwriting your clipboard) or copied to the clipboard.

This exists because I got tired of paid dictation wrappers (SuperWhisper, Spokenly, etc.) that felt expensive (often ~$12/month) for comparatively little gain. In a world where you can bring your own API key, I wanted the simplest possible app that talks directly to the OpenAI transcription API, uses a sane default model, and is reliable about retries/timeouts.

Notchtalk is intentionally small. It is not planned to be paid, and it is likely not going to be distributed via an app store. The expected workflow is: clone, build in Xcode, sign it with your own Apple account, and run it.

## What It Does

- Lives in the macOS menu bar (MenuBarExtra).
- Global hotkey:
  - Tap **Right Command (⌘)** to start recording.
  - Tap **Right Command (⌘)** again to stop and transcribe.
  - Press **Esc twice within 2.5 seconds** to cancel recording/transcription.
- Shows a small “pill” UI near the notch/screen center while active.
- Lets you choose OpenAI or ElevenLabs Scribe v2 as the transcription provider.
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

There is a provider picker, but no model picker. The goal is “works well by default” rather than “a huge dropdown”.

## Requirements

- macOS `26.2+` (current Xcode project deployment target)
- Xcode (recent enough to build for macOS 26)
- An API key for the selected provider (usage is billed by OpenAI or ElevenLabs; Notchtalk does not add any subscription layer)
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
6. Open **Settings...** from the menu bar icon, choose a provider, and paste its API key.

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
