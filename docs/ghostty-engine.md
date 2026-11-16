# Ghostty engine (handoff)

Status: phases 0 and 1 are done and merged with `main`'s layout (RexConnect, feature folders,
RexKit, Swift 6). Both engines run behind `TerminalEngineView`. The Ghostty engine draws output and
restores Rex's snapshot. Phase 2 (input, scroll and mouse, selection) is merged and integrated;
the parity audit is in [ghostty-parity.md](ghostty-parity.md).

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
  - Writes `Vendor/GhosttyVt.stamp` (Ghostty commit, Zig version, patch hash).
  - Skips the build when the stamp matches the pins. `--force` rebuilds.
- `scripts/check-ghostty.sh` compares the stamp with the pins. The app target's pre-build phase
  and the macdesk scripts run it (docs/release.md).
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

- `RexConnect/Features/Terminal/Engine/TerminalEngine.swift`: the seam.
  - `TerminalEngineKind`: Ghostty or SwiftTerm, stored in UserDefaults `terminalEngine`, default
    Ghostty. `makeView` is the factory.
  - `TerminalKeyTarget`: what `KeyBar` needs. `SwiftTerm.TerminalView` conforms as is.
  - `TerminalEngineDelegate`.
  - `TerminalEngineView`: the seam protocol. `TerminalHost` holds `any TerminalEngineView` and
    doesn't import SwiftTerm. It owns the gestures, the clipboard, the copy-on-select shimmer,
    the edit menu and the hardware keymap; the engine owns the selected range, scrolling and
    key encoding (`beginSelection(at:word:)`, `extendSelection(to:autoscroll:)`,
    `selectionRects`, `selectedText`, `scrollPage`, `scrollToPrompt`, `keyHook`, …).
- `RexConnect/Features/Terminal/Engine/SwiftTermEngine.swift`: `RexTerminalView`, the SwiftTerm
  adapter and the reference for what each seam member does.
- `RexConnect/Features/Terminal/Ghostty/`: core, render thread, Metal renderer, glyph atlas,
  sprites, `GhosttyTerminalView` (output side) and its `+Input`, `+Scroll`, `+Selection` files,
  which hold input, scrolling and selection. `GhosttyDemoScreen` is the
  offline replay (`-ghosttyDemo <path>`).
- `Packages/RexKit/Sources/RexKit/TerminalStream.swift`: `GhosttySnapshotPart`, `APCFilter`'s
  snapshot framing, `restoresGhosttySnapshot`, `snapshotRestoreFailed()`.
- Tests: `RexConnectTests/SeamTests.swift` and `RexConnectTests/Ghostty*.swift` (fixtures in
  `RexConnectTests/Fixtures`) run in the simulator with the app scheme;
  `Packages/RexKit/Tests/RexKitTests/Stream*.swift` (fixtures in `Tests/RexKitTests/Fixtures`)
  run with `swift test --package-path Packages/RexKit`. Tests reach libghostty-vt only through
  the app's Swift types: the static library is linked into the app, not the test bundle.
- Build: `scripts/build-ghostty.sh`, `xcodegen generate`, then the `RexConnect` scheme (see
  AGENTS.md).

## Plan (2026-11-16)

Goal: a Ghostty engine that beats SwiftTerm on every benchmark below with no parity regressions.
SwiftTerm stays as the fallback behind `TerminalEngineView`. Nothing ships to a device or to
`main` without the user's yes.

### Phases

| # | Chunk | Owner | Files (exclusive) | Gate to merge |
| --- | --- | --- | --- | --- |
| 0 | Link `GhosttyVt`, add a test target, build green | lead | `project.yml`, `.gitignore`, `RexConnectTests/` | app builds, empty test passes |
| 1a | Seam + UI: SwiftTerm adapter, `TerminalHost` on `any TerminalEngineView`, engine picker, pane-menu label | agent | `TerminalHost.swift`, `KeyBar.swift`, `SettingsView.swift`, `WindowScreen.swift`, `Features/Terminal/Engine/SwiftTermEngine.swift`, `Engine/TerminalEngine.swift` | SwiftTerm behaves as before (manual checklist in a `zz-` session) |
| 1b | Core + renderer: `GhosttyCore`, render thread, Metal renderer, glyph atlas, sprites, output-only `GhosttyTerminalView` | agent | `Features/Terminal/Ghostty/*`, `RexConnectTests/Ghostty*` | unit tests; offline replay of a capture matches a reference screenshot |
| 1c | Stream: snapshot handoff in `APCFilter`, `restoresGhosttySnapshot`, fallback to `resync()` | agent | `Packages/RexKit/Sources/RexKit/TerminalStream.swift`, `Packages/RexKit/Tests/RexKitTests/Stream*` | unit tests on real captures, split at every chunk boundary |
| 2a | Input: `UIKeyInput`, hardware keys through the key encoder, key bar modifiers, paste, marked text | agent | `Ghostty/GhosttyTerminalView+Input.swift`, `GhosttyCore+Input.swift` | key-encoding tests against SwiftTerm's bytes |
| 2b | Scroll + mouse: native scroll, scrollbar, wheel and arrow drags, tap click | agent | `Ghostty/…+Scroll.swift`, `GhosttyCore+Scroll.swift` | tests on mouse bytes; manual scroll check |
| 2c | Selection: long press word, drag, copy, edit menu, copy-on-select shimmer | agent | `Ghostty/…+Selection.swift`, `GhosttyCore+Selection.swift` | selection-text tests |
| 2d | Benchmarks: `PerfProbe`, offline replay mode, `scripts/bench/` | agent | `Features/Terminal/Perf/*`, `scripts/bench/*`, `RexConnectTests/PerfTests.swift` | SwiftTerm baseline table in this doc |
| 3 | Parity run, tuning from benchmark results, review, `git merge main` | lead | all | checklist all green; Ghostty wins every metric |

Phase 1 chunks run in parallel, then phase 2 chunks. Each agent works in its own git worktree
(with `Vendor` symlinked), its own simulator (`zz-gh-<chunk>`) and its own Rex session
(`zz-gh-<chunk>`), and deletes all three when done. The lead merges each chunk after a focused
review, and runs `git merge main` before every phase.

Main's restructure (feature folders, the `RexKit` package, RexConnect, generated xcodeproj
untracked, Swift 6) is merged: engine files live under `RexConnect/Features/Terminal/`, the
stream's snapshot code in RexKit, and the tests in `RexConnectTests` and RexKit's `swift test`.
The phase 2 file names below are under `RexConnect/Features/Terminal/Ghostty/`.

### Quality gates

1. **Unit tests** (`RexConnectTests` and RexKit's `swift test`, seconds to run): core feed and resize, snapshot restore from
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
`seq 1 200000`, `yes | head -n 200000`, 10 s of `top` (htop isn't installed on the Rex Mac, and
we don't install packages there), and a Claude Code-style redraw loop (synchronized output,
full-screen repaints, spinner). Captures of these feed the offline replay.
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
   - Add `- framework: Vendor/GhosttyVt.xcframework` (`embed: false`) to the RexConnect target.
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
5. **`RexConnect/Features/Terminal/Ghostty/` engine**
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

The engine comparison is under Measurements below.

## Measurements

Provisional: taken 2026-11-16 while other builds and tests ran on the same Mac. The spread in
brackets shows which cells are noisy. To be rerun on a quiet machine.

- Code: `ghostty-engine` at `16a96b4` (both engines as they are there) plus the harness.
- Where: iPhone 17 simulator (`iPhone18,3`), iOS 27.2, 60 Hz, on a 14-core Apple silicon Mac.
  Release build, assertions off (each result file records it), grid 60×50 at 11 pt, drawn 1:1.
- A simulator draws with the Mac's GPU and runs on the Mac's cores. The numbers compare the two
  engines; they are not device numbers.

### How to run

```sh
xcrun simctl create zz-bench "iPhone 17"                    # prints the simulator id
rex session new zz-bench                                    # only for --live
scripts/bench/run.sh <simulator id> --fresh --live zz-bench
```

- One command: it builds Release once (`build/dd-bench`), generates the scenarios, runs
  7 scenarios × 2 engines × 3 runs, then 5 cold launches per engine for `--live`, and prints the
  report. About 8 minutes after the build, 2 more with `--live`.
- Results: `build/bench/results/<scenario>__<engine>__<run>.json`, one file per run.
  `node scripts/bench/report.mjs build/bench/results` prints the report again.
- Resumable: a run whose file exists is skipped, so the same command without `--fresh` goes on
  after an interruption. `--only seq,claude` and `--runs N` narrow it.
- The app is terminated after each run and when the script ends or is interrupted.
- Replay runs use no server. `--live` opens the named session in mirror mode (no claim, no
  resize) after `seq 1 3000` in its pane. Use a throwaway session.
- The build passes `ONLY_ACTIVE_ARCH=YES`: a Release build for the simulator otherwise also
  links x86_64, which libghostty-vt's simulator slice doesn't have. Optimization is unchanged.
- Device: not run (needs the user's yes). The harness is ready for it: install a Release build,
  copy the scenario files into the app's Documents (`xcrun devicectl device copy to …
  --domain-type appDataContainer`), launch with `-replay <name> -perfLog <name> -terminalEngine
  <kind>` (a relative `-replay` path is read from Documents), and copy `Documents/perf/*.json`
  back. These device steps are untested.

### What is measured

`PerfProbe` (`RexConnect/Features/Terminal/Perf/PerfProbe.swift`, launch argument `-perfLog
<name>`) writes one JSON file per run. Its header comment defines every number. In short:

- **First frame**: pane open (`TerminalHost.init`) to the first frame that shows the restored
  screen, with the steps between (connecting, socket live, snapshot received, restored).
- **First output, parsed, drawn**: from the first `streamFeed` to the first frame that shows the
  first chunk, to the last byte parsed, and to the frame that shows the final state.
- **Main gaps**: gaps over 25 ms between callbacks of a main-thread display link (hitches).
- **Frame gaps, frames/s**: frames handed to the GPU. Ghostty: presents on its render thread.
  SwiftTerm: its own `diagnostics.renders`.
- **Main busy**: main run loop time between waking and sleeping; the worst slice is the longest
  time the main thread could not react.
- **CPU**: user + system time of the process, and of the main thread.
- **Memory**: `phys_footprint`, peak during the run and 2 s after it. Both engines keep 10,000
  lines of scrollback.

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
one chunk per main-actor hop. So SwiftTerm's display-link pacing and Ghostty's direct feed are
the production code. `-ghosttyDemo` is unchanged.

### Results

Replay: 3 runs per cell, median (min–max). iPhone18,3 simulator, Version 27.2 (Build 24B8117), 60 Hz, grid 60×50, 11 pt.

#### Replay

| Scenario | Engine | first output ms | parsed ms | drawn ms | frames/s | frame gaps >25 ms | main gaps >25 ms | worst main gap ms | main busy ms | worst main slice ms | CPU ms (main) | peak MB | idle MB |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| claude | SwiftTerm | 34.1 (15.9–36.4) | 9988 (9985–9989) | 9998 (9998–9999) | 59.9 (59.9–59.9) | 1 (1–1) | 1 (1–2) | 33 (33–33.2) | 2408 (2212–2480) | 22.6 (21.2–23.5) | 2598 (2541–2728), main 2317 | 23 (22–23.1) | 22.9 (22–23.1) |
| claude | Ghostty | 18.2 (12.4–18.7) | 9963 (9961–9973) | 9974 (9964–9979) | 59.2 (51.6–60) | 9 (0–84) | 0 (0–0) | 17.2 (16.9–18.3) | 88.9 (71.9–95.7) | 0.50 (0.47–1.12) | 807 (775–818), main 136 | 22.5 (21.2–22.7) | 22.5 (21.2–22.7) |
| seq-wire | SwiftTerm | 19.1 (14–27) | 727 (725–728) | 743 (738–744) | 60.5 (59.6–60.5) | 0 (0–1) | 0 (0–0) | 16.9 (16.7–17.1) | 208 (202–217) | 10.4 (7.37–13.6) | 185 (182–208), main 151 | 29.8 (29.8–29.9) | 29.8 (29.8–29.9) |
| seq-wire | Ghostty | 10.9 (10.9–19.7) | 703 (701–709) | 715 (707–724) | 60.8 (60.1–60.8) | 0 (0–0) | 0 (0–0) | 16.7 (16.7–16.9) | 27 (26.4–28.4) | 0.25 (0.20–0.34) | 145 (139–161), main 38.4 | 27.2 (27.1–27.4) | 22.7 (22.5–22.8) |
| seq | SwiftTerm | 39.3 (37.7–41.4) | 63 (61.9–82.9) | 81.9 (80.1–101) | 49.4 (48.8–49.9) | 1 (1–1) | 1 (0–1) | 32 (17–32.4) | 37.8 (34–41.8) | 11.5 (9.77–12.9) | 35.6 (31.9–36.3), main 32.2 | 29.9 (29.8–30.1) | 28.5 (28.5–28.6) |
| seq | Ghostty | 15.9 (10.6–20.3) | 10.7 (9.43–11.1) | 20.3 (15.9–23.7) | 63 (49.3–84.3) | 0 (0–0) | 0 (0–0) | 15.3 (12.9–16.7) | 2.21 (1.73–3.10) | 0.15 (0.13–0.20) | 17.3 (14.5–20.9), main 3.05 | 27 (26.8–27.1) | 22.5 (22.3–22.6) |
| top | SwiftTerm | 26.1 (15.1–28.7) | 9995 (9984–9999) | 10005 (9994–10015) | 2.20 (2.20–2.20) | 21 (20–21) | 2 (1–2) | 33.3 (32–33.4) | 200 (188–227) | 16.7 (14.9–19.8) | 239 (218–296), main 212 | 21.1 (21–23.9) | 20.2 (20.1–22.9) |
| top | Ghostty | 18.1 (14.7–25.9) | 9983 (9982–10001) | 10000 (9994–10006) | 2.10 (2.10–2.10) | 20 (20–21) | 0 (0–0) | 16.8 (16.8–22.9) | 60.5 (50–64.5) | 2.02 (0.75–6.27) | 139 (138–163), main 101 | 21.5 (20.9–23) | 20.9 (20.5–22.9) |
| unicode | SwiftTerm | 185 (65.8–190) | 298 (194–307) | 320 (217–329) | 28.1 (24.3–46) | 2 (1–3) | 1 (1–1) | 167 (50.2–183) | 250 (180–262) | 155 (64.4–168) | 121 (119–160), main 113 | 33.4 (32.9–34.4) | 31 (31–31.1) |
| unicode | Ghostty | 39.6 (25.9–274) | 16.5 (14–16.6) | 39.6 (28.1–276) | 25.2 (7.30–71.3) | 1 (1–1) | 0 (0–0) | 16.7 (16.6–16.7) | 3.85 (3.19–4.02) | 0.17 (0.16–0.17) | 44.2 (38.7–46), main 5.15 | 29.4 (29.3–29.4) | 23.9 (23.9–23.9) |
| yes-wire | SwiftTerm | 23.7 (23.5–45.6) | 278 (250–280) | 284 (260–285) | 59.8 (57.6–59.8) | 0 (0–0) | 0 (0–1) | 16.7 (16.7–40.3) | 88.5 (82.5–97.6) | 8.88 (8.30–24.3) | 71.4 (70.5–82.3), main 57.9 | 27.5 (27.5–27.5) | 27.5 (27.5–27.5) |
| yes-wire | Ghostty | 11.5 (10.8–21.6) | 264 (258–276) | 275 (268–291) | 61.8 (59.6–61.9) | 0 (0–0) | 0 (0–0) | 16.7 (16.7–17) | 9.65 (9.20–10) | 0.14 (0.12–0.20) | 60 (58.8–64.9), main 14 | 26.3 (26.2–26.4) | 21.6 (21.5–21.7) |
| yes | SwiftTerm | 34.4 (32.1–43.1) | 51.6 (42.7–56.3) | 69.1 (58.6–77) | 51.2 (43.4–52) | 1 (1–1) | 0 (0–1) | 16.9 (16.9–32.2) | 30.7 (29.3–32.4) | 11.4 (9.63–12.4) | 28.1 (25.3–28.4), main 25.1 | 28 (28–28.1) | 28 (28–28.1) |
| yes | Ghostty | 20 (10.7–22.7) | 9.47 (8.48–11.3) | 21.5 (20–22.7) | 50.1 (44–93.1) | 0 (0–0) | 0 (0–0) | 16 (15.1–16.6) | 0.99 (0.80–1.69) | 0.09 (0.06–0.10) | 14.4 (13–16.1), main 1.39 | 26.2 (26.1–26.2) | 21.6 (21.4–21.6) |

#### Live: time to first frame, ms after pane open (5 cold launches per engine)

| Scenario | Engine | connecting | socket live | snapshot received | restored | first frame | snapshot bytes | peak MB |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| live | SwiftTerm | 188 (181–250) | 629 (603–1128) | 592 (570–1103) | 592 (571–1103) | 618 (602–1125) | 22898 (22898–22898) | 40.5 (40–42.9) |
| live | Ghostty | 186 (167–207) | 211 (196–260) | 212 (200–261) | 212 (200–268) | 216 (208–283) | 21722 (21722–21722) | 32.9 (32–33.2) |

#### Pass / fail

- first frame: **pass**
- main gaps >25 ms: **pass**
- frame gaps >25 ms: **FAIL**: claude: Ghostty 9 vs SwiftTerm 1 (not more)
- worst main gap: **pass**
- main-thread time: **pass**
- memory peak: **pass**
- memory idle: **pass**
- first output (info): **pass**
- final state drawn (info): **pass**

Criteria (first frame, gaps, main-thread time, memory within 10%): **FAIL**

### Reading them

- **Ghostty wins every main-thread number.** Its main thread only passes chunks on: 1 to 89 ms
  busy where SwiftTerm needs 31 to 2400 ms, and a worst slice of 2 ms or less where SwiftTerm
  has 9 to 155 ms.
- **Ghostty parses 5 to 18 times faster** (`seq`: 11 ms against 63 ms; `unicode`: 17 ms against
  298 ms) and shows the final state sooner in every burst.
- **First frame, live: 216 ms against 618 ms.** Ghostty saves the `terminal.format` round trips
  (about 400 ms here). Of its 216 ms, 186 ms pass before the stream is even started.
- **Ghostty loses one metric: frame gaps in `claude`.** It presented 590, 515 and 598 of 600
  frames with 9, 84 and 0 gaps over 25 ms; SwiftTerm presented 599 each time with 1 gap. This
  fails the "gaps" criterion as measured from the renderer's presents. Cause and fix are the
  first proposal below.
- **Memory**: within 10% everywhere. Ghostty is 0.5 to 4 MB lower at peak and 0.4 to 7 MB
  lower at rest (it compresses history when idle), except `top`: 0.4 and 0.7 MB higher.
- **Noisy cells**: `unicode` first output on Ghostty (26 to 274 ms, see proposal 2), `claude`
  frame gaps (a later SwiftTerm run under load had 42), live first frame on SwiftTerm (602 to
  1125 ms).

### Fairness and limits

- The probe adds the same main-thread display link and run loop observers to both engines:
  about 6 ms of main busy time per second (`top` on Ghostty: 60 ms in 10 s with only 22
  chunks). SwiftTerm also pays three reads of its counters per run loop pass; that cost was not
  measured separately and is small against its numbers.
- "Frame handed to the GPU" is a commit on the CPU side for both engines. Time on the GPU and
  in the compositor is not in any number.
- SwiftTerm frames are seen at the end of the run loop pass that drew them, Ghostty's at the
  commit. That can add under a millisecond to SwiftTerm's times.
- The simulator's display is 60 Hz, so a "first output" below one frame (16.7 ms) is mostly the
  wait for the next vsync. A 120 Hz device halves that for both.
- `seq` and `yes` at full speed last 20 to 80 ms: their gap counts are a handful of frames. The
  `-wire` runs are the ones to read for pacing.
- Replay has no `terminal.format` text to seed SwiftTerm with, so replay measures no first
  frame. A capture with a `<file>.vt` beside it would, but the fair number is the live one,
  which includes the round trips SwiftTerm really makes.
- Live first frame is a cold app launch into `-autoOpen`: launch work is inside it for both.
  Mirror mode skips fit mode's 120 ms settle and claim, for both.
- No run needed an assumed frame (the report lists any run where no frame was seen in time).

### Where Ghostty loses or is close, and what to do (ranked)

1. **The render link pauses after every idle tick: dropped frames at 60 frames/s.**
   `GhosttyRenderThread.Worker.tick` pauses its display link as soon as one tick finds nothing
   dirty, and `wake()` resumes it. When output arrives at about the refresh rate, a frame that
   lands just before a vsync finds the link paused, and the resumed link fires one vsync late:
   a 33 ms gap. Which runs suffer depends on the phase between the program and the display.
   Checked with a throwaway change: keeping the link running for 30 idle ticks before pausing
   gave 598, 596, 598 and 599 presents with 0, 3, 0 and 0 gaps in four runs (same loaded
   machine). Proposal: pause only after about 0.5 s without a frame. Expected: `claude` frame
   gaps from 9 (0 to 84) to about 0. Cost: idle ticks for half a second after output stops.
2. **Glyphs are rasterized inside the frame that first needs them.** The first `unicode` frame
   spent 17 to 19 ms in the row build, and 266 ms in one run (CoreText fallback fonts, cold).
   `top` and `claude` spend 4 to 7 ms on their first frame. Proposal: draw the frame with the
   glyphs already in the atlas, rasterize misses on a second queue and redraw when they arrive;
   warm ASCII, box drawing and the four font styles when the atlas is made. Expected:
   first-frame build under 3 ms, and the 266 ms case becomes one late frame for the fallback
   glyphs only.
3. **The stream starts only after the host's first layout.** In the live runs 186 of Ghostty's
   216 ms pass between `TerminalHost.init` and `streamStatus(.connecting)` (cold launch: SwiftUI
   and the launch transition). Connecting, receiving 22 KB, restoring and presenting take the
   other 30 ms. A snapshot needs no size from the client, so a mirror-mode Ghostty pane could
   start its stream in `init`. Expected: up to 150 ms off a cold first frame. The gain on a
   warm pane switch was not measured.
4. **One main-actor hop per chunk.** `TerminalStream.receive` hops to the main actor for every
   WebSocket message, runs `APCFilter` there, and `GhosttyCore.feed` copies the bytes into its
   queue. That is all of Ghostty's main-thread time: about 30 µs a chunk, 33 ms a second at
   2 MB/s in 1.8 KB messages. Proposal: for an engine that parses elsewhere, run the filter on
   the socket's queue and hand output straight to the core; only messages hop. Expected: main
   busy time under output near zero, and delivery no longer waits behind a busy main thread.
5. **Full repaints rebuild every row.** `claude` costs Ghostty about 1.1 ms of CPU per frame
   off the main thread (0.15 ms row build, 0.14 ms encode, the rest parse and present), 807 ms
   in 10 s. That is 3 times less than SwiftTerm, so this is last. Proposal: compare rebuilt
   rows with the previous instances and skip the buffer upload for unchanged ones.

Not a problem at this size: the host joins snapshot bytes and decodes at `end` instead of at
READY (0.01 ms between the first and last byte of a 22 KB snapshot, 1 ms to restore); the lock
between feed slices and `begin_update` (no frame build over 8 ms outside glyph rasterization).
Both would need a large history over a slow link to show, which was not measured.
