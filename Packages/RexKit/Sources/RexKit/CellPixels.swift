import Foundation

/// The size of one character cell of a pane, in pixels, as the pane's program is told it (its
/// window size and CSI 14t). Rex says it in `terminal.size` (`cell_width_px`, `cell_height_px`)
/// and in the stream's `resize` message, with 0 for a size it doesn't know; an older server
/// leaves both out. The app only reads it, for SGR-Pixels mouse reports (mode 1016), and never
/// sends one in `terminal.resize`.
public struct CellPixels: Equatable, Sendable {
    public let width: Int
    public let height: Int

    /// Nil unless both are known and above 0.
    public init?(width: Int?, height: Int?) {
        guard let width, let height, width > 0, height > 0 else { return nil }
        self.width = width
        self.height = height
    }

    /// From `terminal.size`'s answer or a `resize` message.
    init?(_ size: JSONObject) {
        self.init(width: size.int("cell_width_px"), height: size.int("cell_height_px"))
    }
}
