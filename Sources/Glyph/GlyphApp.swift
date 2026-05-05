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
    private static let minimumRecordingDuration: TimeInterval = 0.35
    private static let autoSubmitDefaultsKey = "autoSubmitEnabled"
    private static let permissionOnboardingShownDefaultsKey = "permissionOnboardingShown"

    private enum State {
        case idle
        case recording
        case transcribing
        case injecting
        case error(String)

        var menuSystemImage: String {
            switch self {
            case .idle:
                "checkmark.circle"
            case .recording:
                "record.circle"
            case .transcribing:
                "waveform"
            case .injecting:
                "paperplane"
            case .error:
                "exclamationmark.triangle"
            }
        }

        var menuTitle: String {
            switch self {
            case .idle:
                "Ready. Hold Right Option."
            case .recording:
                "Recording"
            case .transcribing:
                "Transcribing with whisper.cpp"
            case .injecting:
                "Sending to Ghostty"
            case .error(let message):
                message
            }
        }

        var iconStyle: GlyphMenuBarIcon.Style {
            switch self {
            case .idle:
                .idle
            case .recording:
                .recording
            case .transcribing, .injecting:
                .transcribing
            case .error:
                .error
            }
        }

        var allowsTransientStatus: Bool {
            if case .idle = self {
                return true
            }

            return false
        }
    }

    private let settings = WhisperSettings.defaults()
    private let userDefaults = UserDefaults.standard
    private var statusItem: NSStatusItem?
    private let idleStatusIcon = GlyphMenuBarIcon.makeImage(style: .idle)
    private let recordingStatusIcon = GlyphMenuBarIcon.makeImage(style: .recording)
    private let transcribingStatusIcon = GlyphMenuBarIcon.makeImage(style: .transcribing)
    private let errorStatusIcon = GlyphMenuBarIcon.makeImage(style: .error)
    private var waveformHUD: RecordingWaveformHUD?
    private var sendLastMenuItem = NSMenuItem()
    private var copyLastMenuItem = NSMenuItem()
    private var lastTranscriptPreviewMenuItem = NSMenuItem()
    private var autoSubmitMenuItem = NSMenuItem()
    private var launchAtLoginMenuItem = NSMenuItem()
    private var permissionsMenuItem = NSMenuItem()
    private var statusMenuItem = NSMenuItem()
    private lazy var permissionOnboardingPanel = PermissionOnboardingPanel(
        target: self,
        accessibilityAction: #selector(openAccessibilitySettings),
        microphoneAction: #selector(openMicrophoneSettings),
        doneAction: #selector(closePermissionPanel)
    )
    private var eventMonitors: [Any] = []
    private var isRecordingChordDown = false
    private var waveformTimer: Timer?
    private let recordingSession = RecordingSession()
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
        prewarmGhosttyInjector()
        state = .idle
    }

    func applicationWillTerminate(_ notification: Notification) {
        for monitor in eventMonitors {
            NSEvent.removeMonitor(monitor)
        }
        recordingSession.cancel()
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
        openSystemSettingsPane("Privacy_Accessibility")
    }

    @objc private func openMicrophoneSettings() {
        openSystemSettingsPane("Privacy_Microphone")
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

        statusMenuItem = disabledMenuItem(title: "Ready. Hold Right Option.")

        lastTranscriptPreviewMenuItem = disabledMenuItem(title: "Last: None", systemImage: "text.quote")

        sendLastMenuItem = actionMenuItem(
            title: "Send Last Transcript",
            action: #selector(injectLastTranscript),
            systemImage: "paperplane"
        )
        sendLastMenuItem.isEnabled = false

        copyLastMenuItem = actionMenuItem(
            title: "Copy Last Transcript",
            action: #selector(copyLastTranscript),
            systemImage: "doc.on.doc"
        )
        copyLastMenuItem.isEnabled = false

        autoSubmitMenuItem = actionMenuItem(
            title: "Auto-submit",
            action: #selector(toggleAutoSubmit),
            systemImage: "return"
        )

        launchAtLoginMenuItem = actionMenuItem(
            title: "Launch at Login",
            action: #selector(toggleLaunchAtLogin),
            systemImage: "power"
        )

        permissionsMenuItem = actionMenuItem(
            title: "Permissions",
            action: #selector(openPermissions),
            systemImage: "lock.shield"
        )

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

    private func disabledMenuItem(title: String, systemImage: String? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.image = systemImage.flatMap(MenuIcon.system)
        item.isEnabled = false
        return item
    }

    private func actionMenuItem(title: String, action: Selector, systemImage: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.image = MenuIcon.system(systemImage)
        return item
    }

    private func openSystemSettingsPane(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    private func updateStatus() {
        if !state.allowsTransientStatus {
            transientStatusToken = nil
        }

        statusItem?.button?.image = statusIcon(for: state)
        statusMenuItem.image = MenuIcon.system(state.menuSystemImage)
        statusMenuItem.title = state.menuTitle
        statusItem?.button?.toolTip = "Glyph: \(state.menuTitle)"

        sendLastMenuItem.isEnabled = !lastTranscript.isEmpty
        copyLastMenuItem.isEnabled = !lastTranscript.isEmpty
        refreshLastTranscriptPreview()
    }

    private func statusIcon(for state: State) -> NSImage {
        switch state.iconStyle {
        case .idle:
            idleStatusIcon
        case .recording:
            recordingStatusIcon
        case .transcribing:
            transcribingStatusIcon
        case .error:
            errorStatusIcon
        }
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

        permissionOnboardingPanel.show(status: status)
    }

    @objc private func closePermissionPanel() {
        permissionOnboardingPanel.close()
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
            try recordingSession.start()
            state = .recording
            startWaveformHUD()
        } catch {
            showOperationFailure(error, hudTitle: "Recording Failed")
        }
    }

    private func stopRecording() {
        guard let result = recordingSession.stop(minimumDuration: Self.minimumRecordingDuration) else {
            state = .idle
            return
        }

        switch result {
        case .tooShort(let audioURL):
            recordingSession.removeTemporaryRecording(audioURL)
            stopWaveformHUD()
            state = .idle
        case .ready(let audioURL):
            state = .transcribing
            startWaveformProcessingHUD()

            Task {
                await transcribeAndInject(audioURL)
            }
        }
    }

    private func transcribeAndInject(_ audioURL: URL) async {
        let settings = settings
        defer {
            recordingSession.removeTemporaryRecording(audioURL)
        }

        do {
            let transcript = try await Task.detached(priority: .userInitiated) {
                try WhisperTranscriber(settings: settings).transcribe(audioFile: audioURL)
            }.value

            lastTranscript = transcript
            refreshLastTranscriptPreview()

            do {
                try await injectIntoGhostty(transcript)
                finishGhosttyInjection()
            } catch {
                showOperationFailure(error, hudTitle: "Send Failed")
            }
        } catch {
            showOperationFailure(error, hudTitle: "Transcription Failed")
        }
    }

    private func injectLastTranscriptIntoGhostty() async {
        do {
            startWaveformProcessingHUD()
            try await injectIntoGhostty(lastTranscript)
            finishGhosttyInjection()
        } catch {
            showOperationFailure(error, hudTitle: "Send Failed")
        }
    }

    private func finishGhosttyInjection() {
        stopWaveformHUD()
        state = .idle
        showTransientStatus(autoSubmitEnabled ? "Submitted to Codex" : "Sent to Ghostty")
    }

    private func showOperationFailure(_ error: Error, hudTitle: String) {
        stopWaveformTimer()
        state = .error(error.localizedDescription)
        activeWaveformHUD().showError(hudTitle)
        hideHUDLater()
    }

    private func injectIntoGhostty(_ text: String) async throws {
        stopWaveformTimer()
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
        activeWaveformHUD().showRecording()
        startWaveformTimer()
    }

    private func startWaveformProcessingHUD() {
        waveformTimer?.invalidate()
        activeWaveformHUD().showTranscribing()
        startWaveformTimer()
    }

    private func activeWaveformHUD() -> RecordingWaveformHUD {
        if let waveformHUD {
            return waveformHUD
        }

        let waveformHUD = RecordingWaveformHUD()
        self.waveformHUD = waveformHUD
        return waveformHUD
    }

    private func startWaveformTimer() {
        let timer = Timer(
            timeInterval: 1.0 / 30.0,
            target: self,
            selector: #selector(updateWaveformFromTimer),
            userInfo: nil,
            repeats: true
        )
        timer.tolerance = 0.006
        RunLoop.main.add(timer, forMode: .common)
        waveformTimer = timer
    }

    @objc private func updateWaveformFromTimer(_ timer: Timer) {
        switch state {
        case .recording, .transcribing:
            waveformHUD?.advanceAnimation()
        case .idle, .injecting, .error:
            break
        }
    }

    private func stopWaveformHUD() {
        waveformTimer?.invalidate()
        waveformTimer = nil
        waveformHUD?.hide()
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

    private func prewarmGhosttyInjector() {
        let injector = ghosttyInjector
        Task.detached(priority: .utility) {
            try? injector.prepare()
        }
    }

}
