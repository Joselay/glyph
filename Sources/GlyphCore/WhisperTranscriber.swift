import Foundation

public enum WhisperTranscriberError: Error, LocalizedError, Sendable {
    case missingExecutable(String)
    case missingModel(String)
    case whisperFailed(status: Int32, stderr: String)
    case noTranscript

    public var errorDescription: String? {
        switch self {
        case .missingExecutable(let path):
            "Whisper executable was not found at \(path)."
        case .missingModel(let path):
            "Whisper model was not found at \(path)."
        case .whisperFailed(let status, let stderr):
            "Whisper failed with status \(status): \(stderr)"
        case .noTranscript:
            "Whisper finished but did not return text."
        }
    }
}

public struct WhisperTranscriber: Sendable {
    public var settings: WhisperSettings

    public init(settings: WhisperSettings = .defaults()) {
        self.settings = settings
    }

    public func transcribe(audioFile: URL) throws -> String {
        let fileManager = FileManager.default

        guard fileManager.isExecutableFile(atPath: settings.executablePath) else {
            throw WhisperTranscriberError.missingExecutable(settings.executablePath)
        }

        guard fileManager.fileExists(atPath: settings.modelPath) else {
            throw WhisperTranscriberError.missingModel(settings.modelPath)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: settings.executablePath)
        process.arguments = arguments(for: audioFile)

        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("Glyph-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: temporaryDirectory)
        }

        let stdoutURL = temporaryDirectory.appendingPathComponent("stdout.txt")
        let stderrURL = temporaryDirectory.appendingPathComponent("stderr.txt")
        fileManager.createFile(atPath: stdoutURL.path, contents: nil)
        fileManager.createFile(atPath: stderrURL.path, contents: nil)

        let stdout = try FileHandle(forWritingTo: stdoutURL)
        let stderr = try FileHandle(forWritingTo: stderrURL)
        defer {
            try? stdout.close()
            try? stderr.close()
        }

        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        try stdout.close()
        try stderr.close()

        let output = (try? String(contentsOf: stdoutURL, encoding: .utf8)) ?? ""
        let errorOutput = (try? String(contentsOf: stderrURL, encoding: .utf8)) ?? ""

        guard process.terminationStatus == 0 else {
            throw WhisperTranscriberError.whisperFailed(
                status: process.terminationStatus,
                stderr: TranscriptionCleaner.clean(errorOutput)
            )
        }

        let transcript = TranscriptionCleaner.clean(output)
        guard !transcript.isEmpty else {
            throw WhisperTranscriberError.noTranscript
        }

        return transcript
    }

    public func arguments(for audioFile: URL) -> [String] {
        [
            "-m", settings.modelPath,
            "-f", audioFile.path,
            "-np",
            "-nt",
            "--suppress-nst",
            "-l", settings.language,
            "-t", String(settings.threads),
            "--prompt", settings.prompt
        ]
    }
}
