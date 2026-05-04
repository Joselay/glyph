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

        let stdout = ProcessOutputCapture()
        let stderr = ProcessOutputCapture()
        process.standardOutput = stdout.pipe
        process.standardError = stderr.pipe

        try process.run()
        stdout.startReading()
        stderr.startReading()
        process.waitUntilExit()

        let output = stdout.stringValue()
        let errorOutput = stderr.stringValue()

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
            "-bs", "1",
            "-bo", "1",
            "-nf",
            "--prompt", settings.prompt
        ]
    }
}

private final class ProcessOutputCapture: @unchecked Sendable {
    private static let readQueue = DispatchQueue(
        label: "Glyph.ProcessOutputCapture",
        qos: .userInitiated,
        attributes: .concurrent
    )

    let pipe = Pipe()

    private let group = DispatchGroup()
    private var data = Data()

    func startReading() {
        group.enter()
        Self.readQueue.async {
            self.data = self.pipe.fileHandleForReading.readDataToEndOfFile()
            self.group.leave()
        }
    }

    func stringValue() -> String {
        group.wait()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
