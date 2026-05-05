import AppKit

@MainActor
final class RecordingWaveformHUD {
    private let panel: NSPanel
    private let containerView: NSView
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

        containerView = NSView(frame: frame)
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
        waveformView.setProcessingPattern()
        waveformView.phase = .recording
        showPanel()
    }

    func showTranscribing() {
        position()
        waveformView.setProcessingPattern()
        waveformView.phase = .transcribing
        showPanel()
    }

    func advanceAnimation() {
        waveformView.advanceAnimation()
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

    func hide() {
        guard panel.isVisible else {
            return
        }

        panel.alphaValue = 0
        panel.orderOut(nil)
        waveformView.reset()
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
        case error(String)
    }

    private static let barCount = 36
    private static let baselineLevel = CGFloat(0.18)
    private static let errorLevel = CGFloat(0.22)
    private let statusAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 13, weight: .medium),
        .foregroundColor: NSColor(calibratedWhite: 1, alpha: 0.90)
    ]
    private let recordingStatusColor = NSColor(calibratedRed: 0.46, green: 0.92, blue: 0.63, alpha: 1)
    private let transcribingStatusColor = NSColor(calibratedRed: 0.46, green: 0.72, blue: 1.00, alpha: 1)
    private let errorStatusColor = NSColor(calibratedRed: 1.00, green: 0.42, blue: 0.42, alpha: 1)
    private let recordingWaveformColor = NSColor(calibratedRed: 0.50, green: 0.76, blue: 1.00, alpha: 1)
    private let transcribingWaveformColor = NSColor(calibratedRed: 0.70, green: 0.58, blue: 1.00, alpha: 1)
    private let errorWaveformColor = NSColor(calibratedRed: 1.00, green: 0.48, blue: 0.48, alpha: 1)
    private var levels = Array(repeating: baselineLevel, count: barCount)
    private var processingFrame = 0
    var phase = Phase.recording {
        didSet {
            needsDisplay = true
        }
    }

    override var isFlipped: Bool {
        true
    }

    func reset() {
        fillLevels(with: Self.baselineLevel)
        processingFrame = 0
        phase = .recording
        needsDisplay = true
    }

    func setProcessingPattern() {
        processingFrame = 0
        updateProcessingPattern()
    }

    func advanceAnimation() {
        switch phase {
        case .recording, .transcribing, .error:
            processingFrame += 1
            updateProcessingPattern()
        }
    }

    private func updateProcessingPattern() {
        let frameOffset = CGFloat(processingFrame) * 0.28
        for index in levels.indices {
            let progress = CGFloat(index) / CGFloat(max(1, levels.count - 1))
            let primaryWave = abs(sin(progress * .pi * 2.4 + frameOffset))
            let secondaryWave = abs(sin(progress * .pi * 5.2 - frameOffset * 0.72))
            levels[index] = 0.18 + 0.34 * primaryWave + 0.16 * secondaryWave
        }
        needsDisplay = true
    }

    func setErrorPattern() {
        fillLevels(with: Self.errorLevel)
        needsDisplay = true
    }

    private func fillLevels(with value: CGFloat) {
        for index in levels.indices {
            levels[index] = value
        }
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

        NSString(string: status.title).draw(
            at: NSPoint(x: rect.minX + 16, y: rect.minY - 1),
            withAttributes: statusAttributes
        )
    }

    private var statusPresentation: (title: String, color: NSColor) {
        switch phase {
        case .recording:
            ("Recording", recordingStatusColor)
        case .transcribing:
            ("Transcribing", transcribingStatusColor)
        case .error(let title):
            (title, errorStatusColor)
        }
    }

    private func drawBars(in rect: NSRect) {
        let barWidth: CGFloat = 4
        let gap = max(4, (rect.width - CGFloat(levels.count) * barWidth) / CGFloat(levels.count - 1))
        let centerY = rect.midY
        let maxHeight = rect.height
        let color = waveformColor

        for index in levels.indices {
            let level = levels[index]
            let x = rect.minX + CGFloat(index) * (barWidth + gap)
            let shaped = pow(level, 0.62)
            let height = max(8, maxHeight * shaped)
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
            recordingWaveformColor
        case .transcribing:
            transcribingWaveformColor
        case .error:
            errorWaveformColor
        }
    }

}
