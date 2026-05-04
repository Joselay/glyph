# Glyph

Glyph is a lightweight native macOS menu bar utility for dictating into Codex CLI running in Ghostty.

It intentionally has no main window. The menu bar item exposes runtime status, a recording-only waveform HUD, a short last-transcript preview, recovery actions, permission checks, launch-at-login, auto-submit, and quit.

## Requirements

- macOS 14 or newer
- Swift 6 toolchain through Xcode or Command Line Tools
- Local `whisper.cpp` binary and model

## Usage

1. Build and launch the app:

   ```sh
   make install
   ```

2. Keep Ghostty focused with Codex CLI open.
3. Hold Right Option and speak.
4. Release Right Option when done. Glyph transcribes locally with `whisper.cpp` and sends the text to Ghostty's focused terminal through AppleScript.

On first run, macOS may ask for Microphone, Accessibility, and Automation permission. Accessibility is used for the global hold-to-record trigger. Automation is used to send the transcript from Glyph to Ghostty.

The app uses Swift 6 language mode, AppKit for a lightweight menu bar process, AVFAudio's current recording-permission API, and no production dependencies. Its waveform meter runs only while recording and stops immediately on release.
Glyph keeps runtime work short: the waveform timer is idle unless recording, Ghostty injection reuses a compiled AppleScript, and `whisper.cpp` runs with low-latency decoder settings for short developer dictation.

## Menu

- `Auto-submit` is off by default. When enabled, Glyph sends Return after the transcript so Codex CLI submits immediately.
- `Launch at Login` uses macOS's native login item service.
- `Copy Last Transcript` and `Send Last Transcript` show short status feedback in the menu after they run.
- Permission rows stay visible for Accessibility shortcut access and Microphone access, with direct shortcuts to both macOS settings panes.

## Privacy

- Audio is recorded to the system temporary directory and deleted after transcription.
- Transcription runs locally through `whisper.cpp`.
- Transcript text is sent only to Ghostty's focused terminal through AppleScript.
- Glyph does not write persistent logs or recordings.

## Local Whisper Defaults

Glyph defaults to a local Whisper install under your home directory:

```txt
~/whisper.cpp-build/bin/whisper-cli
~/whisper-models/ggml-large-v3-turbo-q5_0.bin
```

The app always transcribes as English (`-l en`). Binary and model paths can be overridden before launching:

```sh
GLYPH_WHISPER_CLI=/path/to/whisper-cli \
GLYPH_WHISPER_MODEL=/path/to/model.bin \
make run
```

## Checks

```sh
make spec
make app
```
