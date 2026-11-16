# Terminal: stream, sizing, gestures and input

One `TerminalStream` (RexKit) per visible pane feeds one `TerminalHost` (UIKit), which wraps the
terminal engine view. Output arrives on a data socket; input goes over the control socket.

## Engine

The engine is Ghostty: libghostty-vt for parsing and terminal state, and our own Metal renderer
(`Features/Terminal/Ghostty/`). It restores the snapshot that starts every stream, parses off the
main thread, and reflows on a resize the way the server does, because the server's terminal is
Ghostty too. How it is built: [ghostty-engine.md](ghostty-engine.md). Upstream C API notes:
[ghostty-api-notes.md](ghostty-api-notes.md).

`TerminalHost` reaches it only through `any TerminalEngineView`
(`Features/Terminal/Engine/TerminalEngine.swift`). The host owns the gestures, the clipboard, the
edit menu and the hardware keymap; the engine owns the screen, scrolling, the selected range and
key encoding.

History: until November 2026 the app had a second engine, SwiftTerm, behind the same seam. It read
the screen as escape sequences (`terminal.format`) instead of restoring the snapshot. The stream
keeps that path as its fallback (below); [ghostty-parity.md](ghostty-parity.md) is the audit that
compared the two.

## Start

1. `data.connect` → a base64url ticket (16 bytes, good once, for 60 s).
2. `wss://<server>/api/data`, subprotocol `rex.data.terminal.v1`. Handshake in `DataFrame`:
   send `0x01 + ticket` (HELLO); the first frame is `0x82 <reason>` (REJECT) or a 32-byte `0x81`
   WELCOME with the resume token (bytes 1–16), how long the server keeps a dropped stream for a
   resume (UInt32 LE milliseconds, bytes 20–23; 60 s today) and the nonce (UInt64 LE, bytes 24–31).
3. The stream's first bytes are a Ghostty snapshot (`GHOSTSNP`): screen, scrollback, modes and
   size. `APCFilter` walks its record framing and hands it to the host in parts
   (`streamGhosttySnapshot`: `begin`, `bytes`…, `ready`, `bytes`…, `end`), all before the first
   Rex message. The host restores it into a new terminal.

There is no size or screen read before the stream: the snapshot is the screen, and the `resize`
message that follows it carries the size and the owner.

REJECT `0x02` means this client still has a connection to the terminal. Right after a `restart()`
that is the old socket, whose close the server hasn't handled yet, so the first start asks again
with a new ticket up to 6 times, 50 ms apart.

### If the snapshot can't be restored

The host returns false for a part, the snapshot ends incomplete, or the restore fails afterwards
(`TerminalStream.snapshotRestoreFailed()`). The data stream stays open. Once the snapshot's bytes
have gone by, the stream reads `terminal.size` and `terminal.format` (`vt`, then `blob_read` until
`eof`: the screen and the newest 1 MB of scrollback as escape sequences) and the host resets and
feeds that. Output that arrives during the read is dropped. From then on that stream reads the
screen this way on every start, and `resync()` re-reads it on the open stream.

## Output

- Rex messages are APC sequences, `ESC _ rex1;<nonce>;<json> ESC \`, and can split across frames.
  `APCFilter` removes them in stream order: `resize {cols, rows, owner}`, `theme`,
  `child_exited {exit_code}`. Everything else goes to the engine unchanged, as views into the
  received chunk.
- The host passes each chunk to the engine at once. The engine copies it to its feed queue and
  parses there; the main thread does no parsing and no pacing.
- A `resize` applies at its place in the stream: the local grid changes between the bytes written
  before and after it.

## Reconnect

`RexControl` is the only thing that retries a lost control connection (1 s doubling to 15 s, at
once on `kick()`). A stream never retries on its behalf; it asks to be told
(`RexControl.observeConnected`) and waits.

- Close code 4000: the pane closed. The stream ends (`.ended`).
- Any other drop of the data socket: one RESUME, 400 ms later, with
  `0x02 + token + bytes received (UInt64 LE)`. A resume needs no ticket and no control connection,
  and the stream goes on from the first byte not yet received: no new snapshot. It is not tried
  after close code 1013 (the server dropped the stream) or once the server's keep time has passed.
- If the RESUME fails or can't be tried: a fresh start (ticket, HELLO, snapshot). That needs the
  control connection. Without one the stream does nothing and shows "Reconnecting…"; when
  `RexControl` is connected again it makes exactly one start: a RESUME if the server can still
  have the stream, otherwise a fresh one.
- A fresh start that fails while the control connection is up (a refused ticket or HELLO, a data
  socket that won't open) is tried again after 3 s, then 6, 12, 24 and 30 s, and every 30 s from
  there. The next WELCOME resets that. These later starts ask for one ticket each.
- `stop()`, `restart()` and a newer start end whatever was waiting.
- `resync()` (a fresh stream, for its snapshot) does nothing while a start is under way or owed.
- Back from more than 30 s in the background, the host calls `restart()`.

## Fit and mirror

- Fit: after layout settles (120 ms), `session.own_block` (take), then `terminal.resize` to the
  largest grid that fits (`TerminalLayout.fitGrid`, at least 12×4). Leaving the pane,
  backgrounding the app, or switching to mirror calls `session.disown_block`, and the Mac gets
  its size back. If another client resizes the pane, the host stops and offers "Resized elsewhere ·
  tap to fit here".
- Mirror: never claims or resizes. Shows the server's grid scaled to the view; pinch zooms, drag pans.
  Users always get fit; mirror is only for the `-sizing mirror` launch argument.
- Fit really resizes panes on the Mac. Test it only in `zz-` sessions you created.

## Gestures

- Tap: focus the pane, clear a selection, raise the keyboard on the first tap. On a focused pane:
  open the link under the finger, or move the shell's cursor on its prompt
  (`Ghostty/GhosttyTap.swift`).
- Vertical drag: scrolls the scrollback (a native scroll view). On the alternate screen or when
  the program tracks the mouse it sends wheel reports instead, and arrow keys on the alternate
  screen with mode 1007 and no tracking.
- Horizontal swipe: next or previous pane. Swipe on the title bar: next or previous tab.
- Two-finger tap: zoom the pane (phone-only zoom, see `PhoneState`).
- Long press: select a word (haptic, loupe), drag to extend; on release copy (copy-on-select, with a
  shimmer and a confirming haptic), show handles to adjust with, and Copy / Paste / Select All.
  Double tap selects a word, triple tap a line. Mouse or trackpad drags select directly.
  Design, haptics and the seam: [selection.md](selection.md).
- Pinch: in fit mode changes the font size (one resize claim at the end); in mirror mode zooms.
- Split borders on the unfolded Duo are draggable (`SplitGeometry`), with a detent at 50%.
- A tab shows its splits as the Mac lays them out while every pane keeps 40×8 cells
  (`SplitGeometry.legible`); otherwise one pane shows at a time, with dots in the title bar and a
  sideways swipe on the terminal to move between panes.
- Resizing or toggling the sidebar changes the tab's frame once (on release, or after the slide),
  never per frame, so fit mode claims one new size ([duo-layout.md](duo-layout.md)).
- A width change (fold, unfold, rotation, resize) claims the new size and nothing else: the
  engine reflows its lines as the server reflows its own, so nothing is read again.
- `TerminalHostPool` keeps each pane's `TerminalHost` alive while a fold or unfold swaps the view
  tree. The new `PaneView` takes the host over, so the stream, screen and keyboard focus carry over.

## Input

Every byte goes through `TerminalStream.send`. The rules follow from what the server offers
(`com.superlogical.terminal.write`, API revision 14): it takes one argument, `data`, a string; it
has no sequence number or idempotency key; and the server doesn't order block methods ("wait for
the first call's response before you send the second").

- **One request at a time, in order.** Typed text and the server calls bound to keys
  (`perform(action:)` → `client.action`, `forward(key:)` → `client.key`) share one queue. Text
  typed while a request is out goes together as the next write. An action waits for the text
  typed before it, and text typed after it waits for the action, at most 1.5 s (a Lua action can
  run for seconds).
- **Held while offline.** Without a control connection nothing is sent and nothing is lost; the
  queue goes out, in order, when `RexControl` is connected again.
- **Never sent twice.** What happens to a request that fails:
  - it never left this client (no connection, or the socket didn't take the message;
    `RexError.neverSent`): it stays first in the queue and is sent when the connection is back;
  - the server refused it (the pane closed): dropped;
  - it was sent and the connection broke before the answer: nobody can know whether the server
    ran it. Sending `rm x⏎` again could run it twice, which is worse than a lost keystroke the
    user can see and retype. It is dropped, with everything queued behind it (typed on the
    assumption that it had arrived), and the user gets a notice ("The connection dropped while
    sending. Check the pane before typing that again.").
- **`stop()` drops the queue**, `restart()` keeps it. A pane that was closed or left must not
  receive old keys when it is opened again; a stream that reconnects must not lose them.
- **UTF-8 only.** `data` is a JSON string, so bytes that aren't valid UTF-8 can't be typed.
  `send` drops such a call whole and returns false, rather than type U+FFFD in their place. In
  practice that is a legacy X10 mouse report beyond column 95, where the column is one raw byte
  of 128 or more. The mouse encoder uses the format the program asked for, and programs that
  track the mouse on wide screens ask for SGR (mode 1006) or UTF-8 (1005), both plain UTF-8.

Around that:

- Paste goes through the engine's `pasteText`, so programs that asked for bracketed paste get it.
- Key bar (`KeyBar`): keys from the layout picked in Settings (`KeyBarLayout`); ctrl/alt tap for one key, double-tap to lock; the
  "arrows" key is a trackpad. Bytes are in `KeyBar.bytes(for:appCursor:)`.
- Hardware keyboard: the engine view's `keyHook` sees each press first. `KeymapStore` matches it
  against Rex's keymap (`KeyChord` spellings like `shift+cmd+d` or `cmd+[Digit1]`), and
  `AppAction` turns the binding into an app command, a key to send (`KeyInput.bytes`), a server
  action, or a forwarded key. Unbound keys go to the engine's key encoder.
- A press is matched in tiers (`KeyInput.chordTiers`): what the key types and its position, then
  the character typed with shift (on a Spanish or German keyboard `/` is shift+7, so `cmd+/`
  arrives as shift+cmd+7), then the key's US name when what it types can't be spelled (`ñ`). A
  later tier never takes a key from a binding that names an earlier one.
- Who has the keyboard (`KeyboardFocusPolicy`): with a hardware keyboard the active pane's
  terminal is first responder, as on a Mac, and takes it back when it comes free (pane switch,
  fold, a text field done, the app active again). Never from a text field, under a sheet, or
  after the key bar's hide key. Without a hardware keyboard a pane only keeps what it had.
- The keymap's app commands are also menu shortcuts (`AppShortcutCommands`), so ⌘/ and the rest
  work when no terminal is first responder (no tab open, keyboard put away). The menu replaces
  the system's Settings item, whose ⌘, would open the Settings app before the keymap sees it.
