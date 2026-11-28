# The terminal engine

Pteron's terminal: **libghostty-vt** (upstream's `ghostty-vt.xcframework`) parses the stream
and holds the terminal's state, and **our own Metal renderer** draws it. A pane starts by
restoring the Ghostty snapshot (`GHOSTSNP`) that opens every Rex data stream.

The stream, reconnecting and input are in [terminal.md](terminal.md); touch selection in
[selection.md](selection.md); the C API rules in [ghostty-api-notes.md](ghostty-api-notes.md).
[terminal-checklist.md](terminal-checklist.md) lists what the terminal must do and how each
point is checked.

## Why this design

- **libghostty-vt has what a remote client needs** through a C API: snapshot restore
  (`ghostty_snapshot_decoder_*`), render state with dirty rows (`ghostty_render_state_*`, a
  two-phase update for short locks), selection (word, line) and a formatter for copy (plain, VT,
  HTML), key and mouse encoders (DECCKM, Kitty, SGR and the other formats), paste encoding,
  viewport scrolling, modes, scrollbar.
- **Upstream builds iOS slices** with `-Demit-lib-vt -Demit-xcframework`.
- **The Rex Mac app uses the same split**: libghostty with its own Metal renderer.
- **Not GhosttyKit** (the full libghostty, `include/ghostty.h`): its only termio backend is a
  local PTY with a subprocess, a remote byte source would need a patch to a fast-moving tree, and
  it can't restore a snapshot into a surface.
- **The server's terminal is Ghostty too.** The snapshot restores exactly (screen, scrollback,
  both screens, every mode, unfinished input), and a local `ghostty_terminal_resize` reflows as
  the server's does: a new width needs nothing read again.

## Architecture

```
TerminalStream (RexKit, main actor)          data socket, APCFilter, snapshot parts, input queue
  └─ TerminalHost (UIKit, main)              gestures, clipboard, edit menu, keymap, sizing
       └─ GhosttyTerminalView                the view: +Input, +Scroll, +Selection, +SelectionUI, +Find
            ├─ GhosttyCore                   the terminal, its feed queue, restore, render state
            ├─ GhosttyRenderer               Metal layer, pipelines, one frame
            └─ GhosttyScroller               a transparent UIScrollView over the Metal view
GhosttyRenderThread.shared                   one render thread and display link for all panes
GhosttyGlyphAtlas, GhosttyGlyphWorker.shared glyph pages; CoreText fallback off the frame
```

`TerminalHost` holds the view directly: one engine, no protocol in front of it. The host uses
the view's output side (`feed`, `restoreSnapshot`), geometry (`cellSize`, `setGrid`, `setFont`,
`apply(theme:)`), selection and its UI, scrolling, and input (`keyHook`, `send(txt:)`,
`pasteText`). It never reaches into the core, the renderer or the scroller, except to hear the
core's backpressure signal. Three engine properties shape the host: it parses off the main
thread (the host passes chunks straight on, no pacing of its own), it reflows as the server does
(no redraw from the server after a width change), and a font change keeps the terminal's modes
(no redraw then either).

The view reports back through `TerminalEngineDelegate` (`Features/Terminal/TerminalEngineDelegate.swift`:
the grid changed, bytes for the program). The protocol stays because the engine's tests put a
spy there in place of a host.

Files in `Pteron/Features/Terminal/Ghostty/`:

| File | Holds |
| --- | --- |
| `GhosttyCore.swift` | `GhosttyCore`: terminal, feed queue, locks, restore, render-state access, memory limits |
| `GhosttyCore+Input.swift`, `+Scroll.swift`, `+Selection.swift`, `+Find.swift`, `+ScreenPrint.swift` | the mode mirror and key encoder; scroll math and state; selection; find's passes; the held screen's print (`GhosttyScreenPrint`) |
| `GhosttyRenderer.swift` | `GhosttyMetal`, `GhosttyRenderer`, `GhosttyRenderThread` |
| `GhosttyRowBuilder.swift`, `GhosttyShaders.swift` | cells to instances (`GhosttyRowBuilder`, `GhosttyFrameBuilder`); the Metal source |
| `GhosttyGlyphAtlas.swift`, `GhosttySprites.swift` | metrics, atlas pages, the glyph worker; box, block, braille and Powerline glyphs drawn by rule |
| `GhosttyTerminalView*.swift` | the view `TerminalHost` holds: output, input, scrolling, selection, find, what the selection UI asks |
| `GhosttyScroller.swift`, `GhosttyMouseReporter.swift`, `PanePixelMap.swift` | native scrolling; wheel, mouse and arrow reports; pointer positions in pane pixels (SGR-Pixels) |
| `GhosttyInputKeymap.swift`, `GhosttyInputText.swift`, `GhosttyPlainInsertion.swift` | iOS keys to Ghostty key events; the `UITextInput` shadow text; whether keyboard text is one plain key |
| `GhosttyTap.swift`, `GhosttyLinks.swift`, `GhosttyPrompts.swift` | what a tap does; OSC 8 and plain URLs; OSC 133 prompts and click-to-move |
| `GhosttyClipboard.swift` | clipboard writes from the program (OSC 52 and friends) |
| `GhosttyFindHighlights.swift`, `CatchUpCover.swift` | find's tints as rect instances; whether a new cover draws through the catch-up hold |
| `GhosttyDemoScreen.swift`, `GhosttySelectionDemo.swift`, `GhosttyBuild.swift` | `-ghosttyDemo`, `-selectionDemo`, the linked library's version |

Predicted echo's engine side is in `Pteron/Features/Terminal/Predict/` (`GhosttyCore+Predict.swift`,
`GhosttyEchoGrid.swift`, `TerminalHost+Predict.swift`).

## Threads and locks

Terminal calls in libghostty-vt are not thread-safe. Everything that touches a terminal holds
that terminal's lock.

| Thread or queue | Owner | Does |
| --- | --- | --- |
| main | UIKit | copies fed bytes into the core's queue; gestures, selection, links, taps and mouse reports (through `withTerminal`) |
| `rex.ghostty.feed` (serial queue, user-initiated) | one per `GhosttyCore` | parses bytes; resize, colors, reset, snapshot restore and history compression, in the order asked |
| `rex.ghostty.render` (thread, user-interactive) | `GhosttyRenderThread.shared`, one per process | one `CADisplayLink` (60 to 120 Hz) and the cursor blink timer for all panes; builds and presents frames; exits with the last pane |
| `rex.ghostty.glyphs` (thread, user-initiated) | `GhosttyGlyphWorker.shared` | rasterizes fallback glyphs and clusters with CoreText |
| `rex.ghostty.find` (serial queue, user-initiated) | `GhosttyFind.queue`, one per process | find's passes for every pane: ticks, feeds, steps, closing (`GhosttyCore+Find.swift`) |

Locks of one `GhosttyCore` (`GhosttyLock`, an `os_unfair_lock`):

- `termLock`: the terminal, its size, colors, the prompt watch, the selection anchor.
- `stateLock`: the render state and its iterators, the render holds (the program's and the
  catch-up's), the scrollbar.
- `opLock`: the queue of work for the feed queue. `handlerLock`: the dirty handler.

**Lock order: `termLock` first, then `stateLock`.** Find's `searchLock` (its search handle)
comes after `termLock` (`termLock → searchLock`) and is never held with `stateLock`. Under those
come small locks never held while taking another: find's `published` result (the render thread
reads it under `stateLock`; never held across a library call), the scroll state's lock, the input
mirror's, the clipboard's, the renderer's config lock, and the glyph atlas lock (taken under
`stateLock` during a row build, after `termLock` is released).

Rules that keep the UI and the frame from waiting:

- The feed queue takes `termLock` once per 64 KB slice, not per burst, and yields to waiters
  between slices: `os_unfair_lock` is not fair, so a long burst would starve the renderer.
- The render thread holds `termLock` only for `ghostty_render_state_begin_update` (and the
  scrollbar read). `end_update`, the row build, encoding and the present run without it.
- The main thread never takes `termLock` to scroll: it publishes the offset to the scroll state,
  and the render thread applies it in its next frame.
- The glyph worker takes the atlas lock only to store a finished bitmap, so a frame never waits
  for CoreText.
- Find ticks with `searchLock` alone, in 0.25 ms chunks, at most 2 ms a pass, and takes
  `termLock` (through `lockTerminal`, so the feed queue yields) only to feed, set a needle, step
  or close. Output refreshes are coalesced to one per 24 ms and run only while the pane is drawn;
  the render thread reads only `published` and never waits on a tick. Nothing exists before find
  first opens; the handle is freed when it closes, and swapped with the terminal on a restore
  (freed after the tracked refs, remade on the next pass with the needle kept).

Rules that must stay kept; each was broken once (the input mirror's lock is taken under
`termLock` or alone):

- Only the render thread moves the viewport, inside the frame's update. Input
  (`scrollToBottomForInput`) and an edge drag leave a request with the scroll state; they never
  scroll on the feed queue or under the terminal lock on the main thread.
- `scrollPage` on an alternate screen uses the input mirror, not the terminal lock.
- Nothing takes `termLock` per frame without telling the feed queue.

Accepted, with the bound:

- **Main-thread waits.** Selection calls, mouse reports, the wheel's mode read and the cursor
  position during composition take `termLock` on the main thread. The wait is one 64 KB slice of
  output, plus one row build if the feed queue is itself waiting for the renderer at the start
  of a synchronized update. Typing, pasting and scrolling take no terminal lock.
- **Stale input modes.** A key is encoded with the modes of the last parsed slice; output still
  queued (a snapshot being restored included) hasn't changed them yet. The window is the feed
  queue's backlog.
- **Stale scroll routing.** Whether one-finger drags go to the program follows the last drawn
  frame, at most 33 ms behind, and is not updated during a synchronized-output hold (1 s at most).
- **Hit-testing against the last frame.** A touch is mapped with the scroll position of the last
  drawn frame; the terminal may have scrolled since (one frame of output at most).

## Predicted echo

What it is and when it runs: [terminal.md](terminal.md), Predicted echo. In the engine:

- **The predictor is on the feed queue.** `GhosttyCore+Predict.swift` holds an `EchoPredictor`
  (RexKit) only while the pane's level is not off, and touches it only on the feed queue with
  `termLock` held. The main thread enqueues what it learned (`echoTyped`, `echoAnswered`,
  `echoSettled`, `echoCleared`, `echoInputMode`), so each is in order with the bytes. After every
  slice the overlay is checked against the rows just parsed; at the end of a drain batch the
  guesses are judged. `GhosttyEchoGrid` is the predictor's read-only view of the terminal.
- **The overlay travels with the rows.** `echoPublished` is written in the lock section that
  parsed the slice, and `lockFrame` latches it (`frameEcho`) with the rows. A frame never shows a
  guess beside the character that confirms it, or rows without the guess they were judged
  against. Every grid change from outside the parser (resize, reset, restore, theme, dropped
  output) clears the guesses in its own lock section.
- **Drawing.** The row builder turns the overlay into three small instance lists (masks, glyphs,
  underlines and the cursor) with a version of their own; rows keep their `rowsVersion` reuse.
  The renderer keeps them in their own buffers, one set per frame in flight, and fills a set only
  when its `EchoFill` (the lists' version and the cursor) differs from what it holds. A pane with
  no overlay has no buffers and builds nothing.
- **Off costs nothing.** With the gate off there is no predictor, the stream has no observer
  (one `nil` check per input call), `echoPublished` stays `nil`, and builder and renderer take
  the path without it. `EchoParityTests` holds that.
- **Timers.** One `asyncAfter` on the feed queue for the predictor's next deadline (the 1.5 s
  cap, the 300 ms slow signal), armed only while a guess is pending.

## From bytes to a frame

1. `TerminalHost.streamFeed` calls `feed(buffer:)`. `GhosttyCore.feed` copies the bytes under
   `opLock` and starts a drain on the feed queue if none is running. That copy is all the main
   thread does for output.
2. The feed queue writes in 64 KB slices. Per slice: `termLock`, `ghostty_terminal_vt_write`
   (watching for prompts), sync of the input mirror, unlock, then the dirty handler.
3. The dirty handler marks the pane and, if it is visible, wakes the render thread.
4. The render thread, per dirty pane: `termLock`, `begin_update`, unlock, `end_update`, build the
   rows that changed, encode, present.

- **Pacing** follows Ghostty's own renderer thread. A wake-up draws at once if the pane has not
  presented in the current display interval; otherwise the next tick draws. A pane hands over at
  most one frame per refresh, and a frame never waits a whole interval for a tick (presenting
  only from ticks dropped frames that landed near the tick). The link runs 0.1 s past the last
  output frame, then pauses: an idle pane has no ticks.
- **Rows.** A dirty row is rebuilt only if its cells, its selection or the styles its cells name
  changed (`GhosttyRowBuilder.matches`): scrolling output and full repaints dirty rows they don't
  change.
- **Synchronized output** (mode 2026) holds frames until the program ends the update, at most 1 s.
- **The catch-up hold** (`GhosttyCore.setCatchUpHold`) is the same kind of hold, set by the host
  while its stream's fence is up ([terminal.md](terminal.md), The catch-up fence). The frame on
  show is the terminal as it was when the hold began; bytes are parsed as always; the first frame
  after the hold shows everything at once, so a returning pane doesn't flicker through missed
  output or a resize's reflow. It has the program hold's 1 s limit and exceptions (a scroll, a
  selection and find still draw; `GhosttyScrollState.hasRequest` is what counts as a scroll),
  with one difference:
  - A new cover (the keyboard's, find's bar) draws through the program's hold, so the prompt
    comes above the keyboard at once. Through the catch-up hold it draws only while the grid is
    the one the hold began with (`CatchUpCover`). Once another grid was asked for or restored
    under the hold, the cover waits and the hold's last frame takes it: drawn earlier, it showed
    the screen half caught up at a size on the way (24 rows, then 53, before the pane's 30).
    Waiting at every grid instead kept the prompt under the keyboard for up to half a second on a
    slow link.
  - The two holds are independent: a frame is updated only when neither is on.
  - Setting it takes `termLock` once on the main thread to capture the frame to keep; it is set
    only when a fence goes up, never at rest. In the same section it keeps a print of the held
    screen (`GhosttyScreenPrint`: a hash of the active area as the formatter writes it in VT,
    with the cursor, the modes and the keyboard modes). `showsHeldScreen` compares the parsed
    terminal with it once, as a fence that holds keys comes down: keys go only to the screen they
    were typed at ([terminal.md](terminal.md), The catch-up fence).
  - A fenced pane's cursor is drawn hollow (`GhosttyRenderer.setFenced`); nothing else changes.
  - As the app leaves the front the host sets the same hold with no time limit
    (`setCatchUpHold(_:limited: false)`, `GhosttyTerminalView.holdWhileAway`) and ends it once
    the return has caught up ([terminal.md](terminal.md), Back from the background).
  - A snapshot restored under a hold makes a new render state that has read nothing
    (`renderStateBlank`); the frame builder keeps its rows until the hold ends instead of
    building an empty frame.
- **A parked pane** has no drawables: `releaseDrawables` shrinks the layer's drawable size to one
  pixel and the renderer draws nothing; `restoreDrawables` puts the size back and the first frame
  makes them again.
- **Renderer.** `CAMetalLayer`, bgra8Unorm, premultiplied blending. The layer shows a frame at
  its own pixels, anchored top-left (`contentMode = .topLeft`), never scaled: between a change of
  the view's size and the first frame drawn for it, the last frame keeps its scale. Three
  instanced passes: background rects (adjacent cells of one color merged), glyph quads (an r8
  mask atlas and a bgra atlas for color emoji), decoration rects (underline, strike, cursor).
  Inverse and bold are applied here; the library's resolved colors don't include them.
- **Glyphs.** CoreText rasterizes MesloLGS NF in four faces at pixel size with whole-pixel cell
  metrics. Glyphs of our own faces and sprites are drawn inside the frame (tens of microseconds
  each). Missing glyphs and clusters go to the glyph worker: the frame is drawn without them and
  again when they arrive. A new atlas is warmed on the worker (printable ASCII in four faces, and
  one symbol, CJK character and emoji so CoreText loads its fallback fonts). Only the box of new
  glyphs is uploaded. Box drawing (U+2500–257F), block elements (U+2580–259F), braille and
  Powerline symbols are drawn by rule to the exact cell, because font glyphs leave gaps.
- **Memory.** 10,000 lines of scrollback, at most 64 MB (`scrollbackMaxLines`,
  `scrollbackMaxBytes`); no Kitty image storage. History is compressed on restore, and in small
  steps after 0.25 s without output.
- **Backpressure.** The core counts the bytes it holds unparsed. Above 4 MB `isBackedUp` turns
  true, below 1 MB false again, and `onBackpressureChange` runs on the thread that crossed the
  mark. `TerminalHost` reads the state on the main actor and pauses or resumes its stream's reads
  of the data socket ([terminal.md](terminal.md), Output). A source that never pauses and gets
  64 MB ahead has its backlog dropped (`droppedBytes`).

## Restoring the snapshot

A fresh stream (HELLO) starts with a snapshot; a resumed one (RESUME) does not.

1. **`APCFilter` (RexKit)** finds where the snapshot ends from its own framing: a 10-byte
   envelope, then records of `tag | length | CRC | payload`, with an empty READY record after the
   renderable state and an empty FINISH record at the end. It keeps none of the bytes. Each
   chunk's snapshot bytes are passed on as a view, as `GhosttySnapshotPart`s: `begin`, `bytes`…,
   `ready`, `bytes`…, `end(complete:)`, all before the first Rex message.
2. **`TerminalHost.streamGhosttySnapshot`** joins the bytes on the main thread (`SnapshotBuffer`,
   which refuses more than 16 MiB) and calls `restoreSnapshot` at `end(complete: true)`. It
   ignores `ready` and decodes the whole snapshot at once; showing the screen at READY would only
   matter for a long history over a slow link.
3. **`GhosttyCore.restore`** runs on the feed queue, so it keeps its place among fed bytes:
   `ghostty_snapshot_decoder_new_buf`, history compression on, Kitty image storage 0, `_decode`,
   then the scrollback limits, clipboard and prompt callbacks and theme colors are set on the new
   terminal. The new terminal replaces the old one under `termLock` then `stateLock`, with a new
   render state. It keeps the snapshot's grid; the `resize` message that follows the snapshot
   sets the size the host wants (resizing to the old local grid and back would cut an alternate
   screen). If the snapshot has mode 2026 set, the render hold is seeded by hand: no callback
   fires for a restored mode.
4. **If anything fails**, nothing is lost. The filter stops walking records and scans for the
   first Rex message as soon as a part is refused, so a damaged length can't swallow the stream.
   A failed decode leaves the old terminal in place and calls
   `TerminalStream.snapshotRestoreFailed()` on the main thread. Either way the stream falls back
   to `terminal.format` ([terminal.md](terminal.md), If the snapshot can't be restored).

The snapshot format (version 1) carries no compatibility promise. The decoder fails cleanly on a
mismatch (version, CRC, record order), which is what the fallback is for. Re-pin when Rex updates
its Ghostty.

## Resize

`streamResized` reaches `GhosttyTerminalView.setGrid`, then `GhosttyCore.resize`, which goes
through the feed queue behind every byte fed before it, so the grid changes exactly where the
server changed it. `ghostty_terminal_resize` reflows.

## Toolchain

- `scripts/ghostty.version` pins the Ghostty commit and Zig (Ghostty's `minimum_zig_version`),
  with the tarball's SHA-256.
- `scripts/build-ghostty.sh` (zsh, Apple silicon only):
  - Does nothing when `Vendor/GhosttyVt.stamp` matches the pins and patches. `--force` rebuilds.
  - Fetches Zig into `Vendor/zig-<version>/`, clones Ghostty into `Vendor/ghostty/`, checks out
    the pin and applies `scripts/ghostty-patches/*.patch`.
  - Runs `zig build -Demit-lib-vt=true -Demit-xcframework=true -Doptimize=ReleaseFast` with
    `ZIG_GLOBAL_CACHE_DIR=Vendor/zig-global-cache`.
  - Copies the result to a staging folder in `Vendor/` and runs `scripts/check-symbols.sh` on it
    there. A framework that fails is deleted with the folder.
  - Only then replaces `Vendor/GhosttyVt.xcframework` and writes the stamp (Ghostty commit, Zig
    version, patch hash) last. A stamp always means "this framework passed the checks and came
    from these pins"; an interrupted run leaves at worst a framework without a stamp, which
    counts as not built.
- `scripts/check-ghostty.sh` compares the stamp with the pins and checks that every iOS
  deployment target in `project.yml` is at least 17.4 (the patch below). The app target's
  pre-build phase runs it on every build, and the build Mac scripts run it before copying or
  archiving ([release.md](release.md)).
- `scripts/check-symbols.sh [path…]` fails when a framework, static library, app or archive
  imports a system symbol that is not public API (rules in its header comment).
  `ship-macdesk.sh` runs it on the framework before archiving and on the archived app before
  export.
- `project.yml` links `Vendor/GhosttyVt.xcframework` (static, `embed: false`) with
  `OTHER_LDFLAGS: -lc++`: simdutf and highway are C++.
- `Vendor/` is gitignored. Nothing is installed system-wide. A cold build takes about 130 s.
- Slices: `ios-arm64`, `ios-arm64-simulator` (arm64 only) and `macos-arm64_x86_64`. Release
  builds for the simulator therefore need `ONLY_ACTIVE_ARCH=YES`.
- Swift module name: `GhosttyVt`. Umbrella header: `ghostty/vt.h`.
- **Re-pin:** change `GHOSTTY_COMMIT` in `scripts/ghostty.version` (and the Zig version and hash
  if Ghostty's `minimum_zig_version` moved) and run `scripts/build-ghostty.sh`. Then check
  `Pteron/Resources/Acknowledgements.txt` against the `"use": "linked"` entries in
  `Vendor/ghostty/deps/libghostty-vt-third-party.json`: the app must ship every linked licence.
  Re-check [ghostty-api-notes.md](ghostty-api-notes.md) against the headers, and run the
  benchmark.

### Patches

`scripts/ghostty-patches/` holds our changes to the Ghostty checkout, applied in name order. To
change one: edit `Vendor/ghostty`, write `git diff` over the file, run `scripts/build-ghostty.sh`.
A new or changed patch changes the stamp's hash, so every existing framework becomes stale.
List every patch file under the app target's `preBuildScripts` `inputFiles` in `project.yml`:
Xcode's script sandbox lets `check-ghostty.sh` read only listed files (listing the folder is not
enough), and the build stops with that instruction when it cannot read one.

- `0001-tinyio-public-darwin-futex.patch`: no private futex symbols.
  - Upstream's `src/lib/tinyio/posix.zig` calls `__ulock_wait` and `__ulock_wake` on Darwin. No
    SDK header declares them, and App Store review rejects binaries that import such symbols
    (ITMS-90338).
  - They reach the app although nothing calls them on a 64-bit target: `TinyIo` (lib-vt's
    `std.Io`) is a table of function pointers whose futex entries point at them, and the linker
    cannot strip what a table references.
  - The patch points those entries at `os_sync_wait_on_address`,
    `os_sync_wait_on_address_with_timeout`, `os_sync_wake_by_address_any` and
    `os_sync_wake_by_address_all` (`<os/os_sync_wait_on_address.h>`): public since iOS 17.4 and
    macOS 14.4, wrappers of the same kernel operation. The futex stays real; thread safety is
    unchanged.
  - Test: `zig build test-lib-vt -Demit-lib-vt=true -Dtest-filter=futex -Dtest-filter=Io.Mutex`
    in `Vendor/ghostty`, with `ZIG_GLOBAL_CACHE_DIR` set as in the build script.
  - The library then needs iOS 17.4 when it loads, although its objects still say iOS 13, so no
    link step would catch a lower deployment target. `check-ghostty.sh` does.
  - Drop the patch when Ghostty or Zig's std does the same upstream.
- Not built single-threaded instead: that turns the generation counter that all terminals share
  into a plain add, and terminals run on different threads.

### Tools and tests

- `scripts/ghostty-tools/capture.mjs` (Node 24, built-in WebSocket) records a real data stream:
  `node capture.mjs <https server> <session id> <block id> <out> <seconds> [text to type]`.
  It also writes `<out>.nonce`.
- `scripts/ghostty-tools/decode.c` decodes a capture with the macOS slice:
  `clang -O2 -I$X/Headers decode.c $X/libghostty-vt.a -lc++ -o decode`, where
  `X=Vendor/GhosttyVt.xcframework/macos-arm64_x86_64`.
- `PteronTests/Ghostty*.swift` (fixtures in `PteronTests/Fixtures`) run in the simulator with the
  app scheme. They reach libghostty-vt only through the app's Swift types: the static library is
  linked into the app, not the test bundle.
- `Packages/RexKit/Tests/RexKitTests/Stream*.swift` cover the filter and the stream on recorded
  streams, split at every chunk boundary, and the stream's reconnect and input rules against a
  fake control connection.
- Offline: `-ghosttyDemo <path>` replays a capture in a bare terminal view; `-replay <file>` feeds
  one to a real pane through the same `APCFilter` ([debug-args.md](debug-args.md)).

## Gotchas

The library's own rules (no write-pty callback, the default scrollback, mode 2026 after a
restore, encoder syncs, Swift import) are in [ghostty-api-notes.md](ghostty-api-notes.md). The
engine adds:

- **An OSC 52 read is never answered**, for the same reason as the missing write-pty callback:
  the server's terminal answers.
- **The mouse encoder is synced from the terminal** (`ghostty_mouse_encoder_set_from_terminal`,
  modes 9, 1000, 1002, 1003, 1005, 1006, 1015, 1016) on every press, release and wheel, and on
  motion only when the modes changed. The encoder can't be asked its format, and 1016 can be on
  under another (1016, then 1006), so with 1016 on a second encoder reads it from a probe press.
  SGR-Pixels reports are made in the pane's pixels on the server ([terminal.md](terminal.md),
  Input). An X10 report beyond column 95 is not valid UTF-8 and can't be sent at all
  (`TerminalStream.send`).
- **The atlas can be reset in the middle of a row build** (overflow). The build retries up to
  three times, and encoding gives up on a frame built against an older atlas.
- **Private system symbols** fail App Store review (ITMS-90338), and a static library can bring
  them in without any call: a function pointer table is enough (Patches above).
  - After a re-pin, `build-ghostty.sh` runs `scripts/check-symbols.sh` and says which symbol
    came back.
  - Symbols that look private and are fine are in that script's `ALLOW` list with the reason
    for each. `__availability_version_check` is one: Zig's compiler-rt supplies
    `__isPlatformVersionAtLeast` to `#available` checks and imports it, as Apple's own
    `libclang_rt` does in every app. Localizing Zig's copy keeps the import and grows the app.
  - `close$NOCANCEL` and `realpath$DARWIN_EXTSN` are the names `<unistd.h>` and `<stdlib.h>`
    give `close` and `realpath` through `__DARWIN_ALIAS_C` and `__DARWIN_EXTSN`.

## Measurements

`scripts/bench/run.sh` measures the terminal on generated output and checks the numbers against
fixed budgets, so a regression in the feed path, the renderer or the host's main-thread work
fails the run.

### How to run

```sh
xcrun simctl create zz-bench "iPhone 17"                    # prints the simulator id
rex session new zz-bench                                    # only for --live
scripts/bench/run.sh <simulator id> --fresh --runs 3 [--live zz-bench]
```

- One command: it builds Release once (`build/dd-bench`), generates the scenarios, runs every
  scenario `--runs` times (default 3), then 5 cold launches for `--live`, prints the report and
  exits 1 if a budget is passed, a run failed or a scenario has no result.
- Run it at normal priority on an otherwise idle machine, never under `taskpolicy -b`: at
  background priority the main-thread times pass their budgets with no change in the code.
- It boots the simulator after the build, never during it: a first boot takes the Mac's 1-minute
  load past 100 for about a minute. Then it waits until that load is under `BENCH_LOAD_FLOOR`
  (default 10), checking every 10 s for 300 s at most, prints the load and the wait, and goes on
  either way.
- Results: `build/bench/results/<scenario>__<run>.json`, one file per run.
  `node scripts/bench/report.mjs build/bench/results` prints and checks the report again.
- Resumable: a run whose file exists is skipped, so the same command without `--fresh` goes on
  after an interruption. `--only seq,claude` and `--runs N` narrow it (with `--only`, only the
  scenarios that ran are checked).
- The app is terminated after each run and when the script ends or is interrupted.
- Every measured `unicode` run follows an unmeasured one, thrown away: on a freshly booted
  simulator CoreText's first load of its fallback fonts (CJK, emoji) in a new process is slow
  unless another process did it seconds before.
- Replay runs use no server. `--live` opens the named session in mirror mode (no claim, no
  resize) after `seq 1 3000` in its pane. Use a throwaway session. Live numbers have no budget:
  they depend on the network and the server.
- `--switch <zz- label>` measures pane switches on real panes in fit mode: the session's first
  tab holds two panes side by side, and each run switches between them 10 times, 1.5 s apart,
  with no added delay (`switch0`) and with a simulated 150 ms round trip (`switch150`,
  `-netDelay`). Every pane mount is recorded as cold (a new host), parked or warm (a host kept
  from an earlier visit), with its time to the first frame and to the current screen (fence
  down, everything parsed and drawn), and a key is typed into each pane as it comes back, with
  the time to the server's answer. Budget: a returning pane draws its first frame within 34 ms.
  `--warm <zz- label>` (three panes, the first two writing steadily) measures what two panes
  streaming unseen cost the one on screen over 10 s: main-thread time, CPU, energy.
- A full run ends with `scripts/bench/flood.sh` and `scripts/bench/filter.sh` (below).
- On the iPhone Duo: `scripts/bench/run-device.sh [--runs 5] [--only …] [--live zz-bench]`
  (header comment). It builds the `BENCH` Release on the build Mac, installs it, copies the
  scenarios into the app's Documents and launches the app once per run through `devicectl`.
  `--tag` and `--args` compare builds or switches in one results folder; `--clean` deletes the
  files it left on the phone; `--stop` quits the app. The phone must be unlocked, awake and left
  alone. Reinstall the shipping build with `scripts/install-duo.sh` afterwards. Device runs have
  no budgets. Memory there is about three times the simulator's, because the Metal drawables and
  textures count in the footprint. `-peelLeadIn <s>` and `-drawables 2` are device A/B switches
  for the launch peel; neither changes a shipped build.

### Budgets

`scripts/bench/budgets.mjs` holds them, with the measured value and the reason beside each. The
median of a scenario's runs must not pass:

| Number | Budget |
| --- | --- |
| main-thread hitches over 25 ms | 1, every scenario |
| worst main slice | 8 ms, every scenario |
| main busy | `seq`, `yes` 10 ms; `unicode` 15; `yes-wire` 35; `seq-wire` 90; `top` 160; `claude` 250 |
| frame gaps over 25 ms | 1, every scenario but `top` (it draws twice a second by itself) |
| first byte to the final frame | `seq`, `yes` 60 ms; `unicode` 150 |
| memory peak, at rest | 40 MB, 32 MB |
| a title or a waiting badge during a flood of progress reports (`scripts/bench/flood.sh`, an app test) | 0.5 s |
| the stream's filter as a ratio to the filter it replaced (`scripts/bench/filter.sh`, on the Mac) | 1.15, snapshot collection off and on |

Find open runs the same budgets: `seq-find`, `unicode-find` and `claude-find` replay with find
open and step 20 matches (`-findTest 99` for `seq`'s digits, `e` for the others, `-findSteps 20`;
`seq-find` also flings with `-perfScroll 6`), and `cap-find` (`-findTest 99`) streams `yes`
after `seq 1 10000` filled the scrollback to its cap, so every line prunes one. Each result also
has `ghosttyRender.termLockWaitWorstMs` (the render thread's longest wait for the terminal lock)
and, with find open, `find` (passes, feeds, total) and a `find` phase for the steps.

`predict` is predicted echo: a pane that opens with a recorded stream (a snapshot after
`seq 1 3000`, 80×24 at 8 pt) on a scripted link with a 150 ms round trip (`ScriptedEchoLink`),
typed into from a recorded zsh session (`EchoScript`) three times over. Nothing forces
predictions on: the gate turns them on during the first pass, as on a real slow link.
`predict-off` is the same with no gate. `predict-fast` and `predict-fast-off` are the pair on a
5 ms link, where the gate is there and stays off.

| Number (median of 3 runs) | Budget |
| --- | --- |
| a guessed key to the frame that shows it | 17 ms |
| guesses the user saw taken back; guesses that vanished | 0; 0 |
| a key on the main thread, prediction's part, gate on | 50 µs |
| a key on the feed queue | 40 µs |
| main busy, more than with no gate | 15 ms |
| gate present and off: predictors made, keys through prediction code | 0; 0 |
| gate present and off: a key's send, against the same with no gate | 1.05 times |
| fast link: a key's whole send on the main thread, with and without a gate | 100 µs |

The send's numbers leave out what `RexControl.start` does in the same turn on a real connection
(the request's JSON, URLSession's send, the watchdog): the scripted link's `start` only records
the text. That part is measured alone on the Mac against a local server (RexKit
`ControlStartTests.testWhatAStartCostsTheCallersTurn`, run by hand; its comment has the command)
and has no budget: there is no second number in the same process to take a ratio to.

Times have about twice the measured median as headroom, memory a quarter, so a busy Mac doesn't
fail a run and a real regression does. They hold for the iPhone 17 simulator at 60 Hz, grid 60×50
at 11 pt; they are not device numbers. A change that moves a number on purpose moves its budget
in the same commit.

### What is measured

`PerfProbe` (`Pteron/Features/Terminal/Perf/PerfProbe.swift`, launch argument `-perfLog
<name>`) writes one JSON file per run. Its header comment defines every number. In short:

- **First frame**: pane open (`TerminalHost.init`) to the first frame that shows the restored
  screen, with the steps between (connecting, socket live, snapshot received, restored).
- **First output, parsed, drawn**: from the first `streamFeed` to the first frame that shows the
  first chunk, to the last byte parsed, and to the frame that shows the final state. The
  first-output mark is queued behind the first chunk's bytes, and a frame that still waits for
  glyphs decides no mark: "drawn" means drawn with every glyph.
- **Main gaps**: gaps over 25 ms between callbacks of a main-thread display link (hitches).
- **Frame gaps, frames/s**: presents on the render thread.
- **Hitches** (`hitches`): the same two event streams against the display's own interval: a gap
  over 1.5 frames (12.5 ms at 120 Hz) is a hitch, and the time past one frame is hitch time.
  Presents count only where every refresh should have a frame (bursts, the fling). GPU and
  compositor time are in no number.
- **Energy** (`power`): what the kernel charges the process (`TASK_POWER_INFO_V2`: CPU energy,
  wake-ups). Zero in the simulator; GPU energy isn't reported on the Duo.
- **Main busy**: main run loop time between waking and sleeping; the worst slice is the longest
  time the main thread could not react.
- **CPU**: user + system time of the process, and of the main thread.
- **Memory**: `phys_footprint`, peak during the run and 2 s after it, with 10,000 lines of
  scrollback.
- **Echo** (`echo`, from `-echoTest` or `-echoScript`): every key's times, the predictor's
  counters and a `trace` line for each wrong guess, cap or reset, with the screen row.

Without `-perfLog`, `PerfProbe.active` is nil and every hook is one branch.

Live runs can add phases after the first frame: `-perfIdle <s>` (the pane sits still with the
probe's own link and timers stopped: CPU, wake-ups, render ticks and passes, energy) and
`-perfScroll <s>` (a scripted fling through up to 1000 rows of scrollback and back, one scroll
view offset per refresh: frames/s and hitches). The launch transition reports its steps from
process start, which peel ran, and the Metal peel's frame times and missed refreshes
(`launch.peelHitchesAt`).

Scenarios (`scripts/bench/gen.mjs`, deterministic):

| Name | What | How it is fed |
| --- | --- | --- |
| `seq`, `yes` | `seq 1 200000` (1.5 MB), `yes \| head -n 200000` (0.6 MB) | 16 KB chunks, as fast as the host takes them |
| `seq-wire`, `yes-wire` | the same bytes | 1.8 KB chunks at 2 MB/s: what the server sent over Tailscale on the same host for `seq 1 200000` |
| `unicode` | 20,000 lines of CJK, emoji and combining marks (2 MB) | 16 KB chunks, as fast as taken |
| `top` | `top`-like repaint on the alternate screen, 2 frames/s for 10 s | one write per frame, in real time |
| `claude` | Claude Code-style loop: mode 2026 around full repaints with box drawing and colours, 60 frames/s for 10 s, the transcript scrolling twice a second (2.2 MB) | one write per frame, in real time |

Replay (`-replay <file>`, `ReplayScreen.swift`) hosts a real `TerminalHost` and feeds it through
`ReplaySource`, which makes the sink calls `TerminalStream` makes, through the same `APCFilter`,
one chunk per main-actor hop. So the feed path is the production code.

### Known costs

Measured, small at today's sizes, not addressed:

- **A pane's stream starts after the host's first layout.** In the simulator most of a cold
  pane's time to first frame passes between `TerminalHost.init` and `streamStatus(.connecting)`;
  on the Duo much less. A snapshot needs no size from the client, so a mirror-mode pane could
  start its stream in `init`.
- **One main-actor hop per chunk.** `TerminalStream` takes every WebSocket message on the main
  actor, runs `APCFilter` there, and `GhosttyCore.feed` copies the bytes into its queue: about
  30 µs a chunk, all of the main-thread time under output. Running the filter on the socket's
  queue and handing output straight to the core would bring it near zero.
