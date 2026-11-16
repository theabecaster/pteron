import GhosttyVt

/// Facts about the linked libghostty-vt.
enum GhosttyBuild {
    /// The library's version, for example "1.3.0-dev+5ebe501".
    static let version = String(cString: ghostty_version())
}
