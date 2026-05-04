import AVFAudio
import Foundation

@MainActor
final class RecordingSession {
    private static let settings: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatLinearPCM),
        AVSampleRateKey: 16_000,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false
    ]

    enum StopResult {
        case ready(URL)
        case tooShort(URL)
    }

    private let fileManager: FileManager
    private var recorder: AVAudioRecorder?
    private var startedAt: TimeInterval?

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    @discardableResult
    func start() throws -> URL {
        let url = try nextRecordingURL()
        let recorder = try AVAudioRecorder(url: url, settings: Self.settings)
        recorder.prepareToRecord()
        recorder.record()

        self.recorder = recorder
        startedAt = ProcessInfo.processInfo.systemUptime
        return url
    }

    func stop(minimumDuration: TimeInterval) -> StopResult? {
        guard let recorder else {
            return nil
        }

        let audioURL = recorder.url
        let recorderDuration = recorder.currentTime
        let wallClockDuration = startedAt.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0
        let duration = max(recorderDuration, wallClockDuration)

        recorder.stop()
        self.recorder = nil
        startedAt = nil

        if duration < minimumDuration {
            return .tooShort(audioURL)
        }

        return .ready(audioURL)
    }

    func cancel() {
        guard let recorder else {
            return
        }

        let url = recorder.url
        recorder.stop()
        self.recorder = nil
        startedAt = nil
        removeTemporaryRecording(url)
    }

    func removeTemporaryRecording(_ url: URL) {
        try? fileManager.removeItem(at: url)
    }

    private func nextRecordingURL() throws -> URL {
        let directory = fileManager.temporaryDirectory
            .appendingPathComponent("Glyph", isDirectory: true)

        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("recording-\(UUID().uuidString).wav")
    }
}
