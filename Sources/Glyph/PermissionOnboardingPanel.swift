import AppKit

@MainActor
final class PermissionOnboardingPanel {
    private weak var target: AnyObject?
    private let accessibilityAction: Selector
    private let microphoneAction: Selector
    private let doneAction: Selector
    private var panel: NSPanel?

    init(
        target: AnyObject,
        accessibilityAction: Selector,
        microphoneAction: Selector,
        doneAction: Selector
    ) {
        self.target = target
        self.accessibilityAction = accessibilityAction
        self.microphoneAction = microphoneAction
        self.doneAction = doneAction
    }

    func show(status: PermissionStatus) {
        if let panel, panel.isVisible {
            panel.orderFrontRegardless()
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

        for view in contentViews(for: status) {
            contentView.addSubview(view)
        }

        self.panel = panel
        panel.center()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        panel?.close()
    }

    private func contentViews(for status: PermissionStatus) -> [NSView] {
        let titleLabel = NSTextField(labelWithString: "Finish Glyph Setup")
        titleLabel.frame = NSRect(x: 28, y: 198, width: 384, height: 24)
        titleLabel.font = .systemFont(ofSize: 20, weight: .semibold)
        titleLabel.textColor = NSColor(calibratedWhite: 1, alpha: 0.94)

        let subtitleLabel = NSTextField(
            wrappingLabelWithString: "Glyph needs these macOS permissions to hold Right Option, record, and send text into Ghostty."
        )
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

        let accessibilityButton = button(
            title: "Accessibility",
            action: accessibilityAction,
            frame: NSRect(x: 28, y: 56, width: 130, height: 32)
        )
        let microphoneButton = button(
            title: "Microphone",
            action: microphoneAction,
            frame: NSRect(x: 166, y: 56, width: 118, height: 32)
        )
        let doneButton = button(
            title: "Done",
            action: doneAction,
            frame: NSRect(x: 312, y: 56, width: 100, height: 32)
        )
        doneButton.keyEquivalent = "\r"

        return [
            titleLabel,
            subtitleLabel,
            shortcutLabel,
            microphoneLabel,
            accessibilityButton,
            microphoneButton,
            doneButton
        ]
    }

    private func button(title: String, action: Selector, frame: NSRect) -> NSButton {
        let button = NSButton(title: title, target: target, action: action)
        button.frame = frame
        button.bezelStyle = .rounded
        return button
    }

    private func permissionLabel(title: String, frame: NSRect) -> NSTextField {
        let label = NSTextField(labelWithString: title)
        label.frame = frame
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = NSColor(calibratedWhite: 1, alpha: 0.84)
        return label
    }
}
