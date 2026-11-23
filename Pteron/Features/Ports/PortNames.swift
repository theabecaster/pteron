import Foundation
import RexKit

/// How a port's row is named: by what runs ("Next.js", "Python"), then the folder it runs in.
/// Pure, so it is tested (docs/terminal.md, Ports).
enum PortNames {
    /// Programs with a name people know them by, keyed by the program's name in lower case
    /// without its extension and version. Anything else keeps its own name.
    static let known: [String: String] = [
        "next": "Next.js", "next-server": "Next.js", "vite": "Vite", "bun": "Bun", "node": "Node", "nodejs": "Node",
        "deno": "Deno", "python": "Python", "uvicorn": "Uvicorn", "gunicorn": "Gunicorn", "flask": "Flask",
        "manage": "Django", "django-admin": "Django", "rails": "Rails", "puma": "Rails", "ruby": "Ruby",
        "storybook": "Storybook", "start-storybook": "Storybook", "webpack": "webpack", "webpack-dev-server": "webpack",
        "astro": "Astro", "nuxt": "Nuxt", "nuxi": "Nuxt", "remix": "Remix", "ng": "Angular", "expo": "Expo",
        "php": "PHP", "hugo": "Hugo", "jekyll": "Jekyll", "caddy": "Caddy", "nginx": "nginx", "wrangler": "Wrangler",
        "workerd": "Wrangler", "parcel": "Parcel", "esbuild": "esbuild", "java": "Java",
    ]

    private static let extensions: Set<String> = ["js", "mjs", "cjs", "ts", "py", "rb", "php", "exe"]

    /// A program's name as the table keys it: `python3.12` and `Python` are `python`,
    /// `vite.js` is `vite`, `next-server (v15.1.0)` is `next-server`.
    static func key(_ name: String) -> String {
        var s = (name as NSString).lastPathComponent.lowercased()
        if let cut = s.firstIndex(where: { $0 == " " || $0 == "(" }) { s = String(s[..<cut]) }
        if extensions.contains((s as NSString).pathExtension) { s = (s as NSString).deletingPathExtension }
        while let last = s.last, last.isNumber || last == "." { s.removeLast() }
        return s
    }

    /// What runs: the known name of the process's label (its script, or how it was started),
    /// else of its executable (`python3 app.py` is Python), else the label as it is. Nil when
    /// the server couldn't tell which process holds the port.
    static func program(_ e: PortEntry) -> String? {
        if let p = e.process, let k = known[key(p)] { return k }
        if let p = e.program, let k = known[key(p)] { return k }
        if let p = e.process, !p.isEmpty { return p }
        if let p = e.program, !p.isEmpty { return p }
        return nil
    }

    /// The folder's own name: `~` for a home directory, `/` for the root.
    static func folder(_ path: String?) -> String? {
        guard var p = path?.trimmingCharacters(in: .whitespaces), !p.isEmpty else { return nil }
        if p == "/" { return "/" }
        if p.hasSuffix("/") { p.removeLast() }
        let parts = p.split(separator: "/")
        if parts.count == 2, p.hasPrefix("/Users/") || p.hasPrefix("/home/") { return "~" }
        return parts.last.map(String.init)
    }

    /// The row's first line: "Next.js · anchor", "Python", or "Port 3000" with no process known.
    static func title(_ e: PortEntry) -> String {
        guard let program = program(e) else { return "Port \(e.port)" }
        guard let folder = folder(e.folder) else { return program }
        return "\(program) · \(folder)"
    }
}
