import AppKit
import AVFoundation

@MainActor
final class RecordingWaveformHUD {
    private let panel: NSPanel
    private let waveformView = RecordingWaveformView()

    init() {
        let frame = NSRect(x: 0, y: 0, width: 360, height: 96)
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
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        let materialView = NSVisualEffectView(frame: frame)
        materialView.material = .hudWindow
        materialView.blendingMode = .behindWindow
        materialView.state = .active
        materialView.wantsLayer = true
        materialView.layer?.cornerRadius = 24
        materialView.layer?.masksToBounds = true

        waveformView.frame = materialView.bounds
        waveformView.autoresizingMask = [.width, .height]
        materialView.addSubview(waveformView)
        panel.contentView = materialView
    }

    func show() {
        position()
        waveformView.reset()
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
    private static let barCount = 34
    private var levels = Array(repeating: CGFloat(0.08), count: barCount)
    private var smoothedLevel: CGFloat = 0.08

    override var isFlipped: Bool {
        true
    }

    func reset() {
        levels = Array(repeating: CGFloat(0.08), count: Self.barCount)
        smoothedLevel = 0.08
        needsDisplay = true
    }

    func push(averagePower: Float, peakPower: Float) {
        let average = normalizedPower(averagePower)
        let peak = normalizedPower(peakPower)
        let target = max(0.08, min(1, average * 0.72 + peak * 0.28))
        smoothedLevel = smoothedLevel * 0.68 + target * 0.32
        levels.removeFirst()
        levels.append(smoothedLevel)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let bounds = bounds.insetBy(dx: 20, dy: 18)
        drawRecordingLabel(in: bounds)
        drawBars(in: NSRect(x: bounds.minX, y: bounds.minY + 30, width: bounds.width, height: bounds.height - 30))
    }

    private func drawRecordingLabel(in rect: NSRect) {
        NSColor(calibratedWhite: 1, alpha: 0.92).setFill()
        NSBezierPath(ovalIn: NSRect(x: rect.minX, y: rect.minY + 3, width: 8, height: 8)).fill()

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
        let barWidth: CGFloat = 5
        let gap = max(3, (rect.width - CGFloat(levels.count) * barWidth) / CGFloat(levels.count - 1))
        let centerY = rect.midY
        let maxHeight = rect.height

        for (index, level) in levels.enumerated() {
            let x = rect.minX + CGFloat(index) * (barWidth + gap)
            let shaped = pow(level, 0.72)
            let height = max(8, maxHeight * shaped)
            let barRect = NSRect(x: x, y: centerY - height / 2, width: barWidth, height: height)
            let path = NSBezierPath(roundedRect: barRect, xRadius: barWidth / 2, yRadius: barWidth / 2)

            let distance = abs(CGFloat(index) - CGFloat(levels.count - 1))
            let freshness = max(0.30, 1 - distance / CGFloat(levels.count))
            NSColor(calibratedRed: 0.62, green: 0.70, blue: 1.00, alpha: 0.42 + freshness * 0.48).setFill()
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
