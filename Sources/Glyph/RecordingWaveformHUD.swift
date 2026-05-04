import AppKit
import AVFAudio

@MainActor
final class RecordingWaveformHUD {
    private let panel: NSPanel
    private let waveformView = RecordingWaveformView()

    init() {
        let frame = NSRect(x: 0, y: 0, width: 420, height: 108)
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

        let containerView = NSView(frame: frame)
        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = NSColor(calibratedWhite: 0.06, alpha: 0.94).cgColor
        containerView.layer?.borderColor = NSColor(calibratedWhite: 1, alpha: 0.12).cgColor
        containerView.layer?.borderWidth = 1
        containerView.layer?.cornerRadius = 16
        containerView.layer?.masksToBounds = true

        waveformView.frame = containerView.bounds
        waveformView.autoresizingMask = [.width, .height]
        containerView.addSubview(waveformView)
        panel.contentView = containerView
    }

    func show() {
        position()
        waveformView.reset()
        panel.level = .statusBar
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
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
            y: screenFrame.maxY - size.height - 52
        )
        panel.setFrameOrigin(origin)
    }
}

private final class RecordingWaveformView: NSView {
    private static let barCount = 36
    private var levels = Array(repeating: CGFloat(0.05), count: barCount)
    private var smoothedLevel: CGFloat = 0.05
    private var nextLevelIndex = 0

    override var isFlipped: Bool {
        true
    }

    func reset() {
        levels = Array(repeating: CGFloat(0.05), count: Self.barCount)
        smoothedLevel = 0.05
        nextLevelIndex = 0
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

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let bounds = bounds.insetBy(dx: 22, dy: 18)
        drawRecordingLabel(in: bounds)
        drawBars(in: NSRect(x: bounds.minX, y: bounds.minY + 32, width: bounds.width, height: bounds.height - 34))
    }

    private func drawRecordingLabel(in rect: NSRect) {
        NSColor(calibratedRed: 0.50, green: 0.86, blue: 0.66, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: rect.minX, y: rect.minY + 4, width: 9, height: 9)).fill()

        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor(calibratedWhite: 1, alpha: 0.90)
        ]
        NSString(string: "Recording").draw(
            at: NSPoint(x: rect.minX + 16, y: rect.minY - 1),
            withAttributes: attributes
        )
    }

    private func drawBars(in rect: NSRect) {
        let barWidth: CGFloat = 4
        let gap = max(4, (rect.width - CGFloat(levels.count) * barWidth) / CGFloat(levels.count - 1))
        let centerY = rect.midY
        let maxHeight = rect.height

        for index in levels.indices {
            let level = levels[(nextLevelIndex + index) % levels.count]
            let x = rect.minX + CGFloat(index) * (barWidth + gap)
            let shaped = pow(level, 0.64)
            let height = max(6, maxHeight * shaped)
            let barRect = NSRect(x: x, y: centerY - height / 2, width: barWidth, height: height)
            let path = NSBezierPath(roundedRect: barRect, xRadius: barWidth / 2, yRadius: barWidth / 2)

            let distance = abs(CGFloat(index) - CGFloat(levels.count - 1))
            let freshness = max(0.34, 1 - distance / CGFloat(levels.count))
            NSColor(calibratedRed: 0.50, green: 0.76, blue: 1.00, alpha: 0.38 + freshness * 0.54).setFill()
            path.fill()
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
