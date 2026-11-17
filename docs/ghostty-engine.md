# The terminal engine

Rex DUO's terminal: **libghostty-vt** (upstream's `ghostty-vt.xcframework`) parses the stream
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

Locks of one `GhosttyCore` (`GhosttyLock`, an `os_unfair_lock`):

- `termLock`: the terminal, its size, colors, the prompt watch, the selection anchor.
- `stateLock`: the render state and its iterators, the render hold, the scrollbar.
- `opLock`: the queue of work for the feed queue. `handlerLock`: the dirty handler.

**Lock order: `termLock` first, then `stateLock`.** Under those come the small ones that are
never held while taking another: the scroll state's lock, the input mirror's, the clipboard's,
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
  pre-build phase runs it on every build, and the macdesk scripts run it before copying or
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
- **Worktree-isolated agents** must give git absolute paths inside the worktree, and can't run
  compound shell commands that use git. They can symlink another checkout's `Vendor`.

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
- Replay runs use no server. `--live` opens the named session in mirror mode (no claim, no
  resize) after `seq 1 3000` in its pane. Use a throwaway session. Live numbers have no budget:
  they depend on the network and the server.
- Device, untested: install a Release build made with the `BENCH` compilation condition, copy the
  scenario files into the app's Documents (`xcrun devicectl device copy to … --domain-type
  appDataContainer`), launch with `-replay <name> -perfLog <name>` (a relative `-replay` path is
  read from Documents), and copy `Documents/perf/*.json` back. The budgets are simulator budgets.

### Budgets

`scripts/bench/budgets.mjs` holds them, one small file. The median of a scenario's runs must not
pass:

| Number | Budget | Measured (comparison run, below) |
| --- | --- | --- |
| main-thread hitches over 25 ms | 1, every scenario | 0 |
| worst main slice | 8 ms, every scenario | 0.3 to 1.2 ms |
| main busy | `seq`, `yes` 10 ms; `unicode` 15; `yes-wire` 35; `seq-wire` 90; `top` 160; `claude` 250 | 2.2, 1.7; 4.4; 13.3; 40; 78; 122 |
| frame gaps over 25 ms | 1, every scenario but `top` (it draws twice a second by itself) | 0 |
| first byte to the final frame | `seq`, `yes` 60 ms; `unicode` 150 | 19.7, 21.4; 38.3 |
| memory peak, at rest | 40 MB, 32 MB | 23.5 to 32, 23.4 to 26.6 |

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
- **Main busy**: main run loop time between waking and sleeping; the worst slice is the longest
  time the main thread could not react.
- **CPU**: user + system time of the process, and of the main thread.
- **Memory**: `phys_footprint`, peak during the run and 2 s after it, with 10,000 lines of
  scrollback.

Without `-perfLog`, `PerfProbe.active` is nil and every hook is one branch.

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

## The comparison with SwiftTerm (a record)

Until November 2026 the app had a second engine, SwiftTerm 1.99.3, and this benchmark ran every
scenario on both. Ghostty met every criterion and SwiftTerm was removed. **The comparison cannot
be run again**: the SwiftTerm engine, its package and the benchmark's engine dimension are gone
from the code. What follows is the last run, kept as the record and as the source of the budgets
above.

- Code: `ghostty-engine` at `983d27f` (the last commit with both engines is `307a4c4`).
- Where: iPhone 17 simulator (`iPhone18,3`), iOS 27.2, 60 Hz, on a 14-core Apple silicon Mac.
  Release build, assertions off (each result file recorded it), grid 60×50 at 11 pt, drawn 1:1.
- Replay: 7 scenarios × 2 engines × 5 runs. Live: 5 cold launches per engine. Median (min–max).
- Criteria then: Ghostty better on first frame, gaps and main-thread time in every scenario, and
  within 10% on memory. All met.

Read the numbers with these limits in mind:

- **A simulator draws with the Mac's GPU and runs on the Mac's cores.** The numbers compare the
  two engines; they are not device numbers.
- **No device run was made.**
- **The two engines' frame-gap counts measured different things.** Ghostty presents when a frame
  arrives (at most one per display interval), so its count is stalls of the renderer. SwiftTerm
  drew from its display link, so its count also included a frame that slipped past a vsync.
- **The engine has changed since `983d27f`** (review fixes up to `307a4c4`, then the removal), so
  today's numbers for Ghostty need not equal this table's. The budgets are what is checked now.

### Results of the comparison

Replay: 5 runs per cell, median (min–max). iPhone18,3 simulator, Version 27.2 (Build 24B8117), 60 Hz, grid 60×50, 11 pt.

Replay:

| Scenario | Engine | first output ms | parsed ms | drawn ms | frames/s | frame gaps >25 ms | main gaps >25 ms | worst main gap ms | main busy ms | worst main slice ms | CPU ms (main) | peak MB | idle MB |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| claude | SwiftTerm | 32.7 (5.70–45.8) | 9978 (9975–9997) | 9988 (9980–10000) | 59.9 (59.8–60) | 1 (1–3) | 1 (1–2) | 32.8 (32.8–33) | 2384 (2257–2596) | 29.9 (24.6–33.6) | 2675 (2539–2887), main 2353 | 24.9 (23.8–25.1) | 24.9 (23.8–25.1) |
| claude | Ghostty | 12.4 (1.60–18.4) | 9961 (9959–9977) | 9968 (9961–9993) | 60.1 (60.1–60.1) | 0 (0–1) | 0 (0–1) | 17.5 (17–32.6) | 122 (111–135) | 1.18 (1–1.23) | 821 (770–919), main 176 | 24.9 (23.9–24.9) | 24.8 (23.8–24.9) |
| seq-wire | SwiftTerm | 22.6 (16.2–25.8) | 722 (720–725) | 732 (729–733) | 60.1 (60.1–60.4) | 0 (0–1) | 0 (0–1) | 17.4 (16.8–28.2) | 214 (177–230) | 10.8 (8.41–14.9) | 211 (173–225), main 173 | 32.6 (32.2–33.1) | 32.3 (32.2–33.1) |
| seq-wire | Ghostty | 3.33 (1.98–13.1) | 723 (702–725) | 729 (709–740) | 62.1 (61.6–62.3) | 0 (0–0) | 0 (0–1) | 16.8 (16.7–27.6) | 40 (18.4–44.7) | 0.71 (0.28–5.73) | 175 (92.3–200), main 50 | 29.7 (29.6–30) | 25.2 (25–25.4) |
| seq | SwiftTerm | 38.8 (34.4–44.2) | 59.4 (58.6–66.2) | 79.4 (77–83.8) | 50.4 (47.7–52) | 1 (1–1) | 0 (0–1) | 17.8 (16.8–33.1) | 44 (32.2–46.2) | 14.4 (10.5–16.1) | 40.6 (29–44), main 37 | 31.9 (31.8–32.5) | 30.4 (30.4–30.5) |
| seq | Ghostty | 8.56 (3.50–16.6) | 12.1 (7.20–16) | 19.7 (12.3–25.2) | 121 (119–162) | 0 (0–0) | 0 (0–0) | 16.7 (11.4–23.9) | 2.23 (1.62–2.93) | 0.32 (0.15–0.39) | 16.2 (12.3–18.7), main 2.81 | 30 (29.5–31) | 25.3 (25–25.5) |
| top | SwiftTerm | 13.7 (5.73–26.1) | 10000 (9996–10001) | 10012 (10006–10015) | 2.20 (2.20–2.20) | 21 (20–21) | 1 (0–3) | 32.8 (18.1–33) | 235 (206–257) | 19.2 (11.5–22) | 295 (263–329), main 266 | 22.9 (22.8–22.9) | 21.9 (21.8–21.9) |
| top | Ghostty | 4.63 (3.72–17.4) | 9984 (9979–10000) | 9984 (9979–10001) | 2.10 (2.10–2.20) | 20 (20–20) | 0 (0–0) | 17.6 (17.5–19.4) | 78.2 (68.1–91.8) | 0.92 (0.34–1.31) | 179 (160–211), main 132 | 23.5 (23.2–23.6) | 23.4 (23.2–23.5) |
| unicode | SwiftTerm | 161 (64.3–328) | 254 (174–443) | 272 (195–467) | 29.4 (19.3–46.1) | 2 (1–2) | 1 (1–2) | 133 (49.9–333) | 218 (145–392) | 128 (39.8–303) | 117 (108–122), main 109 | 35.2 (34.9–35.7) | 33 (32.9–33.1) |
| unicode | Ghostty | 38.3 (16.8–114) | 21.4 (17.1–24.6) | 38.3 (28.6–114) | 78.3 (61.6–105) | 0 (0–2) | 0 (0–0) | 16.7 (16.7–16.7) | 4.39 (3.96–5.64) | 0.30 (0.19–0.57) | 41.1 (37.6–54.7), main 5.39 | 32 (31.9–32.2) | 26.6 (26.4–26.7) |
| yes-wire | SwiftTerm | 19.4 (10.2–27.1) | 279 (275–294) | 294 (286–303) | 59.9 (59.4–61.9) | 0 (0–1) | 0 (0–1) | 17.2 (16.7–28) | 95 (68.9–105) | 8.76 (6.15–10.6) | 90.5 (66.4–99.4), main 74.4 | 29.5 (29.4–30.1) | 29.4 (29.4–29.5) |
| yes-wire | Ghostty | 7.02 (3.09–19.7) | 259 (256–261) | 266 (261–272) | 64 (62.6–65) | 0 (0–0) | 0 (0–0) | 16.7 (16.7–17.2) | 13.3 (12.6–17.2) | 0.52 (0.31–0.80) | 68.1 (65.6–77.7), main 17.1 | 29.1 (29–29.1) | 24.4 (24.4–24.4) |
| yes | SwiftTerm | 34.3 (31.1–38.8) | 56 (38.9–58.4) | 73.5 (57.3–75.8) | 52.3 (39.6–54.4) | 1 (1–2) | 0 (0–0) | 17.2 (16.9–18) | 41.1 (28.3–46.2) | 14.1 (10.6–16.8) | 36.9 (23.3–40.9), main 34.4 | 30 (29.9–30.4) | 30 (29.9–30.2) |
| yes | Ghostty | 9.82 (5.78–13.9) | 12.9 (9.61–15.4) | 21.4 (13.9–25.4) | 118 (93.4–144) | 0 (0–0) | 0 (0–0) | 16.7 (12.9–16.7) | 1.74 (1.11–2.11) | 0.31 (0.18–0.61) | 18.5 (12.7–18.6), main 2.16 | 29.1 (28.7–29.6) | 24.4 (24.1–24.5) |

Live: time to first frame, ms after pane open (5 cold launches per engine):

| Scenario | Engine | connecting | socket live | snapshot received | restored | first frame | snapshot bytes | peak MB |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| live | SwiftTerm | 334 (333–389) | 502 (478–607) | 467 (445–588) | 468 (446–589) | 501 (480–607) | 23036 (23036–23036) | 46.1 (45.9–47.8) |
| live | Ghostty | 320 (305–330) | 452 (412–480) | 452 (412–485) | 454 (414–486) | 454 (414–487) | 22861 (22861–22861) | 38.1 (37.9–38.3) |

Pass / fail, as the comparison's report printed it:

- first frame: **pass**
- main gaps >25 ms: **pass**
- frame gaps >25 ms: **pass**
- worst main gap: **pass**
- main-thread time: **pass**
- memory peak: **pass**
- memory idle: **pass**
- first output (info): **pass**
- final state drawn (info): **pass**

Criteria (first frame, gaps, main-thread time, memory within 10%): **PASS**

### Reading the comparison

- **Ghostty wins every main-thread number.** Its main thread only passes chunks on: 2 to 122 ms
  busy where SwiftTerm needs 41 to 2384 ms, and a worst slice of about 1 ms where SwiftTerm has
  9 to 128 ms. Ghostty has no main-thread hitch over 25 ms at the median in any scenario.
- **Ghostty parses 4 to 12 times faster** in the bursts (`seq`: 12 ms against 59 ms; `unicode`:
  21 ms against 254 ms) and shows the final state sooner in every one. The `-wire`, `top` and
  `claude` runs are fed in real time, so their parse times are the feed's length for both.
- **CPU**: lower in every scenario; in `claude`, 821 ms against 2675 ms for 10 s of repaints.
- **First frame, live: 454 ms against 501 ms.** Ghostty has no `terminal.format` round trips: its
  first frame comes 2 ms after the socket is live, SwiftTerm's when its screen read and the
  socket are both done. About 320 ms of both pass before the stream is even started (cold
  launch, see below).
- **Frame gaps**: Ghostty has none at the median outside `top`, where the program itself draws
  twice a second and both engines count its 20 pauses. See the limit above on comparing them.
- **Memory**: within 10% everywhere. Ghostty's peak is equal or up to 3 MB lower, and at rest it
  is up to 7 MB lower (it compresses history when idle), except `top`: 0.6 MB higher at peak and
  1.5 MB higher at rest.
- **Noisy cells**: first output on both engines (a wait for the next vsync, see below), and
  `unicode` on SwiftTerm (first output 64 to 328 ms).

### Fairness and limits of the comparison

- The probe adds the same main-thread display link and run loop observers to both engines:
  about 6 ms of main busy time per second. SwiftTerm also pays three reads of its counters per
  run loop pass; that cost was not measured separately and is small against its numbers.
- "Frame handed to the GPU" is a commit on the CPU side for both engines. Time on the GPU and
  in the compositor is not in any number.
- SwiftTerm frames are seen at the end of the run loop pass that drew them, Ghostty's at the
  commit. That can add under a millisecond to SwiftTerm's times.
- The simulator's display is 60 Hz, so a "first output" below one frame (16.7 ms) is mostly the
  wait for the next vsync. A 120 Hz device halves that for both.
- `seq` and `yes` at full speed last 20 to 80 ms: their gap counts are a handful of frames. The
  `-wire` runs are the ones to read for pacing.
- Replay has no `terminal.format` text to seed SwiftTerm with, so replay measures no first
  frame. The fair number is the live one, which includes the round trips SwiftTerm really made.
- Live first frame is a cold app launch into `-autoOpen`: launch work is inside it for both.
  Mirror mode skips fit mode's 120 ms settle and claim, for both.

## Not done

Two ideas from the measurements that were not built:

1. **Start the stream before the host's first layout.** In the live runs about 320 of the
   454 ms to the first frame pass between `TerminalHost.init` and `streamStatus(.connecting)` (cold launch: SwiftUI
   and the launch transition). A snapshot needs no size from the client, so a mirror-mode pane
   could start its stream in `init`. The gain on a warm pane switch was not measured.
2. **One main-actor hop per chunk.** `TerminalStream` takes every WebSocket message on the main
   actor, runs `APCFilter` there, and `GhosttyCore.feed` copies the bytes into its queue. That
   is all of the main-thread time under output: about 30 µs a chunk. Running the filter on
   the socket's queue and handing output straight to the core would bring it near zero.

Not a problem at today's sizes: the host joins snapshot bytes and decodes at `end` instead of at
READY (a 22 KB snapshot arrives in one message and restores in about 1 ms), and the lock between
feed slices and `begin_update`. Both would need a large history over a slow link to show, which
was not measured.
