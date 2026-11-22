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

`RexControl` is the only thing that retries a lost control connection, by `ReconnectPolicy`
([architecture.md](architecture.md), Offline). A stream never retries on its behalf, and opens no
socket to a host whose control connection has no welcome; it asks to be told
(`RexControl.observeConnected`) and waits.

- Close code 4000: the pane closed. The stream ends (`.ended`).
- Any other drop of the data socket: one RESUME, 400 ms later, with
  `0x02 + token + bytes received (UInt64 LE)`. A resume needs no ticket, and the stream goes on
  from the first byte not yet received: no new snapshot. Like every socket to the host it waits
  for the control connection: with no welcome, in the background, or back from it before that
  connection has answered, the stream keeps its token and resumes when it may. It is not tried
  after close code 1013 (the server dropped the stream) or once the server's keep time has passed.
- If the RESUME fails or can't be tried: a fresh start (ticket, HELLO, snapshot). That needs the
  control connection. Without one the stream does nothing and shows "Reconnecting…"; when
  `RexControl` is connected again it makes exactly one start: a RESUME if the server can still
  have the stream, otherwise a fresh one.
- A fresh start that fails while the control connection is up (a refused ticket or HELLO, a data
  socket that won't open) is tried again after 3 s, then 6, 12, 24 and 30 s, and every 30 s from
  there. The next WELCOME resets that. These later starts ask for one ticket each.
- **A handshake does not wait for ever.** A data socket's HELLO or RESUME has one deadline: the
  connect deadline of the path the phone is on, 10 s on Wi-Fi and 15 s on cellular
  (`RexControl.dataHandshakeDeadline`, `HandshakeClock`). It is one scheduled wait, ended with
  the first answer, and it does nothing for a stream that has moved on.
  - A RESUME with no answer is dropped without a status 1000 close, so the server keeps the
    stream and the token stays good. The fence is up since the drop that led there, so nothing
    typed goes out. The stream does not ask again by itself: it asks the control connection
    whether the host is there (`RexControl.checkLiveness`, a ping with the pong deadline). No
    pong drops the host, and its next welcome resumes the stream. After a pong the stream
    tries again by itself: after 3 s, then 6, 12, 24, and every 30 s from there, with a RESUME
    for as long as the server can still have the stream (its keep time), and a fresh start
    after that. One retry waits at a time: the control connection's verdict or welcome, or a
    fresh start, takes its place.
  - A HELLO with no answer is closed with status 1000, which also ends a stream the server may
    have opened for it. It is a failed start like any other, and the control connection is
    asked the same way.
  - In the background a handshake that is under way is given up at once, the same way: nothing
    waits or fires there. The stream waits for the control connection's verdict after the
    return, and the handshake it makes then has a deadline of its own.
  - A file's socket (`FileUploader`, `FileDownloader`) and a tunnel's connection
    (`TunnelSession.open`) have the same deadline: no answer is a lost connection.
- `stop()`, `park()`, `restart()` and a newer start end whatever was waiting.
- `resync()` (a fresh stream, for its snapshot) does nothing while a start is under way or owed.
- A fresh start whose ticket is refused with `conflict` right after a reconnect (the app's resync
  hasn't attached the session again yet) is tried again after 250 ms, up to 8 times, before the
  backoff.
- Back from the background, the host calls `wake()`: the stream pings its data socket. A socket
  that fails is dropped without a status 1000 close and the stream goes on with a RESUME, as
  after any drop. One that doesn't answer (half open after a suspension) has no deadline of its
  own: the control connection judges the host. If that connection gets no pong, the stream's
  socket is dropped with it; if it does, the stream's socket has 0.5 s more.
- When the control socket gets no answer (a missed pong, a timeout), every data socket to the
  host is dropped at once, without a status 1000 close: the token stays good, the fence goes up
  as on any drop, and the welcome brings the stream back with only the bytes it missed. One that answers is
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
  the screen or closes first, the notice says "Didn't send <files>: the pane was still
  reconnecting. Try again in a moment." with Try Again.
- **Always allowed**: scrolling, selection, copy, find, opening links, menus.
- **Look**: the screen as it was, with no dimming and no badge. Only the cursor is hollow, as an
  unfocused pane's. The engine holds the screen on show and draws what arrived as one frame when
  the fence comes down ([ghostty-engine.md](ghostty-engine.md), The catch-up hold), for 1 s at
  most; after that the screen follows the bytes while the fence stays up. A pane that opens at
  the size it will keep draws its first screen at once.
- A fence over a screen that is still up after 2.5 s shows "Reconnecting…".
- A `resize` from another client counts as "Resized on another screen" only on a current stream or after
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
  and leaving the pane does 10 s later (Parking, claim grace); the Mac then gets its size back. If another client resizes the pane, the host stops and offers "Resized on another screen ·
  tap to fit here". Until then it shows the server's grid as mirror does. A pinch there fits the
  pane here too (Gestures).
- Ownership. A pane follows its owner's size, and a resize from a client that isn't the owner
  is answered and only kept for later ([rex-protocol.md](rex-protocol.md), Block ownership).
  The Rex Mac app takes the panes it shows. So:
  - Every claim moment takes the pane before it sizes it: the pane comes on screen (a first
    view, a return from the park or from warm, a fold), the app comes back, the chip is tapped.
    A refit of a pane that stayed on screen (the keyboard on the alternate screen, find's hold)
    resizes under the claim it has, and a return inside the grace at the size in place sends
    nothing (`FitClaim.request(reassert:)`). Before, the phone took a pane once and from then
    on sent only resizes; once the Mac app had taken the pane, they were all kept for later
    and the pane never took the phone's size.
  - Nothing counts as claimed that the server didn't answer. A take or resize the connection
    lost (back from the background, the socket died while the app was away) is asked again,
    take first, once the control connection is back; until then the claim is on its way and
    the fence waits for it. Before, a failed call still answered "ours", and the pane showed
    the Mac's grid 1:1, cut at the right edge. `conflict` (the session not attached again yet
    after a reconnect) is asked again 250 ms later, up to 8 times; a server's no ends the claim
    with the chip; a server from before ownership (`method_not_found`) is resized only.
  - Answered is not applied. 1 s after a claim's answer, a size from another client, or the
    fence coming down (`checkFit`, `FitCheck`), a pane on screen with nothing on its way looks
    at its grid: a claimed size the server doesn't have, or another owner named in the
    session's view, shows the chip, with the server's grid scaled. A pane at another grid with
    nothing claimed (no path should leave it so) claims once and logs `FIT_GUARD`; if that
    doesn't hold either, the chip. Never per frame.
  - Not fought over: a pane another client has never takes it back by itself, not at a later
    claim moment either; the chip's tap or a pinch does. It also leaves the line (`disown_block`, which changes
    nothing for the owner), so the pane never passes back to a phone that isn't asking. One
    exception: a pane the server gives back at the size that fits here (an owner whose
    connection dropped gets its panes back when it reconnects) is the phone's again, with no
    call (`FIT_BACK`). Mirror never takes, resizes or gives back.
- The software keyboard covers a fitted pane; it doesn't resize it. The grid stays the one that
  fits the pane with the keyboard down (`TerminalLayout.fitSize`, from the tab's canvas as
  measured with the keyboard down, `PaneLayout`), so a program on the main screen gets no
  resize when the keyboard shows or hides and has nothing to redraw. The engine view keeps the
  grid's height, the pane shows its top part, and the engine draws the rows shifted up so the
  last row with content sits above the key bar (`GhosttyScrollState`, "The cover"). The scroll
  view has that much more room at the bottom: dragging down brings the covered rows into view,
  then the scrollback, in one motion. Typing returns to the bottom. A view in the scrollback
  doesn't move when the keyboard shows or hides.
  - Stick to the bottom, as chat apps and terminals do. At the pin the view follows the screen:
    output, a cover change and a refit keep the newest rows and the cursor above the key bar. A
    scroll off the pin of any size leaves it, and output never brings the view back: new rows
    take the shift down by as much, so what the user reads holds still, and once the covered rows
    are used up the view goes on into the scrollback, where output leaves it as before. A drag
    a row or more past the covered rows still puts the keyboard away (Gestures).
  - The view sticks again when it comes back to the pin: a scroll there, or a drag or fling that
    comes to rest within a row of it, which UIKit ends at the pin (a nudge while tapping sticks
    too); on any key or paste; on the jump-to-bottom button; and when the keyboard shows again
    over a view at the bottom. The button counts rows from the pin, so it also shows for a view
    half a screen up among the covered rows.
  - Whether a view at the bottom follows is decided against the pin of the frame that applies
    the scroll, so a cover change in the same frame (the keyboard's top measured again, the emoji
    keyboard) can't leave the shift short of the pin.
  - On the alternate screen (an editor, a pager) the grid fits above the keyboard, as its rows
    can't be scrolled: one resize when the program enters or leaves that screen with the
    keyboard up, and one when the keyboard shows or hides while it is there.
  - The key bar alone (hardware keyboard) takes room from the layout and the grid fits above it.
  - The canvas with the keyboard down is worked out from each layout, never kept from an earlier
    one (`PaneLayout.restCanvas`): the canvas as it is, plus the room the keyboard takes from the
    root's bottom (`KeyboardInset`, handed down as `keyboardRoom`), less a title bar or strip that
    stepped aside for it, and in tabletop no taller than the region above the crease. Both are
    read with the size they made, and each counts whichever comes first as the keyboard moves,
    so no layout in between gives another size. So a fold, a rotation or Split View with the
    keyboard up is one resize, to the new posture's columns and keyboard-down rows, and the
    keyboard going down afterwards sends none. Before, the height measured with the keyboard
    down was kept while it was up: after a turn to portrait with the keyboard up the panes got
    landscape's rows (26 of 41 on the folded Duo), then a second resize when the keyboard went.
  - Only rows the pane is meant to have count as covered (`TerminalLayout.cover(terminal:fits:pane:)`).
    Right after a fold or a rotation the old grid can be taller than the new pane until the
    resize lands; its bottom is past the pane's edge for that moment, and nothing is shifted.
    Before, it counted as a keyboard's cover: the rows jumped up, then back, and removing that
    shift could leave the view in the scrollback (below).
  - The shift under a cover is put right once. When a cover shrinks, the render side puts the
    shift inside it and moves the terminal by itself; each snapshot says which cover its shift
    was decided against (`GhosttyScrollState.Snapshot.covered`), and the main thread corrects a
    shift only from a snapshot of the cover it set. Before, a snapshot from just before reached
    the main thread late and the shift was taken off twice: after a fold the view sat rows up in
    the scrollback with a part of a row showing, the bottom row cut in half and older rows at the
    top, until the keyboard came up again.
  - A pane laid out out of a window (the view a fold leaves, once more on its way out) claims
    nothing; back in a window it lays out again. A layout that finds the claimed size while
    another request settles asks for the claimed size again, which supersedes it, so a size a
    layout on the way had is never sent.
  - Another client's size that comes after our resize's echo but before the claim's answer
    (the echo comes first in the stream) counts as "Resized on another screen", as one after the
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

## Predicted echo

On a slow link a typed character shows at once, before the program's echo comes back, as mosh
does it. Nothing changes in what is sent: the guess is drawn over the grid and never written to
the terminal, and the program's output always wins. On a fast link there is no predictor and the
key path is the one without it.

**When it is on.** `EchoGate` (RexKit, one per server, since a server's panes share one control
connection) keeps a smoothed round trip (α 1/8) of the `terminal.write` calls typing already
makes, each from the moment the write leaves to its answer. Nothing is sent to measure.

| Change | When |
| --- | --- |
| off → on | 5 samples since the last reset, and the smoothed round trip over 60 ms or two writes of 250 ms within 10 s. One spike does not turn it on. |
| on → slow | Over 80 ms, or a drawn guess still unconfirmed 300 ms after it was typed. |
| slow → on | 50 ms or less, the last 10 samples each under 250 ms. |
| → off | 40 ms or less with no spike in the last 10 samples. |
| reset to off | A new control connection, a change of route (`RexControl.observeRoute`). Every guess goes too. |

A pane shows more at once; it shows less (slow → on, → off) only once it has nothing pending,
so the look never changes in the middle of a word (`EchoPaneLevel`). The 80 and 50 ms marks are
mosh's. The 60 and 40 are not (mosh starts at 30): the off path has to cover a nearby computer on
Wi-Fi, where an echo lands within a few frames anyway.

**Where a key may be a guess.** Only at a shell's prompt, and every gate must say so:

- The stream classifies every input call (`EchoInputClassifier`): one printable ASCII byte or one
  Backspace can be a guess; everything else (Enter, control keys, escape sequences, a paste, a
  key with a modifier, more than one character in a call, a report, an action) is a boundary
  that ends the line being guessed.
- The pane's gate on the main thread (`EchoHostGate`): a shell is the program in front
  (`EchoForeground.shells`), no agent runs in the pane (`BlockMeta.agentKind`), the catch-up
  fence is down, the keyboard is not composing, no selection is up, Find is closed, and the view
  is at the bottom. Anything else makes the key a boundary. A pane whose program is unknown
  guesses nothing.
- The predictor on the feed queue (`EchoPredictor`), against the grid: the primary screen, the
  cursor visible, room ahead on the row.
- Proof that the program echoes. With OSC 133 marks, the prompt's `B` mark of the line being
  typed. Without them, the first key of a line is tracked but not drawn; once the program has
  echoed it, the tty's state is read (`terminal.input_mode`, one call per line, on slow links
  only) and the rest of the line is drawn only if echo and canonical mode are both off with a
  local shell in front, which is a line editor reading a line. Echo off with canonical on is a
  password reader. Echo on proves nothing, canonical or not: it is the tty's resting state or a
  script reading keys, and a program can turn echo off from it at any moment. No reading is
  asked for when the program in front could prove nothing anyway. Over `ssh` the reading describes the local client, so an `ssh`
  pane predicts only with OSC 133 marks from the remote shell.

So a password prompt (`sudo`, `read -s`), an editor, a pager, an agent's input box and anything
on the alternate screen draw no guess, typed ahead or not.

**Confirming.** mosh's rules. A line being guessed is an epoch. It starts only once every
earlier input is answered and 50 ms have passed, so guesses never build on output still on its
way. A key is confirmed only from the screen after the answer to its own write, in typing
order, and never from a grid that looks like the state before it. Only contrary screen content
removes guesses: then the whole epoch's overlay goes in the frame that first draws what proved it
wrong, with no notice. After wrong guesses (30% or fewer of the last 24 judged keys right) lines
are tracked without being drawn until 60% are right again. A late echo removes nothing. Enter
does not either: while the prompt is not open no new key is drawn, but what is on screen stays
until the screen confirms it. Guesses go at once when the program leaves the screen they were
made on (the alternate screen, a hidden cursor). A hold of the screen (a program's synchronized
output) keeps the guesses of the moment it began with its rows; the catch-up hold of a
returning pane draws none. A guess still unconfirmed 1.5 s after its
write's answer is cleared without a sign (counted as `vanished` when it was drawn). A resize, a
reset, a restored snapshot, a theme, dropped output, a lost write, the fence, a park, a stop and
a reconnect clear every guess.

**Not watched, not trusted.** A pane that parked or stopped, a new control connection, a
restored snapshot, a terminal reset and dropped output all mean the screen was not watched
being written: the program in front may be another one. The proof goes with the guesses
(`EchoPredictor.unprove`): an earlier `input_mode` reading counts no more, and neither does any
`133;B` up to that moment. A pane that comes back from the park draws no guess until the shell
announces a new prompt or, without OSC 133, a new line's first key was echoed and the tty read
again. A resize keeps the proof.

**Nothing is kept of a pane that is gone.** The stream holds its observers weakly, the core's
event handler and the gate's closures hold the host weakly, and the host's watch on the gate
(`EchoGateWatch`) leaves the gate when the host goes, however it leaves: closed, evicted from
the park, or its computer removed.

**How a guess looks.** The glyph the program will draw: same font and atlas, the colour and
bold of the typed cell to its left, else the theme's foreground. No background is drawn over a
blank cell, so a prompt's own background shows; a cell that holds a character a pending
Backspace removes gets a mask in that cell's background. The cursor is drawn after the last
guess, in the terminal's cursor style. While the link is slow every unconfirmed character,
spaces too, carries a solid underline in its own colour at half strength (full with Increase
Contrast), and loses it in the frame that draws the program's character. Nothing animates.
VoiceOver reads the grid, so it reads confirmed text only.

- A program's own underline (a syntax highlighter's path style) looks like an unconfirmed
  character. Accepted.
- With an underline cursor the cursor sits in the cell after the trail at full strength.
- A tap on the prompt that moves the cursor with arrow keys is sent at once while guesses are
  drawn, counted from the cursor on screen (`EchoPromptClick`): the engine's count plus the
  pending keys on text the program has, the columns to the cursor on a guessed cell. Its arrows
  queue behind the typed keys. On a wrapped input line or a row with a wide character it is
  counted from the program's cursor, as without predicted echo. If a pending key does not land
  as guessed the cursor ends up off by that much.
- Prompt marks are forgotten for a new program in front at the next key, not when the computer
  reports the change. Known; a follow-up.

**Threads.** The main thread only hands on what it learned (a key's kind and number, a write's
answer, a clear), in order with the bytes. The predictor runs on the feed queue with the
terminal lock held, publishes its overlay in the same lock section as the rows it was computed
for, and the render thread latches both together (docs/ghostty-engine.md, Predicted echo). The
host listens to its stream (`inputObserver`, `writeObserver`) only while its gate is on; when
the gate turns off and nothing is pending, the predictor retires and the host stops listening.

**Limits.** ASCII and Backspace only: no IME text, no emoji, no cursor keys, no completion. No
guess in the last cells of a row, on a wrapped line's next row, or beside a right-hand prompt
that the line reaches. An agent that keeps running after its status record is gone is only kept
out by the other gates.

**Measuring and testing.** `-predict never|always` (Debug only) forces the gate; `-echoTest`
reports `predictedMs` and the counters; the benchmark's `predict` scenario plays a recorded
typing session on a scripted link (docs/debug-args.md, docs/ghostty-engine.md, Measurements).
Recorded sessions of a real shell (`RexDuoTests/Fixtures/echo`, from
`scripts/record-echo-fixtures.py`) run through the real core in `EchoScriptTests`.

## Find

Find in Pane, as on the Rex Mac app: type a needle, every match on screen is tinted, the
current one stands out, and Next and Previous step through the pane's screen and history.

- **Where it searches.** The pane's own terminal, with libghostty-vt's search
  (`GhosttyCore+Find.swift`; [ghostty-api-notes.md](ghostty-api-notes.md), Search). No server call:
  the phone holds the newest 10,000 lines, and a match older than that has no row to show. Matching
  is the library's: byte for byte, with ASCII letters folded (no regex, no case option, as on the
  Mac). The needle is the field's first line, composed (NFC), at most 1 KB (`FindQuery`). With the
  history at its cap and nothing found the count says "No matches in recent history".
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
  claimed size again, which supersedes it (as any layout does: Fit and mirror).
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
  never scrolls out of sight. A tap opens one short list with no titles, subtitles or switches:
  Paste Image or Paste File (when the clipboard has one), Photos, Camera (where the device has
  one) and Files, then, after a divider, "Files on <computer>" with Browse Files… and Insert
  Path… (see Browse). Where the files go, the agent working in the pane (OSC 7501) or else the
  pane's computer, is said by the send's progress and result ("Sent Photo… to Claude"). The
  same rows are under Attach in the pane menu, right after Share (subtitle "or 📎 on the
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
  The pacing ping (`RexControl.paceProbe`) is a ping of its own and only measures: with no
  pong within the pong deadline (10 s, 20 s on cellular) it counts as a slow sample and the
  rate halves; it never drops the host. In the background, or when the connection is lost, its
  wait ends with no sample.
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
- **Photos** (`ImagePrep`), with fixed values made for the agents that read them (Claude Code,
  Codex: JPEG, PNG, GIF, WebP, no HEIC) and for the tunnel. Photos, the camera, pastes and drops
  are prepared alike, with no switch. A screenshot (a PNG, or an image iOS marked "Screenshot" in
  its EXIF) stays PNG at full size up to 3,000 px on its long side, the most Claude takes once a
  conversation holds more than 20 images, so its text stays crisp. A photo becomes JPEG at 0.85,
  at most 2,048 px on its long side: Claude reads at most 2,576 px and 4,784 patches of 28 px,
  GPT-5.5 at most 2,048 px, so larger pixels would be thrown away. HEIC, HEIF and every other
  still format are always converted (PNG where there is transparency). A prepared image weighs
  about 5 MB at most (lower JPEG qualities, then a smaller PNG). Scaling goes through ImageIO
  thumbnails off the main thread, with the EXIF orientation applied, and location and other
  metadata are always left out. A small upright JPEG or PNG is copied without being decoded. It
  fails closed: each copy is checked for GPS, IPTC and XMP place names; one that can't be
  stripped is drawn again, and one that can't be drawn either is sent only after "Couldn't
  remove location. Send anyway?". Live Photos send the still; videos, moving GIFs and files
  picked in Files go as they are, so Files is the way to send a photo's exact bytes.
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
- **Browse.** "Browse Files…" in the attach menu's "Files on <computer>", below the sending
  rows, and in the palette's commands (as are Insert Path…, Insert File… and Insert Photo…;
  [goto.md](goto.md)), opens a sheet over
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
  (the Files picker) and `pane.insert_photo` (the Photos picker) are
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

- **Where.** The pane menu's middle section is Find…, Share ▸, Attach ▸, Arrange ▸ and Ports,
  in that order. "Arrange ▸" shows on a tab with two or more panes. One submenu, its groups
  titled inline sections: Swap With (the other panes), Move to Tab (the session's other tabs,
  then New Tab), Balance Splits, Close Other Panes… in a destructive section of its own.
  Floating Windows is a section of the pane menu of its own, not inside Arrange, while the tab
  has a float (Floating windows, below).
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
above its tiled panes where the Mac places them in a wide window, and one at a time in a sheet
over the tab in a narrow one. View-only: the phone raises, focuses, minimizes and shows them
again, and never moves or resizes one (`Features/Tab/TabPresentation.swift`, `FloatLayout.swift`,
`FloatSheet.swift`, `State/ServerConnection+Floats.swift`).

- **No float, no change.** Only a tab with a floating window on screen has a `TabPresentation`.
  Every other tab, one whose floats are all minimized included, runs the screen's split-or-page
  logic over its tiled panes as before, so it is drawn exactly as before.
- **One decision per body.** `TabPresentation.decide` is read by the canvas, the floats, the
  dots, the Waiting pill and Zoom. Book mode's sidebar collapse still asks about the tiled
  splits alone, with the sidebar collapsed: beside the sidebar they may show as pages under a
  float, and the float must not keep the sidebar open. Zoom (the server's or the phone's) gives
  pages: one pane at a time, the tiled panes then the floats' panes front first, minimized ones
  left out, with dots and swipes as any tab. A narrow window gives the float sheet (below). A
  wide window draws floating windows when the tiled splits are legible and every float can be
  placed; else pages.
- **The float sheet** (narrow windows: folded, iPhone portrait, SE, half the inner screen;
  `FloatSheet`). A float is never one of the tab's pages there: the tiled panes show exactly as
  in a narrow tab without floats (legible splits, else one at a time with the title bar's dots,
  which count tiled panes only), and one float at a time shows in a sheet over them, as Maps and
  Music show theirs.
  - *One rule.* The sheet shows exactly while the tab's active pane is a drawn float's. Showing a
    float makes its pane active; going back to the tab makes the tiled pane shown under the
    sheet active again (`PhoneState.sheets` keeps which, and the size), on the phone only.
    Every path that points the phone at a pane (a tap, the Waiting pill, a link, the palette, a
    server focus on a float at open) shows or hides the sheet with it, and a hidden sheet's
    float never takes the keyboard (`ActivePane`).
  - *Sizes.* Large leaves about 15 % of the tab above it (24 pt at most while typing); Medium
    about 55 %; compact height and a tab with no tiled pane have Large only, and a tab with no
    tiled pane can't hide it. Typing or a tap on the float lifts it to Large; Medium while
    typing puts the keyboard down.
  - *Look.* The canvas less 4 pt each side, top corners 12, the terminal's color with a stroke
    and a soft shadow, running on under the home indicator. A 36 pt grabber strip in the title
    bar's color: the handle, the shown pane's status and name (never its title), page dots when
    the float pages its panes, the floats' dots when there are several, and a chevron (44 pt)
    that goes back to the tab. No badge, nothing on the panes.
  - *Gestures, on the grabber only* (the panes keep theirs): up and down change the size and a
    drag down past Medium goes back to the tab, by where the drag would coast; sideways shows the
    next or previous float, front first, no wrap; a tap switches Large and Medium. A drag picks
    its axis once, past 10 pt. A tap on the tab above goes back to it, with that pane active. A
    float whose splits keep 40 × 8 cells in the sheet shows them; else one pane at a time, and a
    sideways swipe on the pane walks its panes. Next and Previous Pane walk the active pane's
    group, the tiled panes or the float's, never from one into the other.
  - *The Mac.* A tap or the floats' menu raises as a tap does (`FloatTap`); a swipe on the
    grabber changes only the phone, unless the keyboard is up and typing goes there next. Going
    back to the tab sends nothing.
  - *No resize.* The sheet's panes claim their grid once, at Large with the keyboard down
    (`FloatSheet.Geometry.rest`). A size change moves the sheet by position only: at Medium the
    part below the screen counts as covered, as the keyboard covers a pane
    (`TerminalHost.setSheetCover`, set once the sheet rests), so the row the program writes on
    stays in view and nothing is sent. The keyboard covers the sheet as any pane.
  - *Floats' control.* One glyph (`macwindow.on.rectangle`) with the count in the title bar (in
    tab mode, in the strip's slot beside the pane menu), and last in the vertical bar with the
    keyboard down when the sidebar navigates, only while the tab has a float to list. Its menu:
    the drawn floats front first (the shown one ticked), those minimized on the Mac (shown again
    there, then in the sheet), and Back to the Tab. Its own view, so tab mode's strip can host it.
  - *Motion.* The sheet slides up from the bottom and between floats as pages do; Reduce Motion
    fades instead, a size change included. Only the shown float is in the view tree: the
    others park as panes off screen do.
  - *VoiceOver.* The grabber is one adjustable element ("Floating window, <name>", "2 of 3"):
    swiping up or down on it shows another float; its actions switch the size and go back to
    the tab. The control says how many floating windows there are.
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
- **Floating Windows**, a section of the pane menu of its own while the tab has a float
  (`FloatMenuSection`), not inside Arrange: Minimize (the active pane's float; hidden when it
  holds the tab's last panes on screen, which the server refuses), Minimize All when it does more
  than Minimize, and each minimized float by its first pane's name, which shows it again in front
  (`set_layer_state` normal with `focus`). In a narrow window the drawn floats not in the sheet
  are rows too, so the sheet stays in reach where the title bar steps aside. Keys:
  `pane.minimize_floating` and `pane.minimize_all_floating` ("Minimize Floating Window(s)", no
  default keys). Minimize All sends every drawn float's minimize in order in one turn, keeping
  the front one when no tiled pane is left; a refusal shows one notice.
- **Waiting agents.** The pill and the toasts count a drawn float as on screen, and a minimized
  float or a page a swipe away as not. Jumping to an agent in a minimized float shows the float
  again first.
- **Fit.** A float claims the grid of the frame it is drawn at (grown or narrowed), as a split
  pane does, and in the sheet the grid of the sheet at Large; one no longer drawn parks after
  0.5 s (`scheduleStop`) and lets its claim go 10 s after it left (Parking). A claim resizes the
  float's pane only: the layer's bounds on the Mac stay as they were (checked against Rex,
  2026-11-20: a float at [0.15, 0.2, 0.7, 0.5] kept them after its pane took 56×32).
- **Compatibility.** Drawing is data-driven: no `layers`, a null `layer_id` (an ID from the
  layer's first block, stable across raises) and an unknown kind (floating) or state (normal)
  all draw; a float without usable bounds is skipped. Minimize, the rows, the keys and the raise
  follow `PaneArrange.isAvailable` (revision 13 or later, and `set_layer_state` not found missing
  on this connection); without them floats still draw.

## Ports

A program in a local pane that listens on a TCP port (`npm run dev` on `localhost:5173`) opens on
the phone, in the app's own browser, through a Rex dial tunnel. Servers bound to
127.0.0.1 only work too. No port opens on the computer, and the phone listens on its own
loopback only while the page is up. Nothing shows on a pane. Each machine's sidebar header
opens every such port of the machine, so nobody scrolls a pane's history for a link
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
- **Which ports show** (`PortProbe`, `PortProbeBook` in RexKit;
  `State/ServerConnection+PortProbe.swift`, `PortForward.probe`). A web port by `PortRules` may
  still be no web page: an editor plugin's WebSocket server (Claude Code's IDE link in nvim
  answers "Bad WebSocket upgrade request"), or a raw TCP service on an unknown port. So each
  one is asked once what it answers, and the Ports list, its count on the globe, the palette
  and the pane menu's row leave out only a port that gave positive evidence. A tapped link
  never looks at the probes: one to a hidden port opens as before, since the user asked for
  it. A typed address finds the shown rows, as the list does.
  - The question: a dial block of its own (same label, ledger and sweep as the browser's, no
    `client_address`), one data connection, `GET /` with `Host: localhost:<port>`,
    `Accept: */*` and `Connection: close`, no cookies. At most 4 KB of the reply is read, for
    at most 2 s, then the connection drops and the block closes. Nothing reaches a pane,
    nothing is kept, nothing is shown when it fails, and the log has the verdict and the
    reply's size only, never its content.
  - No web page, hidden: 426; a 400 whose headers or body say "upgrade" and "websocket" (any
    case); bytes that aren't HTTP (Redis's `-ERR`, an SSH banner, an HTTP/2 frame). A web
    server, shown: every other HTTP status, 401, 403, 404 and 500 included (a dev server's 404
    at `/` is still one), and an HTTP/0.9 page. Unknown, shown as before: no reply (refused, an
    empty close, out of time), a tunnel that couldn't be made, offline, and a TLS record
    (0x15 or 0x16 first: an HTTPS-only server such as `vite --https`). The browser opens
    `http://` only, so such a server didn't open before either; it keeps its row.
  - A verdict belongs to the process's port (pid, port, dial address), per computer, kept
    across reconnects while the lists stay: one port in two panes is asked once, and a dev
    server that restarts under a new pid is asked again. It goes when no list holds that
    port for that pid. An answer for a port that went, or for an older ask, is dropped.
    Web and no-web are final; unknown is asked again once at the next new list of a pane
    that holds the port (a read on a new connection or a `ports_changed`), so a server that
    was still starting isn't hidden or stuck. Nothing asks on a timer.
  - No jump. A new port is held, in no list and with no count, until its answer or 1.5 s,
    whichever comes first; then it shows unless the answer was no web page. One wake, set
    for the earliest hold, shows it; the globe counts shown rows only. A port that takes the
    place of a shown row on the same port within a minute (a restart, Restart's own) isn't
    held. While probes can't run (offline, no tunnels) a new port shows at once and is asked
    at its next listing. After an update, every port is new once at the first launch.
  - Cost. At most 2 asks run at once per computer, and only while it is online with tunnels
    and synced; the rest wait in order. Debugger and service ports are left out by
    `PortRules` first and never dialed. The asks don't go through `CallGate`, on cellular
    either: the dial tunnel is separate from the sync's calls, and each ask is one small
    request per new port. A test launch (`-autoOpen <label>`) asks only that session's ports.
- **A machine's ports** (`Features/Ports/MachinePorts.swift`, `PortsGroup.swift`;
  [sidebar.md](sidebar.md), Ports): the globe button on its sidebar header, or on its heading in
  tab mode's session popover, lists them. The rows are `ServerConnection.portRows`: the web ports of the machine's local terminals in
  sidebar order, set only when they change. A port an agent holds itself (its sign-in or editor
  link) gets no row; a server an agent started does. A row is named by what runs, then the
  folder it runs in ("Next.js · anchor"), with `localhost:3000` under it (`PortNames`: a small
  table of known programs, else the program's own name). A tap opens the page in the app, as
  the pane menu's row does. The row's menu and VoiceOver's actions: Open in Browser, Copy Link
  (`http://localhost:3000`), Show Pane, Restart and Stop, each only where it applies. The
  palette lists the same ports as "Open localhost:3000 · Next.js"
  ([goto.md](goto.md)).
- **Stop** (`PortStop`, `PortActions`). Stop types one Ctrl-C into the port's pane. From Rex
  alone it is offered only when the process that holds the port is itself the pane's
  foreground process and the pane runs no agent: Rex names the foreground's parents and never
  the port holder's, so a server started through a wrapper (`npm run dev`, where `npm` is in
  front and its child holds the port) can't be told from one beside the foreground. Where the
  computer's Beacon names a port's process (see **The Beacon** below), the wrapped server gets
  Stop too: the pane's foreground process must be the holder, the leader of the holder's
  process group, or a parent of the holder in that same group, the foreground group of the
  holder's terminal must be that group where the Beacon names it, and no process of the group
  may be an agent (`PortOwner.interruptReaches`, `PortStop.agentInGroup`). A server left in the
  background, one its starter put in a group of its own, one an agent started and a port whose
  process nobody could name get no Stop, only Show Pane. On the tap the pane's processes are
  read again (`terminal.process`), and for a wrapped server the Beacon is asked again about
  that process, so nothing is decided from what the row showed; if the answer is no longer a
  yes, nothing is typed and a notice offers Show Pane. Stop never shows the pane. The Ctrl-C goes once, through the pane's input queue when the pane is
  on screen or kept warm (`sendOnce`) and as one call otherwise (a parked pane has no running
  stream); one that doesn't leave the phone, as while the pane is behind its catch-up fence, is
  a calm notice with Show Pane, never a later send. The row says "Stopping…"; a port still held 5 s later says
  "Still running" and Stop is there to tap again. The phone never sends a signal and never a
  second interrupt by itself. The row goes when Rex says the port is gone.
- **Restart** (`RestartCommand`, `PortRestart` in RexKit; `PortActions.restartNow`). Rex gives no
  command line (`terminal.process` returns each process's first argument only, and no event
  carries a shell's command marks), so Restart exists only where the Beacon names the job. It
  is offered when all of this holds: Stop's rule above; the leader of the holder's process
  group is in the Beacon's answer with the process that started it; that parent is a shell
  (`ProcessNames.isShell`); the leader's arguments are there, whole and text (`argv` not null,
  not `truncated`, not `argv_lossy`); they are not the shell's own (a subshell or a function
  runs as a copy of the shell); they are not a title the program wrote over them (`npm run
  dev` reports one string with the whole line and empty strings after it: no argument is
  empty, a single argument has no whitespace, and the first argument's last part names the
  process or its executable, a version suffix or a cut-short name aside:
  `RestartCommand.isRetitled`); the leader's folder is the shell's folder, so no `cd` is ever
  typed; the job is one command and no pipeline (the Beacon's `job_members` is 1: the
  shell started one process of the group; a pipeline's leader holds only its first part, and
  an answer without the field gives no Restart); every argument has a spelling on one line (`ShellEscape`, with a literal `~` kept
  literal; an empty argument, a control character or a first word with `=` gives no Restart);
  the line is at most 300 characters; and no agent is in the pane or the group.
  - It is not what the user typed: variables set in front (`PORT=4000 npm run dev`) and an
    alias are not in a process's arguments. So nothing says the command is
    the same. The row asks instead, in place and never in an alert: "Restart: npm run dev" in
    monospace, "Runs this command again in its pane." under it, and Restart or Cancel. The
    command shows whole, on as many lines as it takes, never with a part left out: a program
    that starts another under its full path (Homebrew's `python3`) reads as that path.
  - After the tap, in this order, nothing twice (`PortRestart`): the Beacon is asked again and
    the command must read exactly as the row showed it; the pane is shown if it isn't on
    screen, and nothing is typed until it is on screen with its catch-up fence down (5 s at
    most); one Ctrl-C goes as Stop sends it, with Stop's own checks; the port must go and the
    pane's processes (`terminal.process`, read at most three times) must name the very shell
    that started the job as the foreground, and Rex's events must name it too, within 10 s;
    the command and Return go once through `sendOnce`, after a last look (the port still
    gone, the foreground the events name still that shell, no agent, the screen still current); the row says "Restarting…" until the
    port is back, 30 s at most. The row keeps its place in the list while its port is away
    (`ServerConnection.holdPortRow`).
  - Its waits are events with one deadline each, never a repeating timer: the pane's host
    says when the pane shows and its stream when the fence is down
    (`ServerConnection.whenPaneCurrent`), and the port lists and the panes' foreground
    processes are observed state that Rex's `ports_changed` and `process_changed` write.
  - Any step that doesn't hold ends it: one notice with Show Pane, the row says "Couldn't
    restart" with Show Pane for 30 s, and nothing is typed afterwards. A command that didn't
    leave is never sent later; one that left without an answer is never sent again.
- **Open in Browser** (`PortBrowser`, `PortActions.openInBrowserNow`). The page in the
  iPhone's own browser, at an address the computer's Beacon hands out for that port and this
  iPhone (`port_share`; [helper.md](helper.md)). The item is in a row's menu and in
  the browser's menu only while all of this holds: the Beacon's status says the computer can
  (`helper_status`' `share_possible`, read where the app already reads the status and never
  for this alone; a status without the field is a no), the Beacon has answered `port_owner`
  on this connection, no answer has said otherwise (`not_supported`, `not_registered` and
  `not_your_phone` for the connection; `not_available`, which can only follow a status that
  said yes, until the next status is read), the iPhone has a tailnet address (`PrivateNetwork.address`: 100.64.0.0/10
  on a tunnel, or fd7a:115c:a1e0::/48), and the port is 80 or from 1024 up on the computer's
  loopback. A tap asks the Beacon, then opens the address with the system's browser. Nothing
  else asks: showing a row or opening a page in the app never makes such an address. And a
  tap is never how someone learns that their computer can't: there the item isn't shown.
  - A row whose page is out there adds "In browser" to its address line, and its Copy Link
    gives that address. The app takes the address to exist until a minute before the Beacon
    would end it unused (`idle_seconds`), on this connection and for the process that held the
    port; then the words go, and the next tap asks again.
  - One site. While the address exists, a page opened in the app loads from it too and not
    from the phone's listener, so a login made in one is the same site in the other. The app
    asks for it again at that moment, which keeps it and finds out that it ended; then the
    page loads the old way. The chrome still shows the computer's address (`localhost:3000`);
    Copy Link and Share give the address that works outside the app.
  - A tap that opens nothing says why in one line (`PortBrowser.notice`), in the open browser's
    own line when the tap was there. "Nothing is running on localhost:3000 now." for a port
    that stopped listening.
- **The Beacon** (`PortActions.learnOwner`, `PushRegistrar.ask`). Open in Browser, Stop for a
  wrapped server and Restart need Beacon 0.7 on the computer, holding this iPhone
  (notifications set up there). There is no setting. A row that shows asks `port_owner` for its
  process once per process and connection; a computer with no Beacon is asked nothing, and one
  that answers `not_supported`, `not_registered` or `refused` is not asked again on that
  connection. Nothing is asked while the computer's ports list is closed (it has no row then), and
  nothing on a timer. Without a Beacon everything above is absent and Ports works as before,
  plain Stop included.
- **The browser.** `PreviewBrowser`: the app's own view, one `WKWebView` made when the page
  opens and let go when it closes, never kept warm. It loads `http://localhost:<port>/` from the
  menu or a Ports row, or the tapped link's scheme and path. The phone listens on 127.0.0.1 on
  the same port when it is free and above 1024, else on a free one, and forwards **only the
  opened port**. A page on one port that calls an API on another (a frontend on 5173 and its API
  on 3000) can't reach the second: open that one on its own. Done or a swipe down ends the
  forward, and the pane that had the keyboard gets it back.
  - Nothing of it exists before a page opens. The sheet's first frame is the sheet alone; its
    bars, with everything in them, are shown on the turn after, while the sheet has only begun
    to rise (laying out bars is most of what a sheet with bars costs the main thread over an
    empty one). The web view, which WebKit makes on the main thread only, is made on the turn
    after that, its load starts at once, and it joins the view one turn later. The error page is put
    together the first time a load fails. Pages keep their cookies and storage in the app's one
    WebKit store, so a login on a dev server is still there the next time its page opens.
    Debug and benchmark builds mark the steps of an open as signpost intervals (`PreviewTrace`:
    subsystem `dev.abrahamgonzalez.rexduo`, category `PreviewBrowser`).
  - Chrome: Done, the page's title over its address, a menu (Copy Link, Share…), and back,
    forward and reload. The top bar is the navigation controller's. The three under the page
    are the browser's own buttons in its own view, placed and drawn as a toolbar's: UIKit
    (iOS 27.2) keeps a `UIToolbar`'s items, their buttons and its model after a toolbar that
    held items is gone, about 90 KB for every page opened, and 100 opens must cost what 30 do
    (`-portsLoop`, `scripts/bench/ports-loop.sh`). `PreviewBarLayout` puts them where that
    toolbar's items are on each shape: under the page on an iPhone upright or on its side and
    in a sheet that floats, and in the system's vertical bar on the iPhone Duo, from the
    bottom up, where the page keeps its height. They say Back, Forward and Reload to
    VoiceOver, say when they are off, and show large on a long press at the accessibility
    text sizes.
    Open in Browser is in the menu only while the computer can hand the page to the
    iPhone's browser (see **Open in Browser**), looked up each time the menu opens, and never
    for a page of another site; otherwise there is no button that leaves for another app,
    since the address shown only works inside this one. It is a menu item, never a bar item.
  - The loop's reading sits at one of two levels in the simulator, about 32.4 MB or about
    37.9 MB, and some runs climb from the first to the second in their first 25 or so opens.
    In the one run measured at the high level, `vmmap` showed 6.4 MB of the app's pages
    compressed by the Mac and a footprint equal to dirty plus compressed (31.7 + 6.4 MB); in
    eleven runs at the low level nothing was compressed and the footprint was about 5 MB under
    the dirty pages (37.1 to 37.8 MB), so the app had written the same amount in both. A sheet
    with only a `WKWebView` (`-portsLoopBare`) read 30.4 to 30.7 MB in seven runs and was never
    seen at a high level, so whether it has one too is not known; a busy processor alone did
    not bring the high level on.
  - The address shown is the one the user knows from the computer (`PreviewAddress`,
    `LocalhostLink.shown`): a tapped link's own host and port as written (`localhost:3000`,
    `127.0.0.1:5173`, `0.0.0.0:8000`, `[::1]:4000`, a LAN address), and `localhost:<port>` from
    the pane menu, a Ports row or the palette. What loads underneath (the phone's listener,
    whose port may differ) is never shown, the error page included. Copy Link and Share give
    that same address with the path of the page on screen. A link that leaves the server shows
    its own host.
  - A response the page can't show, or one sent as an attachment, downloads to the phone's
    temporary folder and goes to the share sheet. A link for a new window opens in the same
    view. A server that asks for a name and password (Basic or Digest) gets a small form, kept
    for the session only. A load that fails shows "Couldn't load localhost:3000" with Try Again.
    Light and dark come from the page's own CSS.
  - A tap on the address edits it, as in Safari: the field holds the address as shown and the
    path on screen, and Go resolves it with `PortAddress`, which reads only the port lists the
    app already holds (no call, no network). The forms are `localhost:3000`, `127.0.0.1:3000`,
    `:3000`, `[::1]:3000` and `0.0.0.0:3000`, with or without `http://` or `https://`, and a
    path and query are kept. One connected computer listens there: its page opens (in place
    when it is the server on screen). Several: a list asks which, one row a computer ("Desk ·
    Next.js · anchor"). None: "Nothing is running on localhost:3000 on your computers." A
    computer that is offline is left out. The address shown afterwards is the one typed. An
    address that isn't a computer's own (`example.com`, another machine's IP) is never loaded
    here: it opens in the system's browser. The same port on two computers is two rows in the
    Ports group, and a tap there opens that one with no question.
  - What Safari's view gave and this one doesn't: Reader, the saved passwords' AutoFill bar,
    content blockers and Safari's cookies. None matters for a dev server's page.
- **Why one listener.** The ports plan's spike (P0) tried a `WKWebView` with a loopback HTTP
  CONNECT proxy (`WKWebsiteDataStore.proxyConfigurations`, iOS 17). WebKit sent `localhost`
  through the proxy, but never `127.0.0.1` or `[::1]`, with or without `matchDomains`: loopback
  IP literals always go direct, to the phone. So no proxy forwards every port, and the view
  loads from one listener for the opened port.
- **The tunnel.** One dial block (`session.new_block`, `com.superlogical.tunnel.dial`, options
  `host`, `port`, `client_address`), detached, in the pane's session, labeled `Pteron #<tag>`,
  made on the browser's first connection. The tag is 8 hex characters in the Keychain, this
  device only, never synchronized. Each browser connection is a data connection of its own
  (`data.connect`, `conn:<uuid>`, `rex.data.bytes.v1`), at most 16 at once; more wait for a slot.
  Connections made while the server isn't synced wait for it, up to 30 s. A refused target
  resets the browser's connection. A block a new client ID can't use (after a long drop) is
  dropped and a new one made; a 4006 before any byte came back, even one that comes while the
  request is still going up, sends the request again, once, on a new block. A server that is full (`conflict`), a refused block and a block request that never left (the connection dropped) show one notice per browser.
  A probe (see **Which ports show**) makes a block of its own the same way, without
  `client_address`, and shows no notice.
- **Cleanup.** Rex never removes a tunnel block. Every block made is remembered in UserDefaults,
  and a session where one is about to be made is marked first. On each sync of a server with
  remembered blocks or a mark, and before each `new_block`, the sweep lists the session's blocks
  and closes every dial block with this phone's label that no open browser or running probe
  uses, whoever owns it.
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
