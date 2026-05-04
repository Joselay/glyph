# Repository Guidelines

## Project Structure & Module Organization

Glyph is a native macOS menu bar utility for dictating into Codex CLI in Ghostty. It targets macOS 14+.

- `Sources/Glyph/` contains the AppKit app, menu bar lifecycle, recording HUD, permissions, and runtime UI.
- `Sources/GlyphCore/` contains testable core logic for Whisper settings, transcription cleanup, whisper.cpp invocation, and Ghostty injection.
- `Specs/GlyphSpec/` contains the lightweight executable spec runner.
- `Resources/Info.plist` and `Scripts/generate_app_icon.swift` support app bundle creation.
- `Makefile` is the build, run, install, and cleanup interface.

## Build, Test, and Development Commands

- `make build` builds the release `Glyph` executable with SwiftPM.
- `make app` builds, generates the icon, signs locally, and stages `.build/glyph-app/Glyph.app`.
- `make run` stops Glyph, stages the app, and opens it.
- `make install` installs to `/Applications/Glyph.app` and launches it.
- `make spec` runs `swift run GlyphSpec`.
- `make test` aliases `make spec`.
- `make clean` removes build artifacts.

## Coding Style & Naming Conventions

Use Swift 6 language mode and keep production dependencies at zero unless explicitly approved. Follow 4-space indentation, explicit access control, focused types, and `@MainActor` isolation for AppKit UI code. Keep app-facing code in `Sources/Glyph` and pure logic in `Sources/GlyphCore`. Use `UpperCamelCase` for types, `lowerCamelCase` for functions and properties, and `GLYPH_` for environment variables.

## Performance & Footprint

Glyph should stay native, fast, and lightweight. Prefer AppKit, Swift standard libraries, and macOS system APIs over cross-platform wrappers or heavy frameworks. Avoid idle background work, persistent logs, large bundled assets, or new runtime services. Stop recording and waveform timers immediately after use.

## Testing Guidelines

Add focused checks to `Specs/GlyphSpec/main.swift` for core behavior, especially settings normalization, transcript cleanup, and Ghostty AppleScript safety. Keep specs independent of the real Whisper binary, model, microphone, and Ghostty process. Run `make spec` for `Sources/GlyphCore` changes and `make app` for bundle or resource changes.

## Commit & Push Guidelines

This repo uses only `main`. Do not create feature branches or pull requests; make narrow commits and push directly to `main`. Recent commits use short imperative subjects, for example `Add menu bar icon` and `Optimize Glyph runtime and bundle weight`. Before pushing, review the diff and report verification commands.

## Security & Runtime Configuration

Glyph records temporary audio, transcribes locally through `whisper.cpp`, and sends text to Ghostty through AppleScript. Preserve this local-first privacy model. Default Whisper paths are `~/whisper.cpp-build/bin/whisper-cli` and `~/whisper-models/ggml-large-v3-turbo-q5_0.bin`; support overrides through `GLYPH_WHISPER_CLI`, `GLYPH_WHISPER_MODEL`, `GLYPH_WHISPER_THREADS`, and `GLYPH_WHISPER_PROMPT`.
