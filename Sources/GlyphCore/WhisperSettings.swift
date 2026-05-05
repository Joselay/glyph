import Foundation

public struct WhisperSettings: Equatable, Sendable {
    public static let englishLanguageCode = "en"
    public static let defaultPrompt = [
        "Developer dictation into Codex CLI in Ghostty.",
        "Keep English technical terms, casing, punctuation, file names, paths, shell commands, flags, and code symbols exact.",
        "Vocabulary: Codex, Ghostty, AppKit, SwiftUI, SwiftPM, Xcode, TypeScript, JavaScript, Next.js, React, Tailwind, shadcn/ui, Bun, Biome, GitHub, GitLab, AGENTS.md, README.md, Package.swift, Makefile, Info.plist, JSON, YAML, TOML, zsh, Homebrew, Docker, Colima, Postgres, stdout, stderr, stdin, rg, git status, git diff, git commit, git push, chmod, mkdir."
    ].joined(separator: " ")

    private enum EnvironmentKey {
        static let executablePath = "GLYPH_WHISPER_CLI"
        static let modelPath = "GLYPH_WHISPER_MODEL"
        static let threads = "GLYPH_WHISPER_THREADS"
        static let prompt = "GLYPH_WHISPER_PROMPT"
    }

    public var executablePath: String
    public var modelPath: String
    public private(set) var language: String
    public var threads: Int
    public var prompt: String

    public init(
        executablePath: String,
        modelPath: String,
        threads: Int = 8,
        prompt: String = WhisperSettings.defaultPrompt,
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
        let executablePath = environment[EnvironmentKey.executablePath]
            .map { expandedPath($0, homeDirectory: homeDirectory) }
            ?? "\(homeDirectory)/whisper.cpp-build/bin/whisper-cli"
        let modelPath = environment[EnvironmentKey.modelPath]
            .map { expandedPath($0, homeDirectory: homeDirectory) }
            ?? "\(homeDirectory)/whisper-models/ggml-large-v3-turbo-q5_0.bin"

        return WhisperSettings(
            executablePath: executablePath,
            modelPath: modelPath,
            threads: Int(environment[EnvironmentKey.threads] ?? "") ?? 8,
            prompt: environment[EnvironmentKey.prompt] ?? defaultPrompt,
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
