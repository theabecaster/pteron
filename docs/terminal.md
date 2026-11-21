# Terminal: stream, sizing, gestures and input

One `TerminalStream` (RexKit) per pane feeds one `TerminalHost` (UIKit), which wraps the
terminal engine view. Output arrives on a data socket; input goes over the control socket. The
panes on screen stream; the few that left it last are parked (Parking).

## Engine

The engine is Ghostty: libghostty-vt for parsing and terminal state, and our own Metal renderer
(`Features/Terminal/Ghostty/`). It restores the snapshot that starts every stream, parses off the
main thread, and reflows on a resize the way the server does, because the server's terminal is
Ghostty too. How it is built: [ghostty-engine.md](ghostty-engine.md). Upstream C API notes:
[ghostty-api-notes.md](ghostty-api-notes.md).

`TerminalHost` holds the engine's view, `GhosttyTerminalView`, directly, and hears from it through
`TerminalEngineDelegate` (grid changes, bytes for the program). The host owns the gestures, the
clipboard, the edit menu and the hardware keymap; the view owns the screen, scrolling, the
selected range and key encoding. What must keep working, and the manual script for a device:
[terminal-checklist.md](terminal-checklist.md).

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
message that follows it carries the size and the owner. So a fitted pane starts its stream at its
first layout, beside its fit claim and not after it (Fit and mirror): the claim's settle delay and
two round trips no longer come before the first request for a screen.

Until the first screen can be drawn the pane shows `GlideLoader` in its center: Glide's outline,
about 44 pt, with a soft stroke gliding along it in a 1.2 s loop while the body holds still
(a still mark that breathes slowly with Reduce Motion), in the theme's text color. It
fades in over 180 ms only after 400 ms, and out over 150 ms, so a pane that opens fast shows
nothing. "Connecting…" sits under it and waits 2.5 s. Core Animation runs all of it: no
main-thread work per frame. A pane that has a screen never shows it.

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

The host refuses a snapshot of more than 16 MiB (`SnapshotBuffer`), so a server with a huge
history takes this path too.

## Output

- Rex messages are APC sequences, `ESC _ rex1;<nonce>;<json> ESC \`, and can split across frames.
  `APCFilter` removes them in stream order: `resize {cols, rows, owner}`, `theme`,
  `child_exited {exit_code}`. Everything else goes to the engine unchanged, as views into the
  received chunk.
- The host passes each chunk to the engine at once. The engine copies it to its feed queue and
  parses there; the main thread does no parsing and no pacing.
- **Backpressure.** When more than 4 MB wait unparsed, the engine says so
  (`GhosttyCore.isBackedUp`) and the host calls `TerminalStream.pauseReading()`: the stream takes
  the message it is waiting for and asks the socket for no other. Below 1 MB the host calls
  `resumeReading()` and the stream goes on in order. So a program that writes faster than the
  phone parses fills the socket's and the server's buffers, not the phone's memory. Input and
  control calls are not held, and a RESUME still counts only the bytes taken. Past 64 MB unparsed
  (a source that never pauses) the engine drops the backlog instead (`GhosttyCore.droppedBytes`).
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
- `stop()`, `park()`, `restart()` and a newer start end whatever was waiting.
- `resync()` (a fresh stream, for its snapshot) does nothing while a start is under way or owed.
- A fresh start whose ticket is refused with `conflict` right after a reconnect (the app's resync
  hasn't attached the session again yet) is tried again after 250 ms, up to 8 times, before the
  backoff.
- Back from the background, the host calls `wake()`: the stream pings its data socket. A socket
  that fails, or doesn't answer within 2.5 s (half open after a suspension), is dropped without a
  status 1000 close and the stream goes on with a RESUME, as after any drop. One that answers is
  live. iOS can call a ping's handler a second time when the socket is dropped while the ping
  waits, so `URLSessionStreamSocket.ping` acts on the first call only (a second resume of its
  continuation was a crash, seen on a wake during a slow upload). Transient chips ("Reconnecting…") wait out the wake's grace (`ForegroundWake.grace`).
  The fence is up from the wake until the socket has answered and the stream is quiet.
  URLSession can call a pong handler twice, the second time with an error, so the ping (and the
  socket's receive) resumes through `ResumeOnce`: only the first call counts. A second resume of
  a checked continuation is a fatal error; build 2611201727 crashed that way at Try Again.

## The catch-up fence

Input has no sequence number and is never sent twice (Input), so a key typed at a screen that is
behind the program can't be taken back. `CatchUpFence` (RexKit, one per stream) keeps input away
from a program state the user has not seen.

- **Up**: from `start()` until the first screen, and on every data socket drop, wake, return from
  the park and fresh restart. Raising it again while it is up is still the same fence.
- **Down**, only when all of these hold:
  1. the stream has arrived: the WELCOME of a RESUME, the end of a fresh stream's snapshot (or
     the screen read that stands in for it), or the pong of a wake. A stream whose snapshot
     is still coming in has not arrived, whatever else answers meanwhile;
  2. no fit claim is on its way (`TerminalStream.setClaimPending`, set by the host from the
     request until the resize has returned, the claim is released or the pane is lost);
  3. no byte and no Rex message came for 40 ms, or for 60 ms once our own `resize` came back in
     the stream, while the program redraws for its new size;
  4. the engine has parsed everything it was fed (`streamWhenParsed`), and nothing came meanwhile.
- **A pane that never goes quiet** (`yes`, a build log) would never pass 3 and could not be typed
  into, not even Ctrl-C. So 300 ms after 1 and 2 hold, the fence comes down once the engine has
  parsed what it has. The screen then moves as the program writes, as on any busy pane.
- **Keys and pastes while it is up** are held as the bytes they were encoded to, in order.
  - When the fence comes down with nothing received since it went up, over a screen the user saw,
    the screen was exact: the held bytes go out, in order, through the one input queue. This is
    the common case (an idle shell, an agent waiting) and feels local.
  - As soon as anything arrives (a byte, a resize, a snapshot, any message) they are dropped,
    with one notice: "The pane changed. Nothing was sent." Key bytes depend on terminal modes
    that may have changed with the screen, so they are never sent to another one.
  - They live 1 s at most, counted from the first; then they are dropped though nothing came,
    and the notice says that instead: "Not sent: the pane was still reconnecting."
  - Both notices are in the neutral style (`TerminalStream.onFenceNotice`): nothing failed.
  - After a drop, every later key of the same fence is dropped too, silently: the rest of a line
    whose start was dropped must not arrive alone. At most one notice per fence, and none when
    nothing was typed.
  - A pane that shows nothing yet has no screen to type at: keys typed before its first screen
    are dropped ("Not sent: the pane was still reconnecting."), and so are keys typed during a
    fresh start, whose snapshot replaces the screen.
- **Input still queued when it goes up** (typed without a connection, or behind a request that
  is out) waits for it in the queue: sent if the screen was exact, dropped with the notice
  otherwise. A request that had left is never sent again, as always.
- **Dropped while it is up, never held**: mouse and wheel reports, focus reports and the keys a
  tap or a drag makes (`engineSendReport`, `TerminalStream.send(report:)`), silently; server
  actions bound to keys, forwarded keys, palette runs and Insert Path, with the notice;
  `sendOnce` (the watch) is told it never left.
- **Made up for when it comes down**: the focus report. A program that asked for focus reports
  and was last told otherwise learns that the pane has the keyboard, ahead of any held keys
  (`GhosttyTerminalView.sayFocus`).
- **A file send** waits for the fence and then goes: the user picked a file, not a place on the
  screen (`whenCurrent`). It waits 10 s at most; if the pane is still behind then, or leaves
  the screen or closes first, the notice says "Not sent: <files>. The pane was still
  reconnecting." with Retry.
- **Always allowed**: scrolling, selection, copy, find, opening links, menus.
- **Look**: the screen as it was, with no dimming and no badge. Only the cursor is hollow, as an
  unfocused pane's. The engine holds the screen on show and draws what arrived as one frame when
  the fence comes down ([ghostty-engine.md](ghostty-engine.md), The catch-up hold), for 1 s at
  most; after that the screen follows the bytes while the fence stays up. A pane that opens at
  the size it will keep draws its first screen at once.
- A fence over a screen that is still up after 2.5 s shows "Reconnecting…".
- A `resize` from another client counts as "Resized elsewhere" only on a current stream or after
  our own resize has come by: a size from before our resize can arrive after the claim's answer.

## Parking

A pane that leaves the screen (a pane or tab switch) parks instead of stopping, so coming back
is not a cold start.

- **What parking does** (`TerminalHost.park`, 0.5 s after the pane left its window, as a fold
  moves a pane within that): the host, its terminal with screen and scrollback, the stream's
  resume token, byte count and place in the stream stay. The data socket is dropped without a
  status 1000 close (the server keeps the stream for its resume window, 60 s), the input queue
  is dropped (nothing sent is sent again), the drawables are freed, find closes, and no timer or
  ping runs. A parked pane uses no CPU and no network.
- **Coming back**: the same host is on screen in its first frame with its last screen and no
  loader. The fence goes up, and one RESUME starts at once, with no ticket and no control
  connection; only the missed bytes arrive. Typed on an idle pane, keys arrive as the fence
  comes down; on a pane that changed they are dropped with the notice.
- **If the RESUME is refused or its window has passed**: a fresh start, which keeps the old
  screen until the new snapshot begins; the fence stays up throughout.
- **Claim grace**: a parked pane keeps its fit claim for 10 s after it left the screen
  (`LeaveTiming.claimGrace`), so going back and forth between two panes resizes neither and the
  screen can be exact. On the Mac the pane stays phone-sized for those 10 s; then it gets its
  size back as before, and a later return claims again beside its RESUME. Going to the
  background still releases every claim at once.
- **How many** (`TerminalHostPool`, `ParkPolicy`): the 4 panes parked last, within 96 MB of
  terminal memory together by the engine's own figure (`GhosttyCore.memoryBytes`, read once
  when a pane leaves the screen and again if a warm pane parks: `TerminalHost.keptBytes`). The
  oldest goes first. Panes on screen don't count.
- **Warm panes** (`WarmPolicy`, `TerminalHost.warm`): the 2 panes left last don't park. Their
  streams go on off screen, parsed and never drawn (no drawables, no find, no timers of their
  own), so the screen is current the moment one is back: no RESUME, no round trip. They count
  toward the 4 and the 96 MB; the parked panes are the older ones.
  - Only in the foreground. Going to the background, Low Power Mode and a thermal state of
    serious or worse park every warm pane at once; on a cellular network or a hotspot
    (`NWPath.isExpensive`) one stays warm, not two.
  - A warm pane that writes more than 64 KB/s on average over 2 s parks (`WarmRate`, checked as
    bytes arrive, no timer): a build log is not followed unseen.
  - A warm pane comes back with no fence when nothing about it will change (`WarmReturn`): a
    mirror pane always, and a fitted pane that still holds its claim at the size that fits,
    inside its 10 s grace. It streamed at that size the whole time, so what is typed goes at
    once, also on a pane that keeps writing. A fitted pane whose claim lapsed, or that fits
    another grid now, is fenced (`TerminalStream.returned`) until the new claim's resize has
    landed and the stream is quiet.
  - A warm pane whose stream drops reconnects as a pane on screen does, behind its fence.
- **All of them go** on a memory warning, when the app comes back after 10 minutes in the
  background, when the user leaves their server or it is removed, and when their session closes
  (`ParkWatcher`). A pane let go stops as before: status 1000, claim released.

## Fit and mirror

- Fit: after layout settles (120 ms), `session.own_block` (take), then `terminal.resize` to the
  largest grid that fits (`TerminalLayout.fitGrid`, at least 12×4), while the stream starts
  beside it. Backgrounding the app or switching to mirror calls `session.disown_block` at once,
  and leaving the pane does 10 s later (Parking, claim grace); the Mac then gets its size back. If another client resizes the pane, the host stops and offers "Resized elsewhere ·
  tap to fit here". Until then it shows the server's grid as mirror does. A pinch there fits the
  pane here too (Gestures).
- The software keyboard covers a fitted pane; it doesn't resize it. The grid stays the one that
  fits the pane with the keyboard down (`TerminalLayout.fitSize`, from the tab's canvas as
  measured with the keyboard down, `PaneLayout`), so a program on the main screen gets no
  resize when the keyboard shows or hides and has nothing to redraw. The engine view keeps the
  grid's height, the pane shows its top part, and the engine draws the rows shifted up so the
  last row with content sits above the key bar (`GhosttyScrollState`, "The cover"). The scroll
  view has that much more room at the bottom: dragging down brings the covered rows into view,
  then the scrollback, in one motion. Typing returns to the bottom. A view in the scrollback
  doesn't move when the keyboard shows or hides.
  - A view left among the covered rows stays there while nothing is written and while a finger
    or the scroll's momentum holds it. The next output takes it back to the pin, so a server's
    log and the cursor never stream on under the key bar (a slight drag, then letting go). A view
    in the scrollback stays where it is under output, as before.
  - Whether a view at the bottom follows is decided against the pin of the frame that applies
    the scroll, so a cover change in the same frame (the keyboard's top measured again, the emoji
    keyboard) can't leave the shift short of the pin.
  - On the alternate screen (an editor, a pager) the grid fits above the keyboard, as its rows
    can't be scrolled: one resize when the program enters or leaves that screen with the
    keyboard up, and one when the keyboard shows or hides while it is there.
  - The key bar alone (hardware keyboard) takes room from the layout and the grid fits above it.
  - A new width (a fold, a rotation, Split View) counts at once, also with the keyboard up: the
    canvas takes the new width and keeps the height it had with the keyboard down
    (`PaneLayout.restCanvas`). So the fold is one resize, to the new columns and the rows of the
    keyboard-down pane, and the keyboard going down afterwards sends none when the height
    matches. Before, the canvas kept the old width while the keyboard was up, every pane was
    left without a rest size, and the grid fitted what showed (a dozen rows on the folded Duo):
    the program redrew for a sliver, then again when the keyboard went down. Only a canvas never
    measured with the keyboard down leaves the grid fitting what shows.
  - Another client's size that comes after our resize's echo but before the claim's answer
    (the echo comes first in the stream) counts as "Resized elsewhere", as one after the
    answer does. Taken in silently, the claim would answer "ours" over a server grid wider than
    the pane, and every later layout found the claim in place and sent nothing: lines and the
    input line cut at the right edge until the width changed.
- Mirror: never claims or resizes. Shows the server's grid scaled to the view's width; drag pans.
  Users always get fit; mirror is only for the `-sizing mirror` launch argument.
- Fit really resizes panes on the Mac. Test it only in `zz-` sessions you created.

## Gestures

- Tap: focus the pane, clear a selection, raise the keyboard on the first tap. A tap on a link
  (an OSC 8 hyperlink or a web address in the text) opens it every time, also on the first tap
  and with the keyboard down; the keyboard stays as it was. On a focused pane a tap elsewhere
  moves the shell's cursor on its prompt (`TerminalTap.swift` has the order,
  `Ghostty/GhosttyTap.swift` the engine's part).
  In a program that tracks the mouse, a tap on a link opens it and the program gets no click:
  the phone's Cmd-click, as Mac terminals open links on Cmd-click in such programs. A tap
  anywhere else is the program's click. A program that wants clicks on its own URLs loses them;
  that is rare, and a long press still selects the text to copy.
  A tap that catches moving scrollback, or lands within 0.15 s of it stopping, only stops it: no
  keyboard, link, Paste menu or click (`TerminalScrollTouch`). Reading with flicks stays reading,
  and a link just scrolled into view opens on the next tap.
  A tapped link that can't open says why in a short notice (a malformed hyperlink, Safari
  refusing it, and every failure under Ports below); none fails silently.
- Vertical drag: scrolls the scrollback (a native scroll view). On the alternate screen or when
  the program tracks the mouse it sends wheel reports instead, and arrow keys on the alternate
  screen with mode 1007 and no tracking.
- Dragging into the scrollback while the software keyboard is up puts the keyboard away, as the
  key bar's hide key does: reading gets the whole pane. Nothing moves under the finger; the rows
  the keyboard covered come into view below. A tap brings the keyboard back.
- Jump to bottom: while the view is half a screen or more (at least 3 rows) into the scrollback,
  a small glass button with a down arrow shows in the pane's bottom trailing corner, and goes
  again within a row of the bottom (`JumpToBottomRule`). A tap returns to the newest line and
  nothing else: it doesn't bring the keyboard back or focus the pane. The arrow takes the
  cursor's color once output has arrived below. No button during a selection or a pinch, or
  while the program takes the drags (mouse tracking, the alternate screen).
- Horizontal swipe: next or previous pane, only when the drag is at least twice as sideways as up or
  down and doesn't catch moving scrollback; anything less scrolls. Swipe on the title bar: next or
  previous tab.
- Two-finger tap: zoom the pane (phone-only zoom, see `PhoneState`).
- Long press: select a word (haptic, loupe), drag to extend; on release copy (copy-on-select, with a
  shimmer and a confirming haptic), show handles to adjust with, and Copy / Paste / Select All.
  Double tap selects a word, triple tap a line. Mouse or trackpad drags select directly.
  Design and haptics: [selection.md](selection.md).
- Pinch: sets the text size in every state (`TerminalPinch`). The text scales under the fingers;
  on release the size is stored (`Prefs.fontSize`) and applied, and fit mode claims one new
  grid. On a pane resized elsewhere the pinch also fits it here, as the chip does. Mirror draws
  the server's grid at the new size, still scaled to the width. A pinch during a selection drag
  doesn't start. The canvas never zooms by pinch.
- Split borders on the unfolded Duo are draggable (`SplitGeometry`), with a detent at 50%. In
  book mode the border on the crease has no handle ([duo-layout.md](duo-layout.md), Book mode).
- A tab shows its splits as the Mac lays them out while every pane keeps 40×8 cells
  (`SplitGeometry.legible`); otherwise one pane shows at a time, with dots in the title bar and a
  sideways swipe on the terminal to move between panes.
- Resizing or toggling the sidebar changes the tab's frame once (on release, or after the slide),
  never per frame, so fit mode claims one new size ([duo-layout.md](duo-layout.md)).
- A width change (fold, unfold, rotation, resize) claims the new size and nothing else: the
  engine reflows its lines as the server reflows its own, so nothing is read again.
- `TerminalHostPool` keeps each pane's `TerminalHost` alive while a fold or unfold swaps the view
  tree. The new `PaneView` takes the host over, so the stream, screen and keyboard focus carry over.
  It also keeps the panes that left the screen last (Parking).

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
- **Held while offline.** Without a control connection nothing is sent; the queue waits. When
  `RexControl` is connected again it goes out, in order, once the stream has caught up and only
  if the screen it was typed at is still exact (The catch-up fence); otherwise it is dropped
  with the fence's notice.
- **Nothing leaves behind the fence.** The queue is not pumped while the fence is up.
- **Never sent twice.** What happens to a request that fails:
  - it never left this client (no connection, or the socket didn't take the message;
    `RexError.neverSent`): it stays first in the queue and is sent when the connection is back;
  - the server refused it (the pane closed): dropped;
  - it was sent and the connection broke before the answer: nobody can know whether the server
    ran it. Sending `rm x⏎` again could run it twice, which is worse than a lost keystroke the
    user can see and retype. It is dropped, with everything queued behind it (typed on the
    assumption that it had arrived), and the user gets a notice ("The connection dropped while
    sending. Check the pane before typing that again.").
- **`stop()` and `park()` drop the queue.** A pane that was closed or left must not receive old
  keys when it is opened again. `restart()` leaves it to the fence, whose new snapshot drops it.
- **UTF-8 only.** `data` is a JSON string, so bytes that aren't valid UTF-8 can't be typed.
  `send` drops such a call whole and returns false, rather than type U+FFFD in their place. In
  practice that is a legacy X10 mouse report beyond column 95, where the column is one raw byte
  of 128 or more. The mouse encoder uses the format the program asked for, and programs that
  track the mouse on wide screens ask for SGR (mode 1006) or UTF-8 (1005), both plain UTF-8.

Around that:

- Paste goes through the engine's `pasteText`, so programs that asked for bracketed paste get it.
- Key bar (`KeyBar`): keys from the layout picked in Settings (`KeyBarLayout`); ctrl/alt/cmd tap for one key, double-tap to lock; the
  "arrows" key is a trackpad. Bytes are in `KeyBar.bytes(for:appCursor:)`. Keys send on release, and
  a sideways drag scrolls the bar and cancels the key under it.
- Key bar trackpad (✥): it takes a drag as the space bar's trackpad does on the iOS keyboard
  (`TrackpadEngage`). It engages after a still hold of 0.3 s (within 10 pt), or at once when the
  first 10 pt of travel is mostly up or down (more than 1.5 times as far as sideways). Engaging
  plays the tick its steps play and draws its cursor-colored ring; one arrow per 14 pt across or
  18 pt up or down, counted from where the finger rested at the hold, or from the touch-down for a
  vertical drag. A quick sideways swipe that starts on it scrolls the bar and sends nothing: an
  immediate sideways drag no longer moves the cursor, so hold first. A tap sends nothing, as
  before.
- Key bar repeat: arrows and PgUp/PgDn repeat while held, and stop once the finger moves more
  than 10 pt from where it went down or off the key (`RepeatSlop`). The release then sends what a
  tap does if nothing repeated yet.
- Keyboard room: the root keeps clear of the keyboard's last reported frame
  ([duo-layout.md](duo-layout.md), Keyboard room) and, while the keyboard is up, of the key bar's
  own top. The keyboard is sometimes reported last without its accessory, after an input-mode
  switch (ES/EN, emoji) or when a sheet, menu or the palette hands it back, and the pane then ran
  one key bar too tall, the line being typed behind the bar. So the bar reports itself when it
  enters or leaves a window, is shown or hidden, or moves by a point or more (`KeyBar.frameChanged`),
  and `KeyboardInsetReader` reads its frame live and pads by the larger of the two
  (`KeyboardInset.padding(…keyBar:…)`). Only while the keyboard is shown or showing, and only a bar
  in a window of this scene that the keyboard's top reaches and that sits above the root's bottom:
  hiding, the palette's or find's keyboard (no key bar), a floating keyboard and a bar beside the
  root (Split View, the Duo's other side) leave the keyboard's frame in charge. The padding is
  measured again 0.3 s after the keyboard's last frame change and on each input-mode change,
  without animation and only if it changed, and the palette's hold (`PadHold`) ends with a fresh
  measure rather than the value it kept.
- Key bar Return: pinned in every layout (`KeyBarLayout.pinned`), at the end of the keys' capsule
  past a hairline, next to the hide key (or, beside the Duo's vertical bar, 6 pt short of the
  bar's column, which has Hide Keyboard; [duo-layout.md](duo-layout.md), Key bar), so it never
  scrolls away. A tap sends what the bar's
  Enter always sent: CR, ESC CR with alt, CR with ctrl (as Ctrl-M), and with cmd the
  `cmd+enter` binding. It never repeats. Held for half a second (`KeyCap.holdDelay`, with a
  medium haptic) it sends Shift-Return through the engine's encoder, as a hardware Shift-Return:
  `CSI 27;2;13~`, or `CSI 13;2u` under the Kitty protocol, which agents such as Claude Code take
  as a new line without sending; with cmd it runs `shift+cmd+enter`. VoiceOver offers it as the
  "Shift-Return" action. While an input method composes, Return (tap or hold) types the
  composition as it stands and sends nothing else, as the system keyboard's return does: composed
  text hasn't reached the program, and sending Return would drop it. Under the agent board no bar
  key sends.
- Key bar cmd: ⌘ for the next key, as on a Mac keyboard. That key is never typed. A bar key
  (`KeyInput.press(barKey:mods:)`) or a key typed on the system keyboard (the engine view's
  `commandModifier` hands it to `commandKeyHook`; `KeyInput.press(typing:mods:)`) becomes the
  press a hardware keyboard reports for it, with ⌘, the bar's ctrl and alt, and shift where the
  US key needs it (`D`, `?`, `|`). `TerminalHost.keyBarShortcut` runs it through the same lookup
  as a hardware press (`KeymapStore.resolve(press:)`) and the same `perform`, so app commands,
  `pane.send_key`, `perform(action:)` and `forward(key:)` behave as they do for ⌘ on a keyboard.
  A chord nothing is bound to sends nothing and plays an error haptic. A held arrow or a
  trackpad drag runs the binding once, then again only if it repeats on a hardware keyboard.
- Hardware keyboard: the engine view's `keyHook` sees each press first. `KeymapStore` matches it
  against Rex's keymap (`KeyChord` spellings like `shift+cmd+d` or `cmd+[Digit1]`), and
  `AppAction` turns the binding into an app command, a key to send (`KeyInput.bytes`), a server
  action, or a forwarded key. Unbound keys go to the engine's key encoder.
- A press is matched in tiers (`KeyInput.chordTiers`): what the key types and its position, then
  the character typed with shift (on a Spanish or German keyboard `/` is shift+7, so `cmd+/`
  arrives as shift+cmd+7), then the key's US name when what it types can't be spelled (`ñ`). A
  later tier never takes a key from a binding that names an earlier one.
- Option on a hardware keyboard is Alt (Meta) unless the layout needs it. If Option makes a
  printable ASCII character other than the key's own (`@ [ ] { } | \ ~ #`), that character is
  typed. Otherwise, on an English layout Option is always Alt, dead keys included. On other
  layouts, a letter or digit key is Alt unless Option makes it a dead key, which composes (German
  and French Option+N, Space gives `~`); any other key types the layout's character. Option+Space,
  Option+Return, Option+Delete and Control+Option are always Alt. The layout's language comes
  from the keyboard's input mode.
- Who has the keyboard (`KeyboardFocusPolicy`): with a hardware keyboard the active pane's
  terminal is first responder, as on a Mac, and takes it back when it comes free (pane switch,
  fold, a text field done, the app active again). Never from a text field, under a sheet, or
  after the key bar's hide key. Without a hardware keyboard a pane only keeps what it had.
- The keymap's app commands are also menu shortcuts (`AppShortcutCommands`), so ⌘/ and the rest
  work when no terminal is first responder (no tab open, keyboard put away). The menu replaces
  the system's Settings item, whose ⌘, would open the Settings app before the keymap sees it.

## Find

Find in Scrollback, as on the Rex Mac app: type a needle, every match on screen is tinted, the
current one stands out, and Next and Previous step through the pane's screen and history.

- **Where it searches.** The pane's own terminal, with libghostty-vt's search
  (`GhosttyCore+Find.swift`; [ghostty-api-notes.md](ghostty-api-notes.md), Search). No server call:
  the phone holds the newest 10,000 lines, and a match older than that has no row to show. Matching
  is the library's: byte for byte, with ASCII letters folded (no regex, no case option, as on the
  Mac). The needle is the field's first line, composed (NFC), at most 1 KB (`FindQuery`). With the
  history at its cap and nothing found the count says "No Results in recent history".
- **Opening.** ⌘F (the keymap's `client.find.open`), "Find…" in the pane menu's section above
  Close (its key text comes from the keymap, `KeyLabel`, and hides when nothing runs it), "Find
  Selection" in the edit menu (a one-row selection of at most 200 bytes), or another client
  performing `client.find.open`. The field starts with the last needle used in any pane, selected.
- **Keys.** Return and ⌘G: next (older, `chevron.up`); ⇧Return and ⇧⌘G: previous (newer,
  `chevron.down`). With find closed ⌘G and ⇧⌘G do nothing, as before. Escape with text gives the
  keyboard back to the terminal; with none it closes. Return and Escape belong to an input method
  while it composes. While the field edits, only app commands and the find keys stay with the pane
  (an allowlist, `FindKeys`): ⌘V, ⌘A, arrows and Delete with any modifier edit the field. ⌘W
  closes the pane, as on the Mac.
- **Two bars, one model.** `FindAccessoryBar` sits in the keyboard's accessory slot (the key bar's
  height function, so the keyboard keeps its frame) and holds the keyboard while the system
  keyboard or the key bar shows. `FindOverlayBar` floats in the pane (bottom; top on the alternate
  screen, below the status chip) whenever the field isn't in the accessory slot, and holds the
  keyboard when the terminal held it quietly (after the hide key, with a hardware keyboard). No
  view moves between the keyboard's window and the pane.
- **The hand-over** (spike S1, checked on the Duo). Terminal to field: the terminal shows the find
  bar in its accessory slot (`reloadInputViews`), and once the bar is in the keyboard's window its
  field becomes first responder with the terminal's input views; the key bar is the terminal's
  accessory again at once, without a reload. Field to terminal: the terminal takes the keyboard
  back as panes do from each other; one more reload of the same views a turn later puts back the
  2 pt the window is otherwise laid out off by. With the keyboard down (no hardware keyboard) the
  keyboard rises as a tap's does. `FindHandover.shipped` is the one switch to the fallback (the
  floating field with an empty accessory of the key bar's height, `FindSpacer`).
- **No resize.** The keyboard's frame is the same before and after every hand-over (a rise and a
  fall when it was down). Fit mode's grid while the field holds the keyboard on a rising
  keyboard is the newest one asked for (`FitClaim.wanted`, the *fit hold*), taken before the
  keyboard moves and released at once when the field stops editing, find closes, the font, width
  or sizing changes, or the pane is lost. `FitHoldDeferral` can make the release wait while
  another surface holds the layout; it is built for goto's palette and unused until goto lands. A layout that finds the claimed size while another request settles asks for the
  claimed size again, which supersedes it.
- **Tints.** Every match: the theme's yellow at 30%. The current one: opaque bright yellow, its
  text black or white by contrast (at least 4.5:1 on every theme), on its first four rows. Drawn
  between the backgrounds and the cursor, so a block cursor and underlines stay on top
  ([ghostty-engine.md](ghostty-engine.md), From bytes to a frame).
- **Scrolling.** A step scrolls only when the match isn't in view, its first row a third of the
  way down (`.reveal`). The bottom bar's height counts like the keyboard's cover for the last rows
  (`setFindInset`) but never as reading: a drag under it doesn't hide the keyboard. The
  jump-to-bottom button sits above it. On the alternate screen under the hold the keyboard hides
  the program's bottom rows, and a match under it lifts the grid until the next step.
- **Focus.** The pane's own field holding the keyboard counts as the pane holding it: no reclaim
  takes it away. Another pane becoming active takes it (the bar stays open there). A sheet, a
  menu or the agent board takes it as from the terminal and gives it back. A fold gives the
  floating field its keyboard back.
- **Compatibility.** Local only: no method, event or capability. The keys and the label come from
  each pane's server keymap, and from `KeyDefaults` (⌘F, ⌘G, ⇧⌘G) where `client.keymap` fails
  (any server revision). Copy-mode actions (`pane.copy_mode.*`) stay unbound on the phone.

## Files

A pane takes files as the Rex Mac app's terminal takes a dropped file: they are copied to the
pane's computer and the server types their paths into the pane as if pasted. Enter is never sent,
so it works in a shell and in an agent alike. The reverse, Open, brings a file the terminal names
to the phone, and the file browser lists the folders of the pane's computer. The wire rules are
in [rex-protocol.md](rex-protocol.md), Folders and Files.

- **Sending.** The key bar's attach key (paperclip) is pinned before Return in every layout, so it
  never scrolls out of sight. A tap opens a menu titled with where the
  files go: the agent working in the pane (OSC 7501), else the pane's computer. It offers Paste
  Image or Paste File (when the clipboard has one), Photos, Camera, Files, and Send Original.
  The same rows are under Attach in the pane menu, right after Share (subtitle "or 📎 on the
  key bar"), for a pane whose keyboard is down (`AttachMenuItem`, built from
  `PaneFiles.sections`). Close Pane and Close Tab stay last.
  Paste, the paste key, ⌘V and the edit menu's Paste paste text whenever the clipboard has text;
  they send an image or files only from a clipboard with no text at all (`ClipboardChoice`).
  Beside Paste the edit menu offers Paste Image (Paste File for copied files) whenever the
  clipboard has one and the host takes uploads, even with text; deciding checks the clipboard's
  types only, and its content is read when the row is picked. The palette finds Insert Photo…,
  Insert File…, Browse Files… and Insert Path… by image, photo, picture, screenshot, attach,
  upload, file and send.
  Images, movies and files dragged in from another app can be dropped on a pane (`PaneDrop`); a
  drag of text or a link is refused, never sent as a `.txt`, and the app's own drags, such as a
  selection, are left alone. Nothing is sent without one of these actions.
- **One batch.** The files of one action go as one `upload_begin` batch, a single file included,
  one file at a time, each with a ticket asked for just before its connection (`FileUploader`,
  RexKit). The server types all the paths together, in order, once the last file has arrived,
  escaped with backslashes. A notice shows progress with Cancel, then the result. A connection
  lost before the last file went out whole sends the batch again from the start under a new ID,
  at most twice: the server deleted the aborted batch's files and can't resume an upload. Once
  the last file's end has gone out the server may type at any moment, so nothing is sent again
  and Cancel no longer applies; a lost confirmation then says to check the pane.
- **Pacing** (`UploadPacer`, RexKit). A socket's send returns once the system has the bytes, so an
  unpaced file fills the phone's uplink queue at once, and the control connection's pings, calls
  and typed keys wait behind all of it (a 7.5 MB photo on a 2 Mbit/s uplink: 10 s), past every
  wake ping's 2.5 s. So each message waits its turn at a rate set from the control connection's
  ping round trip, as LEDBAT does: the queue the upload adds is kept near 100 ms, and messages
  shrink to about 100 ms of the rate (at least 8 KiB). On a fast network the rate climbs past
  what the link takes within a few round trips. On top of the rate, a window: at most 256 KiB
  handed to the socket beyond what an answered control ping vouches for, so the network never
  gets a burst. On an iPhone a burst queues as packets inside the Tailscale extension, which iOS
  kills past about 50 MB, and the tunnel is gone for 30 to 60 s (tailscale/tailscale#17967). The
  upload's own socket can't confirm bytes: Rex answers a ping there only once the file has ended.
  No control connection, or no answer in 5 s, leaves the rate alone in charge: never a stall.
- **Cancel** cuts off the file on its way, and the server deletes the batch's earlier files and
  types nothing. Between files, when the server may hold finished files and nothing is on its
  way, the next file is reserved and cut off at once to the same effect (`FileUploader.abort`).
- **Where files land.** `<state>/rex/uploads/<server pid>-<run>/<block>/<ref>/<name>`: on Linux
  `~/.local/state/rex/uploads/…`, on macOS `~/Library/Application Support/rex/uploads/…`. Files
  are mode 0600 and owned by the user, so the shell and any agent in the pane can read them.
  Closing the pane deletes its folder.
- **Names** (`UploadName`). One path component, NFC, at most 200 bytes with the extension kept,
  without control characters, bidi embeddings, overrides and isolates (U+202A–202E,
  U+2066–2069) or the zero-width space. The zero-width joiner and non-joiner stay (emoji,
  Persian). A photo without a name gets `Photo 2026-11-17 17.31.jpg`, a pasted image
  `Pasted Image …`.
- **Photos** (`ImagePrep`). HEIC, HEIF and every other still format go as JPEG at 0.85 (PNG for a
  PNG or an image with transparency), anything longer than 2000 px is scaled down through ImageIO
  thumbnails with its EXIF orientation applied, and location and other metadata are left out. A
  small upright JPEG or PNG is copied without being decoded. It fails closed: each copy is checked
  for GPS, IPTC and XMP place names; one that can't be stripped is drawn again, and one that can't
  be drawn either is sent only after "Couldn't remove location. Send original?". Send Original
  sends the bytes untouched; the choice lasts until the app quits. Live Photos send the still;
  videos, moving GIFs and files picked in Files go as they are, as the menu says.
- **Limits.** The server takes files up to 100 MiB (`too_large`); a larger one is refused before
  anything is sent. On an expensive network (cellular, a hotspot) a send over 25 MB asks first; a
  second send meanwhile is turned away with a notice. A send keeps running briefly in the
  background; cut off, its notice offers Retry.
- **Typing during a send.** The server types the paths itself, outside the input queue. Keys typed
  while a batch is on its way reach the pane first and the paths land after them. The app never
  sends keys for the paths; the progress notice is the cue to wait.
- **Support.** Each of `upload_begin`, `download_begin` and `list_dir` is known per host, on its
  own (`ServerConnection.fileSupport`; [rex-protocol.md](rex-protocol.md), Folders): two panes
  of one tab can differ when one is on a remote host with an older Rex. The attach key shows
  where the pane's host takes uploads or lists folders. Its sending rows, Paste Image, drops and
  the two insert keys need `upload_begin`; Open, Preview, Share and Save need `download_begin`;
  the browser and Insert Path need `list_dir`. Without a method its rows are absent and nothing
  says so; a host with none shows no attach key.
- **Open.** When a small selection (at most 4 rows and about 1 KB, all in view, checked before its
  text is read) reads as a path (`PathGuess`: absolute, `~`, relative, or a name with an
  extension; shell escapes and quotes undone, `:line:column` dropped, a wrapped path joined), the
  edit menu offers Open. It downloads the file with `download_begin` (relative to the foreground
  process's directory) into the app's temporary folder, with progress in 1% steps and Cancel, up
  to 100 MB, writing off the main thread, and shows it in Quick Look, which offers Share and Save
  to Files. The copy is deleted when Quick Look goes; none is kept for later, so nothing is left
  when the pane closes or the app goes to the background. Not found, a folder, a device and an
  unreadable file each get a plain message.
- **Browse.** "Browse Files…" in the attach menu, under the sending rows, and in the palette's
  commands (as are Insert Path…, Insert File… and Insert Photo…; [goto.md](goto.md)), opens a sheet over
  the pane with the folder the pane's program is in (`PaneBrowser`, `BrowserModel`): folders
  first, names as Finder orders them, hidden files out until "Show Hidden Files" in the title's
  menu (⇧⌘.), which also has the parent folders, Home and Copy Path. A tap opens a folder or
  previews a file in Quick Look, by the same download as Open; a file with no extension that
  reads as text, up to 1 MB, is shown as text (`TextHint`). A long press offers Preview, Insert
  Path, Copy Path, Share… and Save to Files…, which keep the file's own name. The filter matches
  anywhere in a name; a filter that starts with `/` or `~` is a path, and Return goes there. A
  folder with more than 2,000 entries says "Showing the first N. Search to find others.", and
  its filter also asks the server for names that start with the text, 250 ms after the last
  key. Each folder keeps its listing while the sheet is up; pulling down lists it again, and so
  does coming back from the background. Selecting a folder's path in the terminal and choosing
  Open opens the browser there. With a hardware keyboard: ↑ ↓ move, Return opens, Space
  previews, ⌘↑ goes up, ⌘↓ opens, Esc closes.
- **Off the main thread.** A listing is read out of its reply, sorted and filtered on other
  threads, and the newest request wins; the main thread only swaps the rows in. Rows are a lazy
  stack identified by position, so a filter keystroke updates the rows on screen in place.
- **What the browser says.** One line and at most one button: an empty folder, "Only hidden
  files here." (Show Hidden Files), a folder Rex may not read (on macOS, under Desktop, Documents
  or Downloads, with where to allow it) or that is gone (Go Up), and a lost connection (Retry;
  it lists again by itself when the connection is back). If a reconnect lands on a server
  without `list_dir`, or the pane closes, the listing on screen stays to read with a line above
  it, nothing in it can be opened or inserted, and nothing is sent.
- **Insert Path.** "Insert Path…" opens the same browser in insert mode: a tap on a file writes
  its path into the pane and closes the sheet, the bottom button inserts the folder on screen,
  and "Recent" lists the last 8 paths inserted on that server and host. What is written, and
  whether, is decided by `PathInsert` from the foreground program's name and bracketed paste
  only, never from a title, a status record or a reported directory:
  - `ssh`, `mosh`, `tmux`, `screen`, a container tool and the like in the foreground: Insert
    isn't offered, and the browser says whose files it shows (`ProcessNames.remoteWrappers`).
  - A shell (`sh bash zsh fish dash ksh mksh`): the path escaped for a shell (`ShellEscape`,
    RexKit: a backslash before each character a shell reads as syntax, every `~` but a leading
    `~/`, and a leading `=`). A macOS test reads the escaped names back through zsh (plain,
    `extendedglob`, `equals`, `magicequalsubst`), bash, bash `--posix`, dash, ksh and sh, and
    through fish where it is installed.
  - An agent by its program name, or any program that asked for bracketed paste: the path as
    it is.
  - Anything else: "htop isn't taking text. Insert anyway?" first, then the path as it is.
  - The path is relative to the program's folder when under it (`./-x` for a name that starts
    with a dash), `~/…` under home, absolute otherwise, followed by a space. Enter is never
    sent. A name with a control character or a direction mark isn't inserted. Scalars go out as
    listed, with no normalization. It goes through `TerminalHost.paste`, so it is bracketed
    where the program asked. A Windows server has Browse only.
  - Known limits: a cursor inside an open quote gets the escaped text literally; under `sudo
    -s`, `~/` means root's home.
- **Keys.** The Mac's `pane.go_to_directory` (browse), `pane.insert_path`, `pane.insert_file`
  (the Files picker) and `pane.insert_photo` (the Photos picker, honoring Send Original) are
  declared with the Mac's titles and no default key, so a key bound in init.lua does on the
  phone what it does on the Mac, where the pane's host has the method; elsewhere the key does
  nothing. They are pane actions (`AppAction.files`, `FilesCommand`): they run while a terminal
  has the keyboard, and not from the find field.
- **The keyboard** goes back, when the browser closes, to whoever held it: the terminal shown
  or quiet, nobody, or the pane's find field (`KeyboardRecord`). With a hardware keyboard the
  sheet makes the key bar leave, as the Settings sheet does.
- **Temporary copies** live in the app's `tmp/Outgoing` and `tmp/Incoming`; a finished send or a
  closed preview removes its own, and launch removes what is left.
- `-filesTest` drives all of this in the simulator, which can't tap through a picker
  ([debug-args.md](debug-args.md)). Debug builds log the SHA-256 of each file sent (`FILES_SENT`)
  and opened (`FILES_OPENED`), to check against the computer's copy.

## Share

A pane's output goes to the share sheet, as text or as a styled HTML file with the theme's
colors (`Features/Files/ShareOutput.swift`). Nothing new shows on a pane, and nothing runs until a
Share item is chosen.

- **Where.** "Share…" is last in the selection's edit menu, after Select All, on every non-empty
  selection: the selection as plain text, as Copy takes it. "Share ▸" sits in the pane menu after
  Find…, one submenu of two titled sections, Plain and Styled, each with Screen and All Output.
  Screen is the viewport as drawn, scrolled rows and rows under the keyboard included, each row
  its own line. All Output is the screen and scrollback as the server holds it (the active screen
  for a full-screen program).
- **Sources.** The selection and the screen come from the pane's own terminal: the libghostty-vt
  formatter (`GhosttyCore.format(scope:emit:)`), in one `termLock` section, so only that pane's
  parsing waits. The selection is formatted when Share… is tapped, as Copy takes it, so a tap
  that clears it a moment later changes nothing; the screen is formatted on a detached task. They
  work offline and on any server. All Output asks the server:
  `terminal.format` (`text` with `trim` and `unwrap`, or `html`) with `max_bytes`, then
  `blob_read` with the same `id` until `eof` or `total` (rex-protocol.md, Methods used).
- **Chunks** (`ChunkSizer`). The first request is 64 KiB; each later one is sized to take about
  100 ms at the throughput the previous one had, between 64 and 256 KiB. One request is out at a
  time, and before each the reader waits while any pane on that server has typed input on its
  way (`TerminalStream.hasPendingInput`, gathered in `RexControl.inputActivity`; observed, not
  polled). A stream leaves that count when it stops or goes. The wait also ends when the
  connection drops, and the read checks the connection before and after it, so a drop with
  input queued ends the read at once. A keystroke's reply waits behind at most one chunk: about
  100 ms, up to about 250 ms at 2 Mbps. The reconnect `readScreen` (900 KB chunks) is unchanged.
- **Retry and connections.** A `not_found` mid-read (a concurrent `format` evicted the id, or it
  expired) starts the read over once with a new `format`. A second one, a lost connection, or a
  new connection (`connectionSerial`; the id belongs to the old one) ends the read, deletes its
  folder and shows "Couldn't read the output." with Retry, or "The pane has closed." when the
  pane is gone. `method_not_found` ends it without Retry and hides All Output on that
  connection.
- **Styled.** The document (`ShareHTML`) puts a Content Security Policy right after
  `<meta charset>` (`default-src 'none'; style-src 'unsafe-inline'; form-action 'none';
  base-uri 'none'`), the theme's 256 colors as `--vt-palette-N` custom properties marked
  `!important` (server HTML has no palette, and the local formatter's own palette block loses to
  them), the theme's background and foreground over the wrapper's inline defaults, and Menlo
  (`ui-monospace`) over the wrapper's inline `monospace`, which iOS draws in Courier. Colors are
  `#rrggbb` from components clamped to 0...1. RGB colors programs set stay as they are; a cell the
  server writes with an explicit hex of the computer's default colors keeps it. Inverse video
  comes as `filter: invert(100%)` on a run with no background, which would flip only the text to
  a color near the page's; such a run gets the theme's background, so both flip.
- **Links** (`LinkSanitizer`). Each `href` is decoded once as a browser does, tabs and line breaks
  are removed, C0 controls and spaces trimmed at its ends, and it is kept only if it starts with
  `http:`, `https:` or `mailto:` in any case; otherwise the attribute goes and the text stays. The
  formatter escapes `<` and `>` in text and attributes, so a chunk holds back from its last `<`
  that has no `>` and a split tag comes out whole. Non-ASCII URLs arrive as Latin-1 byte entities
  and stay so.
- **Forms and files.** Plain text up to 256 KiB goes as text; above that, and every styled share,
  as a file `<Tab title> <yyyy-MM-dd HH.mm>.txt|html` in its own folder under `tmp/Shared`,
  deleted when the sheet goes and swept at launch. Every file is written off the main thread
  (`ShareFile`), styled ones through the link cleaning.
- **Limits.** All Output text over 32 MiB keeps the newest 32 MiB (`TextCap`): it reads from
  `total - 32 MiB`, drops the U+FFFD the server sends for each byte of a character the offset
  cut through, starts after the first line break (or at the first whole character) and begins
  with `[Earlier output not included: N MB]`. Styled output over 8 MiB is refused from the first
  reply's `total`, before reading on: "Too much output to share styled." offers Share Plain.
  Without a `total` in the first reply, the first `blob_read`'s total, else the bytes read so
  far, decide. On an expensive network a read over 25 MB asks first.
- **Progress** (`Notice` job lane). A read of more than one chunk shows "Reading the output · N%"
  with Cancel in the notice's job lane: a plain notice that comes meanwhile shows its full time,
  then the progress and Cancel come back, and a transfer's progress (`showProgress`) never
  replaces a plain notice that is up. One job at a time: a second share waits until the first
  ends or is cancelled. Cancel deletes the folder.
- **In the background.** An All Output read runs inside a `BackgroundTask`. When its time runs out
  the read stops, the folder is deleted, the lane clears and no sheet follows; nothing resumes on
  return. A read that finishes in the background keeps its file and presents the sheet on return
  if the pane still exists.
- **Offline.** Selection and Screen work. All Output says "Needs a connection to the computer."
  and its rows stay, so the menu keeps its shape. Empty output or selection: "Nothing to share."
- **The sheet** comes from the topmost controller, always with a popover source (an iPad and
  `-simulateDuo` make it a popover): the edit menu's target for the selection, the pane's
  top-trailing corner under the title bar's menu, or the middle of the window's edge facing away
  from the system's vertical bar (`ShareAnchor`). It carries the tab's title as subject and in its
  header. The selection is formatted first and cleared once the sheet is up.
- **Compatibility.** Selection and Screen need no server method. All Output needs `format` and
  `blob_read` (both at revision 13 and below); its rows hide only when the pane's creator on its
  host is known to lack one, or a read on this connection found one missing.

## Arrange

The Mac's pane commands, in the pane menu and on the keymap's keys (`Features/Tab/PaneArrange.swift`,
`PaneMenuItems.swift`, `State/ServerConnection+Panes.swift`). Nothing new shows on a pane.

- **Where.** "Arrange ▸" sits in the pane menu's section above Close, after Find… and Share ▸,
  on a tab with two or more panes, or with a floating window to minimize or show again (a
  one-pane tab too). One submenu, its groups titled inline sections: Swap With (the other
  panes), Move to Tab (the session's other tabs, then New Tab), Balance Splits, Close Other
  Panes… in a destructive section of its own, then Floating Windows (Floating windows, below).
  No shortcut text, no `.keyboardShortcut`: the keymap stays the only key dispatch.
- **Names.** A pane is named by its label when someone gave it one (on the Mac, from the CLI or a
  layout; not `shell` or `Block 89abcdef`), else its agent, else its program, else "Pane N" by
  its place (`PaneName.menu`). Never its title, which an agent's spinner changes ten times a
  second: the names' parts live in their own per-block table (`ServerConnection.paneNames`),
  written only when the agent or the program changes, and only `PaneMenuItems` reads them, so a
  spinning title rebuilds neither the menu nor the tab screen. Two panes of the same name also
  say "Pane N". A tab is its own label, else "Tab N", with the name of the pane a moved pane
  goes beside. Labels never become titles (Rename Pane isn't in v1).
- **Which panes.** The tiled panes in reading order, then the floating windows' panes, front
  first, the minimized ones last. Every such list and count reads `PaneScope.arrangeable(window:)`,
  so with no floats it is the tiled panes as before.
- **Swap With** is `session.swap_blocks`. The pane on screen stays the one shown; with one pane
  at a time only the dots move. A minimized float's pane isn't listed: the pane swapped in would
  vanish with it.
- **Move to Tab** is `session.move_block` beside the target tab's focused tiled pane (else its
  first), along that pane's longer side, so a pane doesn't land in a floating layer while the tab
  has a tiled one; a tab with only floats takes it beside its focused (else front) float
  (`MoveAnchor`). When the call returns the session's view is read at once (`reloadView`, no
  80 ms wait) and the target tab opens in the same update as the layout that holds the pane, so
  the pane's terminal, stream and fit claim carry over (well inside `scheduleStop`'s 0.5 s, before
  the pane would park). If
  no view shows it there within 2 s the tab stays; if this tab is gone too, a notice says
  "Moved the pane to <tab>." with Open. A full target: "That tab can't take another pane."
- **Move to New Tab** (hidden for a tab's only pane): `session.new_window` with `focus: false`
  and no label, so the new tab's title follows its pane; then, in one turn and in order
  (`RexControl.callInOrder`), `move_block` beside the placeholder, `block.close` of the
  placeholder, and `move_window` right after this tab (left out from the last tab). A failed move
  is rolled back by the close (it empties the new tab), and the place call's `not_found` is
  expected; only the move's error shows. A suspend between the two steps leaves a tab with a
  fresh shell, visible and harmless. Nothing is ever sent again after a reconnect.
- **Balance Splits** gives each pane in a row or column of splits the same way the same share
  (`SplitBalance`: a split's weight is the sum of its sides' when they split the same way, else
  1), clamped to 0.05–0.95. Every changed split goes at once (`resize_pane` isn't ordered and
  sets one split outright), then one view read and at most one notice: each pane sees one layout
  change and sends one `terminal.resize`. Disabled when every split is within 0.005 of even.
- **Close Other Panes…** always asks: "Close 3 other panes?", adding "The agents running there
  stop, on the Mac too." when one runs. The panes and the agent check are taken at the tap; the
  dialog closes exactly those, in order in one turn, and a pane that is gone already is fine.
- **Keys** (the Mac's action names and titles): `pane.balance`, `pane.close_others`,
  `pane.move_to_tab` (a list of the tabs), `pane.move_to_new_tab`, `client.tab.move.backward` and
  `.forward` (the tab one place along). No default keys. `pane.rename` and `pane.move.<dir>`
  stay unbound and fall through. Where a command doesn't apply (one pane, the last tab) the key
  bumps.
- **Compatibility.** One check, `PaneArrange.isAvailable`, for the menu, the keys and the
  shortcut list: the connection's revision is 13 or later (every method is there from 13), and
  no call on this connection found the command's method missing (`method_not_found`). A missing
  method hides only the commands that use it, at once; the tap that found it shows the usual
  failure notice. Below 13 nothing shows, keys fall through and the pane menu is as before. An
  open menu is a snapshot: each item checks again at the tap and only bumps if the server can't.

## Floating windows

A tab's floating layers (Rex's floating panes, "floating windows" in the Mac's menus) are drawn
above its tiled panes where the Mac places them. View-only: the phone raises, focuses, minimizes
and shows them again, and never moves or resizes one (`Features/Tab/TabPresentation.swift`,
`FloatLayout.swift`, `State/ServerConnection+Floats.swift`).

- **No float, no change.** Only a tab with a floating window on screen has a `TabPresentation`.
  Every other tab, one whose floats are all minimized included, runs the screen's split-or-page
  logic over its tiled panes as before, so it is drawn exactly as before.
- **One decision per body.** `TabPresentation.decide` is read by the canvas, the floats, the
  dots, the Waiting pill and Zoom. Book mode's sidebar collapse still asks about the tiled
  splits alone, with the sidebar collapsed: beside the sidebar they may show as pages under a
  float, and the float must not keep the sidebar open. Zoom (the server's or the phone's) and narrow
  windows give pages: one pane at a time, the tiled panes then the floats' panes front first,
  minimized ones left out, with dots and swipes as any tab. A wide window draws floating windows
  when the tiled splits are legible and every float can be placed; else pages.
- **Where a float is drawn** (`FloatLayout.place`). Rex's rects are window fractions; they map to
  the area the splits use (the canvas inset by 3 pt). A layer grows as one unit around its
  center until each of its panes keeps 40 × 8 cells, then stays inside the area. Across a
  vertical crease (`CreaseSettle`, book mode or not) it moves onto the page that holds its
  center, narrowed to it if it must be; illegible there, the tab shows pages. The tiled layer
  under it is laid out exactly as before, a single pane across the fold included. A float big
  enough is drawn at the Mac's own rect.
- **Look.** Radius 8 and the split panes' stroke (1 pt, 1.5 pt on the active pane), over a
  backing of the terminal's color with one soft shadow (radius 12, y 4, black at 25 %, 35 % in
  Dark Mode) that takes no touches and never sits on the Metal view. No title strip, no buttons.
  A single tiled pane under floats keeps its own 6 pt inset and radius 10. With no tiled pane
  left, the floats sit on the terminal's background.
- **View tree.** The floats are an overlay beside the tiled canvas, so one coming or going never
  rebuilds the panes below; panes keep their hosts by block, so a raise or a moved rect rebuilds
  nothing.
- **Taps** (`FloatTap`). A tap, long press, two-finger tap or pointer drag on a float makes its
  pane active. A float behind another is raised: `set_layer_state` with `focus`, then
  `focus_block` for the tapped pane when the layer holds several, in one turn. It shows in front
  at once and holds there until the server's view agrees, at most 1 s, on that connection only.
  A front float only takes focus; a front, focused one sends nothing. Without `set_layer_state` a
  tap focuses as a tiled pane does. A raise that fails says nothing.
- **Active pane** (`ActivePane`). Never one in a float that isn't drawn (minimized on the Mac,
  say): the next pane on screen takes the keyboard instead.
- **Floating Windows**, in Arrange: Minimize (the active pane's float; hidden when it holds the
  tab's last panes on screen, which the server refuses) and each minimized float by its first
  pane's name, which shows it again in front (`set_layer_state` normal with `focus`). Keys:
  `pane.minimize_floating` and `pane.minimize_all_floating` ("Minimize Floating Window(s)", no
  default keys). Minimize All sends every drawn float's minimize in order in one turn, keeping
  the front one when no tiled pane is left; a refusal shows one notice.
- **Waiting agents.** The pill and the toasts count a drawn float as on screen, and a minimized
  float or a page a swipe away as not. Jumping to an agent in a minimized float shows the float
  again first.
- **Fit.** A float claims the grid of the frame it is drawn at (grown or narrowed), as a split
  pane does; one no longer drawn parks after 0.5 s (`scheduleStop`) and lets its claim go 10 s
  after it left (Parking).
- **Compatibility.** Drawing is data-driven: no `layers`, a null `layer_id` (an ID from the
  layer's first block, stable across raises) and an unknown kind (floating) or state (normal)
  all draw; a float without usable bounds is skipped. Minimize, the rows, the keys and the raise
  follow `PaneArrange.isAvailable` (revision 13 or later, and `set_layer_state` not found missing
  on this connection); without them floats still draw.

## Ports

A program in a local pane that listens on a TCP port (`npm run dev` on `localhost:5173`) opens on
the phone, in Safari's view inside the app, through a Rex dial tunnel. Servers bound to
127.0.0.1 only work too. No port opens on the computer, and the phone listens on its own
loopback only while the page is up. Nothing shows on a pane. The sidebar lists every such port
of a machine in its Ports group, so nobody scrolls a pane's history for a link
(`State/ServerConnection+Ports.swift`, `State/PortForward.swift`, `State/PortActions.swift`,
`Features/Ports/`).

- **Where.** The pane menu's last row in the section above Close: `localhost:5173` with the
  program under it for one web port, `Ports ▸` for two or more, nothing for none. A tapped
  loopback link (`localhost`, `127.0.0.1`, `[::1]`, `0.0.0.0`, `[::]`) in a local pane opens through Rex:
  at once when a program in the pane listens on that port, else after "Open localhost:3000 from
  <computer>?". A link the link policy already asked about isn't asked again. Debugger ports
  (9229, 9222, 9230) never open. Offline a notice says so; such a link never goes to Safari,
  which would reach the phone itself. A link to a private network address (10/8, 172.16/12,
  192.168/16, 169.254/16, fd00::/8), such as the `Network: http://10.0.0.246:3000` that
  `next dev` prints, opens the same way, dialed at that address and named `localhost` in the
  browser, but only when a program in the pane listens on that port; otherwise (another
  machine's address, an unknown port, no port list, offline) it goes to Safari, which reaches it
  on the same network. Every other link, and every link on a server without tunnels or in a
  remote pane, opens as before.
- **Never silent.** A page that can't open says why, once, in a calm notice, and only after a
  tap: "Couldn't open localhost:3000: …" when the pane closed before its question could show,
  when the app has no forward, when the phone can't listen, when the pane left the screen
  before the page came up, and when the tunnel's request never reached the computer.
- **Ports.** After each sync, every local terminal reads `terminal.ports` once per connection,
  panes on screen first and four calls at a time; then `ports_changed` (the whole list each
  time) keeps it, applied in the 150 ms metadata flush and written only when the list changed.
  Nothing polls: Rex looks for ports itself, and a list changes on the phone only when Rex says
  so. An event counts as the pane's read. A new pane's event that comes before its view waits
  for the view. A dropped `ports_changed` reads the list again. On a new connection the lists
  from before stay until they are read again, so nothing leaves and comes back on a reconnect;
  a read that fails takes that pane's list. Web ports are every port but debuggers, SSH, mail,
  DNS, databases, queues and caches, by number and by program (`PortRules`). The dial address
  is the program's loopback address; `0.0.0.0` dials 127.0.0.1 and `::` dials ::1.
- **The Ports group** (`Features/Ports/PortsGroup.swift`; [sidebar.md](sidebar.md), Ports). Its
  rows are `ServerConnection.portRows`: the web ports of the machine's local terminals in
  sidebar order, set only when they change. A port an agent holds itself (its sign-in or editor
  link) gets no row; a server an agent started does. A row is named by what runs, then the
  folder it runs in ("Next.js · anchor"), with `localhost:3000` under it (`PortNames`: a small
  table of known programs, else the program's own name). A tap opens the page in the app, as
  the pane menu's row does. The row's menu and its swipe: Copy Link (`http://localhost:3000`),
  Show Pane, and Stop. The palette lists the same ports as "Open localhost:3000 · Next.js"
  ([goto.md](goto.md)).
- **Stop** (`PortStop`, `PortActions`). Stop types one Ctrl-C into the port's pane. It is
  offered only when the process that holds the port is itself the pane's foreground process
  and the pane runs no agent. A server left in the background, one started by a script or an
  agent that is still in front (`npm run dev`, where `npm` is in front and its child holds the
  port), and a port whose process Rex couldn't name get no Stop, only Show Pane: Rex names the
  foreground's parents and never the port holder's, so the phone can't tell such a server from
  one beside the foreground. On the tap the pane's processes are read again
  (`terminal.process`); if the foreground is no longer that process, nothing is typed and a
  notice offers Show Pane. The Ctrl-C goes once, through the pane's input queue when the pane is
  on screen or kept warm (`sendOnce`) and as one call otherwise (a parked pane has no running
  stream); one that doesn't leave the phone, as while the pane is behind its catch-up fence, is
  a calm notice with Show Pane, never a later send. The row says "Stopping…"; a port still held 5 s later says
  "Still running" and Stop is there to tap again. The phone never sends a signal and never a
  second interrupt by itself. The row goes when Rex says the port is gone.
- **No Restart.** Typing a server's command again needs its exact command line from a source
  that can't be wrong. Rex gives none: `terminal.process` returns each process's first argument
  only ("Rex never returns the other arguments, because they can hold secrets"), no event
  carries a shell's command marks, and Rex installs no shell integration that would write them.
  So the app has Stop and Show Pane, and no Restart.
- **The browser.** `SFSafariViewController`, on `http://localhost:<port>/` from the menu, or the
  tapped link's scheme, host and path. The phone listens on 127.0.0.1 on the same port when it
  is free and above 1024, else on a free one, and forwards **only the opened port**. A page on
  one port that calls an API on another (a frontend on 5173 and its API on 3000) can't reach the
  second: open that one on its own. `[::1]` links open as `localhost`, since the phone listens on
  IPv4 only. "Open in Safari" in its menu leaves the app's forward behind and fails. Done or a
  swipe down ends the forward, and the pane that had the keyboard gets it back.
- **Why not WKWebView.** The ports plan's spike (P0) tried a `WKWebView` with a loopback HTTP
  CONNECT proxy (`WKWebsiteDataStore.proxyConfigurations`, iOS 17). WebKit sent `localhost`
  through the proxy, but never `127.0.0.1` or `[::1]`, with or without `matchDomains`: loopback
  IP literals always go direct, to the phone. So `WKWebView` can't forward every port, and the app
  uses Safari's view with one listener.
- **The tunnel.** One dial block (`session.new_block`, `com.superlogical.tunnel.dial`, options
  `host`, `port`, `client_address`), detached, in the pane's session, labeled `Pteron #<tag>`,
  made on the browser's first connection. The tag is 8 hex characters in the Keychain, this
  device only, never synchronized. Each browser connection is a data connection of its own
  (`data.connect`, `conn:<uuid>`, `rex.data.bytes.v1`), at most 16 at once; more wait for a slot.
  Connections made while the server isn't synced wait for it, up to 30 s. A refused target
  resets the browser's connection. A block a new client ID can't use (after a long drop) is
  dropped and a new one made; a 4006 before any byte came back, even one that comes while the
  request is still going up, sends the request again, once, on a new block. A server that is full (`conflict`), a refused block and a block request that never left (the connection dropped) show one notice per browser.
- **Cleanup.** Rex never removes a tunnel block. Every block made is remembered in UserDefaults,
  and a session where one is about to be made is marked first. On each sync of a server with
  remembered blocks or a mark, and before each `new_block`, the sweep lists the session's blocks
  and closes every dial block with this phone's label that no open browser uses, whoever owns it.
  When the app goes to the background (not merely inactive), a background task begins at once,
  then `block.close` goes for the browser's block (it ends the open streams with 4000) before the
  listener and the connections close; back in front with the page still up, the phone listens on
  the same port again and a new block is made when the page connects. A server removed in
  Settings has its blocks closed if it is connected, else forgotten.
- **Gates** (per server, re-read on every connection). Ports need revision 15 (`terminal.ports`)
  and no `method_not_found` from it. Tunnels need revision 14 and the dial flavor in the creator
  list for the server's host. The row needs both and a local pane (`isLocal`: the block names the
  server's host or none; on a server that names none, only blocks that name none). Without ports,
  a tapped link still opens through Rex and always asks; without tunnels nothing changes. A gate
  that closes while a page is up stops the listener with one notice; when it opens again the
  phone listens again.
- **Metadata of new panes.** `block_created` no longer starts a fixed 300 ms metadata read: the
  read starts when the block reaches a view, no sooner than 300 ms after the event. A detached
  tunnel never reaches one, so it costs no terminal calls. This app's tunnel events
  (`block_created` while it makes one, `block_owner_changed`, `block_closed`) read no view.
