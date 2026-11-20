#if DEBUG
import Foundation

/// `-goTo anything|sessions|commands` (testing): opens the palette once the first tab shows,
/// as its key would, so a screenshot shows it. `-goToQuery <text>` types that text into it.
@MainActor
enum GoToDebug {
    private static var done = false

    static func launch(_ model: AppModel) {
        let d = UserDefaults.standard
        guard !done, let raw = d.string(forKey: "goTo") else { return }
        let scope: GoToScope
        switch raw {
        case "sessions": scope = .sessions
        case "commands": scope = .commands
        default: scope = .anything
        }
        done = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(2))
            model.perform(.goTo(scope))
            if let q = d.string(forKey: "goToQuery"), !q.isEmpty {
                try? await Task.sleep(for: .milliseconds(500))
                model.goTo?.typeForTesting(q)
            }
            // `-goToClose <seconds>`: closes it again, as Esc does, that long after it opened.
            let close = d.double(forKey: "goToClose")
            guard close > 0 else { return }
            try? await Task.sleep(for: .seconds(close))
            NSLog("GOTO_CLOSE")
            model.goTo?.dismiss()
        }
    }
}

extension GoToModel {
    /// Types `text` as the field would report it.
    func typeForTesting(_ text: String) {
        field?.text = text
        setQuery(text)
    }
}
#endif
