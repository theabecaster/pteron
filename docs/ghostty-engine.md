# Ghostty engine (handoff)

Status: research done, toolchain done, engine seam started. Nothing is wired into the app yet.
The app still builds and runs on SwiftTerm.

## Decision

Use **libghostty-vt** (upstream `ghostty-vt.xcframework`) for parsing and terminal state, plus
**our own Metal cell renderer**. Restore Rex's `GHOSTSNP` snapshot directly.

Why:
- **libghostty-vt has everything a remote client needs** through a C API:
  - `ghostty_snapshot_decoder_*`: one-call or incremental restore (`ready()`, then `next()`).
  - render state with dirty rows (`ghostty_render_state_*`, two-phase update for lock-light reads).
  - selection, including select word and line.
  - formatter for copy (plain text, VT or HTML).
  - key encoder (DECCKM, Kitty protocol) and mouse encoder (SGR and the other formats).
  - paste encoding, scroll viewport, modes, scrollbar.
- **Upstream builds iOS slices** with `-Demit-lib-vt -Demit-xcframework`.
- **The Rex Mac app uses the same split.** Its `swift-ghostty` / `GhosttyRender` pairs libghostty
  with its own Metal renderer.
- **Rejected: GhosttyKit, the full libghostty from `include/ghostty.h`.**
  - Its only termio backend is `Exec` (local PTY plus subprocess).
  - It has no external or manual backend, so a remote byte source would need a termio patch to a
    fast-moving tree.
  - It also can't restore a snapshot into a surface.
- **Snapshot fidelity is verified.** A real Rex stream (server 0.1.0-preview.19, snapshot
  version 1) decoded at the pinned commit:
  - 6422 bytes decoded in 0.29 ms on an M-series Mac.
  - `GHOSTTY_SNAPSHOT_DECODER_DATA_SOURCE_OFFSET` points exactly at the first `ESC _ rex1;` APC
    (the `resize` message).
  - Live VT bytes fed after it rendered correctly (`seq 1 2000`).
- **Reflow matches the server.** The server is Ghostty too, so a local `ghostty_terminal_resize`
  reflows the same way. SwiftTerm doesn't.

## Toolchain (done)

- `scripts/ghostty.version` pins Ghostty `5ebe501a63425b13d9952e8c54682c046386e5af`
  (main, 2026-11-16) and Zig 0.17.1 (its `minimum_zig_version`), with the tarball's SHA-256.
- `scripts/build-ghostty.sh` (zsh, Apple silicon only) does all of the following:
  - Fetches Zig into `Vendor/zig-0.17.1/`.
  - Clones Ghostty into `Vendor/ghostty/` and checks out the pin.
  - Applies `scripts/ghostty-patches/*.patch`. There are none yet.
  - Runs `zig build -Demit-lib-vt=true -Demit-xcframework=true -Doptimize=ReleaseFast` with
    `ZIG_GLOBAL_CACHE_DIR=Vendor/zig-global-cache`.
  - Copies the result to `Vendor/GhosttyVt.xcframework`.
  - Skips the build when the pins haven't changed. `--force` rebuilds.
- `Vendor/` is gitignored. Nothing is installed system-wide.
- Cold build: 130 s wall (291 s CPU) on a 14-core M-series Mac, including the 51 MB Zig download.
- Output sizes:
  - `GhosttyVt.xcframework`: 51 MB.
  - iOS arm64 and simulator static libs: 12.5 MB each.
  - macOS universal: 27 MB.
- Slices: `ios-arm64`, `ios-arm64-simulator`, `macos-arm64_x86_64`.
- Swift module name: `GhosttyVt`. Umbrella header: `ghostty/vt.h`.

Tools in `scripts/ghostty-tools/`:
- `capture.mjs` (Node 24, built-in WebSocket) dumps a real data stream.
  Usage: `node capture.mjs <https server> <session id> <block id> <out> <seconds> [text to type]`.
  It also writes `<out>.nonce`.
- `decode.c` decodes a capture with the macOS slice. Build:
  `clang -O2 -I$X/Headers decode.c $X/libghostty-vt.a -lc++ -o decode`,
  where `X=Vendor/GhosttyVt.xcframework/macos-arm64_x86_64`.

## Done in code

- `RexDuo/Terminal/TerminalEngine.swift`: compiles standalone, not yet used.
  - `TerminalEngineKind`: Ghostty or SwiftTerm, stored in UserDefaults `terminalEngine`, default
    Ghostty.
  - `TerminalKeyTarget`: what `KeyBar` needs. `SwiftTerm.TerminalView` conforms as is.
  - `TerminalEngineDelegate`.
  - `TerminalEngineView`: the seam protocol, modeled on the calls `TerminalHost` makes on `term`
    today, so the `TerminalHost` diff stays small.

## Plan (2026-11-16)

Goal: a Ghostty engine that beats SwiftTerm on every benchmark below with no parity regressions.
SwiftTerm stays as the fallback behind `TerminalEngineView`. Nothing ships to a device or to
`main` without the user's yes.

### Phases

| # | Chunk | Owner | Files (exclusive) | Gate to merge |
| --- | --- | --- | --- | --- |
| 0 | Link `GhosttyVt`, add `RexDuoTests`, build green | lead | `project.yml`, `.gitignore`, `RexDuoTests/` | app builds, empty test passes |
| 1a | Seam + UI: SwiftTerm adapter, `TerminalHost` on `any TerminalEngineView`, engine picker, pane-menu label | agent | `TerminalHost.swift`, `KeyBar.swift`, `SettingsView.swift`, `WindowScreen.swift`, `Terminal/SwiftTermEngine.swift`, `Terminal/TerminalEngine.swift` | SwiftTerm behaves as before (manual checklist in a `zz-` session) |
| 1b | Core + renderer: `GhosttyCore`, render thread, Metal renderer, glyph atlas, sprites, output-only `GhosttyTerminalView` | agent | `Terminal/Ghostty/*`, `RexDuoTests/Ghostty*` | unit tests; offline replay of a capture matches a reference screenshot |
| 1c | Stream: snapshot handoff in `APCFilter`, `restoresGhosttySnapshot`, fallback to `resync()` | agent | `Protocol/TerminalStream.swift`, `RexDuoTests/APCFilter*` | unit tests on real captures, split at every chunk boundary |
| 2a | Input: `UIKeyInput`, hardware keys through the key encoder, key bar modifiers, paste, marked text | agent | `Ghostty/GhosttyTerminalView+Input.swift`, `GhosttyCore+Input.swift` | key-encoding tests against SwiftTerm's bytes |
| 2b | Scroll + mouse: native scroll, scrollbar, wheel and arrow drags, tap click | agent | `Ghostty/…+Scroll.swift`, `GhosttyCore+Scroll.swift` | tests on mouse bytes; manual scroll check |
| 2c | Selection: long press word, drag, copy, edit menu, copy-on-select shimmer | agent | `Ghostty/…+Selection.swift`, `GhosttyCore+Selection.swift` | selection-text tests |
| 2d | Benchmarks: `PerfProbe`, offline replay mode, `scripts/bench/` | agent | `Terminal/PerfProbe.swift`, `Terminal/ReplayScreen.swift`, `scripts/bench/*` | SwiftTerm baseline table in this doc |
| 3 | Parity run, tuning from benchmark results, review, `git merge main` | lead | all | checklist all green; Ghostty wins every metric |

Phase 1 chunks run in parallel, then phase 2 chunks. Each agent works in its own git worktree
(with `Vendor` symlinked), its own simulator (`zz-gh-<chunk>`) and its own Rex session
(`zz-gh-<chunk>`), and deletes all three when done. The lead merges each chunk after a focused
review, and runs `git merge main` before every phase.

### Quality gates

1. **Unit tests** (`RexDuoTests`, seconds to run): core feed and resize, snapshot restore from
   fixtures, row building, key and mouse bytes, selection text, `APCFilter`.
2. **Offline replay** (`-replay <capture> -terminalEngine <kind>`): feeds a recorded stream into
   an engine with no server. It is the deterministic benchmark and the screenshot check. It never
   touches a real pane.
3. **Live run** in a `zz-` session: only for what replay can't cover (fit claim, input round
   trip, reconnect).
4. **Review** of each chunk's diff before merge.

### Benchmarks

`PerfProbe` (launch argument `-perfLog`) writes one JSON file per run:
- time to first frame: pane open to the first presented frame with content.
- frame gaps over 25 ms, from a main-thread display link and from the renderer's presents.
- main-thread busy time, from a run-loop observer.
- memory: `phys_footprint` peak and at rest.

Scenarios, each on both engines, 3 runs, median reported:
`seq 1 200000`, `yes | head -n 200000`, 10 s of htop, and a Claude Code-style redraw loop
(synchronized output, full-screen repaints, spinner). Captures of these feed the offline replay.
Simulator numbers compare the engines; a device run needs the user's yes.

Pass: Ghostty is better on first frame, gaps and main-thread time in every scenario, and within
10% on memory with the same scrollback budget.

### Parity checklist

Tracked in `docs/ghostty-parity.md` (created in phase 2), one row per item with its test:
feed and resize; system keyboard; key bar; hardware keyboard; scroll and scrollback; pinch font;
long-press selection, drag, copy, copy-on-select shimmer; theme colors; MesloLGS NF in four
styles; box-drawing and block sprites; cursor styles and blink; mouse and wheel reports; 120 Hz;
mirror-mode zoom; fit-mode claim and "resized elsewhere"; reconnect and resume; background and
foreground.

## Design

1. **project.yml**
   - Add `- framework: Vendor/GhosttyVt.xcframework` (`embed: false`) to the RexDuo target.
   - Add `OTHER_LDFLAGS: -lc++`. simdutf and highway are C++.
   - Document in README that you run `scripts/build-ghostty.sh` once first.
2. **SwiftTerm adapter (new file)**
   - `extension RexTerminalView: TerminalEngineView`.
   - Move the SwiftTerm-only parts of `TerminalHost` behind it: fonts, colors, the bounds trick in
     `applyLocalGrid`, `getOptimalFrameSize` cell size, the long-press word select and menu.
   - `TerminalHost` keeps its `TerminalViewDelegate` conformance for SwiftTerm.
   - It also gains `TerminalEngineDelegate` for Ghostty.
3. **TerminalHost seam**
   - `term: any TerminalEngineView`, picked at init from `TerminalEngineKind.current`.
   - `streamFeed`: if `term.parsesOffMainThread`, feed directly and skip the display-link pacing.
   - `setFontSize`: set `needsResync` only if `term.fontChangeResetsModes`.
   - `streamReset`'s `feed(text: "\ec\e[3J")` works on both engines.
4. **TerminalStream** (additive)
   - Add `restoresGhosttySnapshot`.
   - When set, `fullStart` skips `terminal.size` and `readScreen`. That removes the
     `terminal.format` and `blob_read` round trips. It goes straight to `data.connect` and the
     WebSocket.
   - `APCFilter` collects the bytes it skips today. When `skippingSnapshot` flips, it hands them
     to a new sink call (`streamGhosttySnapshot`) **before** the `resize` message in the same
     chunk.
   - On decode failure, fall back to `resync()`, which uses the `terminal.format` path.
   - Feed bytes after `SOURCE_OFFSET` as live VT. Resume (RESUME) carries no snapshot. A fresh
     HELLO always does.
   - Optional: render after READY for huge scrollback. Use the record framing in the guide
     (`Vendor/ghostty/dist/doxygen/pages/guides/snapshots.md`): decode the prefix through READY
     for the first frame, then the full snapshot at FINISH, and swap.
5. **`RexDuo/Terminal/Ghostty/` engine**
   - **GhosttyCore**:
     - Owns the terminal, render state and encoders.
     - Uses an `os_unfair_lock` and a serial feed queue. Bytes are copied, then
       `queue.async { lock; vt_write in 64 KB slices; unlock; markDirty }`.
     - Resize and snapshot restore go on the same queue, so stream order holds.
   - **Shared render thread**:
     - One runloop with one `CADisplayLink` at 120 Hz for all panes. It pauses when idle and is
       woken with `CFRunLoopPerformBlock`.
     - Per dirty pane: lock, `begin_update`, unlock, `end_update`, rebuild dirty rows only, encode,
       present.
   - **Renderer**:
     - `CAMetalLayer`, bgra8Unorm, premultiplied blending.
     - Pipelines: instanced background rects (adjacent same-color cells merged), then glyph quads
       (r8 mask atlas plus bgra color-emoji atlas), then decoration rects (underline, strike,
       cursor).
     - Cells: read with `row_cells_next` plus `ghostty_cell_get_multi`. Call `STYLE`,
       `GRAPHEMES_BUF` and `BG_COLOR` only when the cell needs them.
     - Resolved FG/BG colors don't apply inverse or bold. Handle those yourself.
   - **Glyphs**:
     - CoreText rasterizes MesloLGS NF Regular, Bold, Italic and BoldItalic at pixel size with
       integer cell metrics.
     - Missing glyphs and graphemes go through `CTLine` for automatic fallback.
     - Fast array for ASCII. Reset the atlas on overflow.
     - Draw box drawing (U+2500–257F) and block elements (U+2580–259F) as cell-exact sprites
       (Claude Code boxes and logo, htop). Font glyphs leave gaps.
   - **View**:
     - A `UIScrollView` subclass for native scrolling. `contentSize` comes from the scrollbar
       (`total` × cell height).
     - `scrollViewDidScroll` calls `scroll_viewport(ROW)`. Fractional offset uses
       `OPT_OVERSCAN` below = 1.
     - On the alt screen or with mouse tracking, a vertical drag sends wheel (buttons 4/5) through
       the mouse encoder. On the alt screen with mode 1007 and no tracking, it sends arrows.
       This matches SwiftTerm.
     - When focused and the program tracks the mouse, a tap sends a click.
   - **Input**:
     - `UIKeyInput` plus `UITextInputTraits` (no autocorrect, no smart quotes). Return sends
       `\r`. Backspace sends 0x7f.
     - Hardware keys go through `pressesBegan` and the key encoder.
     - The KeyBar's ctrl/alt flags post SwiftTerm's `.terminalViewControlModifierReset` and
       `.terminalViewMetaModifierReset`, with the view as object.
   - **Selection**:
     - Long press uses `ghostty_terminal_select_word`. Drag sets `OPT_SELECTION` from grid refs.
     - Copy uses the formatter with `OPT_SELECTION`. The menu uses `UIEditMenuInteraction`.
   - **Theme**: after each restore and on theme change, set `OPT_COLOR_FOREGROUND`,
     `OPT_COLOR_BACKGROUND`, `OPT_COLOR_CURSOR` and `OPT_COLOR_PALETTE`.
6. **UI**
   - Settings → Terminal → "Engine: Ghostty / SwiftTerm". It applies to newly opened panes, or
     reopen the panes on `.terminalEngineChanged`.
   - Show a small engine label in Settings and in the pane menu.
   - `KeyBar.terminal` becomes `TerminalKeyTarget?`, a two-line change.
7. **Measure**
   - Run SwiftTerm and Ghostty on the same bursts: `seq 1 200000`, `yes | head -n 200000`, htop,
     and Claude Code-style redraws.
   - Collect time to first frame, frame gaps over 25 ms, main-thread time and memory.

## Gotchas

- **Never install `OPT_WRITE_PTY`.** The Rex server's own terminal already answers DA, DSR,
  mode 2048 and other queries. Answering locally would send duplicates to the program.
- **The default scrollback cap is 10,000 bytes.** Raise it with `OPT_SCROLLBACK_MAX_BYTES`. Use
  `GHOSTTY_SNAPSHOT_DECODER_OPT_COMPRESS_HISTORY` on restore to keep memory down.
- **Snapshot format v1 carries no binary-compatibility promise.**
  - Rex's server and our pin must stay close.
  - The decoder fails cleanly on a mismatch: CRC, version, strict order.
  - Keep the `terminal.format` fallback.
  - Re-pin when Rex updates its Ghostty.
- **C details**
  - `GHOSTTY_INIT_SIZED` is a macro. In Swift, set `.size = MemoryLayout<T>.size`.
  - Enums use `: int`, so they import as structs with `rawValue`.
  - Mode helpers such as `ghostty_mode_new` are static inline.
- **Threading**: terminal calls aren't thread-safe. Serialize them. Only `render_state_end_update`
  is safe without the lock.
- **Worktree-isolated agents** must give git absolute paths inside the worktree, and can't run
  compound shell commands that use git.
- **Simulator builds**: use a concrete simulator id. SwiftTerm's plugin fails on the generic
  destination. A baseline build with the required flags succeeds on Xcode 27.2.

## Measurements so far

| What | Result |
| --- | --- |
| Ghostty build (cold) | 130 s wall |
| xcframework size | 51 MB (iOS slice 12.5 MB static) |
| Rex snapshot decode (80×24, small history), macOS | 0.29 ms |
| Data stream: WELCOME, then first byte (Tailscale, same host) | 3.5 ms, then 3.8 ms |

The engine comparison table is still to be done.
