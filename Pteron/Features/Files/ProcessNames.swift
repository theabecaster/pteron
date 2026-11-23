import Foundation
import RexKit

/// Names of foreground programs, as the server reports them, and what a name says about a pane.
enum ProcessNames {
    /// Shells. One in the foreground owns the terminal: it is at its prompt, a `read` or a builtin.
    static let shells: Set<String> = ["sh", "bash", "zsh", "fish", "dash", "ksh", "mksh"]

    /// Programs that put the pane's real work somewhere else: another machine, a multiplexer or a
    /// container. Folders listed for the pane are then not the ones its program sees.
    static let remoteWrappers: Set<String> = [
        "ssh", "autossh", "mosh", "mosh-client", "et", "tmux", "screen", "docker", "podman", "kubectl", "lxc", "incus",
        "nsenter", "toolbox",
    ]

    static func isShell(_ program: String) -> Bool { shells.contains(program.lowercased()) }

    /// distrobox reports the name of its script (`distrobox-enter`), so it is told by its prefix.
    static func isRemoteWrapper(_ program: String) -> Bool {
        let p = program.lowercased()
        return remoteWrappers.contains(p) || p.hasPrefix("distrobox")
    }

    /// The foreground program's name: its script, else the path it was started by, else its
    /// process name. Used to tell agents (`AgentKind.fromProgram`).
    static func label(_ fg: JSONObject) -> String {
        if let s = fg.str("script"), !s.isEmpty { return scriptLabel(s) }
        if let a = fg.str("invoked_path") ?? fg.str("argv0"), !a.isEmpty {
            return (a.trimmingCharacters(in: CharacterSet(charactersIn: "-")) as NSString).lastPathComponent
        }
        return fg.str("name") ?? ""
    }

    /// A script's file name, except for a generic entry point (`index.js`, `cli.js`, `main.js`,
    /// Python's `__main__.py` for `python -m`), which is named by the package that holds it:
    /// `cursor-agent/versions/<v>/index.js` is cursor-agent, `@anthropic-ai/claude-code/cli.js` is
    /// claude-code, `site-packages/aider/__main__.py` is aider.
    static func scriptLabel(_ path: String) -> String {
        let parts = path.split(separator: "/").map(String.init)
        guard let file = parts.last else { return "" }
        let stem = (file as NSString).deletingPathExtension.lowercased()
        let ext = (file as NSString).pathExtension.lowercased()
        let generic = (["index", "cli", "main", "entry"].contains(stem) && ["js", "mjs", "cjs", "ts"].contains(ext))
            || (stem == "__main__" && ext == "py")
        guard generic else { return file }
        let skipped: Set<String> = ["dist", "build", "lib", "bin", "src", "bundle", "out", "versions", "current",
                                    "node_modules", "package"]
        for dir in parts.dropLast().reversed() {
            let l = dir.lowercased()
            if skipped.contains(l) || l.hasPrefix("@") || l.first?.isNumber == true { continue }
            return dir
        }
        return file
    }
}
