import UIKit
import SwiftTerm

/// The row of extra keys above the software keyboard. Keys come from Prefs.keyBar.
@MainActor
final class KeyBar: UIInputView {
    weak var terminal: SwiftTerm.TerminalView?
    var onPaste: (() -> Void)?
    var onHideKeyboard: (() -> Void)?

    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private var ctrlButton: UIButton?
    private var altButton: UIButton?
    private var theme: TermTheme = ThemeStore.fallback
    private var ctrlOn = false { didSet { refreshToggles() } }
    private var altOn = false { didSet { refreshToggles() } }

    init() {
        super.init(frame: CGRect(x: 0, y: 0, width: 400, height: 46), inputViewStyle: .keyboard)
        allowsSelfSizing = true
        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        stack.axis = .horizontal
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        scroll.addSubview(stack)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 46),
            stack.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: 6),
            stack.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -6),
            stack.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor, constant: -12),
        ])
        rebuild()
        NotificationCenter.default.addObserver(self, selector: #selector(prefsChanged), name: .keyBarChanged, object: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func prefsChanged() { rebuild() }

    func apply(theme: TermTheme) {
        self.theme = theme
        rebuild()
    }

    private func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        ctrlButton = nil
        altButton = nil
        for key in Prefs.shared.keyBar {
            let b = makeButton(key)
            stack.addArrangedSubview(b)
            if key == "ctrl" { ctrlButton = b }
            if key == "alt" { altButton = b }
        }
        let hide = makeButton("hide")
        stack.addArrangedSubview(hide)
        refreshToggles()
    }

    private func makeButton(_ key: String) -> UIButton {
        var cfg = UIButton.Configuration.filled()
        cfg.cornerStyle = .medium
        cfg.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10)
        cfg.baseBackgroundColor = theme.uiFG.withAlphaComponent(theme.isDark ? 0.14 : 0.10)
        cfg.baseForegroundColor = theme.uiFG
        if let sym = Self.symbols[key] {
            cfg.image = UIImage(systemName: sym, withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .medium))
        } else {
            var t = AttributedString(Self.titles[key] ?? key)
            t.font = RexFont.ui(14)
            cfg.attributedTitle = t
        }
        let b = UIButton(configuration: cfg)
        b.accessibilityLabel = key
        b.addAction(UIAction { [weak self] _ in self?.press(key) }, for: .touchUpInside)
        b.setContentHuggingPriority(.required, for: .horizontal)
        return b
    }

    static let symbols: [String: String] = [
        "left": "arrow.left", "right": "arrow.right", "up": "arrow.up", "down": "arrow.down",
        "paste": "doc.on.clipboard", "hide": "keyboard.chevron.compact.down", "enter": "return",
        "tab": "arrow.right.to.line", "shift-tab": "arrow.left.to.line",
    ]
    static let titles: [String: String] = [
        "esc": "esc", "ctrl": "ctrl", "alt": "alt", "ctrl-c": "^C", "ctrl-d": "^D", "ctrl-z": "^Z", "ctrl-r": "^R",
        "ctrl-l": "^L", "pgup": "PgUp", "pgdn": "PgDn", "home": "Home", "end": "End",
    ]

    private func refreshToggles() {
        for (b, on) in [(ctrlButton, ctrlOn), (altButton, altOn)] {
            guard let b else { continue }
            var cfg = b.configuration
            cfg?.baseBackgroundColor = on ? theme.uiCursor : theme.uiFG.withAlphaComponent(theme.isDark ? 0.14 : 0.10)
            cfg?.baseForegroundColor = on ? theme.uiBG : theme.uiFG
            b.configuration = cfg
        }
    }

    /// Called after the terminal sent bytes, so one-shot modifiers turn off.
    func consumedModifiers() {
        if ctrlOn { ctrlOn = false; terminal?.controlModifier = false }
        if altOn { altOn = false; terminal?.metaModifier = false }
    }

    private func press(_ key: String) {
        if Prefs.shared.haptics { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        guard let t = terminal else { return }
        switch key {
        case "ctrl":
            ctrlOn.toggle(); t.controlModifier = ctrlOn
            return
        case "alt":
            altOn.toggle(); t.metaModifier = altOn
            return
        case "paste": onPaste?(); return
        case "hide": onHideKeyboard?(); return
        case "up" where !ctrlOn && !altOn: t.sendKeyUp(); return
        case "down" where !ctrlOn && !altOn: t.sendKeyDown(); return
        case "left" where !ctrlOn && !altOn: t.sendKeyLeft(); return
        case "right" where !ctrlOn && !altOn: t.sendKeyRight(); return
        case "home" where !ctrlOn && !altOn: t.sendKeyHome(); return
        case "end" where !ctrlOn && !altOn: t.sendKeyEnd(); return
        default: break
        }
        if let bytes = Self.bytes(for: key, appCursor: false) {
            var out = bytes
            if altOn { out = [0x1b] + out }
            if ctrlOn, out.count == 1, let c = out.first, c >= 0x40 {
                out = [c & 0x1f]
            }
            t.send(data: out[...])
            consumedModifiers()
        }
    }

    static func bytes(for key: String, appCursor: Bool) -> [UInt8]? {
        let csi: (String) -> [UInt8] = { Array("\u{1b}[\($0)".utf8) }
        switch key {
        case "esc": return [0x1b]
        case "tab": return [0x09]
        case "shift-tab": return csi("Z")
        case "enter": return [0x0d]
        case "up": return csi("A")
        case "down": return csi("B")
        case "right": return csi("C")
        case "left": return csi("D")
        case "home": return csi("H")
        case "end": return csi("F")
        case "pgup": return csi("5~")
        case "pgdn": return csi("6~")
        case "ctrl-c": return [0x03]
        case "ctrl-d": return [0x04]
        case "ctrl-z": return [0x1a]
        case "ctrl-r": return [0x12]
        case "ctrl-l": return [0x0c]
        case "f1": return Array("\u{1b}OP".utf8)
        case "f2": return Array("\u{1b}OQ".utf8)
        case "f3": return Array("\u{1b}OR".utf8)
        case "f4": return Array("\u{1b}OS".utf8)
        case "f5": return csi("15~")
        case "f6": return csi("17~")
        case "f7": return csi("18~")
        case "f8": return csi("19~")
        case "f9": return csi("20~")
        case "f10": return csi("21~")
        case "f11": return csi("23~")
        case "f12": return csi("24~")
        default: return Array(key.utf8)
        }
    }
}

extension Notification.Name {
    static let keyBarChanged = Notification.Name("RexDuo.keyBarChanged")
}
