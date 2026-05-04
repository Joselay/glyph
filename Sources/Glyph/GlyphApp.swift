import AppKit
import ApplicationServices
import AVFAudio
import AVFoundation
import GlyphCore
import ServiceManagement

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
    private static let autoSubmitDefaultsKey = "autoSubmitEnabled"

    private enum State {
        case idle
        case recording
        case transcribing
        case injecting
        case error(String)
    }

    private let settings = WhisperSettings.defaults()
    private let userDefaults = UserDefaults.standard
    private var statusItem: NSStatusItem?
    private let idleStatusIcon = GlyphMenuBarIcon.makeImage(style: .idle)
    private let recordingStatusIcon = GlyphMenuBarIcon.makeImage(style: .recording)
    private let transcribingStatusIcon = GlyphMenuBarIcon.makeImage(style: .transcribing)
    private let errorStatusIcon = GlyphMenuBarIcon.makeImage(style: .error)
    private let waveformHUD = RecordingWaveformHUD()
    private var sendLastMenuItem = NSMenuItem()
    private var copyLastMenuItem = NSMenuItem()
    private var lastTranscriptPreviewMenuItem = NSMenuItem()
    private var autoSubmitMenuItem = NSMenuItem()
    private var launchAtLoginMenuItem = NSMenuItem()
    private var shortcutAccessMenuItem = NSMenuItem()
    private var microphoneAccessMenuItem = NSMenuItem()
    private var statusMenuItem = NSMenuItem()
    private var eventMonitors: [Any] = []
    private var isRecordingChordDown = false
    private var recorder: AVAudioRecorder?
    private var waveformTimer: Timer?
    private var recordingStartedAt: Date?
    private var lastTranscript = ""
    private var transientStatusToken: UUID?
    private var state: State = .idle {
        didSet {
            updateStatus()
        }
    }

    private var autoSubmitEnabled: Bool {
        get {
            userDefaults.bool(forKey: Self.autoSubmitDefaultsKey)
        }
        set {
            userDefaults.set(newValue, forKey: Self.autoSubmitDefaultsKey)
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
        recorder?.stop()
        stopWaveformHUD()
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
        showTransientStatus("Copied Last Transcript")
    }

    @objc private func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func openMicrophoneSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func recheckPermissions() {
        let permissions = refreshPermissionStatus(promptAccessibility: false)
        showPermissionStatus(permissions)
    }

    @objc private func toggleAutoSubmit() {
        autoSubmitEnabled.toggle()
        refreshAutoSubmitMenuItem()
        showTransientStatus(autoSubmitEnabled ? "Auto-submit: On" : "Auto-submit: Off")
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }

            refreshLaunchAtLoginMenuItem()
            showTransientStatus(launchAtLoginSummaryTitle())
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

    private func configureStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem?.button?.image = idleStatusIcon
        statusItem?.button?.imagePosition = .imageOnly
        statusItem?.button?.title = ""
        statusItem?.button?.toolTip = "Glyph"

        let menu = NSMenu()

        statusMenuItem = NSMenuItem(title: "Ready. Hold Right Option.", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false

        lastTranscriptPreviewMenuItem = NSMenuItem(title: "Last: None", action: nil, keyEquivalent: "")
        lastTranscriptPreviewMenuItem.isEnabled = false

        sendLastMenuItem = NSMenuItem(
            title: "Send Last Transcript",
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

        autoSubmitMenuItem = NSMenuItem(
            title: "Auto-submit",
            action: #selector(toggleAutoSubmit),
            keyEquivalent: ""
        )
        autoSubmitMenuItem.target = self

        launchAtLoginMenuItem = NSMenuItem(
            title: "Launch at Login",
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        launchAtLoginMenuItem.target = self

        shortcutAccessMenuItem = NSMenuItem(
            title: "Shortcut: Checking",
            action: nil,
            keyEquivalent: ""
        )
        shortcutAccessMenuItem.isEnabled = false

        microphoneAccessMenuItem = NSMenuItem(
            title: "Microphone: Checking",
            action: nil,
            keyEquivalent: ""
        )
        microphoneAccessMenuItem.isEnabled = false

        let openShortcutAccessMenuItem = NSMenuItem(
            title: "Open Accessibility Settings",
            action: #selector(openAccessibilitySettings),
            keyEquivalent: ""
        )
        openShortcutAccessMenuItem.target = self

        let openMicrophoneSettingsMenuItem = NSMenuItem(
            title: "Open Microphone Settings",
            action: #selector(openMicrophoneSettings),
            keyEquivalent: ""
        )
        openMicrophoneSettingsMenuItem.target = self

        let recheckMenuItem = NSMenuItem(
            title: "Recheck Permissions",
            action: #selector(recheckPermissions),
            keyEquivalent: ""
        )
        recheckMenuItem.target = self

        let quitMenuItem = NSMenuItem(title: "Quit Glyph", action: #selector(quit), keyEquivalent: "q")
        quitMenuItem.target = self

        menu.addItem(statusMenuItem)
        menu.addItem(lastTranscriptPreviewMenuItem)
        menu.addItem(.separator())
        menu.addItem(sendLastMenuItem)
        menu.addItem(copyLastMenuItem)
        menu.addItem(.separator())
        menu.addItem(autoSubmitMenuItem)
        menu.addItem(launchAtLoginMenuItem)
        menu.addItem(.separator())
        menu.addItem(shortcutAccessMenuItem)
        menu.addItem(microphoneAccessMenuItem)
        menu.addItem(openShortcutAccessMenuItem)
        menu.addItem(openMicrophoneSettingsMenuItem)
        menu.addItem(recheckMenuItem)
        menu.addItem(.separator())
        menu.addItem(quitMenuItem)

        statusItem?.menu = menu
        refreshAutoSubmitMenuItem()
        refreshLaunchAtLoginMenuItem()
        refreshLastTranscriptPreview()
        refreshPermissionStatus(promptAccessibility: false)
    }

    private func updateStatus() {
        switch state {
        case .idle:
            statusItem?.button?.image = idleStatusIcon
            statusMenuItem.title = "Ready. Hold Right Option."
            statusItem?.button?.toolTip = "Glyph: Ready. Hold Right Option."
        case .recording:
            transientStatusToken = nil
            statusItem?.button?.image = recordingStatusIcon
            statusMenuItem.title = "Recording"
            statusItem?.button?.toolTip = "Glyph: Recording"
        case .transcribing:
            transientStatusToken = nil
            statusItem?.button?.image = transcribingStatusIcon
            statusMenuItem.title = "Transcribing with whisper.cpp"
            statusItem?.button?.toolTip = "Glyph: Transcribing with whisper.cpp"
        case .injecting:
            transientStatusToken = nil
            statusItem?.button?.image = transcribingStatusIcon
            statusMenuItem.title = "Sending to Ghostty"
            statusItem?.button?.toolTip = "Glyph: Sending to Ghostty"
        case .error(let message):
            transientStatusToken = nil
            statusItem?.button?.image = errorStatusIcon
            statusMenuItem.title = message
            statusItem?.button?.toolTip = "Glyph: \(message)"
        }

        sendLastMenuItem.isEnabled = !lastTranscript.isEmpty
        copyLastMenuItem.isEnabled = !lastTranscript.isEmpty
        refreshLastTranscriptPreview()
    }

    private func requestAccessibilityIfNeeded() {
        refreshPermissionStatus(promptAccessibility: true)
    }

    @discardableResult
    private func refreshPermissionStatus(promptAccessibility: Bool) -> PermissionStatus {
        let shortcutAllowed: Bool
        if promptAccessibility {
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            shortcutAllowed = AXIsProcessTrustedWithOptions(options)
        } else {
            shortcutAllowed = AXIsProcessTrusted()
        }

        let status = PermissionStatus.current(shortcutAllowed: shortcutAllowed)
        shortcutAccessMenuItem.title = status.shortcutTitle
        microphoneAccessMenuItem.title = status.microphoneTitle
        return status
    }

    private func showPermissionStatus(_ status: PermissionStatus) {
        showTransientStatus(status.summaryTitle)
    }

    private func refreshAutoSubmitMenuItem() {
        autoSubmitMenuItem.state = autoSubmitEnabled ? .on : .off
        autoSubmitMenuItem.title = autoSubmitEnabled ? "Auto-submit: On" : "Auto-submit: Off"
    }

    private func refreshLaunchAtLoginMenuItem() {
        switch SMAppService.mainApp.status {
        case .enabled:
            launchAtLoginMenuItem.title = "Launch at Login"
            launchAtLoginMenuItem.state = .on
        case .requiresApproval:
            launchAtLoginMenuItem.title = "Launch at Login: Needs Approval"
            launchAtLoginMenuItem.state = .off
        case .notRegistered:
            launchAtLoginMenuItem.title = "Launch at Login"
            launchAtLoginMenuItem.state = .off
        case .notFound:
            launchAtLoginMenuItem.title = "Launch at Login: Unavailable"
            launchAtLoginMenuItem.state = .off
        @unknown default:
            launchAtLoginMenuItem.title = "Launch at Login: Unknown"
            launchAtLoginMenuItem.state = .off
        }
    }

    private func launchAtLoginSummaryTitle() -> String {
        switch SMAppService.mainApp.status {
        case .enabled:
            "Launch at Login: On"
        case .requiresApproval:
            "Launch at Login: Needs Approval"
        case .notRegistered:
            "Launch at Login: Off"
        case .notFound:
            "Launch at Login: Unavailable"
        @unknown default:
            "Launch at Login: Unknown"
        }
    }

    private func refreshLastTranscriptPreview() {
        guard !lastTranscript.isEmpty else {
            lastTranscriptPreviewMenuItem.title = "Last: None"
            return
        }

        lastTranscriptPreviewMenuItem.title = "Last: \(truncatedTranscriptPreview(lastTranscript))"
    }

    private func truncatedTranscriptPreview(_ transcript: String) -> String {
        let maxLength = 72
        guard transcript.count > maxLength else {
            return transcript
        }

        return String(transcript.prefix(maxLength - 3)) + "..."
    }

    private func showTransientStatus(_ title: String) {
        guard case .idle = state else {
            return
        }

        let token = UUID()
        transientStatusToken = token
        statusMenuItem.title = title
        statusItem?.button?.toolTip = "Glyph: \(title)"

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            guard transientStatusToken == token, case .idle = state else {
                return
            }

            transientStatusToken = nil
            updateStatus()
        }
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
            state = .recording
            startWaveformHUD()
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
        let recorderDuration = recorder.currentTime
        let wallClockDuration = recordingStartedAt.map { Date().timeIntervalSince($0) } ?? 0
        let duration = max(recorderDuration, wallClockDuration)
        recorder.stop()
        self.recorder = nil
        recordingStartedAt = nil
        stopWaveformHUD()

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
            refreshLastTranscriptPreview()
            do {
                try await injectIntoGhostty(transcript)
                state = .idle
                showTransientStatus(autoSubmitEnabled ? "Submitted to Codex" : "Sent to Ghostty")
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
            showTransientStatus(autoSubmitEnabled ? "Submitted to Codex" : "Sent to Ghostty")
        } catch {
            state = .error(error.localizedDescription)
        }
    }

    private func injectIntoGhostty(_ text: String) async throws {
        state = .injecting
        let shouldSubmit = autoSubmitEnabled
        try await Task.detached(priority: .userInitiated) {
            try GhosttyInjector().inject(text, submit: shouldSubmit)
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

    private func startWaveformHUD() {
        waveformTimer?.invalidate()
        waveformHUD.show()
        if let recorder {
            waveformHUD.update(from: recorder)
        }

        waveformTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let recorder = self.recorder else {
                    return
                }

                self.waveformHUD.update(from: recorder)
            }
        }
    }

    private func stopWaveformHUD() {
        waveformTimer?.invalidate()
        waveformTimer = nil
        waveformHUD.hide()
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

    private func removeTemporaryRecording(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }
}

private enum GlyphMenuBarIcon {
    enum Style {
        case idle
        case recording
        case transcribing
        case error
    }

    static func makeImage(style: Style) -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size)

        image.lockFocus()
        defer {
            image.unlockFocus()
            image.isTemplate = true
        }

        NSColor.black.setStroke()

        let badge = NSBezierPath(
            roundedRect: NSRect(x: 1.25, y: 1.25, width: 15.5, height: 15.5),
            xRadius: 3.8,
            yRadius: 3.8
        )
        NSColor.black.setFill()
        badge.fill()

        switch style {
        case .idle:
            drawCutoutLine(from: NSPoint(x: 6.6, y: 5.1), to: NSPoint(x: 11.5, y: 9), lineWidth: 2.5)
            drawCutoutLine(from: NSPoint(x: 11.5, y: 9), to: NSPoint(x: 6.6, y: 12.9), lineWidth: 2.5)
        case .recording:
            drawCutoutCircle(center: NSPoint(x: 9, y: 9), radius: 3.2)
        case .transcribing:
            drawCutoutLine(from: NSPoint(x: 5.2, y: 6.3), to: NSPoint(x: 12.8, y: 6.3), lineWidth: 2.1)
            drawCutoutLine(from: NSPoint(x: 5.2, y: 9), to: NSPoint(x: 12.8, y: 9), lineWidth: 2.1)
            drawCutoutLine(from: NSPoint(x: 5.2, y: 11.7), to: NSPoint(x: 12.8, y: 11.7), lineWidth: 2.1)
        case .error:
            drawCutoutLine(from: NSPoint(x: 9, y: 5.4), to: NSPoint(x: 9, y: 10.5), lineWidth: 2.3)
            drawCutoutCircle(center: NSPoint(x: 9, y: 13), radius: 1.2)
        }

        return image
    }

    private static func drawCutoutCircle(center: NSPoint, radius: CGFloat) {
        let path = NSBezierPath(
            ovalIn: NSRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2,
                height: radius * 2
            )
        )
        cutout(path)
    }

    private static func drawCutoutLine(from start: NSPoint, to end: NSPoint, lineWidth: CGFloat) {
        let path = NSBezierPath()
        path.lineWidth = lineWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.move(to: start)
        path.line(to: end)
        cutout(path)
    }

    private static func cutout(_ path: NSBezierPath) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current?.compositingOperation = .destinationOut
        NSColor.black.set()
        path.fill()
        path.stroke()
        NSGraphicsContext.restoreGraphicsState()
    }
}

private struct PermissionStatus {
    var shortcutAllowed: Bool
    var microphoneAllowed: Bool
    var microphoneTitle: String

    var shortcutTitle: String {
        shortcutAllowed ? "Shortcut: Allowed" : "Shortcut: Missing"
    }

    var summaryTitle: String {
        if shortcutAllowed && microphoneAllowed {
            return "Permissions: Allowed"
        }

        return "\(shortcutTitle), \(microphoneTitle)"
    }

    static func current(shortcutAllowed: Bool) -> PermissionStatus {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            PermissionStatus(
                shortcutAllowed: shortcutAllowed,
                microphoneAllowed: true,
                microphoneTitle: "Microphone: Allowed"
            )
        case .undetermined:
            PermissionStatus(
                shortcutAllowed: shortcutAllowed,
                microphoneAllowed: false,
                microphoneTitle: "Microphone: Not Requested"
            )
        case .denied:
            PermissionStatus(
                shortcutAllowed: shortcutAllowed,
                microphoneAllowed: false,
                microphoneTitle: "Microphone: Missing"
            )
        @unknown default:
            PermissionStatus(
                shortcutAllowed: shortcutAllowed,
                microphoneAllowed: false,
                microphoneTitle: "Microphone: Unknown"
            )
        }
    }
}
