import AppKit
import AVFAudio

@MainActor
final class RecordingWaveformHUD {
    private let panel: NSPanel
    private let containerView: NSVisualEffectView
    private let waveformView = RecordingWaveformView()

    init() {
        let frame = NSRect(x: 0, y: 0, width: 390, height: 104)
        panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        containerView = NSVisualEffectView(frame: frame)
        containerView.material = .hudWindow
        containerView.blendingMode = .behindWindow
        containerView.state = .active
        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = NSColor(calibratedWhite: 0.05, alpha: 0.76).cgColor
        containerView.layer?.borderColor = NSColor(calibratedWhite: 1, alpha: 0.16).cgColor
        containerView.layer?.borderWidth = 1
        containerView.layer?.cornerRadius = 22
        containerView.layer?.masksToBounds = true

        waveformView.frame = containerView.bounds
        waveformView.autoresizingMask = [.width, .height]
        containerView.addSubview(waveformView)
        panel.contentView = containerView
    }

    func showRecording() {
        position()
        waveformView.reset()
        waveformView.phase = .recording
        showPanel()
    }

    func showTranscribing() {
        position()
        waveformView.setProcessingPattern()
        waveformView.phase = .transcribing
        showPanel()
    }

    func showResult(_ title: String) {
        position()
        waveformView.setResultPattern()
        waveformView.phase = .result(title)
        showPanel()
    }

    func showError(_ title: String) {
        position()
        waveformView.setErrorPattern()
        waveformView.phase = .error(title)
        showPanel()
    }

    private func showPanel() {
        panel.level = .statusBar
        let shouldFadeIn = !panel.isVisible
        if shouldFadeIn {
            panel.alphaValue = 0
        }
        panel.orderFrontRegardless()
        if shouldFadeIn {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.14
                panel.animator().alphaValue = 1
            }
        } else {
            panel.alphaValue = 1
        }
    }

    func update(from recorder: AVAudioRecorder) {
        recorder.updateMeters()
        waveformView.push(
            averagePower: recorder.averagePower(forChannel: 0),
            peakPower: recorder.peakPower(forChannel: 0)
        )
    }

    func hide() {
        guard panel.isVisible else {
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.10
            panel.animator().alphaValue = 0
        } completionHandler: {
            Task { @MainActor in
                self.panel.orderOut(nil)
                self.waveformView.reset()
            }
        }
    }

    private func position() {
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = panel.frame.size
        let origin = NSPoint(
            x: screenFrame.midX - size.width / 2,
            y: screenFrame.minY + 52
        )
        panel.setFrameOrigin(origin)
    }
}

private final class RecordingWaveformView: NSView {
    enum Phase {
        case recording
        case transcribing
        case result(String)
        case error(String)
    }

    private static let barCount = 36
    private var levels = Array(repeating: CGFloat(0.05), count: barCount)
    private var smoothedLevel: CGFloat = 0.05
    private var nextLevelIndex = 0
    var phase = Phase.recording {
        didSet {
            needsDisplay = true
        }
    }

    override var isFlipped: Bool {
        true
    }

    func reset() {
        levels = Array(repeating: CGFloat(0.05), count: Self.barCount)
        smoothedLevel = 0.05
        nextLevelIndex = 0
        phase = .recording
        needsDisplay = true
    }

    func push(averagePower: Float, peakPower: Float) {
        let average = normalizedPower(averagePower)
        let peak = normalizedPower(peakPower)
        let target = max(0.05, min(1, average * 0.62 + peak * 0.38))
        smoothedLevel = smoothedLevel * 0.62 + target * 0.38
        levels[nextLevelIndex] = smoothedLevel
        nextLevelIndex = (nextLevelIndex + 1) % levels.count
        needsDisplay = true
    }

    func setProcessingPattern() {
        levels = levels.indices.map { index in
            let progress = CGFloat(index) / CGFloat(max(1, levels.count - 1))
            return 0.24 + 0.42 * abs(sin(progress * .pi * 2.4))
        }
        nextLevelIndex = 0
        needsDisplay = true
    }

    func setResultPattern() {
        levels = levels.indices.map { index in
            let progress = CGFloat(index) / CGFloat(max(1, levels.count - 1))
            return 0.18 + 0.32 * sin(progress * .pi)
        }
        nextLevelIndex = 0
        needsDisplay = true
    }

    func setErrorPattern() {
        levels = Array(repeating: CGFloat(0.22), count: Self.barCount)
        nextLevelIndex = 0
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let bounds = bounds.insetBy(dx: 24, dy: 18)
        drawStatusLine(in: bounds)
        drawBars(in: NSRect(x: bounds.minX, y: bounds.minY + 34, width: bounds.width, height: bounds.height - 38))
    }

    private func drawStatusLine(in rect: NSRect) {
        let status = statusPresentation
        status.color.setFill()
        NSBezierPath(ovalIn: NSRect(x: rect.minX, y: rect.minY + 4, width: 9, height: 9)).fill()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor(calibratedWhite: 1, alpha: 0.90)
        ]
        NSString(string: status.title).draw(
            at: NSPoint(x: rect.minX + 16, y: rect.minY - 1),
            withAttributes: attributes
        )
    }

    private var statusPresentation: (title: String, color: NSColor) {
        switch phase {
        case .recording:
            ("Recording", NSColor(calibratedRed: 0.46, green: 0.92, blue: 0.63, alpha: 1))
        case .transcribing:
            ("Transcribing", NSColor(calibratedRed: 0.46, green: 0.72, blue: 1.00, alpha: 1))
        case .result(let title):
            (title, NSColor(calibratedRed: 0.58, green: 0.94, blue: 0.74, alpha: 1))
        case .error(let title):
            (title, NSColor(calibratedRed: 1.00, green: 0.42, blue: 0.42, alpha: 1))
        }
    }

    private func drawBars(in rect: NSRect) {
        let barWidth: CGFloat = 4
        let gap = max(4, (rect.width - CGFloat(levels.count) * barWidth) / CGFloat(levels.count - 1))
        let centerY = rect.midY
        let maxHeight = rect.height
        let color = waveformColor

        for index in levels.indices {
            let level = levels[(nextLevelIndex + index) % levels.count]
            let x = rect.minX + CGFloat(index) * (barWidth + gap)
            let shaped = pow(level, 0.64)
            let height = max(6, maxHeight * shaped)
            let barRect = NSRect(x: x, y: centerY - height / 2, width: barWidth, height: height)
            let path = NSBezierPath(roundedRect: barRect, xRadius: barWidth / 2, yRadius: barWidth / 2)

            let distance = abs(CGFloat(index) - CGFloat(levels.count - 1))
            let freshness = max(0.34, 1 - distance / CGFloat(levels.count))
            color.withAlphaComponent(0.34 + freshness * 0.58).setFill()
            path.fill()
        }
    }

    private var waveformColor: NSColor {
        switch phase {
        case .recording:
            NSColor(calibratedRed: 0.50, green: 0.76, blue: 1.00, alpha: 1)
        case .transcribing:
            NSColor(calibratedRed: 0.70, green: 0.58, blue: 1.00, alpha: 1)
        case .result:
            NSColor(calibratedRed: 0.56, green: 0.92, blue: 0.72, alpha: 1)
        case .error:
            NSColor(calibratedRed: 1.00, green: 0.48, blue: 0.48, alpha: 1)
        }
    }

    private func normalizedPower(_ power: Float) -> CGFloat {
        guard power.isFinite else {
            return 0
        }

        let clamped = max(-58, min(0, power))
        return CGFloat((clamped + 58) / 58)
    }
}
