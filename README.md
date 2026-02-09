# Notchtalk

Minimal macOS menu bar dictation: press a key, speak, get a transcription copied to your clipboard (and optionally auto-pasted).

This exists because I got tired of paid dictation wrappers (SuperWhisper, Spokenly, etc.) that felt expensive (often ~$12/month) for comparatively little gain. In a world where you can bring your own API key, I wanted the simplest possible app that talks directly to the OpenAI transcription API, uses a sane default model, and is reliable about retries/timeouts.

Notchtalk is intentionally small. It is not planned to be paid, and it is likely not going to be distributed via an app store. The expected workflow is: clone, build in Xcode, sign it with your own Apple account, and run it.

## What It Does

- Lives in the macOS menu bar (MenuBarExtra).
- Global hotkey:
  - Tap **Right Command (⌘)** to start recording.
  - Tap **Right Command (⌘)** again to stop and transcribe.
  - Press **Esc** to cancel recording/transcription.
- Shows a small “pill” UI near the notch/screen center while active.
- Stores your OpenAI API key in the macOS Keychain.
- Lets you set an optional “transcription prompt”.
- Copies the transcription to the clipboard and can optionally auto-paste (simulated Cmd+V).
- Keeps local transcription diagnostics (retry events, HTTP status/errors, timings) and can export JSON/CSV.

## Models

Notchtalk is opinionated on purpose:

- Primary model: `gpt-4o-transcribe`
- Fallback model (hedged): `gpt-4o-mini-transcribe`

There is no “model picker” UI. The goal is “works well by default” rather than “a huge dropdown”.

## Requirements

- macOS `26.2+` (current Xcode project deployment target)
- Xcode (recent enough to build for macOS 26)
- An OpenAI API key (usage is billed by OpenAI; Notchtalk does not add any subscription layer)
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
6. Open **Settings...** from the menu bar icon and paste your OpenAI API key.

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

## Usage

- Tap Right Command (⌘) to start/stop recording.
- While transcribing, you will see “Transcribing” or “Retrying (n/N)” in the pill UI.
- On success, Notchtalk copies the transcription to the clipboard and shows “Copied!”.
- If **Auto-paste** is enabled, it will simulate Cmd+V after copying.

## Diagnostics

Settings -> Diagnostics shows recent transcription runs and log events, including retries and errors. Exports:

- JSON (machine-readable)
- CSV (easy to inspect in a spreadsheet)

Diagnostics are stored locally under:

- `~/Library/Application Support/notchtalk/transcription_diagnostics.json`

## Privacy Notes

- Your OpenAI API key is stored in the macOS Keychain.
- Audio is recorded locally, written to a temporary `.m4a`, and uploaded to OpenAI for transcription.
- Diagnostics (metadata + logs) are stored locally; they are not uploaded anywhere by Notchtalk.

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

