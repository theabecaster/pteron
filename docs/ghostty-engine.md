# The terminal engine

Pteron's terminal: **libghostty-vt** (upstream's `ghostty-vt.xcframework`) parses the stream
and holds the terminal's state, and **our own Metal renderer** draws it. A pane starts by
restoring the Ghostty snapshot (`GHOSTSNP`) that opens every Rex data stream.

This document describes the engine as built. The stream, reconnecting and input are in
[terminal.md](terminal.md); touch selection in [selection.md](selection.md); the C API in
[ghostty-api-notes.md](ghostty-api-notes.md). [terminal-checklist.md](terminal-checklist.md) lists
what the terminal must do and how each point is checked.

## Why this design

- **libghostty-vt has everything a remote client needs** through a C API:
  - `ghostty_snapshot_decoder_*`: restore a terminal from a snapshot.
  - render state with dirty rows (`ghostty_render_state_*`, a two-phase update for short locks).
  - selection, including select word and line; a formatter for copy (plain text, VT or HTML).
  - key encoder (DECCKM, Kitty protocol) and mouse encoder (SGR and the other formats).
  - paste encoding, viewport scrolling, modes, scrollbar.
- **Upstream builds iOS slices** with `-Demit-lib-vt -Demit-xcframework`.
- **The Rex Mac app uses the same split**: libghostty with its own Metal renderer.
- **Not GhosttyKit, the full libghostty from `include/ghostty.h`.** Its only termio backend is a
  local PTY with a subprocess. A remote byte source would need a patch to a fast-moving tree, and
  it can't restore a snapshot into a surface.
- **The server's terminal is Ghostty too.** So the snapshot restores exactly (screen, scrollback,
  both screens, every mode, unfinished input), and a local `ghostty_terminal_resize` reflows the
  way the server's does: a new width needs nothing read again.

## Architecture

```
TerminalStream (RexKit, main actor)          data socket, APCFilter, snapshot parts, input queue
  └─ TerminalHost (UIKit, main)              gestures, clipboard, edit menu, keymap, sizing
       └─ GhosttyTerminalView                the view: +Input, +Scroll, +Selection, +SelectionUI
            ├─ GhosttyCore                   the terminal, its feed queue, restore, render state
            ├─ GhosttyRenderer               Metal layer, pipelines, one frame
            └─ GhosttyScroller               a transparent UIScrollView over the Metal view
GhosttyRenderThread.shared                   one render thread and display link for all panes
GhosttyGlyphAtlas, GhosttyGlyphWorker.shared glyph pages; CoreText fallback off the frame
```

`TerminalHost` holds the view directly: there is one engine and no protocol in front of it. What
the host uses is the view's output side (`feed`, `restoreSnapshot`), geometry (`cellSize`,
`setGrid`, `setFont`, `apply(theme:)`), selection and its UI, scrolling, and input (`keyHook`,
`send(txt:)`, `pasteText`); it never reaches into the core, the renderer or the scroller, except
to hear the core's backpressure signal. Three properties of the engine shape the host: it parses
off the main thread (the host passes chunks straight on, with no pacing of its own), it reflows
as the server does (no redraw from the server after a width change), and a font change keeps the
terminal's modes (no redraw then either).

The view reports back through `TerminalEngineDelegate` (`Features/Terminal/TerminalEngineDelegate.swift`:
the grid changed, bytes for the program). That protocol stays because the engine's tests put a
spy there in place of a host.

Files in `RexDuo/Features/Terminal/Ghostty/`:

| File | Holds |
| --- | --- |
| `GhosttyCore.swift` | `GhosttyCore`: terminal, feed queue, locks, restore, render-state access, memory limits |
| `GhosttyCore+Input.swift`, `+Scroll.swift`, `+Selection.swift` | the mode mirror and key encoder for typing; scroll math and state; selection on the terminal |
| `GhosttyRenderer.swift` | `GhosttyMetal`, `GhosttyRenderer`, `GhosttyRenderThread` |
| `GhosttyRowBuilder.swift`, `GhosttyShaders.swift` | cells to instances (`GhosttyRowBuilder`, `GhosttyFrameBuilder`); the Metal source |
| `GhosttyGlyphAtlas.swift`, `GhosttySprites.swift` | metrics, atlas pages, the glyph worker; box, block, braille and Powerline glyphs drawn by rule |
| `GhosttyTerminalView*.swift` | the view `TerminalHost` holds: output, input, scrolling, selection and what the selection UI asks |
| `GhosttyScroller.swift`, `GhosttyMouseReporter.swift` | native scrolling; wheel, mouse and arrow reports |
| `GhosttyInputKeymap.swift`, `GhosttyInputText.swift` | iOS keys to Ghostty key events; the `UITextInput` shadow text |
| `GhosttyTap.swift`, `GhosttyLinks.swift`, `GhosttyPrompts.swift` | what a tap does; OSC 8 and plain URLs; OSC 133 prompts and click-to-move |
| `GhosttyClipboard.swift` | clipboard writes from the program (OSC 52 and friends) |
| `GhosttyDemoScreen.swift`, `GhosttySelectionDemo.swift`, `GhosttyBuild.swift` | `-ghosttyDemo`, `-selectionDemo`, the linked library's version |

## Threads and locks

Terminal calls in libghostty-vt are not thread-safe. Everything that touches a terminal holds
that terminal's lock.

| Thread or queue | Owner | Does |
| --- | --- | --- |
| main | UIKit | copies fed bytes into the core's queue; gestures, selection, links, taps and mouse reports (through `withTerminal`) |
| `rex.ghostty.feed` (serial queue, user-initiated) | one per `GhosttyCore` | parses bytes; resize, colors, reset, snapshot restore and history compression, all in the order they were asked for |
| `rex.ghostty.render` (thread, user-interactive) | `GhosttyRenderThread.shared`, one per process | one `CADisplayLink` (60 to 120 Hz) and the cursor blink timer for all panes; builds and presents frames; exits with the last pane |
| `rex.ghostty.glyphs` (thread, user-initiated) | `GhosttyGlyphWorker.shared` | rasterizes fallback glyphs and clusters with CoreText |
| `rex.ghostty.find` (serial queue, user-initiated) | `GhosttyFind.queue`, one per process | find's passes for every pane: ticks, feeds, steps, closing (GhosttyCore+Find.swift) |

Locks of one `GhosttyCore` (`GhosttyLock`, an `os_unfair_lock`):

- `termLock`: the terminal, its size, colors, the prompt watch, the selection anchor.
- `stateLock`: the render state and its iterators, the render holds (the program's and the
  catch-up's), the scrollbar.
- `opLock`: the queue of work for the feed queue. `handlerLock`: the dirty handler.

**Lock order: `termLock` first, then `stateLock`.** Find's `searchLock` (its search handle)
comes after `termLock` (`termLock → searchLock`) and is never held with `stateLock`. Under those
come the small ones that are never held while taking another: find's `published` result (the
render thread reads it under `stateLock`; it is never held across a library call), the scroll state's lock, the input mirror's, the clipboard's,
the renderer's config lock, and the glyph atlas lock (taken under `stateLock` during a row
build, after `termLock` has been released).

Rules that keep the UI and the frame from waiting:

- The feed queue takes `termLock` once per 64 KB slice, not for a whole burst, and yields to
  waiters between slices: `os_unfair_lock` is not fair, and without that a long burst would
  starve the renderer.
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

Rules that were once broken, and must stay kept (the input mirror's lock is taken under
`termLock` or alone):

- Only the render thread moves the viewport, inside the frame's update. Input (`scrollToBottomForInput`)
  and an edge drag leave a request with the scroll state; they never scroll on the feed queue or under
  the terminal lock on the main thread.
- `scrollPage` on an alternate screen uses the input mirror, not the terminal lock.
- Nothing takes `termLock` per frame without telling the feed queue.

Accepted, with the bound:

- **Main-thread waits.** Selection calls, mouse reports, the wheel's mode read and the cursor
  position during composition take `termLock` on the main thread. The feed queue lets a waiter in
  between slices, so the wait is one slice of 64 KB of output, plus one row build if the feed queue
  is itself waiting for the renderer at the start of a synchronized update. Typing, pasting and
  scrolling take no terminal lock.
- **Stale input modes.** A key is encoded with the modes of the last parsed slice. Output still in
  the queue (including a snapshot being restored after a reconnect) hasn't changed them yet. The
  window is the feed queue's backlog.
- **Stale scroll routing.** Whether one-finger drags go to the program follows the last drawn
  frame, at most 33 ms behind, and is not updated during a synchronized-output hold (1 s at most).
- **Hit-testing against the last frame.** A touch is mapped with the scroll position of the last
  drawn frame, and the terminal may have scrolled since (one frame of output at most).

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
  most one frame per refresh, and a frame never waits a whole interval for a tick. (Presenting
  only from ticks dropped frames when a program's frames landed near the tick.) The link keeps
  running 0.1 s after the last output frame, then pauses: an idle pane has no ticks.
- **Rows.** A dirty row is rebuilt only if its cells, its selection or the styles its cells name
  changed (`GhosttyRowBuilder.matches`). Scrolling output and programs that repaint the whole
  screen dirty rows they don't change.
- **Synchronized output** (mode 2026) holds frames until the program ends the update, at most 1 s.
- **The catch-up hold** (`GhosttyCore.setCatchUpHold`) is the same hold, set by the host while
  its stream's fence is up ([terminal.md](terminal.md), The catch-up fence): the frame on show
  is the terminal as it was when the hold began, bytes are parsed as always, and the first frame
  after the hold shows everything at once, so a pane that comes back doesn't flicker through
  missed output or the reflow of a resize. It has the program hold's limit (1 s, then the screen
  follows the bytes) and its exceptions (a scroll, a selection and find still draw). The two
  holds are independent: a frame is updated only when neither is on. Setting it takes `termLock`
  once on the main thread, as a selection does, to capture the frame to keep; it is set only
  when a fence goes up, never at rest. A fenced pane's cursor is drawn hollow
  (`GhosttyRenderer.setFenced`); nothing else in the frame changes.
- **A parked pane** has no drawables: `releaseDrawables` shrinks the layer's drawable size to one
  pixel and the renderer draws nothing; `restoreDrawables` puts the size back and the first frame
  makes them again.
- **Renderer.** `CAMetalLayer`, bgra8Unorm, premultiplied blending. Three instanced passes:
  background rects (adjacent cells of one color merged), glyph quads (an r8 mask atlas and a
  bgra atlas for color emoji), decoration rects (underline, strike, cursor). Inverse and bold
  are applied here; the library's resolved colors don't include them.
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
   received chunk's snapshot bytes are passed on as a view, as `GhosttySnapshotPart`s: `begin`,
   `bytes`…, `ready`, `bytes`…, `end(complete:)`, all before the first Rex message.
2. **`TerminalHost.streamGhosttySnapshot`** joins the bytes on the main thread (`SnapshotBuffer`,
   which refuses more than 16 MiB) and, at `end(complete: true)`, calls `restoreSnapshot`. It does not use `ready`: the whole snapshot
   is decoded at once. (Showing the screen at READY would matter for a long history over a slow
   link; a 22 KB snapshot arrives in one message.)
3. **`GhosttyCore.restore`** runs on the feed queue, so it keeps its place among fed bytes:
   `ghostty_snapshot_decoder_new_buf`, history compression on, Kitty image storage 0, `_decode`,
   then the scrollback limits, clipboard and prompt callbacks and theme colors are set on the new
   terminal. The new terminal replaces the old one under `termLock` then `stateLock`, with a new
   render state. It keeps the snapshot's grid; the `resize` message that follows the snapshot in
   the stream sets the size the host wants. (Resizing to the old local grid and back would cut
   an alternate screen.) If the snapshot has mode 2026 set, the render hold is seeded by hand:
   no callback fires for a restored mode.
4. **If anything fails**, nothing is lost. The filter stops walking records and scans for the
   first Rex message as soon as a part is refused, so a damaged length can't swallow the stream.
   A failed decode leaves the old terminal in place and calls
   `TerminalStream.snapshotRestoreFailed()` on the main thread. Either way the stream reads the
   screen with `terminal.format` on the open socket and sends `streamReset`, `streamResized` and
   `streamSnapshot`, which the engine takes as escape sequences ([terminal.md](terminal.md)).

The snapshot format (version 1) carries no compatibility promise. The decoder fails cleanly on a
mismatch (version, CRC, record order), which is what the fallback is for. Re-pin when Rex updates
its Ghostty.

## Resize

`streamResized` reaches `GhosttyTerminalView.setGrid`, then `GhosttyCore.resize`, which goes
through the feed queue behind every byte fed before it. So the grid changes exactly where the
server changed it. `ghostty_terminal_resize` reflows.

## Toolchain

- `scripts/ghostty.version` pins Ghostty `5ebe501a63425b13d9952e8c54682c046386e5af`
  (main, 2026-11-16) and Zig 0.17.1 (its `minimum_zig_version`), with the tarball's SHA-256.
- `scripts/build-ghostty.sh` (zsh, Apple silicon only):
  - Does nothing when `Vendor/GhosttyVt.stamp` matches the pins and patches. `--force` rebuilds.
  - Fetches Zig into `Vendor/zig-0.17.1/`, clones Ghostty into `Vendor/ghostty/`, checks out the
    pin and applies `scripts/ghostty-patches/*.patch`.
  - Runs `zig build -Demit-lib-vt=true -Demit-xcframework=true -Doptimize=ReleaseFast` with
    `ZIG_GLOBAL_CACHE_DIR=Vendor/zig-global-cache`.
  - Copies the result to a staging folder in `Vendor/` and runs `scripts/check-symbols.sh` on it
    there. A framework that fails is deleted with the folder.
  - Only then removes the old stamp and framework, moves the new framework to
    `Vendor/GhosttyVt.xcframework`, and writes the stamp (Ghostty commit, Zig version, patch
    hash) last. A stamp therefore always means "this framework passed the checks and came from
    these pins"; whatever stops the script can at worst leave a framework without a stamp, which
    counts as not built.
- `scripts/check-ghostty.sh` compares the stamp with the pins, and checks that every iOS
  deployment target in `project.yml` is at least 17.4 (see the patch below). The app target's
  pre-build phase runs it on every build, and the build Mac scripts run it before copying or
  archiving (docs/release.md).
- `scripts/check-symbols.sh [path…]` fails when a framework, static library, app or archive
  imports a system symbol that is not public API (rules in its header comment).
  `ship-macdesk.sh` runs it on the framework before archiving and on the archived app before
  export.
- `project.yml` links `Vendor/GhosttyVt.xcframework` (static, `embed: false`) with
  `OTHER_LDFLAGS: -lc++`: simdutf and highway are C++.
- `Vendor/` is gitignored. Nothing is installed system-wide.
- Cold build: 130 s wall (291 s CPU) on a 14-core M-series Mac, including the 51 MB Zig download.
- Output: `GhosttyVt.xcframework`, 51 MB; slices `ios-arm64` and `ios-arm64-simulator` (12.5 MB
  static each) and `macos-arm64_x86_64` (27 MB). In the shipped app the library is 1.48 MB of
  the binary.
- Swift module name: `GhosttyVt`. Umbrella header: `ghostty/vt.h`.
- **Re-pin:** change `GHOSTTY_COMMIT` in `scripts/ghostty.version` (and the Zig version and hash
  if Ghostty's `minimum_zig_version` moved) and run `scripts/build-ghostty.sh`. Then check
  `RexDuo/Resources/Acknowledgements.txt` against the `"use": "linked"` entries in
  `Vendor/ghostty/deps/libghostty-vt-third-party.json`: the app must ship every linked licence.
  Re-check docs/ghostty-api-notes.md against the headers, and run the benchmark.

### Patches

`scripts/ghostty-patches/` holds our changes to the Ghostty checkout, applied in name order. To
change one: edit `Vendor/ghostty`, write `git diff` over the file, run `scripts/build-ghostty.sh`.
A new or changed patch changes the stamp's hash, so every existing framework becomes stale.
List every patch file under the app target's `preBuildScripts` `inputFiles` in `project.yml`:
Xcode's script sandbox lets `check-ghostty.sh` read only listed files (listing the folder is not
enough), and the next build stops with that instruction when it cannot read one.

- `0001-tinyio-public-darwin-futex.patch`: no private futex symbols.
  - Before: `src/lib/tinyio/posix.zig` called `__ulock_wait` and `__ulock_wake` on Darwin.
    libSystem exports them, but no SDK header declares them, and App Store review rejects
    binaries that import such symbols (ITMS-90338). libc++ dropped the same two calls for that
    reason (llvm-project PR 202519).
  - They reached the app although nothing calls them on a 64-bit target. `TinyIo`, lib-vt's
    `std.Io`, is a table of function pointers, its futex entries point at these functions, and
    the linker cannot strip what a table references. The only `std.Io.Mutex` in lib-vt guards
    the Kitty graphics generation counter on 32-bit targets; 64-bit targets use an atomic.
  - After: the same entries call `os_sync_wait_on_address`, `os_sync_wait_on_address_with_timeout`,
    `os_sync_wake_by_address_any` and `os_sync_wake_by_address_all` from
    `<os/os_sync_wait_on_address.h>`: public since iOS 17.4 and macOS 14.4, and wrappers of the
    same kernel operation. The futex stays a real one, so thread safety is unchanged.
  - Upstream's `Io.Mutex` and futex tests pass through the new calls
    (`zig build test-lib-vt -Demit-lib-vt=true -Dtest-filter=futex -Dtest-filter=Io.Mutex` in
    `Vendor/ghostty`, with `ZIG_GLOBAL_CACHE_DIR` set as in the build script).
  - Cost: 336 bytes in the iOS slice, 360 in the app. Of 2297 functions in the iOS slice, 18
    changed, all in TinyIo or `std.Io` file reading; none in the parser, screen or render state.
  - The library now needs iOS 17.4 or macOS 14.4 when it loads, although its objects still say
    iOS 13, so nothing in the link would catch a lower deployment target. `check-ghostty.sh`
    does (the app's target is iOS 18). Drop the patch when Ghostty or Zig's std does the same
    upstream.
- Not built single-threaded instead, although the app serializes each terminal: that turns the
  generation counter, which all terminals share, into a plain add, and terminals run on
  different threads.

### Tools and tests

- `scripts/ghostty-tools/capture.mjs` (Node 24, built-in WebSocket) records a real data stream:
  `node capture.mjs <https server> <session id> <block id> <out> <seconds> [text to type]`.
  It also writes `<out>.nonce`.
- `scripts/ghostty-tools/decode.c` decodes a capture with the macOS slice:
  `clang -O2 -I$X/Headers decode.c $X/libghostty-vt.a -lc++ -o decode`, where
  `X=Vendor/GhosttyVt.xcframework/macos-arm64_x86_64`.
- `RexDuoTests/Ghostty*.swift` (fixtures in `RexDuoTests/Fixtures`) run in the simulator
  with the app scheme. They reach libghostty-vt only through the app's
  Swift types: the static library is linked into the app, not the test bundle.
- `Packages/RexKit/Tests/RexKitTests/Stream*.swift` cover the filter and the stream on recorded
  streams, split at every chunk boundary, and the stream's reconnect and input rules against a
  fake control connection (`swift test --package-path Packages/RexKit`).
- Offline: `-ghosttyDemo <path>` replays a capture in a bare terminal view; `-replay <file>` feeds
  one to a real pane through the same `APCFilter`.

## Gotchas

- **No write-pty callback is installed, and none may be.** The Rex server's own terminal answers
  DA, DSR, mode 2048 and the other queries. Answering locally would send every answer twice.
  For the same reason an OSC 52 read is never answered.
- **The library's default scrollback is 10,000 bytes.** `GhosttyCore` raises it
  (`OPT_SCROLLBACK_MAX_BYTES`, lines too) on every terminal it makes, restored ones included.
- **Mode 2026 and callbacks.** A restored snapshot with the mode set, and setting the mode
  ourselves, call no render-hold callback. The hold is seeded by hand in both places.
- **The mouse encoder copies its format from the terminal** (`ghostty_mouse_encoder_set_from_terminal`,
  modes 9, 1000, 1002, 1003, 1005, 1006, 1015, 1016), on every press, release and wheel, and on
  motion only when the modes changed: the copy clears the encoder's motion dedupe. So a program
  that asked for SGR reports gets them. An X10 report beyond column 95 is not valid UTF-8 and
  can't be sent at all (`TerminalStream.send`, [terminal.md](terminal.md)).
- **The atlas can be reset in the middle of a row build** (overflow). The build retries up to
  three times, and encoding gives up on a frame built against an older atlas.
- **C details.** `GHOSTTY_INIT_SIZED` is a macro: in Swift, set `.size = MemoryLayout<T>.size`.
  Enums use `: int`, so they import as structs with `rawValue`. Mode helpers such as
  `ghostty_mode_new` are static inline.
- **Private system symbols** fail App Store review (ITMS-90338), and a static library can bring
  them in without any call: a function pointer table is enough (Patches above).
  - After a re-pin, `build-ghostty.sh` runs `scripts/check-symbols.sh` and says which symbol
    came back.
  - Symbols that look private and are fine, with the reason for each, are in that script's
    `ALLOW` list. `__availability_version_check` is one: Zig's compiler-rt supplies
    `__isPlatformVersionAtLeast` to the app's `#available` checks and imports it directly, and
    so does Apple's own `libclang_rt`, which every app links. Localizing Zig's copy was tried:
    the import stays and the app grows 16 KB.
  - `close$NOCANCEL` and `realpath$DARWIN_EXTSN` are the names `<unistd.h>` and `<stdlib.h>`
    give `close` and `realpath` through `__DARWIN_ALIAS_C` and `__DARWIN_EXTSN`.
- **Release builds for the simulator** need `ONLY_ACTIVE_ARCH=YES`: they otherwise also link
  x86_64, which the simulator slice doesn't have.

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
- Results: `build/bench/results/<scenario>__<run>.json`, one file per run.
  `node scripts/bench/report.mjs build/bench/results` prints and checks the report again.
- Resumable: a run whose file exists is skipped, so the same command without `--fresh` goes on
  after an interruption. `--only seq,claude` and `--runs N` narrow it (with `--only`, only the
  scenarios that ran are checked).
- The app is terminated after each run and when the script ends or is interrupted.
- Every measured `unicode` run follows an unmeasured one, whose result is thrown away. The
  scenario's time to the final frame is likely mostly CoreText loading its fallback fonts (CJK, emoji) in
  the new process. On a simulator in its first minutes after its first boot that load is slow
  unless a process did the same seconds before: 110 to 310 ms with one or two frame gaps over
  25 ms, on any commit, against 16 to 57 ms right after another launch and on a simulator that
  has settled.
- Replay runs use no server. `--live` opens the named session in mirror mode (no claim, no
  resize) after `seq 1 3000` in its pane. Use a throwaway session. Live numbers have no budget:
  they depend on the network and the server.
- On the iPhone Duo: `scripts/bench/run-device.sh [--runs 5] [--only …] [--live zz-bench]`
  (header comment). It builds the `BENCH` Release on the build Mac, installs it, copies the scenarios
  into the app's Documents and launches the app once per run through `devicectl`. `--tag` and
  `--args` compare builds or switches in one results folder; `--clean` deletes the files it left
  on the phone; `--stop` quits the app. The phone must be unlocked, awake and left alone.
  Reinstall the shipping build with `scripts/install-duo.sh` afterwards. No budgets on device.

### Budgets

`scripts/bench/budgets.mjs` holds them, one small file. The median of a scenario's runs must not
pass:

| Number | Budget | Measured (iPhone 17 simulator, `983d27f`) |
| --- | --- | --- |
| main-thread hitches over 25 ms | 1, every scenario | 0 |
| worst main slice | 8 ms, every scenario | 0.3 to 1.2 ms |
| main busy | `seq`, `yes` 10 ms; `unicode` 15; `yes-wire` 35; `seq-wire` 90; `top` 160; `claude` 250 | 2.2, 1.7; 4.4; 13.3; 40; 78; 122 |
| frame gaps over 25 ms | 1, every scenario but `top` (it draws twice a second by itself) | 0 |
| first byte to the final frame | `seq`, `yes` 60 ms; `unicode` 150 | 19.7, 21.4; 38.3 |
| memory peak, at rest | 40 MB, 32 MB | 23.5 to 32, 23.4 to 26.6 |

Find open runs the same budgets: `seq-find`, `unicode-find` and `claude-find` replay with find
open and step 20 matches (`-findTest 99` for `seq`'s digits, `e` for the others, `-findSteps 20`;
`seq-find` also flings with `-perfScroll 6`), and `cap-find` (`-findTest 99`) streams
`yes` after `seq 1 10000` filled the scrollback to its cap, so every line prunes one. Each result
also has `ghosttyRender.termLockWaitWorstMs` (the render thread's longest wait for the terminal
lock, every run) and, with find open, `find` (passes, feeds, total) and a `find` phase for the steps.

Times have about twice the measured median as headroom, memory a quarter, so a busy Mac doesn't
fail a run and a real regression does. They hold for the iPhone 17 simulator at 60 Hz, grid 60×50
at 11 pt; they are not device numbers. A change that moves a number on purpose moves its budget
in the same commit.

### What is measured

`PerfProbe` (`RexDuo/Features/Terminal/Perf/PerfProbe.swift`, launch argument `-perfLog
<name>`) writes one JSON file per run. Its header comment defines every number. In short:

- **First frame**: pane open (`TerminalHost.init`) to the first frame that shows the restored
  screen, with the steps between (connecting, socket live, snapshot received, restored).
- **First output, parsed, drawn**: from the first `streamFeed` to the first frame that shows the
  first chunk, to the last byte parsed, and to the frame that shows the final state. The
  first-output mark is queued behind the first chunk's bytes, and a frame that still waits for
  glyphs decides no mark: "drawn" means drawn with every glyph.
- **Main gaps**: gaps over 25 ms between callbacks of a main-thread display link (hitches).
- **Frame gaps, frames/s**: frames handed to the GPU: presents on the render thread.
- **Hitches** (`hitches`): the same two event streams against the display's own interval: a gap
  over 1.5 frames (12.5 ms at 120 Hz) is a hitch, and the time past one frame is hitch time.
  Presents only count where every refresh should have a frame (bursts, the fling).
- **Energy** (`power`): what the kernel charges the process (`TASK_POWER_INFO_V2`: CPU energy,
  wake-ups). Zero in the simulator; GPU energy isn't reported on the Duo.
- **Main busy**: main run loop time between waking and sleeping; the worst slice is the longest
  time the main thread could not react.
- **CPU**: user + system time of the process, and of the main thread.
- **Memory**: `phys_footprint`, peak during the run and 2 s after it, with 10,000 lines of
  scrollback.

Without `-perfLog`, `PerfProbe.active` is nil and every hook is one branch.

Live runs can add phases after the first frame: `-perfIdle <s>` (the pane sits still with the
probe's own link and timers stopped: CPU, wake-ups, render ticks and passes, energy) and
`-perfScroll <s>` (a fling by program through up to 1000 rows of scrollback and back, one scroll
view offset per refresh: frames/s and hitches). The launch transition reports its steps from
process start, which peel ran, and the Metal peel's frame times and missed refreshes.

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

## Device measurements (iPhone Duo, 120 Hz)

Measured 2026-11-17 with `scripts/bench/run-device.sh` on the iPhone Duo (`iPhone19,4`, iOS
27.2.1, 6 cores, ProMotion at 120 Hz), on the charger; the fold posture was not recorded. Release builds
with `BENCH`, assertions off; grid 60×50 at 12 pt (the phone's font size), drawn 1:1. Each cell is
the median of 5 runs, with the p95 in brackets (with 5 runs, the highest).

Replay:

| Scenario | drawn ms | first output ms | main busy ms | worst main slice ms | main hitches | worst main gap ms | frames/s | CPU ms | CPU energy mJ | peak MB |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| seq | 24.5 (31.4) | 5.5 (7.9) | 4.6 (5.1) | 1.4 (1.8) | 0 (0) | 8.4 (8.4) | 145 (163) | 33.4 (35.9) | 4.6 (7.9) | 92.5 (108) |
| unicode | 40.2 (101) | 40.2 (101) | 6.4 (6.7) | 1.2 (1.7) | 0 (0) | 8.4 (8.4) | 124 (131) | 70.5 (111) | 13.0 (80.1) | 95.8 (98.1) |
| claude | 9962 (9963) | 5.7 (11.6) | 79.5 (82.1) | 1.5 (1.8) | 0 (0) | 8.4 (8.6) | 60.1 (60.2) | 630 (642) | 44.0 (48.5) | 87.2 (87.3) |
| top | 9982 (9985) | 4.7 (5.4) | 44.0 (45.9) | 1 (1.1) | 0 (0) | 8.5 (10.3) | 2.1 (2.1) | 119 (124) | 8 (8.3) | 73.3 (78.7) |

Live, time to first frame (ms after pane open, `zz-bench` after `seq 1 3000`, mirror sizing, 5
cold launches each):

| connecting | socket live | first frame | peak MB |
| --- | --- | --- | --- |
| 76.2 (99.0) | 144 (209) | 149 (212) | 184 (188) |

Reading it:

- **Hitches at 120 Hz** (a refresh with no frame: a gap over 12.5 ms). The main thread never
  missed a refresh in any replay run. Bursts present at 124 to 145 frames a second (frames drawn
  straight from a wake-up, plus the ticks) with no present hitch at the median; `claude` and `top` present as fast as they draw (60 and
  2 a second).
- **Memory is about three times the simulator's** (65 to 96 MB in replay, against 25 to 32): on
  the device the Metal drawables and textures count in the footprint (a full-screen drawable
  is about 11 MB folded, three per pane). Live runs peak at 184 MB
  during launch (the launch transition's full-screen layers) and settle at 79 MB.
- **Live is network-bound and quick**: the stream starts 76 ms after pane open and the first
  frame follows the snapshot by 2 ms. The simulator's 320 ms before the stream starts (cold
  launch) is not there on the device.

Launch (Ghostty, `main`, warm launches, ms after process start, median (p95)):

- The peel's Metal kit is ready at 135 (270), its first frame drawn and the Metal peel chosen at
  238 (337), the splash shown at 210 (317). The transition starts at 600 (the minimum splash)
  and ends at 2003 (2020): the app takes touches from then. The pane opens at 362 (436) and
  shows its first frame at 511 (648), under the splash. The Metal peel ran in every launch, with
  about 360 ms to spare.
- Peel frames: 110, one every 8.33 ms at the median, GPU 3.2 ms (6.6 at most), never late on
  the GPU. But 12 refreshes are missed per launch (about 100 ms of hitch time in 1 s), see below.

Idle (pane open and still, 10 s, probe's own timers stopped):

- The terminal costs nothing: no display link tick, no render pass, no frame. The cursor blink
  timer doesn't run in a mirror-mode test pane without the keyboard.
- The process still uses 2.5% of a core (p95 4.5%), 65 wake-ups a second (3 from idle), about
  2.5 mW of CPU energy: the sockets to the three saved servers and their events, not the engine.

Scroll (a 6 s fling through 1000 rows each way, one offset per refresh):

- 120 frames a second; 1 hitch per fling at the median (6 at p95), 1.2 ms of hitch time per
  second (5.3 at p95; Apple counts under 5 as good). Worst main-thread slice 1.4 ms, row build
  0.04 ms per frame, 12% of a core.

Limits:

- **No Instruments traces.** `xctrace` on the build Mac lists the Duo as offline (it can't parse iOS
  build 24B91034), so Time Profiler, Metal System Trace and Animation Hitches could not record,
  on the device or, as it turned out, on the simulator. Hitches here come from the probe's own
  display link and present times; time on the GPU and in the compositor is in no number. A
  `sample` of a simulator `claude` replay found the process waiting almost all the time, with
  the row build the busiest code of ours.
- Energy is the kernel's CPU-side figure; GPU energy isn't reported on the Duo.
- The phone was on the charger and warm after many runs; a cool phone on battery may differ.

What the measurements changed:

- **No engine change was needed.** No main-thread stall, no redraw while idle, no hitch source in
  the terminal, and the glyph atlas never showed up. The budgets stay simulator budgets.
- **The launch peel missed 12 refreshes per launch** (gaps of 16.7 and 25 ms) in the first
  session, with the GPU never late. A launch in a later session (folded, outer screen) missed none (122 frames,
  GPU 0.9 ms). The probe now records where each miss falls (`launch.peelHitchesAt`), how long
  before its target each callback ran, and the main thread during the transition. `-peelLeadIn
  <s>` (draw still frames before the start, so ProMotion is at 120 Hz when the motion starts)
  and `-drawables 2` (one less full-screen drawable per pane, about 11 MB folded) are benchmark
  switches for the comparison that was cut short; neither changes a shipped build.

## Not done

Two ideas from the measurements that were not built:

1. **Start the stream before the host's first layout.** In the simulator about 320 of the
   454 ms to the first frame passed between `TerminalHost.init` and `streamStatus(.connecting)`;
   on the Duo it is 76 ms of 149, so the gain is small there. A snapshot needs no size from the
   client, so a mirror-mode pane could start its stream in `init`.
2. **One main-actor hop per chunk.** `TerminalStream` takes every WebSocket message on the main
   actor, runs `APCFilter` there, and `GhosttyCore.feed` copies the bytes into its queue. That
   is all of the main-thread time under output: about 30 µs a chunk (on the Duo, 80 ms of main
   thread for 10 s of `claude`). Running the filter on
   the socket's queue and handing output straight to the core would bring it near zero.

Not a problem at today's sizes: the host joins snapshot bytes and decodes at `end` instead of at
READY (a 22 KB snapshot arrives in one message and restores in about 1 ms), and the lock between
feed slices and `begin_update`. Both would need a large history over a slow link to show, which
was not measured.
