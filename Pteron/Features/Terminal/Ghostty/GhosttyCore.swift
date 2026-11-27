import Foundation
import GhosttyVt
import QuartzCore
import RexKit
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

/// A tracked grid reference and the screen (primary or alternate) it was made on.
struct GhosttyTrackedRef {
    var ref: GhosttyTrackedGridRef
    var screen: UInt32
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
/// What is bound to one terminal, and so replaced or released when a snapshot restore swaps the
/// terminal (`restore`), all under `termLock` and before the old terminal is freed:
/// - the render state, its row iterator and cells handle (also under `stateLock`);
/// - tracked grid references (`trackedRefs`): the fixed end of a selection drag;
/// - the selection, which is the terminal's own and goes with it;
/// - the hold state (`held`), and the hold, clipboard and reset callbacks with their userdata
///   pointer (`configure`);
/// - the prompt click mode (`promptWatch`) and the mirrored input modes (`input`), read again
///   from the new terminal.
/// Formatters, untracked grid references and the snapshot decoder never outlive the critical
/// section or the call that made them. The key and mouse encoders copy modes and borrow nothing.
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
    /// Unparsed bytes above which `isBackedUp` turns true, and below which it turns false again.
    static let backlogHighWater = 4 * 1024 * 1024
    static let backlogLowWater = 1024 * 1024
    /// Unparsed bytes the core refuses to hold: a feed that would pass it drops the backlog
    /// (`droppedBytes`). Far above the high-water mark, so a source that pauses on `isBackedUp`
    /// never gets here.
    static let backlogLimit = 64 * 1024 * 1024

    /// Terminals alive in the process. Tests use it to check teardown.
    static let liveTerminals = Atomic<Int>(0)
    #if DEBUG || BENCH
    /// The benchmark (`PerfProbe`) measures the render thread's longest wait for `termLock`.
    static let measuresLockWait = Atomic<Bool>(false)
    static let lockWaitWorstNs = Atomic<Int>(0)
    #endif

    // MARK: State (internal so phase 2 extensions can use it; respect the locks)

    let termLock = GhosttyLock()
    let stateLock = GhosttyLock()
    /// Guarded by `termLock`.
    var terminal: GhosttyTerminal?
    /// Tracked grid references made on `terminal`, by the object that asked for one (a
    /// `GhosttySelectionAnchor`). The core owns them, so a restore can free them with the
    /// terminal they borrow. Guarded by `termLock`.
    var trackedRefs: [ObjectIdentifier: GhosttyTrackedRef] = [:]
    /// Guarded by `stateLock`.
    var renderState: GhosttyRenderState?
    var rowIterator: GhosttyRenderStateRowIterator?
    var rowCells: GhosttyRenderStateRowCells?
    /// Guarded by `stateLock`. True while the program holds the screen.
    private(set) var held = false
    private var holdStarted: CFTimeInterval = 0
    /// Guarded by `stateLock`. A wake-up for the hold's time limit is scheduled.
    private var holdTimerArmed = false
    /// Guarded by `stateLock`. True while the host holds the screen for a stream that is
    /// catching up (`setCatchUpHold`), and when that began. `catchUpSerial` counts the holds.
    private var catchUpHeld = false
    /// The grid when the catch-up hold went up, and whether another one was asked for or
    /// restored since (`CatchUpCover`). Guarded by `stateLock`.
    private var catchUpGrid = (cols: 0, rows: 0)
    private var catchUpGridChanged = false
    private var catchUpStarted: CFTimeInterval = 0
    private var catchUpSerial = 0
    /// The catch-up hold ends at `renderHoldTimeout` (true), or only when the host ends it: the
    /// hold of a pane whose app is away (`AwayFrame`). Guarded by `stateLock`.
    private var catchUpLimited = true
    /// The screen on show when the catch-up hold began, to type at (`showsHeldScreen`). Guarded
    /// by `stateLock`.
    private var catchUpPrint: GhosttyScreenPrint?
    /// Bumped (under `stateLock`) when the render state is replaced, so a renderer drops its cache.
    private(set) var stateGeneration = 0
    /// The render state is new and has read nothing from the terminal yet: a snapshot restored
    /// under a hold. A frame built from it would be empty, so the renderer keeps the rows it
    /// has (the held screen) until the hold ends. Guarded by `stateLock`: read it between
    /// `lockFrame` and `unlockFrame`.
    private(set) var renderStateBlank = false
    /// Scroll position at the last frame's update. Guarded by `stateLock`. Phase 2 (scroll view).
    var scrollbar = GhosttyTerminalScrollbar()
    var viewportActive = true
    /// Pending scroll requests and the position each frame was drawn at (GhosttyCore+Scroll.swift).
    let scroll = GhosttyScrollState()
    /// Set when the user changed the selection, so the next frame shows it even during a render
    /// hold (GhosttyCore+Selection.swift). Any thread.
    let selectionDirty = Atomic<Bool>(false)
    /// Set when the user acted on find (a needle, a step, open, close), so the next frame shows
    /// it even during a render hold, as a selection does (GhosttyCore+Find.swift). Any thread.
    let findDirty = Atomic<Bool>(false)
    /// The pane's find, made when it first opens (`makeFind`). Nil for a pane that never searched.
    let findSlot = Mutex<GhosttyFind?>(nil)
    /// The find result the frame being drawn shows: latched where `begin_update` runs, so a held
    /// frame that redraws for another reason keeps the result of the rows it shows. Guarded by
    /// `stateLock`.
    var frameFind: FindResult?

    /// Predicted echo (GhosttyCore+Predict.swift): the predictor and the pane's level, on the
    /// feed queue under `termLock`.
    let echo = GhosttyEchoState()
    /// The guesses the feed queue last published for the rows parsed so far. Guarded by
    /// `termLock`. Every change to the grid other than parsing (the backlog drop in `write`,
    /// `resize`, `reset`, `restore`, `setColors`) sets it to nil with `echoInvalidate()` in the
    /// same lock section as its change, so no frame latches new rows with an overlay computed
    /// for the old grid. A mutator added later must do the same.
    var echoPublished: EchoOverlay?
    /// The guesses the frame being drawn shows: latched with its rows where `begin_update` runs,
    /// so they freeze with the rows during a hold. Nil while the view is in the scrollback.
    /// Guarded by `stateLock`.
    var frameEcho: EchoOverlay?

    /// The key encoder and the input modes, synced under `termLock` after every change to the
    /// terminal that can change a mode, so typing never waits for that lock (GhosttyCore+Input.swift).
    let input = GhosttyInputMirror()

    /// OSC 52: text the program copies goes to the pasteboard (GhosttyClipboard.swift).
    let clipboard = GhosttyClipboard()
    /// OSC 133: the prompt click mode the shell announced (GhosttyPrompts.swift). Guarded by `termLock`.
    var promptWatch = GhosttyPromptWatch()

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
    private var backpressureHandler: (@Sendable () -> Void)?
    private var outputDroppedHandler: (@Sendable () -> Void)?

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

    // Backlog accounting. Any thread.
    /// Bytes fed and not parsed yet: queued, or in the batch the feed queue is writing.
    private let backlog = Atomic<Int>(0)
    private let backedUp = Atomic<Bool>(false)
    /// Bumped (under `opLock`) when the backlog is dropped, so the feed queue leaves out the
    /// rest of the bytes it already took.
    private let dropEpoch = Atomic<Int>(0)
    private let dropped = Atomic<Int>(0)

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
            input.sync(from: t)
        }
        makeRenderState()
    }

    deinit {
        // Nothing else can reach us here: queued work, the renderer and selection anchors hold
        // strong references.
        findSlot.withLock { $0 }?.freeHandle()
        releaseTrackedRefs()
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
        // Effects that send nothing to the program: clipboard writes and the full-reset notice.
        installClipboard(t)
        installPromptWatch(t)
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
        renderStateBlank = true
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
    ///
    /// The copy has no bound of its own, so a source that can outrun the parser should stop
    /// reading while `isBackedUp` is true. One that doesn't, and gets `backlogLimit` bytes
    /// ahead, loses output (`droppedBytes`).
    func feed(_ bytes: UnsafeRawBufferPointer) {
        guard !bytes.isEmpty else { return }
        opLock.lock()
        var lost = 0
        if backlog.load(ordering: .relaxed) + bytes.count > Self.backlogLimit {
            // The safety valve. Everything not parsed yet goes: what is on its way now is what
            // the screen should end on. Queued operations (resizes, restores) stay, in order.
            lost = tail.count
            tail.removeAll()
            ops.removeAll {
                guard case .bytes(let b) = $0 else { return false }
                lost += b.count
                return true
            }
            dropEpoch.add(1, ordering: .relaxed)
            // The cut can fall inside an escape sequence. CAN ends it, so the bytes that follow
            // are not read as its parameters.
            tail.append(0x18)
            backlog.add(1 - lost, ordering: .relaxed)
        }
        tail.append(contentsOf: bytes.bindMemory(to: UInt8.self))
        backlog.add(bytes.count, ordering: .relaxed)
        let start = !draining
        draining = true
        opLock.unlock()
        if start { queue.async { self.drain() } }
        if lost > 0 { noteDropped(lost) }
        settleBackpressure()
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
            let epoch = dropEpoch.load(ordering: .relaxed)
            opLock.unlock()
            for op in batch {
                switch op {
                case .bytes(let b): write(b, epoch: epoch)
                case .run(let work): work()
                }
            }
        }
    }

    /// Parses `bytes`, which `backlog` already counts. `epoch` is the `dropEpoch` they were
    /// taken at: once it has moved they belong to a dropped backlog and the rest is left out.
    private func write(_ bytes: [UInt8], epoch: Int) {
        bytes.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            var off = 0
            while off < buf.count {
                if dropEpoch.load(ordering: .relaxed) != epoch {
                    backlog.subtract(buf.count - off, ordering: .relaxed)
                    noteDropped(buf.count - off)
                    // The skipped output may hold echoes: the guesses go with it.
                    termLock.lock()
                    let settled = echoInvalidate(replaced: true)
                    termLock.unlock()
                    if settled { deliverEcho([.settled]) }
                    break
                }
                let n = min(Self.sliceSize, buf.count - off)
                // os_unfair_lock isn't fair: without this a long burst could starve the renderer
                // and make the main thread wait many slices for a short read.
                var spins = 0
                while lockWaiters.load(ordering: .relaxed) > 0, spins < 2000 {
                    sched_yield()
                    spins += 1
                }
                termLock.lock()
                var echoEvents: [GhosttyEchoEvent] = []
                if let t = terminal {
                    // A plain write that also reads the prompt click mode (GhosttyPrompts.swift).
                    writeWatchingPrompts(t, base + off, n)
                    input.sync(from: t)
                    // Predicted echo: the overlay for these rows, published with them; judged
                    // once the batch is parsed. One nil check while predictions are off.
                    if echo.predictor != nil { _ = echoAfterSlice(t, batchEnd: off + n >= buf.count, events: &echoEvents) }
                }
                termLock.unlock()
                deliverEcho(echoEvents)
                off += n
                bytesParsed += n
                backlog.subtract(n, ordering: .relaxed)
                settleBackpressure()
                onDirty?()
                noteFindChanged()
            }
        }
        settleBackpressure()
    }

    // MARK: Backpressure

    /// True from the moment more than `backlogHighWater` bytes wait to be parsed until fewer
    /// than `backlogLowWater` do. A source that can wait (a socket) should stop reading while
    /// it is true. Any thread; one atomic load.
    var isBackedUp: Bool { backedUp.load(ordering: .relaxed) }

    /// Bytes fed and not parsed yet. Any thread; one atomic load.
    var backlogBytes: Int { max(0, backlog.load(ordering: .relaxed)) }

    /// Runs after `isBackedUp` changed, on the thread that changed it (a `feed` caller or the
    /// feed queue), so keep it short and hop. It carries no value on purpose: two changes can
    /// be reported out of order, so read `isBackedUp` when you act. What is read after the last
    /// call is the final value.
    var onBackpressureChange: (@Sendable () -> Void)? {
        get {
            handlerLock.lock()
            defer { handlerLock.unlock() }
            return backpressureHandler
        }
        set {
            handlerLock.lock()
            backpressureHandler = newValue
            handlerLock.unlock()
        }
    }

    /// Bytes thrown away unparsed because the backlog passed `backlogLimit`. Any thread.
    ///
    /// Policy: the whole unparsed backlog is dropped, the bytes that arrive next are kept, and a
    /// CAN byte goes in between. The terminal itself is untouched, so the user sees output skip
    /// ahead: lines missing from the scrollback, and a screen that can be wrong where the lost
    /// bytes would have drawn. Only a fresh snapshot makes it right again, so the stream should
    /// resync when `onOutputDropped` runs.
    var droppedBytes: Int { dropped.load(ordering: .relaxed) }

    /// Runs after `droppedBytes` grew, on a `feed` caller's thread or on the feed queue.
    var onOutputDropped: (@Sendable () -> Void)? {
        get {
            handlerLock.lock()
            defer { handlerLock.unlock() }
            return outputDroppedHandler
        }
        set {
            handlerLock.lock()
            outputDroppedHandler = newValue
            handlerLock.unlock()
        }
    }

    private func noteDropped(_ count: Int) {
        dropped.add(count, ordering: .relaxed)
        onOutputDropped?()
    }

    /// Brings `backedUp` in line with `backlog`. Two atomic loads when nothing changes.
    ///
    /// Both sides call it after they moved `backlog`, and it loops until the flag fits the count
    /// it read last. So a thread that set the flag from a stale count puts it right itself: the
    /// flag can't stay true with nothing left to parse.
    private func settleBackpressure() {
        var flipped = false
        while true {
            let waiting = backlog.load(ordering: .sequentiallyConsistent)
            let up = backedUp.load(ordering: .sequentiallyConsistent)
            let wanted = up ? waiting >= Self.backlogLowWater : waiting > Self.backlogHighWater
            if wanted == up { break }
            if backedUp.compareExchange(expected: up, desired: wanted, ordering: .sequentiallyConsistent).exchanged { flipped = true }
        }
        if flipped { onBackpressureChange?() }
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
        // Noted as it is asked, not when the feed queue gets to it: the caller sets the cover
        // for the new grid in the same turn, and that must not draw the old one.
        noteCatchUpGrid(cols: max(1, cols), rows: max(1, rows))
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
            scroll.gridChanged()
            let settled = echoInvalidate()
            termLock.unlock()
            if settled { deliverEcho([.settled]) }
            onDirty?()
            noteFindChanged()
        }
    }

    func setColors(_ c: GhosttyThemeColors) {
        enqueue { [self] in
            termLock.lock()
            colors = c
            if let t = terminal { applyColors(t) }
            let settled = echoInvalidate()
            termLock.unlock()
            if settled { deliverEcho([.settled]) }
            onDirty?()
        }
    }

    /// Full reset (RIS). Keeps the size.
    func reset() {
        enqueue { [self] in
            termLock.lock()
            if let t = terminal {
                ghostty_terminal_reset(t)
                promptWatch.reset()
                scroll.gridChanged()
                input.sync(from: t)
            }
            let settled = echoInvalidate(replaced: true)
            termLock.unlock()
            if settled { deliverEcho([.settled]) }
            onDirty?()
            noteFindChanged()
        }
    }

    static func isSnapshot(_ bytes: [UInt8]) -> Bool {
        bytes.count >= 10 && bytes.starts(with: Array("GHOSTSNP".utf8))
    }

    /// The terminal as a `GHOSTSNP` snapshot, the format `restore` reads. Nil while the parser
    /// is inside an escape sequence or a UTF-8 character (the encoder wants it at rest; call
    /// after `sync()`). For tests and tools: the app itself only receives snapshots.
    func encodeSnapshot() -> [UInt8]? {
        withTerminal { t -> [UInt8]? in
            var bytes: UnsafeMutablePointer<UInt8>?
            var count = 0
            guard ghostty_snapshot_encode_alloc(t, nil, &bytes, &count) == GHOSTTY_SUCCESS, let bytes else { return nil }
            defer { ghostty_free(nil, bytes, count) }
            return Array(UnsafeBufferPointer(start: bytes, count: count))
        } ?? nil
    }

    /// Replaces the terminal with the one a `GHOSTSNP` snapshot describes.
    ///
    /// The decoder builds a new terminal (upstream: "You get back a terminal that you own"), so
    /// this swaps it in and frees the old one together with everything that borrowed it (the
    /// list is on the class). The selection goes with the old terminal: the user sees it clear,
    /// and a drag under way selects nothing more (`extendSelection` answers `.noAnchor`).
    /// History is compressed as it is restored. The restored terminal keeps the snapshot's grid;
    /// read it with `gridSize`.
    ///
    /// `trailing`: `snapshot` may hold more than the snapshot (a capture of a stream). After a
    /// successful restore the bytes behind it are passed to `trailing`, and what it returns is
    /// parsed at once, before anything fed or queued after this call.
    ///
    /// `completion` runs on the feed queue after that, with the number of bytes the snapshot
    /// used, or nil if decoding failed. On failure the old terminal stays and nothing of
    /// `snapshot` is parsed. Bytes fed from inside `completion` are queued like any other feed:
    /// behind work that was queued before it ran.
    func restore(snapshot: [UInt8], trailing: (@Sendable (ArraySlice<UInt8>) -> [UInt8])? = nil,
                 completion: @escaping @Sendable (Int?) -> Void) {
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
            // First, what borrows the old terminal. The main thread reads a drag's anchor under
            // this lock, so it finds the anchor whole or gone, never half freed. Find's handle
            // too: the next pass makes one on the new terminal, with the needle kept.
            releaseTrackedRefs()
            findSlot.withLock { $0 }?.terminalWillSwap()
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
            noteCatchUpGrid(cols: cols, rows: rows)
            // The snapshot carries mode 2026 (the program was inside a synchronized update), but
            // the decoder made the terminal before our callback existed, so no "hold began" call
            // arrives. Read the mode first: the resize below always turns it off.
            var synchronized = GhosttyTerminalModeConfig(mode: ghostty_mode_new(2026, false), value: false)
            let wasHeld = ghostty_terminal_get(restored, GHOSTTY_TERMINAL_DATA_MODE, &synchronized) == GHOSTTY_SUCCESS
                && synchronized.value
            // Same grid, our cell pixel size (for pixel-based mouse and size reports). The API
            // has no option for the pixel size alone.
            ghostty_terminal_resize(restored, c, r, cellWidthPx, cellHeightPx)
            scroll.gridChanged()
            if wasHeld {
                // Put the mode back, so the program's own reset ends the hold, and begin the hold
                // ourselves: a mode set by hand calls no callback. The frame held is the
                // snapshot's, which is all there is. The time limit runs from now.
                synchronized.value = true
                ghostty_terminal_set(restored, GHOSTTY_TERMINAL_OPT_MODE, &synchronized)
                renderHoldChanged(true)
            }
            input.sync(from: restored)
            // Still under the lock: nobody can be reading a reference into the old terminal
            // while it is torn down.
            if let old {
                ghostty_terminal_free(old)
                Self.liveTerminals.subtract(1, ordering: .relaxed)
            }
            let settled = echoInvalidate(replaced: true)
            termLock.unlock()
            if settled { deliverEcho([.settled]) }
            onDirty?()
            noteFindChanged()
            if let trailing, consumed < snapshot.count {
                let rest = trailing(snapshot[consumed...])
                backlog.add(rest.count, ordering: .relaxed)
                // Counted like bytes that were fed. (A drop while they are written cuts them
                // short too: they are unparsed backlog like any other.)
                write(rest, epoch: dropEpoch.load(ordering: .relaxed))
            }
            completion(consumed)
        }
    }

    /// Output, a resize, a reset or a restore changed the terminal: find refreshes (throttled).
    /// While find is closed it costs a lock of `findSlot` and, once find has opened, one atomic load.
    @inline(__always) func noteFindChanged() {
        findSlot.withLock { $0 }?.noteChanged()
    }

    /// Frees every tracked grid reference. Call with `termLock` held.
    func releaseTrackedRefs() {
        for held in trackedRefs.values { ghostty_tracked_grid_ref_free(held.ref) }
        trackedRefs.removeAll()
    }

    // MARK: Render holds (synchronized output)

    /// Runs inside a terminal call on the feed queue, so `termLock` is already held.
    ///
    /// It doesn't mark the core dirty: the renderer can't read anything before `termLock` is
    /// released, and whoever holds it (a write, a reset, a resize, a restore) does that then.
    private func renderHoldChanged(_ nowHeld: Bool) {
        stateLock.lock()
        if nowHeld, let rs = renderState, let t = terminal {
            // Upstream: capture the frame the program wants left on screen, at the moment the
            // hold begins. Nothing after it has been processed yet.
            ghostty_render_state_update(rs, t)
            renderStateBlank = false
            holdStarted = CACurrentMediaTime()
            // The guesses of the frame that is kept, from the same moment as its rows: not the
            // last drawn frame's, which may be of keys since confirmed, cleared or never sent.
            var atBottom = false
            ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_VIEWPORT_ACTIVE, &atBottom)
            frameEcho = atBottom ? echoPublished : nil
        }
        held = nowHeld
        // The terminal has no clock. Wake the renderer after the limit so it can end a hold the
        // program never released. One timer at a time: a redraw loop begins a hold per frame.
        let arm = nowHeld && !holdTimerArmed
        if arm { holdTimerArmed = true }
        stateLock.unlock()
        if arm { armHoldTimer(after: Self.renderHoldTimeout + 0.02) }
    }

    private func armHoldTimer(after delay: CFTimeInterval) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            stateLock.lock()
            // The hold this timer was armed for may be over and another one running.
            let left = held ? holdStarted + Self.renderHoldTimeout - CACurrentMediaTime() : nil
            if (left ?? 0) <= 0 { holdTimerArmed = false }
            stateLock.unlock()
            guard let left else { return }
            if left > 0 { armHoldTimer(after: left + 0.02) } else { onDirty?() }
        }
    }

    /// The physical memory the terminal's pages hold, both screens: the figure the library
    /// says to budget against. It looks at every page, so it is read only when a pane is
    /// parked, never per write.
    var memoryBytes: Int {
        withTerminal { t in
            var usage = GhosttyTerminalMemoryUsage()
            usage.size = MemoryLayout<GhosttyTerminalMemoryUsage>.size
            guard ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_MEMORY_USAGE, &usage) == GHOSTTY_SUCCESS else { return 0 }
            return Int(clamping: usage.primary_resident_bytes &+ usage.alternate_resident_bytes)
        } ?? 0
    }

    // MARK: The catch-up hold

    /// Holds the screen on show while the pane's stream catches up, and shows what arrived
    /// meanwhile as one frame when the hold ends: a pane that comes back doesn't flicker through
    /// the output it missed or through a resize. The same limit as a program's own hold
    /// (`renderHoldTimeout`): after that the screen follows the bytes again.
    ///
    /// Parsing goes on as always. Scrolling, a selection and find still draw (`lockFrame`), and
    /// so does a new cover (the keyboard's, find's bar) while the grid is the one the hold
    /// began with; once the grid changed under the hold, a new cover waits for the hold's last
    /// frame (`CatchUpCover`).
    /// Called on the main thread; it waits for `termLock` like a selection does.
    ///
    /// `limited: false` is the hold of a pane whose app is away (`AwayFrame`): no time limit,
    /// so the frame the user last saw is the one on show when the app is back, however long it
    /// was away. Only the host ends it.
    func setCatchUpHold(_ on: Bool, limited: Bool = true) {
        if on {
            lockTerminal()
            stateLock.lock()
            // The frame to keep is the terminal as it is now, drawn or not.
            if !catchUpHeld, !held, let rs = renderState, let t = terminal {
                ghostty_render_state_update(rs, t)
                renderStateBlank = false
            }
            // The screen may be behind the program while the stream catches up: no guess is
            // drawn over it, whatever the last frame showed.
            frameEcho = nil
            if !catchUpHeld {
                catchUpGrid = (cols, rows)
                catchUpGridChanged = false
                // The screen the user sees from now on until the hold ends: keys typed meanwhile
                // were typed at it.
                catchUpPrint = terminal.flatMap { GhosttyScreenPrint.of($0) }
            }
            catchUpHeld = true
            catchUpLimited = limited
            catchUpStarted = CACurrentMediaTime()
            catchUpSerial += 1
            let serial = catchUpSerial
            stateLock.unlock()
            termLock.unlock()
            guard limited else { return }
            // The renderer ends a hold only when it draws: wake it at the limit.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + Self.renderHoldTimeout + 0.02) { [weak self] in
                guard let self else { return }
                stateLock.lock()
                let due = catchUpHeld && catchUpLimited && catchUpSerial == serial
                stateLock.unlock()
                if due { onDirty?() }
            }
        } else {
            stateLock.lock()
            let was = catchUpHeld
            catchUpHeld = false
            stateLock.unlock()
            if was { onDirty?() }
        }
    }

    /// A grid was asked for or restored: under the catch-up hold, a cover that changes from
    /// here on is the new grid's (`CatchUpCover`). Any thread.
    private func noteCatchUpGrid(cols: Int, rows: Int) {
        stateLock.lock()
        if catchUpHeld {
            catchUpGridChanged = CatchUpCover.waits(changed: catchUpGridChanged, held: catchUpGrid, now: (cols, rows))
        }
        stateLock.unlock()
    }

    /// The pane leaves the screen (parked or kept warm): the frame it shows when it comes back
    /// carries no guess from before. Any thread.
    func dropFrameEcho() {
        stateLock.lock()
        frameEcho = nil
        stateLock.unlock()
    }

    /// Whether the terminal as parsed is the screen that was on show when the catch-up hold
    /// began: the same text, styles, cursor and input modes, at the same grid. Main thread, once
    /// per fence that holds keys; it waits for `termLock` like a selection does.
    func showsHeldScreen() -> Bool {
        stateLock.lock()
        let kept = catchUpPrint
        stateLock.unlock()
        guard let kept, let now = screenPrint else { return false }
        return kept == now
    }

    /// The host's hold is on (and not past its limit). For tests.
    var isCatchUpHeld: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return catchUpHeld && (!catchUpLimited || CACurrentMediaTime() - catchUpStarted < Self.renderHoldTimeout)
    }

    // MARK: Renderer access

    /// Brings the render state up to date and returns it locked. Returns nil (unlocked) if there
    /// is nothing to read. Call `unlockFrame` when done reading rows.
    ///
    /// The terminal lock is held only for `begin_update`. `end_update` and all reads happen
    /// while the feed queue is free to parse.
    func lockFrame(now: CFTimeInterval) -> GhosttyRenderState? {
        #if DEBUG || BENCH
        if Self.measuresLockWait.load(ordering: .relaxed) {
            let start = CACurrentMediaTime()
            lockTerminal()
            let waited = Int((CACurrentMediaTime() - start) * 1e9)
            var seen = Self.lockWaitWorstNs.load(ordering: .relaxed)
            while waited > seen {
                let (done, now) = Self.lockWaitWorstNs.compareExchange(expected: seen, desired: waited, ordering: .relaxed)
                if done { break }
                seen = now
            }
        } else {
            lockTerminal()
        }
        #else
        lockTerminal()
        #endif
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
        if catchUpHeld, catchUpLimited, now - catchUpStarted >= Self.renderHoldTimeout { catchUpHeld = false }
        // Upstream: a hold may be ignored when someone scrolls or selects. Find's user actions
        // too; a refresh caused by output waits for the program's frame.
        let selectionChanged = selectionDirty.exchange(false, ordering: .relaxed)
        let findChanged = findDirty.exchange(false, ordering: .relaxed)
        // A cover or an inset to take draws through a hold, so the prompt comes above the
        // keyboard at once. Not through the catch-up hold once the grid changed under it: then
        // the cover changes with the grid the stream is catching up to, and a frame built for
        // it would show the screen half caught up, at a size on the way. It stays wanted, and
        // the hold's last frame takes it (`CatchUpCover`).
        let scrolled = catchUpHeld && catchUpGridChanged ? scroll.hasRequest : scroll.hasPending
        if !(held || catchUpHeld) || scrolled || selectionChanged || findChanged {
            scroll.prepareFrame(terminal: t, renderState: rs, cellHeightPx: Int(cellHeightPx), generation: stateGeneration)
            ghostty_render_state_begin_update(rs, t)
            renderStateBlank = false
            // The find result these rows go with (a leaf lock, under `stateLock`).
            if let find = findSlot.withLock({ $0 }) {
                frameFind = find.published.withLock { $0 }
                // The viewport moved: find reads the matches around its new place. Right after a
                // reveal at once, else with the next throttled refresh.
                if scroll.movedViewport || scroll.appliedReveal {
                    if scroll.appliedReveal { find.revealApplied() } else { find.noteChanged() }
                }
            } else {
                frameFind = nil
            }
            // Read in the same critical section so they describe the same moment as the rows.
            ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &scrollbar)
            ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_VIEWPORT_ACTIVE, &viewportActive)
            // The guesses for these rows. Overlay rows are active-area rows, which are the
            // viewport's only at the bottom.
            frameEcho = viewportActive ? echoPublished : nil
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
