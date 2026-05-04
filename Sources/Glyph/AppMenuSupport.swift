import AppKit
import AVFAudio

@MainActor
enum GlyphMenuBarIcon {
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

@MainActor
enum MenuIcon {
    private static var cache: [String: NSImage] = [:]

    static func system(_ name: String) -> NSImage? {
        if let image = cache[name] {
            return image
        }

        guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil) else {
            return nil
        }

        image.isTemplate = true
        cache[name] = image
        return image
    }
}

struct PermissionStatus {
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
        if allAllowed {
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
