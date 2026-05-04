import Carbon
import Foundation
import GlyphCore

@discardableResult
func expect(_ condition: @autoclosure () -> Bool, _ message: String) -> Bool {
    if condition() {
        return true
    }

    FileHandle.standardError.write(Data("Spec failed: \(message)\n".utf8))
    exit(1)
}

let defaultSettings = WhisperSettings.defaults(
    homeDirectory: "/Users/example",
    environment: [:],
    processorCount: 16
)

expect(
    defaultSettings.executablePath == "/Users/example/whisper.cpp-build/bin/whisper-cli",
    "default whisper-cli path should use the home directory"
)
expect(
    defaultSettings.modelPath == "/Users/example/whisper-models/ggml-large-v3-turbo-q5_0.bin",
    "default model path should use the home directory"
)
expect(defaultSettings.language == "en", "default language should be English")
expect(defaultSettings.language == WhisperSettings.englishLanguageCode, "language should use the fixed English code")
expect(defaultSettings.threads == 8, "default thread count should be 8 when enough processors are available")
expect(defaultSettings.prompt == WhisperSettings.defaultPrompt, "default prompt should use the shared prompt constant")

let overriddenSettings = WhisperSettings.defaults(
    homeDirectory: "/Users/example",
    environment: [
        "GLYPH_WHISPER_CLI": "/tmp/whisper-cli",
        "GLYPH_WHISPER_MODEL": "/tmp/model.bin",
        "GLYPH_WHISPER_LANGUAGE": "auto",
        "GLYPH_WHISPER_THREADS": "12",
        "GLYPH_WHISPER_PROMPT": "Prompt"
    ],
    processorCount: 16
)

expect(overriddenSettings.executablePath == "/tmp/whisper-cli", "executable env override should win")
expect(overriddenSettings.modelPath == "/tmp/model.bin", "model env override should win")
expect(overriddenSettings.language == "en", "language should stay English even when env tries to override it")
expect(overriddenSettings.threads == 12, "threads env override should win")
expect(overriddenSettings.prompt == "Prompt", "prompt env override should win")

let tildeSettings = WhisperSettings.defaults(
    homeDirectory: "/Users/example",
    environment: [
        "GLYPH_WHISPER_CLI": "~/bin/whisper-cli",
        "GLYPH_WHISPER_MODEL": "~/models/model.bin",
        "GLYPH_WHISPER_THREADS": "0"
    ],
    processorCount: 8
)

expect(tildeSettings.executablePath == "/Users/example/bin/whisper-cli", "tilde executable path should expand")
expect(tildeSettings.modelPath == "/Users/example/models/model.bin", "tilde model path should expand")
expect(tildeSettings.threads == 1, "thread count should not drop below 1")

let highThreadSettings = WhisperSettings.defaults(
    homeDirectory: "/Users/example",
    environment: ["GLYPH_WHISPER_THREADS": "128"],
    processorCount: 12
)

expect(highThreadSettings.threads == 12, "thread count should not exceed available processors")

let whisperArguments = WhisperTranscriber(settings: overriddenSettings).arguments(
    for: URL(fileURLWithPath: "/tmp/audio.wav")
)

expect(whisperArguments.contains("-l"), "whisper arguments should include language flag")
expect(whisperArguments.contains("en"), "whisper arguments should force English language")
expect(whisperArguments.contains("--suppress-nst"), "whisper arguments should suppress non-speech tokens")
expect(whisperArguments.contains("-bs"), "whisper arguments should tune beam size for low latency")
expect(whisperArguments.contains("-bo"), "whisper arguments should tune best-of candidates for low latency")
expect(whisperArguments.contains("-nf"), "whisper arguments should skip decoder fallback for predictable latency")

let injectedText = #"say "hello codex""#
let ghosttyEvent = GhosttyInjector.eventDescriptor(for: injectedText, submit: true)
let ghosttyParameters = ghosttyEvent.paramDescriptor(forKeyword: AEKeyword(keyDirectObject))

expect(
    GhosttyInjector.scriptSource.contains(#"tell application id "com.mitchellh.ghostty""#),
    "ghostty injection should target Ghostty by bundle identifier"
)
expect(
    GhosttyInjector.scriptSource.contains("focused terminal of selected tab of front window"),
    "ghostty injection should target the focused Ghostty terminal"
)
expect(
    GhosttyInjector.scriptSource.contains("key code 36"),
    "auto-submit should send a real Return key event instead of transcript newline text"
)
expect(
    !GhosttyInjector.scriptSource.contains(injectedText),
    "ghostty injection should not interpolate transcript text into AppleScript source"
)
expect(
    ghosttyEvent.paramDescriptor(forKeyword: AEKeyword(keyASSubroutineName))?.stringValue == GhosttyInjector.handlerName,
    "ghostty injection should call the explicit AppleScript handler"
)
expect(
    ghosttyParameters?.atIndex(1)?.stringValue == injectedText,
    "ghostty injection should pass transcript as an Apple event parameter"
)
expect(
    ghosttyParameters?.atIndex(2)?.booleanValue == true,
    "ghostty injection should pass submit mode as an Apple event parameter"
)

let rawTranscript = """

  [00:00:00.000 --> 00:00:01.000]  hello   codex
[00:00:01.000 --> 00:00:02.000] run swift test

"""

expect(
    TranscriptionCleaner.clean(rawTranscript) == "hello codex run swift test",
    "transcript cleaner should remove timestamps and collapse whitespace"
)

let bomPrefixedTranscript = "\u{feff}[00:00:00.000 --> 00:00:01.000]  open Package.swift"
expect(
    TranscriptionCleaner.clean(bomPrefixedTranscript) == "open Package.swift",
    "transcript cleaner should remove a BOM before timestamp parsing"
)

print("GlyphSpec passed")
