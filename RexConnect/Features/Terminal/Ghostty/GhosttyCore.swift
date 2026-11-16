import Foundation
import GhosttyVt
import QuartzCore
import Synchronization
import os

/// A lock that can be taken and released from different call sites (begin / end of a frame).
///
/// `@unchecked Sendable`: it is an `os_unfair_lock` at a stable address, made to be shared.
final class GhosttyLock: @unchecked Sendable {
    private let raw: os_unfair_lock_t
    init() {
        raw = .allocate(capacity: 1)
        raw.initialize(to: os_unfair_lock())
    }
    deinit {
        raw.deinitialize(count: 1)
        raw.deallocate()
    }
    @inline(__always) func lock() { os_unfair_lock_lock(raw) }
    @inline(__always) func unlock() { os_unfair_lock_unlock(raw) }
}

/// The colors a theme gives the terminal. Programs can still override them with OSC sequences.
struct GhosttyThemeColors: Equatable {
    var foreground: UInt32
    var background: UInt32
    var cursor: UInt32
    /// The 16 ANSI colors, 0xRRGGBB.
    var ansi: [UInt32]

    static let fallback = GhosttyThemeColors(
        foreground: 0xadbac7, background: 0x22272e, cursor: 0x539bf5,
        ansi: [0x545d68, 0xf47067, 0x57ab5a, 0xc69026, 0x539bf5, 0xb083f0, 0x39c5cf, 0x909dab,
               0x636e7b, 0xff938a, 0x6bc46d, 0xdaaa3f, 0x6cb6ff, 0xdcbdfb, 0x56d4dd, 0xcdd9e5])
}

extension GhosttyColorRgb {
    @inline(__always) init(hex v: UInt32) {
        self.init(r: UInt8((v >> 16) & 0xff), g: UInt8((v >> 8) & 0xff), b: UInt8(v & 0xff))
    }
}

/// Owns one libghostty-vt terminal and its render state.
///
/// Threads:
/// - Everything that changes the terminal runs on `queue`, in the order it was asked for, so
///   bytes, resizes and snapshot restores keep their stream order.
/// - `termLock` guards the terminal. `stateLock` guards the render state and its iterators.
///   When both are needed, take `termLock` first.
/// - The renderer calls `lockFrame` / `unlockFrame`. It holds `termLock` only for the begin
///   phase of the render state update.
///
/// No write-pty callback is ever installed: the Rex server's terminal answers queries.
///
/// `@unchecked Sendable`: every mutable property is guarded by `termLock`, `stateLock`, `opLock`
/// or `handlerLock`, or is only touched on `queue`, as noted on each.
final class GhosttyCore: @unchecked Sendable {
    /// Scrollback limits, applied to every terminal this core creates or restores.
    static let scrollbackMaxLines = 10_000
    static let scrollbackMaxBytes = 64 * 1024 * 1024
    /// Bytes parsed per lock hold.
    static let sliceSize = 64 * 1024
    /// How long a program may hold the screen (synchronized output) before we show it anyway.
    static let renderHoldTimeout: CFTimeInterval = 1.0

    /// Terminals alive in the process. Tests use it to check teardown.
    static let liveTerminals = Atomic<Int>(0)

    // MARK: State (internal so phase 2 extensions can use it; respect the locks)

    let termLock = GhosttyLock()
    let stateLock = GhosttyLock()
    /// Guarded by `termLock`.
    var terminal: GhosttyTerminal?
    /// Guarded by `stateLock`.
    var renderState: GhosttyRenderState?
    var rowIterator: GhosttyRenderStateRowIterator?
    var rowCells: GhosttyRenderStateRowCells?
    /// Guarded by `stateLock`. True while the program holds the screen.
    private(set) var held = false
    private var holdStarted: CFTimeInterval = 0
    /// Bumped (under `stateLock`) when the render state is replaced, so a renderer drops its cache.
    private(set) var stateGeneration = 0
    /// Scroll position at the last frame's update. Guarded by `stateLock`. Phase 2 (scroll view).
    var scrollbar = GhosttyTerminalScrollbar()
    var viewportActive = true
    /// PHASE 2 (scroll): pending scroll requests and the position each frame was drawn at.
    let scroll = GhosttyScrollState()

    /// Runs after anything that can change what's on screen. Called on any thread.
    var onDirty: (@Sendable () -> Void)? {
        get {
            handlerLock.lock()
            defer { handlerLock.unlock() }
            return dirtyHandler
        }
        set {
            handlerLock.lock()
            dirtyHandler = newValue
            handlerLock.unlock()
        }
    }
    private let handlerLock = GhosttyLock()
    /// Guarded by `handlerLock`.
    private var dirtyHandler: (@Sendable () -> Void)?

    /// Runs under `termLock` in the begin phase of every frame, for values that must describe the
    /// same moment as the render state (scrollbar, viewport). Phase 2.
    var frameSync: (@Sendable (GhosttyTerminal) -> Void)? {
        get {
            termLock.lock()
            defer { termLock.unlock() }
            return frameHandler
        }
        set {
            termLock.lock()
            frameHandler = newValue
            termLock.unlock()
        }
    }
    /// Guarded by `termLock`.
    private var frameHandler: (@Sendable (GhosttyTerminal) -> Void)?

    let queue = DispatchQueue(label: "rex.ghostty.feed", qos: .userInitiated)
    /// Threads waiting for `termLock` that the feed queue lets in between slices: the renderer
    /// and the main thread (selection, and anything else that goes through `withTerminal`).
    private let lockWaiters = Atomic<Int>(0)

    // The grid last asked for. Guarded by `termLock`.
    private(set) var cols: Int
    private(set) var rows: Int
    private var cellWidthPx: UInt32 = 0
    private var cellHeightPx: UInt32 = 0
    private var colors = GhosttyThemeColors.fallback

    // Pending work. Guarded by `opLock`.
    private enum Op {
        case bytes([UInt8])
        case run(@Sendable () -> Void)
    }
    private let opLock = GhosttyLock()
    private var ops: [Op] = []
    private var tail: [UInt8] = []
    private var draining = false

    /// Total bytes parsed. Written on `queue`; read it after `sync()`.
    private(set) var bytesParsed = 0

    init(cols: Int = 80, rows: Int = 24) {
        self.cols = max(1, cols)
        self.rows = max(1, rows)
        var t: GhosttyTerminal?
        if ghostty_terminal_new(nil, &t, UInt16(clamping: self.cols), UInt16(clamping: self.rows)) == GHOSTTY_SUCCESS, let t {
            terminal = t
            Self.liveTerminals.add(1, ordering: .relaxed)
            configure(t)
            // Grapheme clustering (mode 2027) is on by default in Ghostty, which is what the Rex
            // server runs. A restored terminal brings the server's real modes instead.
            var clustering = GhosttyTerminalModeConfig(mode: ghostty_mode_new(2027, false), value: true)
            ghostty_terminal_set(t, GHOSTTY_TERMINAL_OPT_MODE_DEFAULT, &clustering)
        }
        makeRenderState()
    }

    deinit {
        // Nothing else can reach us here: queued work and the renderer hold strong references.
        freeRenderState()
        if let t = terminal {
            ghostty_terminal_free(t)
            Self.liveTerminals.subtract(1, ordering: .relaxed)
        }
    }

    // MARK: Setup

    /// Options every terminal needs. Called with exclusive access to `t`.
    private func configure(_ t: GhosttyTerminal) {
        ghostty_terminal_set(t, GHOSTTY_TERMINAL_OPT_USERDATA, Unmanaged.passUnretained(self).toOpaque())
        let hold: GhosttyTerminalRenderHoldFn = { _, userdata, held in
            guard let userdata else { return }
            Unmanaged<GhosttyCore>.fromOpaque(userdata).takeUnretainedValue().renderHoldChanged(held)
        }
        ghostty_terminal_set(t, GHOSTTY_TERMINAL_OPT_RENDER_HOLD, unsafeBitCast(hold, to: UnsafeRawPointer.self))
        var bytes = Self.scrollbackMaxBytes
        ghostty_terminal_set(t, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, &bytes)
        var lines = Self.scrollbackMaxLines
        ghostty_terminal_set(t, GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_LINES, &lines)
        // We don't draw images, so don't let programs fill 10 MB per screen with them.
        var noImages: UInt64 = 0
        ghostty_terminal_set(t, GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_STORAGE_LIMIT, &noImages)
        applyColors(t)
    }

    private func applyColors(_ t: GhosttyTerminal) {
        var fg = GhosttyColorRgb(hex: colors.foreground)
        var bg = GhosttyColorRgb(hex: colors.background)
        var cursor = GhosttyColorRgb(hex: colors.cursor)
        ghostty_terminal_set(t, GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &fg)
        ghostty_terminal_set(t, GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, &bg)
        ghostty_terminal_set(t, GHOSTTY_TERMINAL_OPT_COLOR_CURSOR, &cursor)
        var palette = [GhosttyColorRgb](repeating: GhosttyColorRgb(r: 0, g: 0, b: 0), count: 256)
        palette.withUnsafeMutableBufferPointer { p in
            ghostty_color_palette_default(p.baseAddress)
            for (i, c) in colors.ansi.prefix(16).enumerated() { p[i] = GhosttyColorRgb(hex: c) }
            ghostty_terminal_set(t, GHOSTTY_TERMINAL_OPT_COLOR_PALETTE, UnsafeRawPointer(p.baseAddress))
        }
    }

    /// Called with `stateLock` held, or with exclusive access.
    private func makeRenderState() {
        var rs: GhosttyRenderState?
        if ghostty_render_state_new(nil, &rs) == GHOSTTY_SUCCESS { renderState = rs }
        var it: GhosttyRenderStateRowIterator?
        if ghostty_render_state_row_iterator_new(nil, &it) == GHOSTTY_SUCCESS { rowIterator = it }
        var cells: GhosttyRenderStateRowCells?
        if ghostty_render_state_row_cells_new(nil, &cells) == GHOSTTY_SUCCESS { rowCells = cells }
        stateGeneration += 1
    }

    private func freeRenderState() {
        if let c = rowCells { ghostty_render_state_row_cells_free(c) }
        if let i = rowIterator { ghostty_render_state_row_iterator_free(i) }
        if let r = renderState { ghostty_render_state_free(r) }
        rowCells = nil
        rowIterator = nil
        renderState = nil
    }

    // MARK: Ordered work

    /// Copies `bytes` and parses them on the feed queue.
    func feed(_ bytes: UnsafeRawBufferPointer) {
        guard !bytes.isEmpty else { return }
        opLock.lock()
        tail.append(contentsOf: bytes.bindMemory(to: UInt8.self))
        let start = !draining
        draining = true
        opLock.unlock()
        if start { queue.async { self.drain() } }
    }

    func feed(_ bytes: [UInt8]) {
        bytes.withUnsafeBytes { feed($0) }
    }

    /// Runs `work` on the feed queue after everything queued before it.
    func enqueue(_ work: @escaping @Sendable () -> Void) {
        opLock.lock()
        if !tail.isEmpty {
            ops.append(.bytes(tail))
            tail = []
        }
        ops.append(.run(work))
        let start = !draining
        draining = true
        opLock.unlock()
        if start { queue.async { self.drain() } }
    }

    private func drain() {
        while true {
            opLock.lock()
            if !tail.isEmpty {
                ops.append(.bytes(tail))
                tail = []
            }
            if ops.isEmpty {
                draining = false
                opLock.unlock()
                scheduleCompression()
                return
            }
            let batch = ops
            ops = []
            opLock.unlock()
            for op in batch {
                switch op {
                case .bytes(let b): write(b)
                case .run(let work): work()
                }
            }
        }
    }

    private func write(_ bytes: [UInt8]) {
        bytes.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            var off = 0
            while off < buf.count {
                let n = min(Self.sliceSize, buf.count - off)
                // os_unfair_lock isn't fair: without this a long burst could starve the renderer
                // and make the main thread wait many slices for a short read.
                var spins = 0
                while lockWaiters.load(ordering: .relaxed) > 0, spins < 2000 {
                    sched_yield()
                    spins += 1
                }
                termLock.lock()
                if let t = terminal { ghostty_terminal_vt_write(t, base + off, n) }
                termLock.unlock()
                off += n
                bytesParsed += n
                onDirty?()
            }
        }
    }

    // MARK: Scrollback compression

    /// Bumped on the feed queue whenever work ran, so a pending idle step knows it is stale.
    private var workEpoch = 0
    private var compressionToken: UInt64 = 0
    private var compressionDone = false

    /// libghostty-vt compresses nothing by itself. Like Ghostty, wait until the terminal has
    /// been idle for 250 ms, then compress old history in small steps, off the main thread.
    private func scheduleCompression() {
        workEpoch &+= 1
        let epoch = workEpoch
        queue.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.compressStep(epoch) }
    }

    private func compressStep(_ epoch: Int) {
        guard epoch == workEpoch else { return }
        termLock.lock()
        var pending = false
        if let t = terminal {
            var token: UInt64 = 0
            ghostty_terminal_compression_activity(t, &token)
            if token != compressionToken {
                compressionToken = token
                compressionDone = false
            }
            if !compressionDone {
                var result = GHOSTTY_TERMINAL_COMPRESSION_RESULT_COMPLETE
                ghostty_terminal_compress(t, GHOSTTY_TERMINAL_COMPRESSION_MODE_INCREMENTAL, &result)
                pending = result == GHOSTTY_TERMINAL_COMPRESSION_RESULT_PENDING
                compressionDone = !pending
            }
        }
        termLock.unlock()
        if pending {
            queue.asyncAfter(deadline: .now() + 0.001) { [weak self] in self?.compressStep(epoch) }
        }
    }

    /// Blocks until all work queued so far has run. For tests and teardown, not for UI code.
    func sync() {
        let done = DispatchSemaphore(value: 0)
        enqueue { done.signal() }
        done.wait()
    }

    // MARK: Operations (all ordered with the bytes)

    /// Resizes the grid. Reflows the primary screen the way the server's Ghostty does.
    func resize(cols: Int, rows: Int, cellWidthPx: Int, cellHeightPx: Int) {
        enqueue { [self] in
            termLock.lock()
            self.cols = max(1, cols)
            self.rows = max(1, rows)
            self.cellWidthPx = UInt32(max(0, cellWidthPx))
            self.cellHeightPx = UInt32(max(0, cellHeightPx))
            if let t = terminal {
                ghostty_terminal_resize(t, UInt16(clamping: self.cols), UInt16(clamping: self.rows),
                                        self.cellWidthPx, self.cellHeightPx)
            }
            termLock.unlock()
            onDirty?()
        }
    }

    func setColors(_ c: GhosttyThemeColors) {
        enqueue { [self] in
            termLock.lock()
            colors = c
            if let t = terminal { applyColors(t) }
            termLock.unlock()
            onDirty?()
        }
    }

    /// Full reset (RIS). Keeps the size.
    func reset() {
        enqueue { [self] in
            termLock.lock()
            if let t = terminal { ghostty_terminal_reset(t) }
            termLock.unlock()
            onDirty?()
        }
    }

    static func isSnapshot(_ bytes: [UInt8]) -> Bool {
        bytes.count >= 10 && bytes.starts(with: Array("GHOSTSNP".utf8))
    }

    /// Replaces the terminal with the one a `GHOSTSNP` snapshot describes.
    ///
    /// The decoder builds a new terminal (upstream: "You get back a terminal that you own"), so
    /// this swaps it in and frees the old one. History is compressed as it is restored. The
    /// restored terminal keeps the snapshot's grid; read it with `gridSize`.
    ///
    /// `completion` runs on the feed queue with the number of bytes the snapshot used (bytes after
    /// that are not part of it and are left to the caller), or nil if decoding failed. On failure
    /// the old terminal stays.
    func restore(snapshot: [UInt8], completion: @escaping @Sendable (Int?) -> Void) {
        enqueue { [self] in
            var restored: GhosttyTerminal?
            var consumed = 0
            var ok = false
            snapshot.withUnsafeBufferPointer { buf in
                var decoder: GhosttySnapshotDecoder?
                guard ghostty_snapshot_decoder_new_buf(nil, &decoder, buf.baseAddress, buf.count) == GHOSTTY_SUCCESS,
                      let decoder else { return }
                var compress = true
                ghostty_snapshot_decoder_set(decoder, GHOSTTY_SNAPSHOT_DECODER_OPT_COMPRESS_HISTORY, &compress)
                var noImages: UInt64 = 0
                ghostty_snapshot_decoder_set(decoder, GHOSTTY_SNAPSHOT_DECODER_OPT_KITTY_IMAGE_STORAGE_LIMIT, &noImages)
                if ghostty_snapshot_decoder_decode(decoder, &restored) == GHOSTTY_SUCCESS, restored != nil {
                    ok = ghostty_snapshot_decoder_get(decoder, GHOSTTY_SNAPSHOT_DECODER_DATA_SOURCE_OFFSET, &consumed) == GHOSTTY_SUCCESS
                }
                ghostty_snapshot_decoder_free(decoder)
            }
            guard ok, let restored else {
                if let restored { ghostty_terminal_free(restored) }
                completion(nil)
                return
            }
            Self.liveTerminals.add(1, ordering: .relaxed)

            termLock.lock()
            stateLock.lock()
            let old = terminal
            terminal = restored
            configure(restored)
            var c: UInt16 = 0, r: UInt16 = 0
            ghostty_terminal_get(restored, GHOSTTY_TERMINAL_DATA_COLS, &c)
            ghostty_terminal_get(restored, GHOSTTY_TERMINAL_DATA_ROWS, &r)
            // A render state follows one terminal's pages, so start a new one.
            freeRenderState()
            makeRenderState()
            held = false
            stateLock.unlock()
            // Keep the snapshot's grid. Resizing to the old local grid and back would cut an
            // alternate screen, and the server's `resize` message follows the snapshot anyway.
            cols = max(1, Int(c))
            rows = max(1, Int(r))
            // Same grid, our cell pixel size (for pixel-based mouse and size reports).
            ghostty_terminal_resize(restored, c, r, cellWidthPx, cellHeightPx)
            // The snapshot carries mode 2026, but the decoder made the terminal before our
            // callback existed, so no "hold began" call arrives. Seed the hold from the mode.
            var mode = GhosttyTerminalModeConfig(mode: ghostty_mode_new(2026, false), value: false)
            if ghostty_terminal_get(restored, GHOSTTY_TERMINAL_DATA_MODE, &mode) == GHOSTTY_SUCCESS, mode.value {
                renderHoldChanged(true)
            }
            termLock.unlock()
            if let old {
                ghostty_terminal_free(old)
                Self.liveTerminals.subtract(1, ordering: .relaxed)
            }
            onDirty?()
            completion(consumed)
        }
    }

    // MARK: Render holds (synchronized output)

    /// Runs inside a terminal call on the feed queue, so `termLock` is already held.
    private func renderHoldChanged(_ nowHeld: Bool) {
        stateLock.lock()
        if nowHeld, let rs = renderState, let t = terminal {
            // Upstream: capture the frame the program wants left on screen, at the moment the
            // hold begins. Nothing after it has been processed yet.
            ghostty_render_state_update(rs, t)
            holdStarted = CACurrentMediaTime()
        }
        held = nowHeld
        stateLock.unlock()
        onDirty?()
        if nowHeld {
            // The terminal has no clock. Wake the renderer after the limit so it can end a hold
            // the program never released.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.renderHoldTimeout + 0.02) { [weak self] in
                self?.onDirty?()
            }
        }
    }

    // MARK: Renderer access

    /// Brings the render state up to date and returns it locked. Returns nil (unlocked) if there
    /// is nothing to read. Call `unlockFrame` when done reading rows.
    ///
    /// The terminal lock is held only for `begin_update`. `end_update` and all reads happen
    /// while the feed queue is free to parse.
    func lockFrame(now: CFTimeInterval) -> GhosttyRenderState? {
        lockTerminal()
        stateLock.lock()
        guard let t = terminal, let rs = renderState else {
            stateLock.unlock()
            termLock.unlock()
            return nil
        }
        if held, now - holdStarted >= Self.renderHoldTimeout {
            // Changing the mode ourselves doesn't call the hold callback.
            var cfg = GhosttyTerminalModeConfig(mode: ghostty_mode_new(2026, false), value: false)
            ghostty_terminal_set(t, GHOSTTY_TERMINAL_OPT_MODE, &cfg)
            held = false
        }
        // Upstream: a hold may be ignored when someone scrolls.
        if !held || scroll.hasPending {
            scroll.prepareFrame(terminal: t, renderState: rs, cellHeightPx: Int(cellHeightPx), generation: stateGeneration)
            ghostty_render_state_begin_update(rs, t)
            // Read in the same critical section so they describe the same moment as the rows.
            ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &scrollbar)
            ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_VIEWPORT_ACTIVE, &viewportActive)
            frameHandler?(t)
        }
        termLock.unlock()
        ghostty_render_state_end_update(rs)
        return rs
    }

    func unlockFrame() {
        stateLock.unlock()
    }

    /// Takes `termLock` ahead of the feed queue's next slice, so the wait is one slice
    /// (`sliceSize` bytes) even in the middle of a burst. Not for the feed queue itself.
    func lockTerminal() {
        lockWaiters.add(1, ordering: .relaxed)
        termLock.lock()
        lockWaiters.subtract(1, ordering: .relaxed)
    }

    /// Runs `body` with the terminal locked. For short reads and writes (phase 2: encoders,
    /// selection, scrolling).
    func withTerminal<R>(_ body: (GhosttyTerminal) -> R) -> R? {
        lockTerminal()
        defer { termLock.unlock() }
        guard let t = terminal else { return nil }
        return body(t)
    }

    // MARK: Reading (tests, debugging). Call `sync()` first to see everything fed so far.

    /// The terminal's real grid.
    var gridSize: (cols: Int, rows: Int) {
        withTerminal { t in
            var c: UInt16 = 0, r: UInt16 = 0
            ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_COLS, &c)
            ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_ROWS, &r)
            return (Int(c), Int(r))
        } ?? (0, 0)
    }

    /// The cursor in the active area.
    var cursorPosition: (x: Int, y: Int) {
        withTerminal { t in
            var x: UInt16 = 0, y: UInt16 = 0
            ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_CURSOR_X, &x)
            ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_CURSOR_Y, &y)
            return (Int(x), Int(y))
        } ?? (0, 0)
    }

    var scrollbackRows: Int {
        withTerminal { t in
            var n = 0
            ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_SCROLLBACK_ROWS, &n)
            return n
        } ?? 0
    }

    var isAlternateScreen: Bool {
        withTerminal { t in
            var s = GHOSTTY_TERMINAL_SCREEN_PRIMARY
            ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &s)
            return s == GHOSTTY_TERMINAL_SCREEN_ALTERNATE
        } ?? false
    }

    /// The text of viewport row `y`, without trailing blanks.
    func rowText(_ y: Int) -> String {
        withTerminal { t in
            var c: UInt16 = 0
            ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_COLS, &c)
            var out = String.UnicodeScalarView()
            var buf = [UInt32](repeating: 0, count: 32)
            for x in 0..<Int(c) {
                var point = GhosttyPoint()
                point.tag = GHOSTTY_POINT_TAG_VIEWPORT
                point.value.coordinate = GhosttyPointCoordinate(x: UInt16(x), y: UInt32(max(0, y)))
                var ref = GhosttyGridRef()
                guard ghostty_terminal_grid_ref(t, point, &ref) == GHOSTTY_SUCCESS else { break }
                var cell: GhosttyCell = 0
                ghostty_grid_ref_cell(&ref, &cell)
                var wide = GHOSTTY_CELL_WIDE_NARROW
                ghostty_cell_get(cell, GHOSTTY_CELL_DATA_WIDE, &wide)
                if wide == GHOSTTY_CELL_WIDE_SPACER_TAIL { continue }
                var n = 0
                ghostty_grid_ref_graphemes(&ref, &buf, buf.count, &n)
                if n == 0 {
                    out.append(" ")
                } else {
                    for i in 0..<min(n, buf.count) {
                        if let s = Unicode.Scalar(buf[i]) { out.append(s) }
                    }
                }
            }
            var s = String(out)
            while s.hasSuffix(" ") { s.removeLast() }
            return s
        } ?? ""
    }
}
