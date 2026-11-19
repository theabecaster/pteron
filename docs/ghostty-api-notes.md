# libghostty-vt: rules the engine relies on

The C API facts behind `Features/Terminal/Ghostty/`, at the pin in `scripts/ghostty.version`.
Read this before changing how the engine calls the library; [ghostty-engine.md](ghostty-engine.md)
describes the engine itself. Re-check each fact against the headers after a re-pin.

Sources, all under the gitignored `Vendor/` after `scripts/build-ghostty.sh`:

- `G/` = `Vendor/ghostty/dist/doxygen/pages/guides/` (upstream guides: the first authority)
- `H/` = `Vendor/GhosttyVt.xcframework/ios-arm64-simulator/Headers/ghostty/vt/`
- `S/` = `Vendor/ghostty/src/`, `E/` = `Vendor/ghostty/example/`

The research notes this file was cut from, with code samples and the API walk-through, are in
git: `git show 447a94a:docs/ghostty-api-notes.md`.

## Everywhere

- `GHOSTTY_SUCCESS` is 0 and errors are negative. `GHOSTTY_NO_VALUE` is a normal answer for
  optional data (`H/types.h`).
- The library starts no threads. Calls on one handle, or on a handle borrowed from it (formatter,
  selection snapshot, grid ref, snapshot decoder), must never overlap; that is what `termLock` is
  for. Different terminals are independent.
- Pass `NULL` as the allocator and free library buffers with `ghostty_free(NULL, ptr, len)`.
- `ghostty_*_set(handle, option, NULL)` restores the default. Callbacks and userdata are passed as
  the pointer itself, everything else as a pointer to the value.
- `_get_multi` costs the same as separate `_get` calls from Swift and stops at the first
  `NO_VALUE`. Don't use it.

## Callbacks

- Every terminal callback runs inside `ghostty_terminal_vt_write`, on the feed queue, with
  `termLock` held. It must not block, and must never call `vt_write` on the same terminal: that
  corrupts the parser with no error (`G/effects.md`).
- Installed: `RENDER_HOLD` (synchronized output), `CLIPBOARD_WRITE` (OSC 52), `RESET` (forgets the
  prompt click mode).
- Never installed: `WRITE_PTY`. It carries every reply (DA, DSR, DECRQM, mode 2048 size reports,
  color queries), and the Rex server's terminal already answers them, so a local answer would
  reach the program twice. Without it the reply-shaping callbacks send nothing. Paste therefore
  uses `ghostty_paste_encode` with mode 2004 read by hand, not `ghostty_terminal_paste`, which
  fails without `WRITE_PTY` (`H/paste.h`). `ghostty_paste_is_safe` flags every newline; under
  bracketed paste only the `ESC [ 201 ~` terminator is unsafe.
- Swift callbacks are `@convention(c)` closures that capture nothing, passed with
  `unsafeBitCast(fn, to: UnsafeRawPointer.self)`; the object comes back through `OPT_USERDATA`.
  Clear them, or free the terminal, before that object dies.

## Restore

- A snapshot decode returns a new terminal with no userdata and no callbacks
  (`S/terminal/c/terminal.zig`, `fromDecoded`). After every restore, set again: userdata,
  callbacks, scrollback limits, theme colors, the Kitty image limit; re-sync the key and mouse
  encoders; re-point the formatter; and make a new render state.
- The restored terminal takes the server's scrollback limits, not the library default. Set ours.
- No `RENDER_HOLD(true)` arrives for a mode 2026 the snapshot carries. Read the mode and seed the
  hold by hand.
- Decoder options apply only before decoding starts. The decoder borrows the source bytes until
  it finishes or is freed. Any error poisons it: only `free` is allowed after that. A truncated or
  mismatched snapshot (version, CRC, record order) returns `GHOSTTY_INVALID_VALUE`. Format
  version 1 promises no compatibility, so the server's Ghostty and the pin must stay close.
- `ghostty_snapshot_decoder_ready` gives a usable terminal at READY and `next()` prepends history
  into the same terminal. On Rex's single ordered stream that saves decode time only, not network
  time.

## Rendering

- One render state per terminal. `begin_update` clears the dirty flags as it reads them, so a
  second render state would miss changes. A new terminal needs a new render state: an old one
  compares page-node pointers and could skip rows at a reused address.
- Only `begin_update` (with the scrollbar and `VIEWPORT_ACTIVE` reads, for the same instant) needs
  `termLock`. `end_update` and every read after it touch only the render state, which is still one
  handle: one thread at a time.
- Dirty state accumulates until `ghostty_render_state_clean`, so a skipped frame loses nothing.
- Any move of the viewport's top-left pin makes the frame `FULL`: scrolling output and every
  scroll step rebuild all rows. The row builder must be fast on full frames.
- Row and cell data is valid only until the next update. Read cells with one
  `ROW_DATA_CELLS_RAW` per row, and fetch style and graphemes only for cells that have them.
- Until both default foreground and background are set, the render state keeps black and white
  and ignores OSC 10/11. Set both before the first update. A color or palette change is a `FULL`
  frame.
- The library resolves no bold, faint, inverse or selection colors; the renderer applies them as
  Ghostty's renderer does (`S/renderer/generic.zig`, `rebuildRow`). Selected beats inverse.
- `ghostty_render_state_update` ignores mode 2026. Hold frames from `RENDER_HOLD(true)` to
  `(false)`, and end a hold after 1 s by setting the mode off with `OPT_MODE`, which fires no
  callback. Resize, RIS and reset also end a hold.

## Search

- `ghostty_search_*` (search.h) covers screen and scrollback of both screens. `new`, `free`,
  `feed`, `run`, `select_next/prev` and `set(NEEDLE)` read or change the terminal: serialize them
  with all terminal access (`termLock`). `tick` and `get` don't.
- Results are untracked `GhosttySelection` snapshots: valid only until the next terminal change.
  Convert them in the same critical section as the feed (`ghostty_terminal_point_from_grid_ref`,
  `SCREEN` rows: the scrollbar's row space). Rows in one page are consecutive screen rows, so one
  conversion per page (`node`) gives the rest (`GhosttyFind.PageRows`, tested against one per match).
- `VIEWPORT_MATCHES` is cached at the last feed and may include matches just outside the viewport.
  An undersized buffer returns `OUT_OF_SPACE` with the size needed; read again before feeding.
- `select_next` goes older and wraps; `SELECTED_INDEX` 0 is the newest match. Set
  `SELECT_SCROLL` to `NONE`: the renderer moves the viewport (`.reveal`), never the search.
- Setting the same needle again keeps the results; a new needle restarts. Status `COMPLETE` is as
  of the last feed: keep feeding while the search is in use.

## Scrollback, resize, memory

- The library never moves a pinned viewport to the bottom, on output or on paste. The app does it
  for input.
- `ghostty_terminal_resize` reflows the primary screen (with wraparound on), not the alternate
  one. It drops untracked grid refs and selection snapshots; the installed selection is tracked
  and survives. Pass the real device-pixel cell size: size reports and images use it.
- The default scrollback limit is 10,000 bytes (one page). Limits are page-granular estimates.
- Nothing compresses history unless the app drives `ghostty_terminal_compress` (incremental,
  under `termLock`) when `compression_activity` changes. Ghostty waits 250 ms idle.
- Kitty graphics are on by default with 10 MB per screen. The engine sets the limit to 0 on new
  terminals and on decoders: a decoder uses its own limit, not the snapshot's.

## Input

- `ghostty_key_encoder_set_from_terminal` copies the modes (DECCKM, DECBKM, keypad, Kitty flags)
  and resets `MACOS_OPTION_AS_ALT` to false. Set it to true after every sync, or Alt differs
  between the legacy and modifyOtherKeys paths on iOS.
- Never hardcode Return, Tab or Backspace bytes: Kitty `REPORT_ALL` and DECBKM change them.
- `ghostty_key_event_set_utf8` doesn't copy: the bytes must outlive the encode call. Pass the text
  before Ctrl or Meta, never C0 controls or the U+F700 function-key code points `UIKey` returns.
- The mouse encoder's default size is 1×1 pixel: always set `OPT_SIZE`. Its sync clears motion
  dedupe state, so sync when the modes may have changed, not before every motion event.
  Alternate scroll (mode 1007) is not in the library: send arrow keys through the key encoder.

## Selection and copy

- `ghostty_terminal_set(OPT_SELECTION)` installs a tracked selection that follows output,
  scrolling and reflow. Every select function returns only a snapshot, valid until the next
  mutating call; install it, then read it back when needed.
- Grid refs for touches use `GHOSTTY_POINT_TAG_VIEWPORT`; `SCREEN` and `HISTORY` can walk every page.
- Copy with a formatter with `UNWRAP` and `TRIM` on (Ghostty's clipboard text), set and formatted
  in one `termLock` section.

## Swift import

- C enums import as structs with `rawValue` (`GhosttyResult` is `Int32`, the rest `UInt32`).
- `GHOSTTY_INIT_SIZED` doesn't import: set `.size = MemoryLayout<T>.size` on sized structs. A
  wrong size returns `GHOSTTY_INVALID_VALUE`.
- `GHOSTTY_MODE_*` and `GHOSTTY_STYLE_FLAG_*` macros don't import; `ghostty_mode_new(2026, false)`
  does (static inline). `palette[256]` imports as a tuple.
- Link the static library with `-lc++`.
