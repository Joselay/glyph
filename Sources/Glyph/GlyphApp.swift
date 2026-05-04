import AppKit
import ApplicationServices
import AVFAudio
import AVFoundation
import GlyphCore

@main
struct GlyphMain {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = GlyphApp()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

@MainActor
final class GlyphApp: NSObject, NSApplicationDelegate {
    private static let rightOptionKeyCode: UInt16 = 61

    private enum State {
        case idle
        case recording
        case transcribing
        case injecting
        case error(String)
    }

    private let settings = WhisperSettings.defaults()
    private var statusItem: NSStatusItem?
    private var sendLastMenuItem = NSMenuItem()
    private var copyLastMenuItem = NSMenuItem()
    private var shortcutAccessMenuItem = NSMenuItem()
    private var statusMenuItem = NSMenuItem()
    private var whisperMenuItem = NSMenuItem()
    private var eventMonitors: [Any] = []
    private var isRecordingChordDown = false
    private var recorder: AVAudioRecorder?
    private var recordingStartedAt: Date?
    private var recordingMeterTimer: Timer?
    private var recordingPeakPower: Float = -160
    private var recordingAveragePower: Float = -160
    private var lastTranscript = ""
    private var state: State = .idle {
        didSet {
            updateStatus()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureStatusItem()
        installModifierHoldMonitors()
        requestAccessibilityIfNeeded()
        state = .idle
    }

    func applicationWillTerminate(_ notification: Notification) {
        for monitor in eventMonitors {
            NSEvent.removeMonitor(monitor)
        }
        recordingMeterTimer?.invalidate()
        recorder?.stop()
    }

    @objc private func toggleRecording() {
        switch state {
        case .idle, .error:
            Task {
                await startRecording()
            }
        case .recording:
            stopRecording()
        case .transcribing, .injecting:
            break
        }
    }

    @objc private func injectLastTranscript() {
        guard !lastTranscript.isEmpty else {
            return
        }

        Task {
            await injectLastTranscriptIntoGhostty()
        }
    }

    @objc private func copyLastTranscript() {
        guard !lastTranscript.isEmpty else {
            return
        }

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lastTranscript, forType: .string)
    }

    @objc private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func recheckPermissions() {
        refreshPermissionStatus(promptAccessibility: false)
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func configureStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.button?.title = "Glyph"

        let menu = NSMenu()

        sendLastMenuItem = NSMenuItem(
            title: "Send Last Transcript to Ghostty",
            action: #selector(injectLastTranscript),
            keyEquivalent: ""
        )
        sendLastMenuItem.target = self
        sendLastMenuItem.isEnabled = false

        copyLastMenuItem = NSMenuItem(
            title: "Copy Last Transcript",
            action: #selector(copyLastTranscript),
            keyEquivalent: ""
        )
        copyLastMenuItem.target = self
        copyLastMenuItem.isEnabled = false

        statusMenuItem = NSMenuItem(title: "Ready. Hold Right Option.", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false

        whisperMenuItem = NSMenuItem(
            title: "Whisper: \(URL(fileURLWithPath: settings.modelPath).lastPathComponent)",
            action: nil,
            keyEquivalent: ""
        )
        whisperMenuItem.isEnabled = false

        shortcutAccessMenuItem = NSMenuItem(
            title: "Global Shortcut: Checking",
            action: nil,
            keyEquivalent: ""
        )
        shortcutAccessMenuItem.isEnabled = false

        let openShortcutAccessMenuItem = NSMenuItem(
            title: "Open Shortcut Access Settings",
            action: #selector(openAccessibilitySettings),
            keyEquivalent: ""
        )
        openShortcutAccessMenuItem.target = self

        let recheckMenuItem = NSMenuItem(
            title: "Recheck Permissions",
            action: #selector(recheckPermissions),
            keyEquivalent: ""
        )
        recheckMenuItem.target = self

        let quitMenuItem = NSMenuItem(title: "Quit Glyph", action: #selector(quit), keyEquivalent: "q")
        quitMenuItem.target = self

        menu.addItem(sendLastMenuItem)
        menu.addItem(copyLastMenuItem)
        menu.addItem(.separator())
        menu.addItem(statusMenuItem)
        menu.addItem(NSMenuItem(title: "Target: Ghostty focused terminal", action: nil, keyEquivalent: ""))
        menu.items.last?.isEnabled = false
        menu.addItem(whisperMenuItem)
        menu.addItem(shortcutAccessMenuItem)
        menu.addItem(.separator())
        menu.addItem(openShortcutAccessMenuItem)
        menu.addItem(recheckMenuItem)
        menu.addItem(.separator())
        menu.addItem(quitMenuItem)

        statusItem?.menu = menu
        refreshPermissionStatus(promptAccessibility: false)
    }

    private func updateStatus() {
        switch state {
        case .idle:
            statusItem?.button?.title = "Glyph"
            statusMenuItem.title = "Ready. Hold Right Option."
        case .recording:
            refreshRecordingPresentation()
        case .transcribing:
            statusItem?.button?.title = "Glyph ..."
            statusMenuItem.title = "Transcribing with whisper.cpp"
        case .injecting:
            statusItem?.button?.title = "Send ..."
            statusMenuItem.title = "Sending to Ghostty"
        case .error(let message):
            statusItem?.button?.title = "Glyph !"
            statusMenuItem.title = message
        }

        sendLastMenuItem.isEnabled = !lastTranscript.isEmpty
        copyLastMenuItem.isEnabled = !lastTranscript.isEmpty
    }

    private func requestAccessibilityIfNeeded() {
        refreshPermissionStatus(promptAccessibility: true)
    }

    @discardableResult
    private func refreshPermissionStatus(promptAccessibility: Bool) -> Bool {
        let trusted: Bool
        if promptAccessibility {
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            trusted = AXIsProcessTrustedWithOptions(options)
        } else {
            trusted = AXIsProcessTrusted()
        }

        shortcutAccessMenuItem.title = trusted ? "Global Shortcut: Allowed" : "Global Shortcut: Missing"
        return trusted
    }

    private func installModifierHoldMonitors() {
        let globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor in
                self?.handleModifierFlagsChanged(event)
            }
        }

        let localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor in
                self?.handleModifierFlagsChanged(event)
            }
            return event
        }

        if let globalMonitor {
            eventMonitors.append(globalMonitor)
        }
        if let localMonitor {
            eventMonitors.append(localMonitor)
        }

        if eventMonitors.isEmpty {
            state = .error("Could not monitor Right Option")
        }
    }

    private func handleModifierFlagsChanged(_ event: NSEvent) {
        guard event.keyCode == Self.rightOptionKeyCode else {
            return
        }

        let isDown = event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.option)

        guard isDown != isRecordingChordDown else {
            return
        }

        isRecordingChordDown = isDown

        if isDown {
            beginHoldRecording()
        } else {
            endHoldRecording()
        }
    }

    private func beginHoldRecording() {
        switch state {
        case .idle, .error:
            Task {
                await startRecording()

                if !isRecordingChordDown, case .recording = state {
                    stopRecording()
                }
            }
        case .recording, .transcribing, .injecting:
            break
        }
    }

    private func endHoldRecording() {
        switch state {
        case .recording:
            stopRecording()
        case .idle, .error, .transcribing, .injecting:
            break
        }
    }

    private func startRecording() async {
        guard await requestMicrophoneAccess() else {
            state = .error("Microphone permission is required")
            return
        }

        do {
            let url = try nextRecordingURL()
            let recorder = try AVAudioRecorder(url: url, settings: audioSettings())
            recorder.isMeteringEnabled = true
            recorder.prepareToRecord()
            recorder.record()
            self.recorder = recorder
            recordingStartedAt = Date()
            recordingPeakPower = -160
            recordingAveragePower = -160
            startRecordingMeterTimer()
            state = .recording
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    private func stopRecording() {
        guard let recorder else {
            state = .idle
            return
        }

        let audioURL = recorder.url
        sampleRecordingMeters()
        let recorderDuration = recorder.currentTime
        let wallClockDuration = recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        let duration = max(recorderDuration, wallClockDuration)
        recorder.stop()
        self.recorder = nil
        recordingStartedAt = nil
        stopRecordingMeterTimer()

        guard duration >= 0.35 else {
            removeTemporaryRecording(audioURL)
            state = .idle
            return
        }

        state = .transcribing

        Task {
            await transcribeAndInject(audioURL)
        }
    }

    private func transcribeAndInject(_ audioURL: URL) async {
        let settings = settings
        defer {
            removeTemporaryRecording(audioURL)
        }

        do {
            let transcript = try await Task.detached(priority: .userInitiated) {
                try WhisperTranscriber(settings: settings).transcribe(audioFile: audioURL)
            }.value

            lastTranscript = transcript
            do {
                try await injectIntoGhostty(transcript)
                state = .idle
            } catch {
                state = .error(error.localizedDescription)
            }
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    private func injectLastTranscriptIntoGhostty() async {
        do {
            try await injectIntoGhostty(lastTranscript)
            state = .idle
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    private func injectIntoGhostty(_ text: String) async throws {
        state = .injecting
        try await Task.detached(priority: .userInitiated) {
            try GhosttyInjector().inject(text)
        }.value
    }

    private func requestMicrophoneAccess() async -> Bool {
        defer {
            refreshPermissionStatus(promptAccessibility: false)
        }

        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return true
        case .undetermined:
            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        case .denied:
            return false
        @unknown default:
            return false
        }
    }

    private func nextRecordingURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Glyph", isDirectory: true)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("recording-\(UUID().uuidString).wav")
    }

    private func audioSettings() -> [String: Any] {
        [
            AVFormatIDKey: Int(kAudioFormatLinearPCM),
            AVSampleRateKey: 16_000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]
    }

    private func startRecordingMeterTimer() {
        recordingMeterTimer?.invalidate()
        recordingMeterTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.sampleRecordingMeters()
            }
        }
    }

    private func stopRecordingMeterTimer() {
        recordingMeterTimer?.invalidate()
        recordingMeterTimer = nil
    }

    private func sampleRecordingMeters() {
        guard let recorder else {
            return
        }

        recorder.updateMeters()
        recordingPeakPower = max(recordingPeakPower, recorder.peakPower(forChannel: 0))
        recordingAveragePower = max(recordingAveragePower, recorder.averagePower(forChannel: 0))
        refreshRecordingPresentation()
    }

    private func refreshRecordingPresentation() {
        let elapsed = recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        statusItem?.button?.title = "Rec \(formatDuration(elapsed))"
        statusMenuItem.title = "Recording \(formatDuration(elapsed))"
    }

    private func formatDuration(_ seconds: TimeInterval) -> String {
        let clampedSeconds = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", clampedSeconds / 60, clampedSeconds % 60)
    }

    private func removeTemporaryRecording(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}
