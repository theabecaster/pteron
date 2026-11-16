# libghostty-vt API notes

Usage reference for the Ghostty engine in `docs/ghostty-engine.md`. Pinned commit `5ebe501a6` (library reports
`1.0.2-dev+5ebe501a6`).

Authority order: upstream guides, then headers, then examples, then Zig source. Path prefixes used in citations:

- `G/` = `Vendor/ghostty/dist/doxygen/pages/guides/`
- `P/` = `Vendor/ghostty/dist/doxygen/pages/`
- `H/` = `Vendor/GhosttyVt.xcframework/ios-arm64-simulator/Headers/ghostty/vt/`
- `S/` = `Vendor/ghostty/src/`
- `E/` = `Vendor/ghostty/example/`

"Probe" means a claim I checked by compiling a scratch Swift program against the `macos-arm64_x86_64` slice. Nothing
was checked on the iOS slices at run time.

## 0. Conventions that apply everywhere

- **Results.** `GHOSTTY_SUCCESS` is 0, every error is negative (`H/types.h:143-187`). `GHOSTTY_NO_VALUE` (-4) is a
  normal answer for optional data, not a failure. `GHOSTTY_UNSUPPORTED` (-8) means an unknown key or a feature left
  out of the build.
- **Threads.** The library creates none. Calls on one handle, and on any handle borrowed from it, must never run at
  the same time. Different handles are independent (`P/conventions.md:79-96`). Callbacks run on the thread that called
  `ghostty_terminal_vt_write`.
- **Borrowed handles.** A formatter, a selection gesture, tracked grid refs and an in-flight snapshot decoder all
  borrow the terminal. Serialize them with the terminal lock.
- **Allocator.** Pass `NULL` everywhere. Free library buffers with `ghostty_free(NULL, ptr, len)`.
- **`_get_multi`.** From C or Swift it costs the same as one `_get` per key (`H/render.h:1175-1179`,
  `H/screen.h:361`). It exists for WebAssembly and slow FFI. It also stops at the first non-success result, and
  `NO_VALUE` counts as one (`H/render.h:1184-1186`). Do not put `BG_COLOR` or `FG_COLOR` in a batch.
- **Options.** `ghostty_*_set(handle, option, NULL)` restores the default. Callbacks and userdata are passed as the
  pointer itself. Everything else is a pointer to the value (`H/terminal.h:3184-3230`).

## 1. Terminal lifecycle and options

### Create, feed, free

```c
ghostty_terminal_new(NULL, &term, cols, rows);      // H/terminal.h:3114
ghostty_terminal_set(term, OPT, value);             // set options before the first write
ghostty_terminal_vt_write(term, bytes, len);        // never fails, H/terminal.h:3238-3261
ghostty_terminal_free(term);
```

`vt_write` keeps parser state between calls. Chunks can split anywhere, including inside UTF-8 or an escape sequence.

A snapshot restore returns a **new** terminal (section 4). It has no userdata and no callbacks: `fromDecoded` wraps
the decoded state in a fresh wrapper (`S/terminal/c/terminal.zig:951-980`). Put all option setup in one
`configure(term)` function and call it for both new and restored terminals.

### Options that matter to us

| Option | Type | Default | Use |
| --- | --- | --- | --- |
| `GHOSTTY_TERMINAL_OPT_USERDATA` | `void*` | NULL | One pointer for every callback (`G/effects.md:33-36`) |
| `..._SCROLLBACK_MAX_BYTES` | `size_t*` | 10,000 (one page, about 400 KB) | Set our budget. `SIZE_MAX` is unlimited, 0 erases history (`H/terminal.h:2313-2346`) |
| `..._SCROLLBACK_MAX_LINES` | `size_t*` | none | Optional second cap. First limit reached wins (`H/terminal.h:2348-2373`) |
| `..._COLOR_FOREGROUND` / `_BACKGROUND` / `_CURSOR` | `GhosttyColorRgb*` | unset | Theme defaults (section 7) |
| `..._COLOR_PALETTE` | `GhosttyColorRgb[256]*` | built-in | Theme palette |
| `..._RENDER_HOLD` | callback | NULL | Synchronized output (section 2) |
| `..._TITLE_CHANGED`, `_PWD_CHANGED`, `_BELL` | callback | NULL | Safe: they send nothing to the program |
| `..._KITTY_IMAGE_STORAGE_LIMIT` | `uint64_t*` | 10,000,000 per screen | 0 disables Kitty graphics (section 8) |
| `..._SELECTION` | `GhosttySelection*` | none | Install or clear the selection (section 6) |
| `..._MODE` | `GhosttyTerminalModeConfig*` | n/a | Force a mode, for example end a stuck hold. Does not fire callbacks (`H/terminal.h:1910-1913`) |
| `..._RESIZE_PULL_SCROLLBACK` | `bool*` | true | Leave at true. The server is Ghostty with the same default (`G/scrollback.md:115-136`) |

Read state with `ghostty_terminal_get(term, GHOSTTY_TERMINAL_DATA_*, &out)` (`H/terminal.h:2665-3092`). Useful keys:
`COLS`, `ROWS`, `ACTIVE_SCREEN`, `SCROLLBAR`, `VIEWPORT_ACTIVE`, `MOUSE_TRACKING`, `KITTY_KEYBOARD_FLAGS`, `MODE`,
`TITLE`, `PWD`, `SELECTION`, `MEMORY_USAGE`, `VT_PROCESSING_ERROR`. `TITLE` and `PWD` are borrowed strings, valid
until the next mutating call. Copy them inside the callback.

### Callbacks for a remote mirror

All callbacks run synchronously inside `vt_write`, on the feed thread, with the terminal lock held. They must not
block and must not call `vt_write` on the same terminal (`G/effects.md:38-58`).

| Callback | Install? | Why |
| --- | --- | --- |
| `WRITE_PTY` | Only gated (see below) | It carries every reply: DSR, DECRQM, DA, XTVERSION, OSC color queries, mode 2048 reports. The server's terminal already answers these |
| `RENDER_HOLD` | **Yes** | Needed for correct synchronized output |
| `TITLE_CHANGED`, `PWD_CHANGED`, `BELL` | Optional | No reply involved |
| `DEVICE_ATTRIBUTES`, `ENQUIRY`, `XTVERSION`, `SIZE`, `COLOR_SCHEME` | No | They only shape replies. With `WRITE_PTY` NULL nothing is sent anyway: the trampoline returns when it is unset (`S/terminal/c/terminal.zig:473-477`) |
| `CLIPBOARD_WRITE` | Product decision | OSC 52 copy to the iOS pasteboard. No reply for OSC 52. Unconfirmed: whether the Rex server also handles OSC 52 |
| `CLIPBOARD_READ` | No | Its answer goes to the program through `WRITE_PTY`. It also switches paste to Kitty paste events under mode 5522 (`G/input.md:172-183`) |
| `PROGRAM_STATUS`, `UNKNOWN_SEQUENCE`, `RESIZE_WINDOW`, `DESKTOP_NOTIFICATION`, `PROGRESS_REPORT`, `SEMANTIC_PROMPT`, `RESET` | Not needed now | `PROGRAM_STATUS` makes the terminal answer `OSC 7501;?` through `WRITE_PTY` (`H/terminal.h:2623-2644`) |

`WRITE_PTY` and paste: `ghostty_terminal_paste` is the upstream way to paste, and it returns `GHOSTTY_INVALID_VALUE`
when no `WRITE_PTY` is installed (`H/paste.h:136-139`). Two valid choices:

1. Install `WRITE_PTY` with a gate: the callback forwards bytes only while a `pasting` flag is set, and drops
   everything else. Paste and feed both run under the terminal lock, so the flag needs no extra lock. This keeps the
   plan's intent (no duplicate replies).
2. Never install it, and paste with `ghostty_paste_encode` (section 5).

A callback type in Swift:

```swift
let onHold: @convention(c) (GhosttyTerminal?, UnsafeMutableRawPointer?, Bool) -> Void = { term, ud, held in
    let core = Unmanaged<GhosttyCore>.fromOpaque(ud!).takeUnretainedValue()
    core.renderHold(term, held)
}
ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_USERDATA, Unmanaged.passUnretained(core).toOpaque())
ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_RENDER_HOLD, unsafeBitCast(onHold, to: UnsafeRawPointer.self))
```

(Probe: compiles and fires.) Clear the callbacks, or free the terminal, before `core` dies.

### Resize

```c
ghostty_terminal_resize(term, cols, rows, cell_width_px, cell_height_px);  // H/terminal.h:3147-3176
```

- The primary screen reflows when wraparound mode is on. The alternate screen does not.
- It always ends a synchronized-output hold, and fires `RENDER_HOLD(false)` if one was active.
- Cell pixel size feeds image sizing, size reports and `WIDTH_PX`/`HEIGHT_PX`. Pass the real device-pixel cell size.
  With mode 2048 on it writes a size report through `WRITE_PTY`, which the gate drops
  (`S/terminal/stream_terminal.zig:523-550`).
- Call it with unchanged cols and rows when only the font size changed. The grid is left alone and the pixel size
  updates.
- Untracked grid refs and selection snapshots die. The terminal's own selection is tracked state, and nothing in
  `Terminal.resize` or `Screen.resize` clears it. The docs do not promise that it survives a reflow. A size change
  makes the next render update a full redraw (`S/terminal/render.zig:1004-1009`).
- Not confirmed from source: that a client holding less history than the server reflows to the same screen. A reflow
  can pull rows out of scrollback (`G/scrollback.md:117-119`), so a client that pruned those rows may differ until the
  next snapshot.

## 2. Rendering

### Objects and lifetime

- One `GhosttyRenderState` per terminal: `ghostty_render_state_new(NULL, &state)`.
- One `GhosttyRenderStateRowIterator` and one `GhosttyRenderStateRowCells`, created once and refilled each frame
  (`H/render.h:835-851`, `1096-1115`).
- Row and cell data, including a `GhosttyCellsView`, is valid only until the next update of that render state
  (`G/rendering.md:45-46`).
- **Only one render state may consume a terminal.** `beginUpdate` clears the page, row, screen and terminal dirty
  flags as it reads them (`S/terminal/render.zig:1200-1204`, `1411-1413`). A second render state on the same terminal
  would miss changes.
- After a snapshot restore, free the render state and create a new one for the new terminal. The update decides
  "nothing changed" by comparing stored page-node pointers (`S/terminal/render.zig:1021-1024`, `1223-1229`). A new
  terminal can reuse a freed address, so an old render state could skip rows it never built. This is my reading of the
  source. The guide does not cover re-pointing a render state.
- The render state keeps its peak memory. Ghostty frees and recreates it every 100,000 frames
  (`S/terminal/render.zig:282-288`, `S/renderer/generic.zig:1381-1392`).

### Frame order and locking

```c
lock(T);                                             // terminal lock
ghostty_render_state_begin_update(state, term);      // only call that needs the terminal
ghostty_terminal_get(term, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &bar);         // same instant
ghostty_terminal_get(term, GHOSTTY_TERMINAL_DATA_VIEWPORT_ACTIVE, &active);
unlock(T);
ghostty_render_state_end_update(state);              // required before any read
/* read dirty, colors, cursor, rows; build GPU buffers */
ghostty_render_state_clean(state);                   // only after a complete frame
```

- Every `begin` needs an `end` before reading. `end` without `begin` is a no-op. `end` only touches render-state
  memory (`H/render.h:667-713`). Today the deferred work is per-cell style fill (`S/terminal/render.zig:930-937`).
- Read the scrollbar and `VIEWPORT_ACTIVE` in the same critical section as `begin_update` so they describe the same
  moment (`G/rendering.md:214-218`). Ghostty does exactly this (`S/renderer/generic.zig:1484-1500`).
- Everything after `unlock(T)` reads only the render state. It is still one handle: no two threads may touch it at
  once.

### Dirty tracking

Two independent layers (`G/rendering.md:75-100`):

- Global: `GHOSTTY_RENDER_STATE_DATA_DIRTY` gives `GHOSTTY_RENDER_STATE_DIRTY_FALSE`, `_PARTIAL` or `_FULL`.
- Per row: `GHOSTTY_RENDER_STATE_ROW_DATA_DIRTY`.

An update only sets dirty state. It never clears it. Dirty state accumulates across updates until we clear it, so a
skipped frame loses nothing. `ghostty_render_state_clean` clears both layers. For partial consumption use
`ghostty_render_state_set(state, GHOSTTY_RENDER_STATE_OPT_DIRTY, &v)` and `ghostty_render_state_row_set(rows,
GHOSTTY_RENDER_STATE_ROW_OPT_DIRTY, &b)`. Clearing one layer does not clear the other.

`FULL` is set when any of these is true (`S/terminal/render.zig:983-1027`): the active screen changed, any
terminal-level or screen-level dirty flag is set (palette, colors, selection and similar), the size changed, the
overscan request or the captured overscan changed, or **the viewport's top-left pin changed**.

The last one matters most. Output that scrolls the screen moves the pin, so every scrolling frame is `FULL`, even when
pinned to the bottom. (Probe: one typed character gives `PARTIAL`, 40 new lines give `FULL`.) `seq 1 200000` is a
stream of full rebuilds. The row builder must be fast on full frames. Do not design around partial updates only.

`ghostty_render_state_row_iterator_next_dirty(rows, &y)` skips clean rows under `PARTIAL`, returns every row under
`FULL`, and returns nothing under `FALSE`. `y` is the iterator index. With overscan use `ROW_DATA_VIEWPORT_Y` instead
(`H/render.h:880-905`).

### Rows

`ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, &rows)` refills the iterator. Per row,
`ghostty_render_state_row_get(rows, key, &out)`:

| Key | Type | Notes |
| --- | --- | --- |
| `ROW_DATA_DIRTY` | `bool` | |
| `ROW_DATA_CELLS` | `GhosttyRenderStateRowCells` | Refills the reusable cells handle |
| `ROW_DATA_CELLS_RAW` | `GhosttyCellsView` | Pointer to `cols` packed `GhosttyCell` (u64). One call per row (`H/render.h:457-471`) |
| `ROW_DATA_SELECTION` | `GhosttyRenderStateRowSelection` (sized) | Inclusive `start_x..end_x`. `NO_VALUE` when the row has no selection |
| `ROW_DATA_VIEWPORT_Y` | `int32_t` | Negative above the viewport, `>= rows` below it |
| `ROW_DATA_ID` | `GhosttyRenderStateRowId` | Two u64 words. Equality only. All-zero is never valid |
| `ROW_DATA_RAW` | `GhosttyRow` | Feed to `ghostty_row_get` for `WRAP`, `GRAPHEME`, `STYLED`, `KITTY_VIRTUAL_PLACEHOLDER` |

### Cells: fastest path

Three ways to read a row:

1. `ghostty_render_state_row_cells_next` plus `ghostty_render_state_row_cells_get` per field. This is what the example
   does (`E/c-vt-render/src/main.c`). Several calls per cell.
2. `ROW_DATA_CELLS_RAW` once per row, then `ghostty_cell_get(raw, key, &out)` on each u64. The header recommends this
   for callers that have the C header and cheap calls (`H/render.h:467-470`). Swift calls C directly, so it applies to
   us.
3. `ROW_DATA_CELLS_RAW` plus decoding the bits ourselves. Hardcoded bit positions are unsupported. The layout must be
   read from `ghostty_type_json()` at startup (`H/screen.h:46-56`). At this pin the manifest gives `content_tag` lsb 0
   width 2, `content` lsb 2 width 24, `style_id` lsb 26 width 16, `wide` lsb 42 width 2 (probe). That is zero calls
   per plain cell.

Recommended: path 2 for all cells, and touch the cells handle only for cells that need managed data. Move to path 3
only if a profile shows the per-cell calls.

```swift
var view = GhosttyCellsView()
ghostty_render_state_row_get(rows, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS_RAW, &view)
ghostty_render_state_row_get(rows, GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, &cells)
for x in 0..<view.len {
    let raw = view.ptr[x]
    var cp: UInt32 = 0, wide = GHOSTTY_CELL_WIDE_NARROW
    var tag = GHOSTTY_CELL_CONTENT_CODEPOINT, styled = false
    ghostty_cell_get(raw, GHOSTTY_CELL_DATA_CODEPOINT, &cp)
    ghostty_cell_get(raw, GHOSTTY_CELL_DATA_WIDE, &wide)
    ghostty_cell_get(raw, GHOSTTY_CELL_DATA_CONTENT_TAG, &tag)
    ghostty_cell_get(raw, GHOSTTY_CELL_DATA_HAS_STYLING, &styled)
    if wide == GHOSTTY_CELL_WIDE_SPACER_TAIL { continue }
    if styled || tag == GHOSTTY_CELL_CONTENT_CODEPOINT_GRAPHEME {
        ghostty_render_state_row_cells_select(cells, UInt16(x))
        // then ROW_CELLS_DATA_STYLE and/or ROW_CELLS_DATA_GRAPHEMES_BUF
    }
}
```

(Probe: this loop compiles and returns the expected values.)

Rules:

- The per-cell style is undefined unless the cell has styling. The grapheme slice is undefined unless the tag is
  `CODEPOINT_GRAPHEME` (`S/terminal/render.zig:828-845`). The C getters guard this: `ROW_CELLS_DATA_STYLE` returns the
  default style for unstyled cells (`S/terminal/c/render.zig:805-809`). So `STYLE` is always safe, just wasted work.
- `GHOSTTY_CELL_DATA_HAS_STYLING` on the raw cell equals `ROW_CELLS_DATA_HAS_STYLING`.
- Background-only cells have tag `BG_COLOR_PALETTE` or `BG_COLOR_RGB`, no text, and carry the color in the cell
  itself: `GHOSTTY_CELL_DATA_COLOR_PALETTE` or `_COLOR_RGB` (`H/screen.h` `GhosttyCellData`). These are what
  erase-with-background produces.
- `ROW_CELLS_DATA_BG_COLOR` flattens all three background sources and returns `NO_VALUE` for "use the default".
  `ROW_CELLS_DATA_FG_COLOR` resolves the palette and returns `NO_VALUE` when the style has no foreground. Neither
  applies bold, faint, inverse or selection (`S/terminal/c/render.zig:836-868`, `H/render.h:1036-1058`).
- Resolving colors ourselves from `GhosttyStyle` and the palette in `GhosttyRenderStateColors` saves those calls. The
  example does this (`E/c-vt-render/src/main.c` `resolve_color`).

### Style resolution

`GhosttyStyle` is 16 fixed bytes: `fg_color`, `bg_color`, `underline_color` (each a one-byte `tag` plus `palette` or
`rgb`), and `flags` (`H/style.h`). Flag bits: bold 0, italic 1, faint 2, blink 3, inverse 4, invisible 5,
strikethrough 6, overline 7, underline style in bits 8 to 10 as a `GhosttySgrUnderline` (none 0, single 1, double 2,
curly 3, dotted 4, dashed 5). Two styles from the library compare with `memcmp`. Key the glyph and color caches on
that.

What Ghostty's renderer does, in order (`S/renderer/generic.zig:3060-3370`):

1. `fg_style` = style foreground, else the default foreground. `bg_style` = cell or style background, else none.
2. **Inverse** (not selected): background = `fg_style`. Foreground = `bg_style`, or the default background when there
   is none (`:3142-3188`).
3. **Selected**: background = default foreground, foreground = default background, unless `selection-background` /
   `selection-foreground` are configured. Selection wins over inverse (`:3117-3127`, `:3166-3171`). A spacer tail
   tests selection at `x - 1` (`:3076-3079`).
4. **Background**: a cell with no explicit background is not drawn. The frame clear color shows through
   (`:3203-3226`). This matches the plan's merged background rects.
5. **Faint**: alpha = `faint-opacity` (default 0.5) on the glyph and all decorations. The color is not changed
   (`:3193`, `S/config/Config.zig:3933`).
6. **Invisible**: draw the background, then skip glyph and every decoration (`:3241-3243`).
7. **Draw order**: background, underline, overline, glyph, strikethrough (`:3261-3369`).
8. **Underline color**: `style.underline_color`, else the final foreground (`:3268`).
9. **Bold**: font weight only by default. `bold-color` defaults to unset (`S/config/Config.zig:3926`). With
   `bold-color = bright`, a palette foreground with index below 8 uses index + 8, and RGB and default foregrounds are
   unchanged (`S/terminal/style.zig:235-279`).
10. **Minimum contrast**: off by default (`minimum-contrast = 1`, `S/config/Config.zig:784`). When on, the shader
    swaps the glyph color for pure white or black if the contrast ratio against the cell background is too low
    (`S/renderer/shaders/shaders.metal:111-124`). It is skipped for box drawing, block elements, legacy computing
    symbols and Powerline (`S/renderer/cell.zig:292-347`).
11. **Blink**: the flag exists. Ghostty's renderer does not act on it (no use of `flags.blink` in `rebuildRow`).

Reverse video (DECSCNM, mode 5) is already applied: the render state swaps `foreground` and `background` for us
(`S/terminal/render.zig:401-404`, `1063-1069`).

### Wide characters and graphemes

- `GHOSTTY_CELL_WIDE_WIDE`: draw the glyph two cells wide. `_SPACER_TAIL`: the second half, draw nothing.
  `_SPACER_HEAD`: a placeholder at the end of a soft-wrapped row before a wide character that moved to the next row,
  draw nothing (`H/screen.h:116-129`).
- Graphemes: `ROW_CELLS_DATA_GRAPHEMES_BUF` with a `GhosttyCodepointBuffer {ptr, cap, len}`. The base codepoint comes
  first. `len` is always the full count. `OUT_OF_SPACE` means the buffer holds the first `cap` codepoints
  (`H/render.h:1013-1034`). The example uses a 16-entry stack buffer. `ROW_CELLS_DATA_GRAPHEMES_UTF8` gives UTF-8
  directly, with an ASCII fast path (`S/terminal/c/render.zig:881-900`).
- `ghostty_row_get(row, GHOSTTY_ROW_DATA_GRAPHEME, &b)` says whether any cell in the row has a grapheme. Use it to
  skip the tag test for a whole row.
- Kitty placeholder cells hold U+10EEEE. If images are off, skip drawing that codepoint.

### Cursor

```swift
var cursor = GhosttyRenderStateCursor(); cursor.size = MemoryLayout<GhosttyRenderStateCursor>.size
ghostty_render_state_get(state, GHOSTTY_RENDER_STATE_DATA_CURSOR, &cursor)
```

Fields: `viewport_has_value`, `viewport_x`, `viewport_y`, `wide_tail`, `visible` (mode 25), `blinking` (mode 12),
`password_input`, `visual_style` (`GHOSTTY_CURSOR_STYLE_BAR`, `_BLOCK`, `_UNDERLINE`, `_BLOCK_HOLLOW`). When
`viewport_has_value` is false the position fields are undefined (`H/render.h:529-567`). The cursor is never reported
in an overscan row.

Ghostty's decision order (`S/renderer/cursor.zig:36-68`): not in viewport → none; IME preedit → block;
`password_input` → lock glyph; `!visible` → none; unfocused → hollow block; blinking and blink phase off → none; else
`visual_style`. Blink interval is 600 ms (`S/renderer/Thread.zig:20`).

Colors (`S/renderer/generic.zig:2789-2892`): cursor color = `colors.cursor` when `cursor_has_value`, else the
configured color, else the default foreground. The character under a block cursor is drawn in the default background
color (`cursor-text` unset). On a wide character the cursor is two cells wide. With `wide_tail` it starts at `x - 1`
(`:3549-3559`).

`colors.cursor` is the terminal's effective cursor color, default or OSC 12 override (`S/terminal/render.zig:1047`).
If we set `OPT_COLOR_CURSOR`, `cursor_has_value` is always true.

### Colors

`GHOSTTY_RENDER_STATE_DATA_COLORS` fills `GhosttyRenderStateColors` (sized): `background`, `foreground`, `cursor`,
`cursor_has_value`, `palette[256]`.

- If the terminal has no default foreground **or** no default background, the render state keeps its initial black and
  white and ignores OSC 10/11 (`S/terminal/render.zig:1056-1070`, `377-385`). A new terminal starts with both unset
  (`G/colors.md:54-56`; probe: `NO_VALUE`). Set both before the first update.
- The palette is copied only on a full redraw. Every palette change forces one (`S/terminal/render.zig:1049-1054`).
- A color change marks the frame `FULL`. Rebuild all rows and the clear color.

### Synchronized output (render holds)

`ghostty_render_state_update` never checks mode 2026. Updating on every frame shows half-drawn screens
(`G/rendering.md:118-120`). The upstream recipe (`G/rendering.md:122-185`):

1. Install `GHOSTTY_TERMINAL_OPT_RENDER_HOLD`.
2. On `held == true`, update the render state **inside the callback**. At that instant the terminal holds the last
   complete frame. Bytes later in the same `vt_write` have not been processed yet.
3. Do not update again until `held == false`. Keep drawing the captured state.
4. After about 1 s, end the hold ourselves: set `GHOSTTY_MODE_SYNCHRONIZED_OUTPUT` to false with
   `GHOSTTY_TERMINAL_OPT_MODE`. The terminal has no clock. Setting the mode by hand does not fire the callback, so
   clear our own `held` flag too.
5. Ignore the hold while the user scrolls or selects (`G/rendering.md:180-181`).

The hold also ends on RIS, `ghostty_terminal_reset` and `ghostty_terminal_resize`. Calls come in pairs
(`H/terminal.h:1892-1923`).

Threading consequence: the callback runs on the feed thread with the terminal lock held and writes the render state,
while the render thread reads it. The render state needs its own lock R. Use one lock order everywhere, T then R:

- Render thread: `lock T; lock R; begin_update; unlock T; end_update; build rows; clean; unlock R`.
- Callback (T already held): `lock R; ghostty_render_state_update; unlock R`.

The feed thread can then wait for one row build. If that shows in profiles, copy the frame data out under R and build
GPU buffers after releasing it.

Polling the mode before each update is simpler and is what Ghostty's own renderer does
(`S/renderer/generic.zig:1423-1427`). The guide names its two faults: the frame left on screen can be stale or
half-drawn, and a release-then-hold between two draws is never seen, so a busy program looks frozen
(`G/rendering.md:171-178`). The second fault is likely with Claude Code. Use the callback.

After a snapshot restore: the snapshot carries mode 2026 (mode bit 37, `S/terminal/snapshot/terminal.zig` "Modes").
The decoder creates the terminal before we can install a callback, so no `held == true` call arrives. Read the mode
once after restore and seed `held` and the timeout from it. This follows from the source. The guide does not cover it.

### Overscan and row identity

- Request once: `GhosttyRenderStateOverscan {above, below}` with `GHOSTTY_RENDER_STATE_OPT_OVERSCAN`. It applies from
  the next update, which is a full redraw (`H/render.h:235-242`).
- After each update read `GHOSTTY_RENDER_STATE_DATA_OVERSCAN` for what was captured. `below` is 0 while the viewport
  follows the active area. `above` shrinks at the top of history. Do not shift the grid toward a side with nothing
  captured (`G/rendering.md:205-209`).
- Place rows by `ROW_DATA_VIEWPORT_Y * cell_height - offset_px` (`G/rendering.md:241-248`).
  `GHOSTTY_RENDER_STATE_DATA_ROWS` excludes overscan.
- Row ids: reuse a cached row only when the same id is present **and** the row is not dirty. Today every row is dirty
  after any viewport scroll (`G/rendering.md:258-272`). So ids give no saving for scrolling yet. They are still the
  right cache key. Ids are never reused. Entries whose id no longer appears can be dropped.

## 3. Scrollback and scrolling

### Viewport

`ghostty_terminal_scroll_viewport(term, behavior)` with a tagged union (`H/terminal.h:99-168`, `3416-3449`):

| Tag | Value | Cost (`S/terminal/PageList.zig:3525-3640`) |
| --- | --- | --- |
| `GHOSTTY_TERMINAL_SCROLL_VIEWPORT_TOP` | none | O(1) |
| `..._BOTTOM` | none | O(1). Returns to following the active area |
| `..._DELTA` | `delta` (`intptr_t`, negative is up) | O(rows moved) when already scrolled, else a walk from the current top |
| `..._ROW` | `row` (`size_t`, 0 is the oldest row) | O(1) at either end. O(1) relative move when the offset is cached. Otherwise a walk over pages from the nearer end |
| `..._DELTA_PROMPT` | `delta_prompt` | Needs OSC 133 marks |

- Three viewport states: following the active area, pinned to the top, or pinned to a tracked row
  (`S/terminal/PageList.zig:518-533`). A pinned viewport stays on its content while output arrives. `ROW` at or past
  `total - len` snaps back to "following".
- `GHOSTTY_TERMINAL_DATA_VIEWPORT_ACTIVE` says whether we are following.
- The library never jumps a pinned viewport to the bottom. Ghostty does it in the app: on keystroke by default
  (`scroll-to-bottom.keystroke = true`, `S/Surface.zig:2976`) and on output only when configured
  (`S/renderer/generic.zig:1429-1447`). Paste does not scroll either (`H/paste.h:121-122`). Call `BOTTOM` ourselves
  when the user types or pastes.
- Every scroll call restarts compression traversal and bumps the activity token (`S/terminal/PageList.zig:3517-3523`).
- Every viewport move makes the next frame `FULL` (section 2).
- The alternate screen has no scrollback. The viewport stays on the active area.

### Scrollbar

`GHOSTTY_TERMINAL_DATA_SCROLLBAR` → `GhosttyTerminalScrollbar {total, offset, len}` in rows. `offset` is the same row
space as `SCROLL_VIEWPORT_ROW`. There is no change notification, on purpose: poll once per frame and diff
(`G/scrollback.md:82-97`). It is amortized O(1). The first read after a move that was not an absolute row can cost
O(pages) (`H/terminal.h:2725-2741`).

For a `UIScrollView`: `contentSize.height = total * cellHeight`, and `contentOffset.y = offset * cellHeight` while
following. `total` changes on output, on pruning and while an incremental restore prepends history. When `total`
changes and the user is scrolled up, shift `contentOffset` by the row delta without animation and without calling
`scroll_viewport` back.

### Limits and memory

- Limits are estimates at page granularity, about 400 KB per page. Lowering one prunes whole pages at once
  (`G/scrollback.md:36-44`). Ghostty's own default is 50 MB (`S/config/Config.zig:1394`).
- `GHOSTTY_TERMINAL_DATA_MEMORY_USAGE` (sized struct) reports pages, resident, compressed and image bytes per screen.
  It walks every page. Budget against `*_resident_bytes` (`G/scrollback.md:138-166`).

### Compression

Nothing compresses unless we drive it (`G/scrollback.md:172-221`):

```c
uint64_t token;
ghostty_terminal_compression_activity(term, &token);   // equality only, may wrap
/* when token changes: restart an idle timer */
/* when the timer fires: */
GhosttyTerminalCompressionResult r;
ghostty_terminal_compress(term, GHOSTTY_TERMINAL_COMPRESSION_MODE_INCREMENTAL, &r);
/* PENDING: step again soon. COMPLETE: wait for the token to change. UNSUPPORTED: stop. */
```

- Ghostty uses a 250 ms idle delay and 1 ms between steps, and uses `tryLock` so compression never waits on the
  terminal lock (`S/renderer/Thread.zig:755-857`).
- `compress` is not thread-safe with anything else on the terminal. Run it under T.
- `MODE_FULL` scans everything in one call and can stall on large history.
- Compressed pages decompress transparently when scrolled into, searched or formatted.
- Supported on 64-bit Darwin targets (`S/terminal/mem.zig:82-97`; probe on macOS: `compression_supported == true`).
  Not run on iOS. Check `compression_supported` once at startup.
- macOS reclaims freed pages lazily, so process RSS can stay above the reported resident bytes
  (`G/scrollback.md:164-166`). Whether iOS `phys_footprint` does the same is unconfirmed.

## 4. Snapshots

### Decoder API

```c
GhosttySnapshotDecoder dec;
ghostty_snapshot_decoder_new_buf(NULL, &dec, bytes, len);     // borrows bytes, no copy
bool yes = true;
ghostty_snapshot_decoder_set(dec, GHOSTTY_SNAPSHOT_DECODER_OPT_COMPRESS_HISTORY, &yes);
uint64_t no_images = 0;
ghostty_snapshot_decoder_set(dec, GHOSTTY_SNAPSHOT_DECODER_OPT_KITTY_IMAGE_STORAGE_LIMIT, &no_images);

/* one shot */
GhosttyTerminal term;
GhosttyResult r = ghostty_snapshot_decoder_decode(dec, &term);

/* or in pieces */
r = ghostty_snapshot_decoder_ready(dec, &term);               // usable terminal at READY
while ((r = ghostty_snapshot_decoder_next(dec)) == GHOSTTY_SUCCESS) { /* one record */ }
/* r == GHOSTTY_NO_VALUE: FINISH validated */

size_t off;
ghostty_snapshot_decoder_get(dec, GHOSTTY_SNAPSHOT_DECODER_DATA_SOURCE_OFFSET, &off);
ghostty_snapshot_decoder_free(dec);
```

- Options can only be set before decoding starts (`H/snapshot.h:568`, `G/snapshots.md:62-73`).
- The source bytes must stay valid and unchanged until FINISH or until the decoder is freed (`G/snapshots.md:54-56`).
- `SOURCE_OFFSET` at FINISH is the first byte after the snapshot. It is unavailable after a decode error
  (`H/snapshot.h:190-203`).
- `ready()` can be called once, and only before decoding starts. `next()` consumes one history page or one image
  payload. Pages arrive newest first and are prepended.
- With `ready()`, **the same terminal** receives the history. There is no second terminal and no swap. Between
  `next()` calls we may render, resize and feed live bytes to it (`G/snapshots.md:137-155`).
- `GHOSTTY_SNAPSHOT_DECODER_DATA_HISTORY_ROWS_PRIMARY` is available right after READY. Use it to size the scrollbar
  before history arrives (`H/snapshot.h:205-213`, `S/terminal/snapshot/main.zig:99-102`).
- `PROGRESS_ROWS == 0` means a page was validated but could not be applied any more. That is not an error.
- The decoder borrows the terminal until FINISH or free. Run `next()` under T, and keep the terminal alive.
- A reader-based decoder (`ghostty_snapshot_decoder_new`) treats a zero-byte read as permanent EOF. It cannot wait for
  WebSocket data unless the callback blocks (`G/snapshots.md:118-127`).

Incremental restore on our transport: Rex sends the whole snapshot, then the `resize` APC, then live bytes, in one
ordered stream. Upstream says a transport that delivers live data before history finishes must multiplex outside the
snapshot (`S/terminal/snapshot/main.zig:142-146`). Ours does not, so live bytes cannot be fed until the snapshot bytes
are consumed. `ready()` therefore only saves decode time for the first frame, not network time. With the measured 0.29
ms one-shot decode, one-shot is enough for small histories. For large ones, call `ready()`, render, then run `next()`
in slices on the feed queue before feeding the bytes after `SOURCE_OFFSET`.

### What a snapshot carries (`S/terminal/snapshot/terminal.zig:17-250`)

- Size in cells and pixels, scrolling region, tab stops, title, PWD.
- Current, saved and default mode sets. This includes mouse tracking and format, bracketed paste, cursor keys, focus
  events, synchronized output, mode 2031 and mode 2048.
- Mouse event and format, modifyOtherKeys, cursor default style and blink, password flag.
- Colors: default **and** override for foreground, background and cursor, the base palette and per-index overrides.
- **The source terminal's scrollback limits.** The restored terminal uses them, not our 10,000-byte default
  (`S/terminal/snapshot/terminal.zig:975-987`, `S/terminal/snapshot/snapshot.zig:459-473`).
- Per screen: active pages, cursor, saved cursor, charsets, Kitty keyboard flag stack, and full history.
- Unfinished parser input (the CONTINUATION record), replayed for us.
- Kitty images when present, per the guide (`G/snapshots.md:157-172`). The comment at
  `S/terminal/snapshot/terminal.zig:240-243` says image state is not captured. It predates the image records in
  `S/terminal/snapshot/main.zig:50-76`. Treat the guide as correct.

Reset on restore: selection, scrolled viewport (the terminal starts following the active area), dirty flags, search
state, compression state. Callbacks and userdata are ours to set again.

After every restore:

1. `configure(term)`: userdata, callbacks, our scrollback limit, our theme colors, Kitty limit.
2. Re-point everything that borrowed the old terminal: formatter, gesture, tracked refs. Free them against the old
   terminal first.
3. Re-sync the key and mouse encoders from the new terminal.
4. Read mode 2026 and seed the hold state.
5. Create a fresh render state (section 2). Its first update is a full redraw.
6. Compare the snapshot's cols and rows with our pane, then handle the `resize` APC as today.

### Failure modes

- Truncated input: `GHOSTTY_INVALID_VALUE`. `GHOSTTY_IO_ERROR` is only for a reader callback that returned false
  (`G/snapshots.md:90-99`).
- CRC, version, order or count mismatch: `GHOSTTY_INVALID_VALUE`.
- Unfinished input larger than `OPT_MAX_CONTINUATION_BYTES`: `GHOSTTY_LIMIT_EXCEEDED` (`S/terminal/c/snapshot.zig`
  `decoderMapError`). The default limit is 65 MiB.
- Any error after input was consumed poisons the decoder. Only `free` is allowed after that.
- One-shot `decode` frees its partial terminal and returns NULL on failure (`S/terminal/c/snapshot.zig`
  `decoder_decode`). After `ready()`, a failed `next()` leaves a usable terminal with partial history.
- Unknown record tags are CRC-checked and skipped, so a newer server can add optional records. Format version 1 has no
  compatibility promise (`G/snapshots.md:16-18`, `244-251`).

## 5. Input

All encoders need the terminal's modes. `set_from_terminal` copies them at call time, so call it under T
(`G/input.md:21-35`).

### Keys

```swift
ghostty_key_encoder_new(nil, &enc)        // once
ghostty_key_event_new(nil, &ev)           // once, reuse
// per event, under T:
ghostty_key_encoder_set_from_terminal(enc, term)
var alt = GHOSTTY_OPTION_AS_ALT_TRUE
ghostty_key_encoder_set(enc, GHOSTTY_KEY_ENCODER_OPT_MACOS_OPTION_AS_ALT, &alt)
ghostty_key_event_set_action(ev, GHOSTTY_KEY_ACTION_PRESS)
ghostty_key_event_set_key(ev, GHOSTTY_KEY_ARROW_UP)
ghostty_key_event_set_mods(ev, GhosttyMods(GHOSTTY_MODS_SHIFT))
var buf = [UInt8](repeating: 0, count: 128); var n = 0
let r = ghostty_key_encoder_encode(enc, ev, &buf, buf.count, &n)
// r == SUCCESS and n == 0: nothing to send. OUT_OF_SPACE: n is the size needed.
```

(Probe: Shift+Up gives `ESC [ 1 ; 2 A`.)

- The sync replaces **all** encoder options: cursor-key and keypad application modes, backarrow mode,
  ignore-keypad-with-numlock, alt-esc-prefix, modifyOtherKeys 2 and the Kitty flags of the active screen. It resets
  `MACOS_OPTION_AS_ALT` to false every time. Set it again after each sync (`G/input.md:63-69`,
  `S/input/key_encode.zig:59-72`).
- Option as Alt on iOS: the legacy Alt-prefix path checks the option only when the target is macOS
  (`S/input/key_encode.zig:562-572`). The modifyOtherKeys path checks it on every Darwin target and drops Alt when the
  option is false (`:402-411`). So on the iOS slices Alt behaves differently per path unless the option is
  `GHOSTTY_OPTION_AS_ALT_TRUE`. Always set TRUE. The macOS slice (used by `decode.c` and any Mac-hosted test) is
  stricter than iOS, so byte-exact key tests must run on the simulator slice.
- Event fields: `set_action` (PRESS, RELEASE, REPEAT), `set_key` (physical `GHOSTTY_KEY_*`, W3C codes), `set_mods`,
  `set_consumed_mods`, `set_composing`, `set_utf8`, `set_unshifted_codepoint` (`H/key/event.h`).
- `set_utf8` does **not** copy. The bytes must outlive the encode call (`H/key/event.h:466-468`). In Swift keep the
  encode inside the `withUnsafeBufferPointer` closure, then clear the text.
- `utf8` must be the text before Ctrl or Meta changes. Never pass C0 controls or the U+F700 function-key code points
  that `UIKey.characters` returns. Pass empty text and a real key code for those (`H/key/event.h:455-461`).
- Kitty protocol: when the program enabled it, the flags arrive through the sync. Release events only encode with
  `REPORT_EVENTS`. Enter, Tab and Backspace stay `\r`, `\t`, `0x7f` unless `REPORT_ALL` is set
  (`S/input/key_encode.zig:112-124`, `177-195`). With DECBKM (mode 67) Backspace is `0x08`
  (`H/key/encoder.h:122-127`). Do not hardcode those bytes.
- Soft-keyboard text: build an event with `GHOSTTY_KEY_UNIDENTIFIED`, no mods and the text as `utf8`. The legacy and
  Kitty paths both send the text as is. (Probe: "é" gives `C3 A9`.) For one ASCII character also set the matching key
  code and `unshifted_codepoint`, so `REPORT_ALL` can encode it.
- KeyBar Ctrl and Alt: set `GHOSTTY_MODS_CTRL` / `GHOSTTY_MODS_ALT` on the event with the unmodified text, and let the
  encoder produce the control byte or ESC prefix.
- Marked text (IME): send nothing while composing. `set_composing(true)` suppresses output for non-modifier keys.

### Mouse

```c
ghostty_mouse_encoder_new(NULL, &menc);                       // once
ghostty_mouse_encoder_set_from_terminal(menc, term);          // tracking mode + format
GhosttyMouseEncoderSize sz = GHOSTTY_INIT_SIZED(GhosttyMouseEncoderSize);
sz.screen_width = w_px; sz.screen_height = h_px;
sz.cell_width = cell_w_px; sz.cell_height = cell_h_px;        // plus padding_* if any
ghostty_mouse_encoder_set(menc, GHOSTTY_MOUSE_ENCODER_OPT_SIZE, &sz);
bool down = true;
ghostty_mouse_encoder_set(menc, GHOSTTY_MOUSE_ENCODER_OPT_ANY_BUTTON_PRESSED, &down);

ghostty_mouse_event_set_action(mev, GHOSTTY_MOUSE_ACTION_PRESS);   // PRESS, RELEASE, MOTION
ghostty_mouse_event_set_button(mev, GHOSTTY_MOUSE_BUTTON_LEFT);    // or ..._clear_button
ghostty_mouse_event_set_mods(mev, mods);
ghostty_mouse_event_set_position(mev, (GhosttyMousePosition){ .x = px, .y = py });
ghostty_mouse_encoder_encode(menc, mev, buf, sizeof buf, &n);      // n == 0: not reported
```

- Formats: X10, UTF-8, SGR, URxvt, SGR-Pixels. Tracking modes: none, X10, normal, button, any. Both come from the sync
  (`H/mouse/encoder.h:25-52`).
- Positions are surface pixels (float), origin top-left. The encoder converts to cells with `OPT_SIZE`. The default
  size is a 1x1 pixel screen, which is never right. Use the same pixel unit for size and positions
  (`G/input.md:119-124`). Zero cell size is rejected.
- The sync does not touch the size or `ANY_BUTTON_PRESSED`. Those are ours.
- **The sync clears motion dedupe state** (`H/mouse/encoder.h:198-200`). Do not sync before every motion event. Sync
  when a write may have changed modes: keep a "fed since last sync" flag, or sync at the start of each gesture.
- `GHOSTTY_MOUSE_ENCODER_OPT_TRACK_LAST_CELL = true` drops motion events that stay in one cell. SGR-Pixels is never
  deduped (`S/input/mouse_encode.zig:108-117`). `ghostty_mouse_encoder_reset` clears the state.
- Wheel: buttons FOUR (64, up), FIVE (65, down), SIX and SEVEN (66, 67, horizontal), sent as PRESS
  (`S/input/mouse_encode.zig:217-220`). One event per wheel step.
- `GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING` (bool) says whether any tracking mode is on. Use it to choose between "send
  to the program" and "native scroll / select".
- Alternate scroll (mode 1007, arrows on the alt screen) is not in the library. Read the mode with
  `GHOSTTY_TERMINAL_DATA_MODE` and encode arrow key events with the key encoder, so DECCKM is honored.
- Outside the grid: press and motion are dropped unless a motion mode is on and a button is held. Release is always
  reported (`S/input/mouse_encode.zig:88-103`).

### Paste

Upstream path (`G/input.md:159-211`, `E/c-vt-paste`): `ghostty_terminal_paste(term, &paste, &pasted)` with a sized
`GhosttyPaste` (`mimes`, `mimes_len`, `reader`, `source`, `allow_unsafe`). It reads modes itself, replaces unsafe
control bytes with spaces, wraps in `ESC [ 200 ~ ... ESC [ 201 ~` under mode 2004, converts newlines to CR otherwise,
and streams 4096-byte chunks through `WRITE_PTY`. `GHOSTTY_REJECTED` means the text could inject commands: confirm
with the user and call again with `allow_unsafe = true`. It needs the gated `WRITE_PTY` from section 1.

Without `WRITE_PTY`:

```c
GhosttyTerminalModeConfig m = { .mode = ghostty_mode_new(2004, false) };
ghostty_terminal_get(term, GHOSTTY_TERMINAL_DATA_MODE, &m);        // under T
bool unsafe = !ghostty_paste_is_safe(text, len);                   // conservative: any \n or \r
size_t need = 0;
ghostty_paste_encode(text, len, m.value, NULL, 0, &need);          // mutates text in place
ghostty_paste_encode(text, len, m.value, out, need, &written);
```

`ghostty_paste_is_safe` ignores terminal state and flags every newline, even under bracketed paste.
`ghostty_terminal_paste` applies the state-aware rule: newlines are safe when bracketed, the `ESC [ 201 ~` terminator
is not (`H/paste.h:150-170`). To match it without the callback, treat newlines as safe when `m.value` is true and
still reject text that contains the terminator. `ghostty_paste_encode` needs a mutable copy of the text.

### Focus

No encoder. Check mode 1004 with `GHOSTTY_TERMINAL_DATA_MODE`, then `ghostty_focus_encode(GHOSTTY_FOCUS_GAINED |
GHOSTTY_FOCUS_LOST, buf, len, &n)` gives `CSI I` or `CSI O` (`G/input.md:137-153`). Whether a mirror with several
viewers should send them is a product decision.

## 6. Selection

### Model

- `GhosttySelection {start, end, rectangle}`. Both ends are inclusive `GhosttyGridRef` values. `start` can come after
  `end`. It is a snapshot: valid only until the next mutating terminal call (`G/selection.md:19-36`).
- `ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_SELECTION, &sel)` copies it into tracked, terminal-owned state.
  That copy follows scrolling, output, pruning and reflow. NULL clears it. It belongs to the active screen
  (`H/terminal.h:2243-2256`).
- `GHOSTTY_TERMINAL_DATA_SELECTION` reads it back as a fresh snapshot, or `NO_VALUE`.
- The render state reports the installed selection per row (`ROW_DATA_SELECTION`). Setting it dirties the frame.
  Nothing else draws a selection for us.
- Nothing installs a selection automatically. Every function returns a snapshot.

### Points and refs

`GhosttyPoint {tag, value.coordinate {x, y}}` with tags `GHOSTTY_POINT_TAG_ACTIVE`, `_VIEWPORT`, `_SCREEN`,
`_HISTORY`. `ghostty_terminal_grid_ref(term, point, &ref)` is fast for ACTIVE and VIEWPORT and can walk all pages for
SCREEN and HISTORY (`G/grid.md:71-74`). Touch handling should always use VIEWPORT.
`ghostty_terminal_point_from_grid_ref` goes back, and returns `NO_VALUE` when the cell is outside that space.

Tracked refs: `ghostty_terminal_grid_ref_track(term, point, &tracked)`. They follow the cell through scroll, output,
pruning and reflow, and add bookkeeping to every terminal change, so keep few (`G/grid.md:127-135`). Read with
`ghostty_tracked_grid_ref_snapshot` or `_point`. `_has_value` turns false when the cell is discarded.
`ghostty_tracked_grid_ref_free` is safe after the terminal is gone. With an installed selection we need none of our
own: read `GHOSTTY_TERMINAL_DATA_SELECTION` under T and convert the ends with
`ghostty_terminal_point_from_grid_ref(..., GHOSTTY_POINT_TAG_VIEWPORT, ...)`.

### Gestures (the recommended path)

The guide says the gesture API is the one to use for pointer input (`G/selection.md:13-15`). It handles click counts,
word and line granularity during drag, and autoscroll. Hand-built word drag flickers between words
(`G/selection.md:96-103`).

```c
ghostty_selection_gesture_new(NULL, &gesture);                               // one per pointer stream
ghostty_selection_gesture_event_new(NULL, &press, GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_PRESS);
/* also DRAG, RELEASE, AUTOSCROLL_TICK, DEEP_PRESS: one reusable object each */

ghostty_selection_gesture_event_set(press, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REF, &ref);
ghostty_selection_gesture_event_set(press, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_POSITION, &pos);
ghostty_selection_gesture_event_set(press, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_TIME_NS, &now_ns);
GhosttySelection sel;
GhosttyResult r = ghostty_selection_gesture_event(gesture, term, press, &sel);
if (r == GHOSTTY_SUCCESS) ghostty_terminal_set(term, GHOSTTY_TERMINAL_OPT_SELECTION, &sel);
```

| Event | Required | Optional |
| --- | --- | --- |
| PRESS | `OPT_REF` | position, time, repeat distance and interval, behaviors, word boundaries |
| DRAG | `OPT_REF`, `OPT_GEOMETRY` | position, rectangle, word boundaries |
| RELEASE | none | `OPT_REF` (unset means "not over a cell") |
| AUTOSCROLL_TICK | `OPT_VIEWPORT`, `OPT_GEOMETRY` | position, rectangle, word boundaries |
| DEEP_PRESS | none | word boundaries |

- `NO_VALUE` is normal: a single press and every release produce no selection.
- Without `OPT_TIME_NS` only single-click behavior exists. `OPT_BEHAVIORS` maps single, double and triple click to
  CELL, WORD, LINE or OUTPUT (default cell, word, line).
- For long press: a PRESS with a `GhosttySelectionGestureBehaviors` whose `single_click` is WORD selects the word at
  once and makes the following drag word-granular. Or send PRESS then DEEP_PRESS, which selects the word around the
  anchor (`E/c-vt-selection-gesture`).
- `GhosttySelectionGestureGeometry {columns, cell_width, padding_left, screen_height}` in surface pixels.
- After each DRAG read `GHOSTTY_SELECTION_GESTURE_DATA_AUTOSCROLL`. While it is UP or DOWN, run our own timer (about
  15 ms) that sends AUTOSCROLL_TICK. Each tick scrolls the viewport one row itself and extends the drag. `NO_VALUE`
  from a tick means stop the timer (`G/selection.md:162-171`, `H/selection.h:611-620`). The scroll view offset must
  follow.
- All gesture calls run under T. `ghostty_selection_gesture_reset(gesture, term)` cancels.
  `ghostty_selection_gesture_free(gesture, term)` takes the last terminal used, or NULL if that terminal is already
  freed (`H/selection.h:668-691`).

### Other selection functions

All take sized option structs and return a snapshot or `NO_VALUE` (`G/selection.md:76-90`):
`ghostty_terminal_select_word` (`GhosttyTerminalSelectWordOptions {ref, boundary_codepoints,
boundary_codepoints_len}`), `_select_word_between`, `_select_line` (`{ref, whitespace, whitespace_len,
semantic_prompt_boundary}`), `_select_output` (needs OSC 133), `_select_all`. Passing NULL boundaries uses Ghostty's
defaults.

`ghostty_terminal_selection_adjust(term, &sel, GHOSTTY_SELECTION_ADJUST_*)` moves the logical `end` (left, right, up,
down, home, end, page up/down, line begin/end) and rewrites `sel`. Install the result again. `_selection_ordered(term,
&sel, GHOSTTY_SELECTION_ORDER_FORWARD, &out)` gives top-left-first ends. `_selection_contains` hit-tests a point.

### Copy

```swift
var sel = GhosttySelection()
guard ghostty_terminal_get(term, GHOSTTY_TERMINAL_DATA_SELECTION, &sel) == GHOSTTY_SUCCESS else { return }
var yes = true
ghostty_formatter_set(fmt, GHOSTTY_FORMATTER_OPT_UNWRAP, &yes)
ghostty_formatter_set(fmt, GHOSTTY_FORMATTER_OPT_TRIM, &yes)
ghostty_formatter_set(fmt, GHOSTTY_FORMATTER_OPT_SELECTION, &sel)
var p: UnsafeMutablePointer<UInt8>?; var n = 0
ghostty_formatter_format_alloc(fmt, nil, &p, &n)
// copy bytes out, then:
ghostty_free(nil, p, n)
```

- Plain output with UNWRAP and TRIM both true is what Ghostty puts on the clipboard (`G/selection.md:184-216`). UNWRAP
  defaults to false.
- `ghostty_formatter_terminal_new(NULL, &fmt, term)` borrows the terminal, which must outlive it. One formatter can be
  reused (`H/formatter.h:218-222`).
- The formatter's selection copy dies on the next terminal change. Set it and format in one critical section under T.
  Formatting a large selection holds T: copy is rare, accept it.
- Other formats: `GHOSTTY_FORMATTER_FORMAT_VT`, `_HTML` through `GHOSTTY_FORMATTER_OPT_EMIT`.

## 7. Colors and themes

- Two layers per color: a default we set, and an override the program sets with OSC 10, 11, 12 and OSC 4
  (`G/colors.md:7-11`).
- Set defaults with `GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND`, `_BACKGROUND`, `_CURSOR` (`GhosttyColorRgb*`, NULL
  unsets) and `_COLOR_PALETTE` (`GhosttyColorRgb[256]*`, NULL restores the built-in palette).
- Setting the palette updates only indices the program has not overridden. Overrides stay (`G/colors.md:29-31`).
- A program override wins over our default until the program resets it. A theme change does not clear overrides. That
  is correct behavior.
- Read with `GHOSTTY_TERMINAL_DATA_COLOR_*` (effective) and `..._DEFAULT`. Foreground, background and cursor return
  `NO_VALUE` when neither layer is set. The renderer should read colors from the render state, not from the terminal.
- A restore brings the **server's** defaults and overrides. Re-apply our four defaults after every restore. The
  program's overrides survive that.
- Terminal-free helpers: `ghostty_color_parse`, `ghostty_color_palette_default`, `ghostty_color_palette_generate`,
  `ghostty_color_contrast` (`G/colors.md:70-165`).
- Light/dark: the `CSI ? 996 n` query is answered by the `COLOR_SCHEME` callback through `WRITE_PTY`. We do not
  install it, so the server answers. Mode 2031 notifications are ours to send if we want them: check
  `GHOSTTY_MODE_REPORT_COLOR_SCHEME` (2031), then `ghostty_color_scheme_report_encode(GHOSTTY_COLOR_SCHEME_DARK |
  _LIGHT, buf, len, &n)` gives `CSI ? 997 ; 1 n` or `; 2 n` (`G/colors.md:167-185`). Send it only if the server does
  not, or the program gets duplicates. Unconfirmed: what the Rex server does.

## 8. Kitty graphics

- Enabled in our build. `ghostty_build_info(GHOSTTY_BUILD_INFO_KITTY_GRAPHICS, &b)` returns true on the macOS slice
  (probe). The header says it is on for every target with an operating system (`H/build_info.h:71-79`). The same
  probe: SIMD true, tmux control mode false, snapshot, formatter, selection and search features true, optimize
  ReleaseFast.
- On by default with 10 MB of storage per screen. Programs can fill it even if we never draw (`G/images.md:13-23`).
- Not drawing images: set `GHOSTTY_TERMINAL_OPT_KITTY_IMAGE_STORAGE_LIMIT` to 0 on new terminals and
  `GHOSTTY_SNAPSHOT_DECODER_OPT_KITTY_IMAGE_STORAGE_LIMIT` to 0 on decoders. The decoder applies its own limit, never
  the snapshot's (`H/snapshot.h:130-146`). Zero disables the protocol and deletes stored images. Skip the image
  iterator entirely. Protocol queries are answered by the server either way.
- Drawing images later needs: a real cell pixel size in `ghostty_terminal_resize`, a PNG decoder installed
  process-wide with `ghostty_sys_set(GHOSTTY_SYS_OPT_DECODE_PNG, fn)` before any other thread uses the library (PNG
  images are rejected without it), the image iterator (`GHOSTTY_RENDER_STATE_DATA_IMAGE_ITERATOR`), sorting by layer
  then z, and `GHOSTTY_RENDER_STATE_DATA_IMAGE_PLACEMENTS_GENERATION` to skip unchanged lists (`G/images.md:44-140`).

## 9. Performance notes and pitfalls

- **Lock hold time.** Only `vt_write`, `begin_update`, the scrollbar read, encoder syncs, selection, formatter,
  scroll, resize, compress and decoder `next()` need T. Everything else in a frame runs outside it.
- **Callbacks run under T** on the feed thread. A slow callback is a slow terminal (`G/effects.md:54-55`). Hop to main
  for UI work and copy borrowed strings first.
- **Full redraws are common.** Any scroll, color change, resize or screen switch. See section 2.
- **Per-cell calls.** One `ROW_DATA_CELLS_RAW` per row instead of `row_cells_next` per cell. Fetch style and graphemes
  only for cells that have them. `get_multi` saves nothing in Swift.
- **Selection is slow inside the update.** With a selection installed, `beginUpdate` does per-row point conversions
  under T (`S/terminal/render.zig:1301-1311`, marked inefficient by upstream). Fine for a few rows, visible in lock
  time during heavy output.
- **Allocation.** Reuse the row iterator, cells handle, key and mouse events, formatter and gesture events. The render
  state reuses its row and cell storage.
- **Grid refs are not for rendering** (`G/grid.md:18-21`, `H/terminal.h:3595-3598`).
- **Untracked refs and selection snapshots** die on any mutating call, including `ghostty_terminal_set`. Create, use
  and drop them inside one critical section.
- **Reentrancy.** Never call `vt_write` from a callback. No error is reported and the parser state is corrupted
  (`G/effects.md:43-52`).
- **`VT_PROCESSING_ERROR`** is a sticky flag for internal failures. Log it once per session.
- **Sprite coverage.** Ghostty draws these ranges itself instead of using the font (`S/font/sprite/draw/`):
  U+2500–257F, U+2580–259F, U+25E2–25E5, U+25F8–25FA, U+25FF, U+2800–28FF (braille), Powerline U+E0B0–E0BF, U+E0D2,
  U+E0D4, U+F5D0–F60D, U+1FB00–1FBEF with gaps, and parts of U+1CC00–1CEAF. Its cell metrics: width = round(advance),
  height = round(ascent + descent + line gap), baseline centered in the rounded cell, underline thickness = max(1,
  ceil(font value)), box thickness = underline thickness (`S/font/Metrics.zig:227-334`).

### Swift import gotchas (probe results)

- **Enums are structs with `rawValue`**, compared with `==` against the imported constants. `GhosttyResult.rawValue`
  is `Int32`. Other enums are `UInt32`. `GHOSTTY_ENUM_TYPED` expands to nothing before C23, so there is no fixed
  underlying type (`H/types.h:83-126`).
- **Sized structs.** `GHOSTTY_INIT_SIZED` is a macro and does not import. Use `var s = T(); s.size =
  MemoryLayout<T>.size`, or the library's own `ghostty_sized_init(&s, MemoryLayout<T>.size)` (`H/types.h:562-584`). A
  wrong or zero size returns `GHOSTTY_INVALID_VALUE`. Sized structs we use: `GhosttyRenderStateColors`,
  `GhosttyRenderStateCursor`, `GhosttyRenderStateRowSelection`, `GhosttyMouseEncoderSize`, `GhosttyPaste`,
  `GhosttyTerminalMemoryUsage`, `GhosttyTerminalSelectWordOptions`, `GhosttyTerminalSelectWordBetweenOptions`,
  `GhosttyTerminalSelectLineOptions`, `GhosttyTerminalWriteStop`. Not sized (fixed layout): `GhosttyStyle`,
  `GhosttySelection`, `GhosttyTerminalModeConfig`, `GhosttyTerminalScrollbar`, `GhosttyRenderStateOverscan`,
  `GhosttyCodepointBuffer`.
- **Macros that do not import**: every `GHOSTTY_MODE_*` (use `ghostty_mode_new(2026, false)`; the second argument is
  true for ANSI modes), `GHOSTTY_STYLE_FLAG_*`, `GHOSTTY_STYLE_UNDERLINE_MASK`, `GHOSTTY_STYLE_UNDERLINE()`,
  `GHOSTTY_KITTY_KEY_ALL`, `GHOSTTY_FORMATTER_EXTRAS_DEFAULT`, `GHOSTTY_IMAGE_LAYER_MASK_*`. Define Swift constants
  for the style bits listed in section 2.
- **Macros that do import**, as `Int32`: `GHOSTTY_MODS_*`, single `GHOSTTY_KITTY_KEY_*` bits,
  `GHOSTTY_STYLE_UNDERLINE_SHIFT`. `GHOSTTY_FORMATTER_EXTRA_*` import as `UInt32`. Wrap them:
  `GhosttyMods(GHOSTTY_MODS_SHIFT)`.
- **Static inline helpers** `ghostty_mode_new`, `ghostty_mode_value`, `ghostty_mode_ansi` import and work.
  `GhosttyMode` is `UInt16`.
- **`GhosttyStyleColor.tag` is `UInt8`**, the tag constants are a `UInt32` enum. Compare with
  `UInt8(GHOSTTY_STYLE_COLOR_RGB.rawValue)`.
- **`palette[256]` imports as a 256-element tuple.** Read it with `withUnsafeBytes(of:)`. Pass a `[GhosttyColorRgb]`
  of 256 entries to `OPT_COLOR_PALETTE`.
- **Unions** (`GhosttyTerminalScrollViewport.value`, `GhosttyPoint.value`) import with settable members.
  Zero-initialize the struct first.
- **Callbacks** are `@convention(c)` closures that capture nothing, passed with `unsafeBitCast(fn, to:
  UnsafeRawPointer.self)`.
- **Linking**: static library plus `-lc++`.

## 10. Where `docs/ghostty-engine.md` is wrong or suboptimal

1. **No synchronized-output handling** (plan lines 176, 120-121). Updating every frame shows half-drawn frames.
   Install `GHOSTTY_TERMINAL_OPT_RENDER_HOLD`, capture in the callback, use a 1 s timeout, and seed the state from
   mode 2026 after a restore (`G/rendering.md:102-185`). This also adds a render-state lock and the T-then-R order.
2. **"Only `render_state_end_update` is safe without the lock"** (line 238-239) is too narrow and hides a race. Every
   render-state read is terminal-free (`P/conventions.md:94-96`), but the render state itself is one handle, and the
   hold callback writes it from the feed thread.
3. **READY, then full decode, then swap** (lines 164-166) is not the upstream design. `ready()` returns the final
   terminal and `next()` prepends history into it (`G/snapshots.md:101-116`, `137-155`). A swap would need a second
   terminal and breaks dirty tracking. On our single ordered stream, READY only saves decode time
   (`S/terminal/snapshot/main.zig:142-146`).
4. **Restore replaces the terminal handle.** The plan treats the terminal as one long-lived object (lines 168-172).
   Callbacks, userdata, limits, theme, formatter, gesture and encoder state must all be re-applied after each restore
   (`S/terminal/c/terminal.zig:951-980`).
5. **Scrollback gotcha** (line 227). The 10,000-byte default only applies to `ghostty_terminal_new`. A restored
   terminal inherits the server's limits (`S/terminal/snapshot/terminal.zig:975-987`). Set our budget after every
   restore.
6. **"Never install `OPT_WRITE_PTY`"** (line 225) blocks `ghostty_terminal_paste`, the upstream paste path, which
   needs it (`H/paste.h:136-139`, `G/input.md:167-168`). Use a gated callback, or `ghostty_paste_encode` with a
   hand-read mode 2004.
7. **`row_cells_next` plus `ghostty_cell_get_multi`** (line 183). `get_multi` costs the same as separate calls from C
   or Swift (`H/screen.h:361`) and aborts on `NO_VALUE`. Use `GHOSTTY_RENDER_STATE_ROW_DATA_CELLS_RAW` once per row
   (`H/render.h:457-471`).
8. **"Rebuild dirty rows only"** (line 176) is not the common case. Any viewport pin change is a full redraw,
   including scrolling output and every native scroll step (`S/terminal/render.zig:1021-1024`,
   `G/rendering.md:265-267`). Budget for full rebuilds.
9. **Hardcoded Return = `\r`, Backspace = `0x7f`** (lines 203-204) is wrong under Kitty `REPORT_ALL` and DECBKM. Send
   them through the key encoder (`S/input/key_encode.zig:177-195`, `H/key/encoder.h:122-127`).
10. **Selection by `select_word` plus hand-set `OPT_SELECTION` on drag** (line 209). Upstream points to the gesture
    API for pointer input, with word-granular drag and autoscroll (`G/selection.md:13-15`, `96-103`, `162-171`).
11. **No compression driver.** `COMPRESS_HISTORY` (line 228) only covers restored pages. Live history is never
    compressed unless we run the idle loop (`G/scrollback.md:178-181`).
12. **Kitty graphics not addressed.** It is enabled, with 10 MB per screen, and counts against the memory benchmark.
    Set both limits to 0 (`G/images.md:13-23`).
13. **Scrollbar read not tied to the update** (lines 194-196). Read `SCROLLBAR` and `VIEWPORT_ACTIVE` in the
    `begin_update` critical section (`G/rendering.md:214-218`).
14. **Enum note** (line 236). Enums are not `: int` in our C mode. `GhosttyResult` is `Int32`, the rest `UInt32`
    (`H/types.h:113-126`). `GHOSTTY_MODE_*` macros do not import.
15. **Sprite range** (line 191) is narrower than Ghostty's: braille and Powerline are also drawn as sprites
    (`S/font/sprite/draw/`).
