import AppKit
import ApplicationServices
import AVFAudio
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
    private static let permissionOnboardingShownDefaultsKey = "permissionOnboardingShown"
    private static let audioRecordingSettings: [String: Any] = [
        AVFormatIDKey: Int(kAudioFormatLinearPCM),
        AVSampleRateKey: 16_000,
        AVNumberOfChannelsKey: 1,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false
    ]

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
    private var permissionsMenuItem = NSMenuItem()
    private var statusMenuItem = NSMenuItem()
    private var permissionPanel: NSPanel?
    private var eventMonitors: [Any] = []
    private var isRecordingChordDown = false
    private var recorder: AVAudioRecorder?
    private var waveformTimer: Timer?
    private var recordingStartedAt: TimeInterval?
    private var lastTranscript = ""
    private var transientStatusToken: UUID?
    private let ghosttyInjector = GhosttyInjector()
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
        let permissions = requestAccessibilityIfNeeded()
        showPermissionOnboardingIfNeeded(permissions)
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

    @objc private func openPermissions() {
        let permissions = refreshPermissionStatus(promptAccessibility: false)
        if permissions.allAllowed {
            showTransientStatus("Permissions: Allowed")
        } else {
            showPermissionOnboardingIfNeeded(permissions, force: true)
        }
    }

    private func configureStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem?.button?.image = idleStatusIcon
        statusItem?.button?.imagePosition = .imageOnly
        statusItem?.button?.title = ""
        statusItem?.button?.toolTip = "Glyph"

        let menu = NSMenu(title: "Glyph")

        statusMenuItem = NSMenuItem(title: "Ready. Hold Right Option.", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false

        lastTranscriptPreviewMenuItem = NSMenuItem(title: "Last: None", action: nil, keyEquivalent: "")
        lastTranscriptPreviewMenuItem.image = MenuIcon.system("text.quote")
        lastTranscriptPreviewMenuItem.isEnabled = false

        sendLastMenuItem = NSMenuItem(
            title: "Send Last Transcript",
            action: #selector(injectLastTranscript),
            keyEquivalent: ""
        )
        sendLastMenuItem.target = self
        sendLastMenuItem.image = MenuIcon.system("paperplane")
        sendLastMenuItem.isEnabled = false

        copyLastMenuItem = NSMenuItem(
            title: "Copy Last Transcript",
            action: #selector(copyLastTranscript),
            keyEquivalent: ""
        )
        copyLastMenuItem.target = self
        copyLastMenuItem.image = MenuIcon.system("doc.on.doc")
        copyLastMenuItem.isEnabled = false

        autoSubmitMenuItem = NSMenuItem(
            title: "Auto-submit",
            action: #selector(toggleAutoSubmit),
            keyEquivalent: ""
        )
        autoSubmitMenuItem.target = self
        autoSubmitMenuItem.image = MenuIcon.system("return")

        launchAtLoginMenuItem = NSMenuItem(
            title: "Launch at Login",
            action: #selector(toggleLaunchAtLogin),
            keyEquivalent: ""
        )
        launchAtLoginMenuItem.target = self
        launchAtLoginMenuItem.image = MenuIcon.system("power")

        permissionsMenuItem = NSMenuItem(
            title: "Permissions",
            action: #selector(openPermissions),
            keyEquivalent: ""
        )
        permissionsMenuItem.target = self
        permissionsMenuItem.image = MenuIcon.system("lock.shield")

        let quitMenuItem = NSMenuItem(title: "Quit Glyph", action: #selector(quit), keyEquivalent: "q")
        quitMenuItem.target = self
        quitMenuItem.image = MenuIcon.system("xmark.circle")

        menu.addItem(statusMenuItem)
        menu.addItem(lastTranscriptPreviewMenuItem)
        menu.addItem(.separator())
        menu.addItem(sendLastMenuItem)
        menu.addItem(copyLastMenuItem)
        menu.addItem(.separator())
        menu.addItem(autoSubmitMenuItem)
        menu.addItem(launchAtLoginMenuItem)
        menu.addItem(permissionsMenuItem)
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
            statusMenuItem.image = MenuIcon.system("checkmark.circle")
            statusMenuItem.title = "Ready. Hold Right Option."
            statusItem?.button?.toolTip = "Glyph: Ready. Hold Right Option."
        case .recording:
            transientStatusToken = nil
            statusItem?.button?.image = recordingStatusIcon
            statusMenuItem.image = MenuIcon.system("record.circle")
            statusMenuItem.title = "Recording"
            statusItem?.button?.toolTip = "Glyph: Recording"
        case .transcribing:
            transientStatusToken = nil
            statusItem?.button?.image = transcribingStatusIcon
            statusMenuItem.image = MenuIcon.system("waveform")
            statusMenuItem.title = "Transcribing with whisper.cpp"
            statusItem?.button?.toolTip = "Glyph: Transcribing with whisper.cpp"
        case .injecting:
            transientStatusToken = nil
            statusItem?.button?.image = transcribingStatusIcon
            statusMenuItem.image = MenuIcon.system("paperplane")
            statusMenuItem.title = "Sending to Ghostty"
            statusItem?.button?.toolTip = "Glyph: Sending to Ghostty"
        case .error(let message):
            transientStatusToken = nil
            statusItem?.button?.image = errorStatusIcon
            statusMenuItem.image = MenuIcon.system("exclamationmark.triangle")
            statusMenuItem.title = message
            statusItem?.button?.toolTip = "Glyph: \(message)"
        }

        sendLastMenuItem.isEnabled = !lastTranscript.isEmpty
        copyLastMenuItem.isEnabled = !lastTranscript.isEmpty
        refreshLastTranscriptPreview()
    }

    private func requestAccessibilityIfNeeded() -> PermissionStatus {
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
        permissionsMenuItem.title = status.summaryTitle
        refreshPermissionMenuIcons(status)
        return status
    }

    private func refreshPermissionMenuIcons(_ status: PermissionStatus) {
        permissionsMenuItem.image = MenuIcon.system(status.allAllowed ? "lock.shield" : "exclamationmark.triangle")
    }

    private func showPermissionOnboardingIfNeeded(_ status: PermissionStatus, force: Bool = false) {
        guard !status.allAllowed else {
            return
        }
        guard force || !userDefaults.bool(forKey: Self.permissionOnboardingShownDefaultsKey) else {
            return
        }

        userDefaults.set(true, forKey: Self.permissionOnboardingShownDefaultsKey)

        if let permissionPanel, permissionPanel.isVisible {
            permissionPanel.orderFrontRegardless()
            return
        }

        let panelFrame = NSRect(x: 0, y: 0, width: 440, height: 260)
        let panel = NSPanel(
            contentRect: panelFrame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Glyph Permissions"
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.appearance = NSAppearance(named: .darkAqua)

        let contentView = NSVisualEffectView(frame: panelFrame)
        contentView.material = .hudWindow
        contentView.blendingMode = .behindWindow
        contentView.state = .active
        panel.contentView = contentView

        let titleLabel = NSTextField(labelWithString: "Finish Glyph Setup")
        titleLabel.frame = NSRect(x: 28, y: 198, width: 384, height: 24)
        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        titleLabel.textColor = NSColor(calibratedWhite: 1, alpha: 0.94)

        let subtitleLabel = NSTextField(wrappingLabelWithString: "Glyph needs these macOS permissions to hold Right Option, record, and send text into Ghostty.")
        subtitleLabel.frame = NSRect(x: 28, y: 154, width: 384, height: 40)
        subtitleLabel.font = .systemFont(ofSize: 13, weight: .regular)
        subtitleLabel.textColor = NSColor(calibratedWhite: 1, alpha: 0.70)

        let shortcutLabel = permissionLabel(
            title: status.shortcutTitle,
            frame: NSRect(x: 28, y: 112, width: 184, height: 24)
        )
        let microphoneLabel = permissionLabel(
            title: status.microphoneTitle,
            frame: NSRect(x: 228, y: 112, width: 184, height: 24)
        )

        let accessibilityButton = NSButton(title: "Accessibility", target: self, action: #selector(openAccessibilitySettings))
        accessibilityButton.frame = NSRect(x: 28, y: 56, width: 130, height: 32)
        accessibilityButton.bezelStyle = .rounded

        let microphoneButton = NSButton(title: "Microphone", target: self, action: #selector(openMicrophoneSettings))
        microphoneButton.frame = NSRect(x: 166, y: 56, width: 118, height: 32)
        microphoneButton.bezelStyle = .rounded

        let doneButton = NSButton(title: "Done", target: self, action: #selector(closePermissionPanel))
        doneButton.frame = NSRect(x: 312, y: 56, width: 100, height: 32)
        doneButton.bezelStyle = .rounded
        doneButton.keyEquivalent = "\r"

        for view in [titleLabel, subtitleLabel, shortcutLabel, microphoneLabel, accessibilityButton, microphoneButton, doneButton] {
            contentView.addSubview(view)
        }

        permissionPanel = panel
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func permissionLabel(title: String, frame: NSRect) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.frame = frame
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = NSColor(calibratedWhite: 1, alpha: 0.84)
        return label
    }

    @objc private func closePermissionPanel() {
        permissionPanel?.close()
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
            showPermissionOnboardingIfNeeded(refreshPermissionStatus(promptAccessibility: false), force: true)
            return
        }

        do {
            let url = try nextRecordingURL()
            let recorder = try AVAudioRecorder(url: url, settings: audioSettings())
            recorder.isMeteringEnabled = true
            recorder.prepareToRecord()
            recorder.record()
            self.recorder = recorder
            recordingStartedAt = ProcessInfo.processInfo.systemUptime
            state = .recording
            startWaveformHUD()
        } catch {
            state = .error(error.localizedDescription)
            waveformHUD.showError("Recording Failed")
            hideHUDLater()
        }
    }

    private func stopRecording() {
        guard let recorder else {
            state = .idle
            return
        }

        let audioURL = recorder.url
        let recorderDuration = recorder.currentTime
        let wallClockDuration = recordingStartedAt.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0
        let duration = max(recorderDuration, wallClockDuration)
        recorder.stop()
        self.recorder = nil
        recordingStartedAt = nil

        guard duration >= 0.35 else {
            removeTemporaryRecording(audioURL)
            stopWaveformHUD()
            state = .idle
            return
        }

        state = .transcribing
        waveformHUD.showTranscribing()

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
                stopWaveformHUD()
                state = .idle
                showTransientStatus(autoSubmitEnabled ? "Submitted to Codex" : "Sent to Ghostty")
            } catch {
                stopWaveformTimer()
                state = .error(error.localizedDescription)
                waveformHUD.showError("Send Failed")
                hideHUDLater()
            }
        } catch {
            stopWaveformTimer()
            state = .error(error.localizedDescription)
            waveformHUD.showError("Transcription Failed")
            hideHUDLater()
        }
    }

    private func injectLastTranscriptIntoGhostty() async {
        do {
            startWaveformProcessingHUD()
            try await injectIntoGhostty(lastTranscript)
            stopWaveformHUD()
            state = .idle
            showTransientStatus(autoSubmitEnabled ? "Submitted to Codex" : "Sent to Ghostty")
        } catch {
            stopWaveformTimer()
            state = .error(error.localizedDescription)
            waveformHUD.showError("Send Failed")
            hideHUDLater()
        }
    }

    private func injectIntoGhostty(_ text: String) async throws {
        state = .injecting
        let shouldSubmit = autoSubmitEnabled
        let injector = ghosttyInjector
        try await Task.detached(priority: .userInitiated) {
            try injector.inject(text, submit: shouldSubmit)
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
        waveformHUD.showRecording()
        if let recorder {
            waveformHUD.update(from: recorder)
        }

        startWaveformTimer()
    }

    private func startWaveformProcessingHUD() {
        waveformTimer?.invalidate()
        waveformHUD.showTranscribing()
        startWaveformTimer()
    }

    private func startWaveformTimer() {
        let timer = Timer(
            timeInterval: 1.0 / 24.0,
            target: self,
            selector: #selector(updateWaveformFromTimer),
            userInfo: nil,
            repeats: true
        )
        timer.tolerance = 0.01
        RunLoop.main.add(timer, forMode: .common)
        waveformTimer = timer
    }

    @objc private func updateWaveformFromTimer(_ timer: Timer) {
        switch state {
        case .recording:
            guard let recorder else {
                return
            }

            waveformHUD.update(from: recorder)
        case .transcribing, .injecting:
            waveformHUD.advanceAnimation()
        case .idle, .error:
            break
        }
    }

    private func stopWaveformHUD() {
        waveformTimer?.invalidate()
        waveformTimer = nil
        waveformHUD.hide()
    }

    private func stopWaveformTimer() {
        waveformTimer?.invalidate()
        waveformTimer = nil
    }

    private func hideHUDLater() {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.1))
            stopWaveformHUD()
        }
    }

    private func nextRecordingURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Glyph", isDirectory: true)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("recording-\(UUID().uuidString).wav")
    }

    private func audioSettings() -> [String: Any] {
        Self.audioRecordingSettings
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

        NSColor.black.setFill()
        NSColor.black.setStroke()

        switch style {
        case .idle:
            drawLine(from: NSPoint(x: 3.8, y: 6.7), to: NSPoint(x: 3.8, y: 11.3), lineWidth: 1.8)
            drawLine(from: NSPoint(x: 6.4, y: 4.8), to: NSPoint(x: 6.4, y: 13.2), lineWidth: 1.8)
            drawLine(from: NSPoint(x: 9, y: 3.7), to: NSPoint(x: 9, y: 14.3), lineWidth: 1.8)
            drawLine(from: NSPoint(x: 11.6, y: 5.3), to: NSPoint(x: 11.6, y: 12.7), lineWidth: 1.8)
            drawLine(from: NSPoint(x: 14.2, y: 6.9), to: NSPoint(x: 14.2, y: 11.1), lineWidth: 1.8)
        case .recording:
            drawCircle(center: NSPoint(x: 9, y: 9), radius: 3.9)
        case .transcribing:
            drawLine(from: NSPoint(x: 5.2, y: 6.3), to: NSPoint(x: 12.8, y: 6.3), lineWidth: 2.1)
            drawLine(from: NSPoint(x: 5.2, y: 9), to: NSPoint(x: 12.8, y: 9), lineWidth: 2.1)
            drawLine(from: NSPoint(x: 5.2, y: 11.7), to: NSPoint(x: 12.8, y: 11.7), lineWidth: 2.1)
        case .error:
            drawLine(from: NSPoint(x: 9, y: 5.4), to: NSPoint(x: 9, y: 10.5), lineWidth: 2.3)
            drawCircle(center: NSPoint(x: 9, y: 13), radius: 1.2)
        }

        return image
    }

    private static func drawCircle(center: NSPoint, radius: CGFloat) {
        let path = NSBezierPath(
            ovalIn: NSRect(
                x: center.x - radius,
                y: center.y - radius,
                width: radius * 2,
                height: radius * 2
            )
        )
        path.fill()
    }

    private static func drawLine(from start: NSPoint, to end: NSPoint, lineWidth: CGFloat) {
        let path = NSBezierPath()
        path.lineWidth = lineWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.move(to: start)
        path.line(to: end)
        path.stroke()
    }
}

private enum MenuIcon {
    static func system(_ name: String) -> NSImage? {
        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) else {
            return nil
        }

        image.isTemplate = true
        return image
    }
}

private struct PermissionStatus {
    var shortcutAllowed: Bool
    var microphoneAllowed: Bool
    var microphoneTitle: String

    var allAllowed: Bool {
        shortcutAllowed && microphoneAllowed
    }

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
