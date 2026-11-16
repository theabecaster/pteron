# Terminal: stream, sizing, gestures and input

One `TerminalStream` (RexKit) per visible pane feeds one `TerminalHost` (UIKit), which wraps a
terminal engine view. Output arrives on a data socket; input goes over the control socket.

## Engines

`TerminalHost` knows no engine. It talks to `any TerminalEngineView`
(`Features/Terminal/Engine/TerminalEngine.swift`), made by `TerminalEngineKind.makeView`:

- SwiftTerm: `RexTerminalView` in `Engine/SwiftTermEngine.swift`, the only file that imports SwiftTerm.
  This document describes its behavior.
- Ghostty: `Features/Terminal/Ghostty/` (libghostty-vt for terminal state, our Metal renderer).
  It restores the stream's snapshot directly (`restoresGhosttySnapshot`) and parses off the main
  thread. Input, scrolling and selection work; how each compares with SwiftTerm is in
  [ghostty-parity.md](ghostty-parity.md).

Settings → Terminal → Engine picks one (UserDefaults `terminalEngine`, or `-terminalEngine
ghostty|swiftTerm` for one run); changing it rebuilds the open panes. Plan, design and status:
[ghostty-engine.md](ghostty-engine.md). Upstream C API notes: [ghostty-api-notes.md](ghostty-api-notes.md).

## Start

1. `terminal.size` → the server's cols, rows and owner.
2. `terminal.format` (`vt`), then `blob_read` until `eof` (900 KB chunks, at most 40). This is the
   screen and the newest 1 MB of scrollback as escape sequences; the host resets and feeds it.
3. `data.connect` → a base64url ticket (16 bytes).
4. `wss://<server>/api/data`, subprotocol `rex.data.terminal.v1`. Handshake in `DataFrame`:
   send `0x01 + ticket`; the first frame is `0x82 <reason>` (refused) or a 32-byte `0x81` welcome
   with the resume token (bytes 1–16) and the nonce (UInt64 LE, bytes 24–31).

## Output

- The stream starts with a binary Ghostty snapshot. `APCFilter` drops everything before the first
  Rex message, since step 2 already drew the screen. With `restoresGhosttySnapshot` (Ghostty
  engine) steps 1 and 2 are skipped and the filter hands the snapshot to the sink instead
  (`streamGhosttySnapshot`); if it can't be restored, the stream falls back to steps 1 and 2.
- Rex messages are APC sequences, `ESC _ rex1;<nonce>;<json> ESC \`, and can split across frames.
  `APCFilter` removes them in stream order: `resize {cols, rows, owner}`, `theme`,
  `child_exited {exit_code}`. Everything else goes to the engine unchanged.
- Heavy output is parsed in slices on a display link, about 4 ms per frame (engines that parse
  on the main thread; Ghostty takes it all at once on its feed queue).

## Reconnect

- Close code 4000 means the pane closed; stop. 1013 means the server dropped the stream; read the
  screen again.
- Otherwise resume up to 3 times (400 ms × attempt) with `0x02 + token + bytes received (UInt64 LE)`,
  then fall back to a full start.
- Back from more than 30 s in the background, the host re-reads the screen.

## Fit and mirror

- Fit: after layout settles (120 ms), `session.own_block` (take), then `terminal.resize` to the
  largest grid that fits (`TerminalLayout.fitGrid`, at least 12×4). Leaving the pane,
  backgrounding the app, or switching to mirror calls `session.disown_block`, and the Mac gets
  its size back. If another client resizes the pane, the host stops and offers "Resized elsewhere ·
  tap to fit here".
- Mirror: never claims or resizes. Shows the server's grid scaled to the view; pinch zooms, drag pans.
- Fit really resizes panes on the Mac. Test it only in `zz-` sessions you created.

## Gestures

- Tap: focus the pane, clear a selection, raise the keyboard on the first tap. On a focused pane
  (Ghostty engine): open the link under the finger, or move the shell's cursor on its prompt
  (`Ghostty/GhosttyTap.swift`).
- Vertical drag: SwiftTerm's scrollback, mouse wheel reports, or arrow keys (alternate screen).
- Horizontal swipe: next or previous pane. Swipe on the title bar: next or previous tab.
- Two-finger tap: zoom the pane (phone-only zoom, see `PhoneState`).
- Long press: select a word (haptic, loupe), drag to extend; on release copy (copy-on-select, with a
  shimmer and a confirming haptic), show handles to adjust with, and Copy / Paste / Select All.
  Double tap selects a word, triple tap a line (Ghostty). Mouse or trackpad drags select directly.
  Design, haptics and the seam: [selection.md](selection.md).
- Pinch: in fit mode changes the font size (one resize claim at the end); in mirror mode zooms.
- Split borders on the unfolded Duo are draggable (`SplitGeometry`), with a detent at 50%.
- A tab shows its splits as the Mac lays them out on wide windows. On compact ones (folded, half
  the unfolded screen, iPhone portrait) splits show only while every pane keeps 40×8 cells
  (`SplitGeometry.legible`); otherwise one pane shows at a time, with dots in the title bar and a
  sideways swipe on the terminal to move between panes.
- A width change (fold, unfold, rotation, resize) makes fit mode redraw from the server once the
  new size is claimed: SwiftTerm resizes without reflowing, so old lines would stay cut off.
- `TerminalHostPool` keeps each pane's `TerminalHost` alive while a fold or unfold swaps the view
  tree. The new `PaneView` takes the host over, so the stream, screen and keyboard focus carry over.

## Input

- Every byte goes through `TerminalStream.send`, which keeps one `terminal.write` in flight and
  sends keys typed meanwhile as the next write. Rex doesn't order concurrent block calls, so
  parallel writes would reorder keystrokes. Input waits out a dropped connection.
- Paste goes through SwiftTerm's `pasteText`, so programs that asked for bracketed paste get it.
- Key bar (`KeyBar`): keys from Settings; ctrl/alt tap for one key, double-tap to lock; the
  "arrows" key is a trackpad. Bytes are in `KeyBar.bytes(for:appCursor:)`.
- Hardware keyboard: the engine view's `keyHook` sees each press first. `KeymapStore` matches it
  against Rex's keymap (`KeyChord` spellings like `shift+cmd+d` or `cmd+[Digit1]`), and
  `AppAction` turns the binding into an app command, a key to send (`KeyInput.bytes`), a server
  action, or a forwarded key. Unbound keys reach SwiftTerm.
