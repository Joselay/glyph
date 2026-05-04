import Foundation

public struct WhisperSettings: Equatable, Sendable {
    public static let englishLanguageCode = "en"

    public var executablePath: String
    public var modelPath: String
    public private(set) var language: String
    public var threads: Int
    public var prompt: String

    public init(
        executablePath: String,
        modelPath: String,
        threads: Int = 8,
        prompt: String = "Short developer dictation for Codex CLI. Preserve technical terms, file names, shell commands, and punctuation.",
        processorCount: Int = ProcessInfo.processInfo.activeProcessorCount
    ) {
        self.executablePath = executablePath
        self.modelPath = modelPath
        self.language = WhisperSettings.englishLanguageCode
        self.threads = WhisperSettings.normalizedThreadCount(threads, processorCount: processorCount)
        self.prompt = prompt
    }

    public static func defaults(
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        processorCount: Int = ProcessInfo.processInfo.activeProcessorCount
    ) -> WhisperSettings {
        let executablePath = environment["GLYPH_WHISPER_CLI"]
            .map { expandedPath($0, homeDirectory: homeDirectory) }
            ?? "\(homeDirectory)/whisper.cpp-build/bin/whisper-cli"
        let modelPath = environment["GLYPH_WHISPER_MODEL"]
            .map { expandedPath($0, homeDirectory: homeDirectory) }
            ?? "\(homeDirectory)/whisper-models/ggml-large-v3-turbo-q5_0.bin"

        return WhisperSettings(
            executablePath: executablePath,
            modelPath: modelPath,
            threads: Int(environment["GLYPH_WHISPER_THREADS"] ?? "") ?? 8,
            prompt: environment["GLYPH_WHISPER_PROMPT"] ?? "Short developer dictation for Codex CLI. Preserve technical terms, file names, shell commands, and punctuation.",
            processorCount: processorCount
        )
    }

    public static func normalizedThreadCount(_ threads: Int, processorCount: Int) -> Int {
        let availableProcessors = max(1, processorCount)
        return min(max(1, threads), availableProcessors)
    }

    private static func expandedPath(_ path: String, homeDirectory: String) -> String {
        if path == "~" {
            return homeDirectory
        }

        if path.hasPrefix("~/") {
            return homeDirectory + String(path.dropFirst())
        }

        return path
    }
}
