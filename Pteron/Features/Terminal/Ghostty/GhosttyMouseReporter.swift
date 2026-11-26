import CoreGraphics
import Foundation
import GhosttyVt
import RexKit

/// Where a vertical drag or a wheel goes.
enum GhosttyScrollRoute: Equatable {
    /// Wheel reports (buttons 4 and 5) to a program that tracks the mouse.
    case mouse
    /// Arrow keys: alternate screen with alternate scroll (mode 1007) and no mouse tracking.
    case cursorKeys
    /// Nothing is sent.
    case none
}

enum GhosttyScrollRouting {
    /// What a drag does, all cases.
    enum Target: Equatable {
        case wheel
        case arrows
        /// The view's own scrollback.
        case scrollback
        case nothing
    }

    static func route(mouseTracking: Bool, alternateScreen: Bool, alternateScroll: Bool, shiftBypass: Bool) -> GhosttyScrollRoute {
        if shiftBypass { return .none }
        if mouseTracking { return .mouse }
        if alternateScreen && alternateScroll { return .cursorKeys }
        return .none
    }

    /// True when the program gets one-finger drags. An alternate screen counts even with
    /// alternate scroll off: it has no scrollback, so scrolling it locally shows nothing.
    static func captures(mouseTracking: Bool, alternateScreen: Bool) -> Bool {
        mouseTracking || alternateScreen
    }

    /// `fingers` is 0 for a trackpad or wheel scroll. Two fingers always scroll locally. Shift
    /// (hardware keyboard) keeps a scroll away from the program.
    static func target(fingers: Int, mouseTracking: Bool, alternateScreen: Bool, alternateScroll: Bool,
                       shift: Bool = false) -> Target {
        guard captures(mouseTracking: mouseTracking, alternateScreen: alternateScreen), fingers < 2 else { return .scrollback }
        switch route(mouseTracking: mouseTracking, alternateScreen: alternateScreen, alternateScroll: alternateScroll,
                     shiftBypass: shift) {
        case .mouse: return .wheel
        case .cursorKeys: return .arrows
        // A pointer scroll the program doesn't take scrolls locally; a finger drag does nothing.
        case .none: return fingers == 0 && shift ? .scrollback : .nothing
        }
    }
}

/// Drag distance kept until it adds up to a whole line.
struct GhosttyWheelAccumulator {
    private(set) var remainder: CGFloat = 0
    private var route: GhosttyScrollRoute?

    mutating func reset() {
        remainder = 0
        route = nil
    }

    /// Whole lines in `distance` plus what was left over, for one route. Positive is up
    /// (the finger moved down).
    mutating func takeWholeLines(distance: CGFloat, cellHeight: CGFloat, route: GhosttyScrollRoute) -> Int {
        guard cellHeight > 0 else { return 0 }
        if route != self.route {
            remainder = 0
            self.route = route
        }
        remainder += distance
        let lines = Int(remainder / cellHeight)
        remainder -= CGFloat(lines) * cellHeight
        return lines
    }
}

/// Token bucket for generated wheel reports and arrow keys, so a fast drag can't flood a slow
/// program: 100 a second, bursts of 6.
struct GhosttyWheelBudget {
    static let perSecond: Double = 100
    static let burst = 6

    private var allowance = Double(GhosttyWheelBudget.burst)
    private var stamp: UInt64

    init(now: UInt64 = DispatchTime.now().uptimeNanoseconds) { stamp = now }

    /// How many events a move of `lines` asks for. A notched wheel is one report per event.
    static func requested(lines: Int, precise: Bool = true) -> Int {
        guard lines != 0 else { return 0 }
        return precise ? Int(min(lines.magnitude, UInt(burst))) : 1
    }

    mutating func grant(_ wanted: Int, now: UInt64 = DispatchTime.now().uptimeNanoseconds) -> Int {
        guard wanted > 0 else { return 0 }
        let elapsed = now >= stamp ? Double(now - stamp) / 1_000_000_000 : 0
        if now >= stamp { stamp = now }
        allowance = min(Double(Self.burst), allowance + elapsed * Self.perSecond)
        let granted = min(wanted, Int(allowance))
        allowance -= Double(granted)
        return granted
    }
}

/// Turns pointer events into the bytes a program asked for, with libghostty-vt's mouse encoder
/// (X10, UTF-8, SGR, URxvt and SGR-Pixels; X10, normal, button and any-event tracking), and
/// scroll keys with its key encoder (so DECCKM and the Kitty protocol are honored).
///
/// SGR-Pixels reports are in the pane's pixels on the server (`PanePixelMap`), not the phone's;
/// while the pane's cell size is unknown they are SGR cell reports instead.
///
/// Used from one thread (the main thread in the app). Every call that reads the terminal takes
/// its lock through `GhosttyCore.withTerminal`.
final class GhosttyMouseReporter {
    enum Action { case press, release, motion }

    enum Button {
        case left, middle, right
        /// Wheel up and down: buttons 4 and 5.
        case wheelUp, wheelDown
        /// Motion with no button held.
        case none
    }

    enum Key { case arrowUp, arrowDown, pageUp, pageDown }

    struct Modifiers: OptionSet {
        let rawValue: Int
        static let shift = Modifiers(rawValue: 1 << 0)
        static let control = Modifiers(rawValue: 1 << 1)
        static let alt = Modifiers(rawValue: 1 << 2)
    }

    /// The drawn terminal, in the same pixels as event positions.
    struct Geometry: Equatable {
        var width: Int
        var height: Int
        var cellWidth: Int
        var cellHeight: Int
    }

    private var encoder: GhosttyMouseEncoder?
    private var event: GhosttyMouseEvent?
    private var keyEncoder: GhosttyKeyEncoder?
    private var keyEvent: GhosttyKeyEvent?
    private var geometry = Geometry(width: 0, height: 0, cellWidth: 0, cellHeight: 0)
    private var modes: UInt32 = .max
    /// The program asked for SGR-Pixels reports (mode 1016 was the last format it set), as of
    /// the last `sync`.
    private var pixelFormat = false
    /// Finds the format the terminal's modes give (`sync`): the mouse encoder can't be asked.
    private var probe: GhosttyMouseEncoder?
    private let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 128)
    private static let bufferSize = 128

    init() {
        ghostty_mouse_encoder_new(nil, &encoder)
        ghostty_mouse_event_new(nil, &event)
        ghostty_key_encoder_new(nil, &keyEncoder)
        ghostty_key_event_new(nil, &keyEvent)
        // Upstream: the encoder drops motion that stays in one cell (never for SGR-Pixels).
        var dedupe = true
        ghostty_mouse_encoder_set(encoder, GHOSTTY_MOUSE_ENCODER_OPT_TRACK_LAST_CELL, &dedupe)
        ghostty_mouse_encoder_new(nil, &probe)
        var size = GhosttyMouseEncoderSize()
        size.size = MemoryLayout<GhosttyMouseEncoderSize>.size
        size.screen_width = 64
        size.screen_height = 64
        size.cell_width = 2
        size.cell_height = 2
        ghostty_mouse_encoder_set(probe, GHOSTTY_MOUSE_ENCODER_OPT_SIZE, &size)
    }

    deinit {
        if let event { ghostty_mouse_event_free(event) }
        if let encoder { ghostty_mouse_encoder_free(encoder) }
        if let probe { ghostty_mouse_encoder_free(probe) }
        if let keyEvent { ghostty_key_event_free(keyEvent) }
        if let keyEncoder { ghostty_key_encoder_free(keyEncoder) }
        buffer.deallocate()
    }

    /// The bytes for one mouse event, or none if the program didn't ask for it.
    ///
    /// `position` is in pixels from the terminal's top-left corner. `buttonHeld` says whether a
    /// button is down while the event happens (the encoder needs it for motion and for events
    /// outside the grid). `count` repeats the report, for a wheel that moved several lines.
    /// `pane` is the pane's cell size on the server, for SGR-Pixels reports; nil when unknown.
    func mouse(_ action: Action, button: Button, at position: CGPoint, modifiers: Modifiers = [],
               buttonHeld: Bool, geometry device: Geometry, pane: CellPixels? = nil, count: Int = 1,
               core: GhosttyCore) -> [UInt8] {
        guard let encoder, let event, device.cellWidth > 0, device.cellHeight > 0, count > 0 else { return [] }
        return core.withTerminal { t -> [UInt8] in
            sync(t, force: action != .motion)
            var g = device, position = position
            if pixelFormat {
                // Only here: every other format is made from the phone's own cells, as before.
                var c: UInt16 = 0, r: UInt16 = 0
                ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_COLS, &c)
                ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_ROWS, &r)
                let mapped = PanePixelMap.map(position, device: device, pane: pane, cols: Int(c), rows: Int(r))
                if let mapped {
                    g = mapped.geometry
                    position = mapped.position
                }
                // Setting the format it already has changes nothing, the motion dedupe included.
                var format = mapped == nil ? GHOSTTY_MOUSE_FORMAT_SGR : GHOSTTY_MOUSE_FORMAT_SGR_PIXELS
                ghostty_mouse_encoder_set(encoder, GHOSTTY_MOUSE_ENCODER_OPT_FORMAT, &format)
            }
            if g != geometry {
                var size = GhosttyMouseEncoderSize()
                size.size = MemoryLayout<GhosttyMouseEncoderSize>.size
                size.screen_width = UInt32(clamping: g.width)
                size.screen_height = UInt32(clamping: g.height)
                size.cell_width = UInt32(clamping: g.cellWidth)
                size.cell_height = UInt32(clamping: g.cellHeight)
                if ghostty_mouse_encoder_set(encoder, GHOSTTY_MOUSE_ENCODER_OPT_SIZE, &size) == GHOSTTY_SUCCESS { geometry = g }
            }
            var held = buttonHeld
            ghostty_mouse_encoder_set(encoder, GHOSTTY_MOUSE_ENCODER_OPT_ANY_BUTTON_PRESSED, &held)

            switch action {
            case .press: ghostty_mouse_event_set_action(event, GHOSTTY_MOUSE_ACTION_PRESS)
            case .release: ghostty_mouse_event_set_action(event, GHOSTTY_MOUSE_ACTION_RELEASE)
            case .motion: ghostty_mouse_event_set_action(event, GHOSTTY_MOUSE_ACTION_MOTION)
            }
            switch button {
            case .left: ghostty_mouse_event_set_button(event, GHOSTTY_MOUSE_BUTTON_LEFT)
            case .middle: ghostty_mouse_event_set_button(event, GHOSTTY_MOUSE_BUTTON_MIDDLE)
            case .right: ghostty_mouse_event_set_button(event, GHOSTTY_MOUSE_BUTTON_RIGHT)
            case .wheelUp: ghostty_mouse_event_set_button(event, GHOSTTY_MOUSE_BUTTON_FOUR)
            case .wheelDown: ghostty_mouse_event_set_button(event, GHOSTTY_MOUSE_BUTTON_FIVE)
            case .none: ghostty_mouse_event_clear_button(event)
            }
            ghostty_mouse_event_set_mods(event, Self.mods(modifiers))
            ghostty_mouse_event_set_position(event, GhosttyMousePosition(x: Float(position.x), y: Float(position.y)))

            var written = 0
            guard ghostty_mouse_encoder_encode(encoder, event, buffer, Self.bufferSize, &written) == GHOSTTY_SUCCESS,
                  written > 0 else { return [] }
            return Self.repeated(buffer, written, count)
        } ?? []
    }

    /// A key press as the program's modes want it, repeated `count` times.
    func key(_ key: Key, count: Int = 1, core: GhosttyCore) -> [UInt8] {
        guard let keyEncoder, let keyEvent, count > 0 else { return [] }
        return core.withTerminal { t -> [UInt8] in
            // Copies cursor-key mode, keypad mode and the Kitty flags, and resets the rest.
            ghostty_key_encoder_set_from_terminal(keyEncoder, t)
            ghostty_key_event_set_action(keyEvent, GHOSTTY_KEY_ACTION_PRESS)
            ghostty_key_event_set_mods(keyEvent, 0)
            switch key {
            case .arrowUp: ghostty_key_event_set_key(keyEvent, GHOSTTY_KEY_ARROW_UP)
            case .arrowDown: ghostty_key_event_set_key(keyEvent, GHOSTTY_KEY_ARROW_DOWN)
            case .pageUp: ghostty_key_event_set_key(keyEvent, GHOSTTY_KEY_PAGE_UP)
            case .pageDown: ghostty_key_event_set_key(keyEvent, GHOSTTY_KEY_PAGE_DOWN)
            }
            var written = 0
            guard ghostty_key_encoder_encode(keyEncoder, keyEvent, buffer, Self.bufferSize, &written) == GHOSTTY_SUCCESS,
                  written > 0 else { return [] }
            return Self.repeated(buffer, written, count)
        } ?? []
    }

    /// Forgets the last cell a motion event reported, so the next one is sent. Call when a new
    /// hover or drag starts.
    func resetMotion() {
        if let encoder { ghostty_mouse_encoder_reset(encoder) }
    }

    /// Copies the tracking mode and the format from the terminal.
    ///
    /// Upstream: the copy also clears the motion dedupe state, so it must not run before every
    /// motion event. Presses, releases and wheels always copy. Motion copies only when a mouse
    /// mode bit differs from the last copy.
    private func sync(_ t: GhosttyTerminal, force: Bool) {
        var bits: UInt32 = 0
        for (i, mode) in [9, 1000, 1002, 1003, 1005, 1006, 1015, 1016].enumerated() {
            var cfg = GhosttyTerminalModeConfig(mode: ghostty_mode_new(UInt16(mode), false), value: false)
            if ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_MODE, &cfg) == GHOSTTY_SUCCESS, cfg.value { bits |= 1 << UInt32(i) }
        }
        guard force || bits != modes else { return }
        modes = bits
        ghostty_mouse_encoder_set_from_terminal(encoder, t)
        // The format is the one the program set last, so mode 1016 can be on under another
        // (1016, then 1006). Without 1016 it is never SGR-Pixels.
        pixelFormat = bits & (1 << 7) != 0 && probesAsPixels(t)
    }

    /// Whether the terminal's format is SGR-Pixels: a left press at (10, 10) in 2 x 2 pixel cells
    /// reads 10;10 in pixels and 6;6 in cells. Uses the probe encoder only: the real one keeps
    /// its size and its motion dedupe. The caller sets every field of `event` again after this.
    private func probesAsPixels(_ t: GhosttyTerminal) -> Bool {
        guard let probe, let event else { return false }
        ghostty_mouse_encoder_set_from_terminal(probe, t)
        var held = true
        ghostty_mouse_encoder_set(probe, GHOSTTY_MOUSE_ENCODER_OPT_ANY_BUTTON_PRESSED, &held)
        ghostty_mouse_event_set_action(event, GHOSTTY_MOUSE_ACTION_PRESS)
        ghostty_mouse_event_set_button(event, GHOSTTY_MOUSE_BUTTON_LEFT)
        ghostty_mouse_event_set_mods(event, 0)
        ghostty_mouse_event_set_position(event, GhosttyMousePosition(x: 10, y: 10))
        var written = 0
        guard ghostty_mouse_encoder_encode(probe, event, buffer, Self.bufferSize, &written) == GHOSTTY_SUCCESS else { return false }
        return Array(UnsafeBufferPointer(start: buffer, count: written)) == Self.pixelProbe
    }

    private static let pixelProbe = Array("\u{1b}[<0;10;10M".utf8)

    private static func mods(_ m: Modifiers) -> GhosttyMods {
        var out: Int32 = 0
        if m.contains(.shift) { out |= GHOSTTY_MODS_SHIFT }
        if m.contains(.control) { out |= GHOSTTY_MODS_CTRL }
        if m.contains(.alt) { out |= GHOSTTY_MODS_ALT }
        return GhosttyMods(out)
    }

    private static func repeated(_ bytes: UnsafeMutablePointer<UInt8>, _ length: Int, _ count: Int) -> [UInt8] {
        var out = [UInt8]()
        out.reserveCapacity(length * count)
        let one = UnsafeBufferPointer(start: bytes, count: length)
        for _ in 0..<count { out.append(contentsOf: one) }
        return out
    }
}
