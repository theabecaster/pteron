#if DEBUG
import UIKit
import UniformTypeIdentifiers

/// `-filesTest '<step>;<step>…'` (Debug builds, testing): drives file sending in the active pane
/// once it is live, where the simulator can't tap through a picker. Steps run a second apart:
///
/// - `keyboard`: show the software keyboard and its key bar, even with a hardware keyboard.
/// - `menu`: open the attach menu.
/// - `send:<path>|<path>`: send these files (paths on the Mac running the simulator) as one batch,
///   prepared as Photos prepares them. `sendOriginal:` sends them untouched.
/// - `paste:<path>`: put this image on the clipboard alone, then Paste.
/// - `wait:<seconds>`: pause.
///
/// Use only with a throwaway `zz-` session: the files land on its computer and their paths are typed.
@MainActor
enum FilesTest {
    private static var ran = false

    static func run(on host: TerminalHost) {
        guard !ran, let script = UserDefaults.standard.string(forKey: "filesTest") else { return }
        ran = true
        let steps = script.split(separator: ";").map(String.init)
        Task { @MainActor [weak host] in
            try? await Task.sleep(for: .seconds(2))
            for step in steps {
                guard let host else { return }
                await perform(step, on: host)
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private static func perform(_ step: String, on host: TerminalHost) async {
        let (verb, arg) = step.firstIndex(of: ":").map { (String(step[..<$0]), String(step[step.index(after: $0)...])) } ?? (step, "")
        NSLog("FILES_TEST %@", step)
        switch verb {
        case "keyboard":
            host.hardwareKeyboard = { false }
            host.focusKeyboard()
        case "menu":
            host.openAttachMenu()
        case "send", "sendOriginal":
            let files = arg.split(separator: "|").compactMap { path -> StagedFile? in
                let url = URL(fileURLWithPath: String(path))
                guard let f = try? FileStaging.stage(copying: url, as: url.lastPathComponent) else { return nil }
                return f
            }
            host.files?.send(files)
        case "paste":
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: arg)) else { return }
            let type = UTType(filenameExtension: (arg as NSString).pathExtension) ?? .png
            UIPasteboard.general.items = [[type.identifier: data]]
            host.pasteFromClipboard()
        case "wait":
            try? await Task.sleep(for: .seconds(Double(arg) ?? 1))
        default:
            NSLog("FILES_TEST unknown step %@", step)
        }
    }
}
#endif
