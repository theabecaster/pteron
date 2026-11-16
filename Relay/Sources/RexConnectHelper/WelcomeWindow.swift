import AppKit
import ServiceManagement

/// The one window: "it's running, turn on notifications on your iPhone", an Open at login
/// switch, and Quit. Plain AppKit (no SwiftUI) to keep the resident footprint small; the
/// window is freed when it closes.
@MainActor
final class WelcomeWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?

    private let statusDot = NSTextField(labelWithString: "●")
    private let statusLabel = NSTextField(labelWithString: "")
    private let loginSwitch = NSSwitch()
    private let approvalButton = NSButton(title: "Allow in System Settings…", target: nil, action: nil)

    init(dryRun: Bool) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 380, height: 10),
                              styleMask: [.titled, .closable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.title = "Rex Connect Helper"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true
        super.init(window: window)
        window.delegate = self
        window.contentView = makeContent(dryRun: dryRun)
        window.center()
        refreshLoginItem()
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    func present() {
        refreshLoginItem()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func setConnected(_ connected: Bool) {
        statusDot.textColor = connected ? .systemGreen : .systemOrange
        statusLabel.stringValue = connected ? "Connected to Rex on this Mac" : "Waiting for Rex to start…"
    }

    func windowWillClose(_ notification: Notification) { onClose?() }

    func windowDidBecomeKey(_ notification: Notification) { refreshLoginItem() }

    // MARK: Layout

    private func makeContent(dryRun: Bool) -> NSView {
        let background = NSVisualEffectView()
        background.material = .windowBackground
        background.blendingMode = .behindWindow
        background.state = .followsWindowActiveState

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant: 84).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 84).isActive = true

        let title = NSTextField(labelWithString: "Rex Connect is running")
        title.font = .systemFont(ofSize: 19, weight: .semibold)
        title.alignment = .center

        statusDot.font = .systemFont(ofSize: 9)
        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        let status = NSStackView(views: [statusDot, statusLabel])
        status.spacing = 5
        setConnected(false)

        let body = NSTextField(wrappingLabelWithString:
            "Open Rex Connect on your iPhone and turn on notifications. You'll get a push when an agent needs you or finishes.")
        body.font = .systemFont(ofSize: 13)
        body.alignment = .center
        body.textColor = .secondaryLabelColor
        body.preferredMaxLayoutWidth = 300

        var views: [NSView] = [icon, title, status, body]
        if let note = Self.note(dryRun: dryRun) {
            let n = NSTextField(wrappingLabelWithString: note)
            n.font = .systemFont(ofSize: 12, weight: .medium)
            n.textColor = .systemOrange
            n.alignment = .center
            n.preferredMaxLayoutWidth = 300
            views.append(n)
        }

        // Open at login row
        let loginLabel = NSTextField(labelWithString: "Open at login")
        loginLabel.font = .systemFont(ofSize: 13)
        loginSwitch.controlSize = .small
        loginSwitch.target = self
        loginSwitch.action = #selector(toggleLogin(_:))
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let loginRow = NSStackView(views: [loginLabel, spacer, loginSwitch])
        loginRow.distribution = .fill

        approvalButton.isBordered = false
        approvalButton.contentTintColor = .linkColor
        approvalButton.font = .systemFont(ofSize: 12)
        approvalButton.target = self
        approvalButton.action = #selector(openLoginItems)

        let box = NSStackView(views: [loginRow, approvalButton])
        box.orientation = .vertical
        box.alignment = .leading
        box.spacing = 4
        box.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        box.wantsLayer = true
        box.layer?.cornerRadius = 10
        box.layer?.backgroundColor = NSColor.quaternaryLabelColor.withAlphaComponent(0.08).cgColor
        loginRow.widthAnchor.constraint(equalTo: box.widthAnchor, constant: -28).isActive = true

        let quit = NSButton(title: "Quit", target: NSApp, action: #selector(NSApplication.terminate(_:)))
        quit.controlSize = .large
        let done = NSButton(title: "Done", target: self, action: #selector(closeWindow))
        done.controlSize = .large
        done.keyEquivalent = "\r"
        let buttonSpacer = NSView()
        buttonSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [quit, buttonSpacer, done])

        let stack = NSStackView(views: views + [box, buttons])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        stack.setCustomSpacing(14, after: icon)
        stack.setCustomSpacing(4, after: title)
        stack.setCustomSpacing(18, after: views[views.count - 1])
        stack.setCustomSpacing(18, after: box)
        stack.edgeInsets = NSEdgeInsets(top: 36, left: 28, bottom: 22, right: 28)
        stack.translatesAutoresizingMaskIntoConstraints = false

        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor),
            stack.topAnchor.constraint(equalTo: background.topAnchor),
            stack.bottomAnchor.constraint(equalTo: background.bottomAnchor),
            background.widthAnchor.constraint(equalToConstant: 380),
            box.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -56),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -56),
        ])
        return background
    }

    /// A warning shown under the text, if any.
    private static func note(dryRun: Bool) -> String? {
        if Bundle.main.bundlePath.contains("/AppTranslocation/") {
            return "Move Rex Connect Helper to your Applications folder, then open it again."
        }
        if dryRun { return "Dry run: pushes are logged, not sent." }
        return nil
    }

    // MARK: Actions

    private func refreshLoginItem() {
        loginSwitch.state = LoginItem.isEnabled || LoginItem.needsApproval ? .on : .off
        approvalButton.isHidden = !LoginItem.needsApproval
    }

    @objc private func toggleLogin(_ sender: NSSwitch) {
        LoginItem.set(sender.state == .on)
        refreshLoginItem()
    }

    @objc private func openLoginItems() { SMAppService.openSystemSettingsLoginItems() }

    @objc private func closeWindow() { window?.performClose(nil) }
}
