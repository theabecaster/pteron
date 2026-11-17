import SwiftUI
import UIKit

struct TermTheme: Identifiable, Decodable, Equatable {
    var id: String
    var name: String
    var appearance: String
    var background: String
    var foreground: String
    var cursor: String
    var selectionBackground: String
    var ansi: [String]

    var isDark: Bool { appearance != "light" }
    var bg: Color { Color(hex: background) }
    var fg: Color { Color(hex: foreground) }
    var accent: Color { Color(hex: cursor) }
    var uiBG: UIColor { UIColor(hex: background) }
    var uiFG: UIColor { UIColor(hex: foreground) }
    var uiCursor: UIColor { UIColor(hex: cursor) }
    var uiSelection: UIColor { UIColor(hex: selectionBackground).withAlphaComponent(0.55) }

    func ansiColor(_ i: Int) -> Color { Color(hex: ansi[safe: i] ?? foreground) }

    /// Chrome colors derived from the terminal theme, the way Rex's "blend theme" interface style does.
    var chrome: Chrome { Chrome(theme: self) }

    struct Chrome {
        let theme: TermTheme
        var sidebar: Color { theme.bg.mix(with: theme.isDark ? .black : .white, by: theme.isDark ? 0.18 : 0.04) }
        var canvas: Color { theme.bg.mix(with: theme.isDark ? .black : .white, by: theme.isDark ? 0.28 : 0.08) }
        var rowSelected: Color { theme.fg.opacity(theme.isDark ? 0.12 : 0.10) }
        var secondary: Color { theme.fg.opacity(0.55) }
        var tertiary: Color { theme.fg.opacity(0.35) }
        var divider: Color { theme.fg.opacity(0.10) }
        var activeBorder: Color { theme.accent }
        var working: Color { theme.ansiColor(4) }
        var blocked: Color { theme.ansiColor(3) }
        var done: Color { theme.ansiColor(2) }
        var error: Color { theme.ansiColor(1) }
    }
}

enum ThemeStore {
    static let all: [TermTheme] = {
        guard let url = Bundle.main.url(forResource: "themes", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let list = try? JSONDecoder().decode([TermTheme].self, from: data), !list.isEmpty else {
            return [fallback]
        }
        return list
    }()

    static let fallback = TermTheme(id: "github-dark-dimmed", name: "GitHub Dark Dimmed", appearance: "dark",
                                    background: "#22272e", foreground: "#adbac7", cursor: "#539bf5",
                                    selectionBackground: "#3d4e63",
                                    ansi: ["#545d68", "#f47067", "#57ab5a", "#c69026", "#539bf5", "#b083f0", "#39c5cf", "#909dab",
                                           "#636e7b", "#ff938a", "#6bc46d", "#daaa3f", "#6cb6ff", "#dcbdfb", "#56d4dd", "#cdd9e5"])

    static func theme(_ id: String) -> TermTheme { all.first { $0.id == id } ?? all.first ?? fallback }
}

enum RexFont {
    static func ui(_ size: CGFloat, bold: Bool = false) -> UIFont {
        UIFont(name: bold ? "MesloLGS-NF-Bold" : "MesloLGS-NF-Regular", size: size)
            ?? UIFont.monospacedSystemFont(ofSize: size, weight: bold ? .bold : .regular)
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

extension UIColor {
    convenience init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        if s.count == 3 {
            let r = (v >> 8) & 0xf, g = (v >> 4) & 0xf, b = v & 0xf
            self.init(red: CGFloat(r * 17) / 255, green: CGFloat(g * 17) / 255, blue: CGFloat(b * 17) / 255, alpha: 1)
        } else {
            self.init(red: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255,
                      blue: CGFloat(v & 0xff) / 255, alpha: 1)
        }
    }
}

extension Color {
    init(hex: String) { self.init(uiColor: UIColor(hex: hex)) }

    func mix(with other: Color, by t: CGFloat) -> Color {
        let a = UIColor(self), b = UIColor(other)
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        a.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        b.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return Color(red: r1 + (r2 - r1) * t, green: g1 + (g2 - g1) * t, blue: b1 + (b2 - b1) * t)
    }
}
