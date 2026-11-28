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
2. `wss://<server>/api/data`, subprotocol `rex.data.terminal.v1`, opened in the turn the ticket
   is asked for (The early socket, below). Handshake in `DataFrame`: send `0x01 + ticket`
   (HELLO); the first frame is `0x82 <reason>` (REJECT) or a 32-byte `0x81` WELCOME with the
   resume token (bytes 1–16), the server's keep time for a dropped stream (UInt32 LE ms, bytes
   20–23; 60 s today) and the nonce (UInt64 LE, bytes 24–31).
3. The stream's first bytes are a Ghostty snapshot (`GHOSTSNP`): screen, scrollback, modes and
   size. `APCFilter` walks its record framing and hands it to the host in parts
   (`streamGhosttySnapshot`: `begin`, `bytes`…, `ready`, `bytes`…, `end`), all before the first
   Rex message. The host restores it into a new terminal.

No size or screen read comes before the stream: the snapshot is the screen, and the `resize`
message after it carries the size and the owner. So a fitted pane starts its stream at its first
layout, beside its fit claim (Fit and mirror).

Until the first screen can be drawn the pane shows `GlideLoader` in its center (Glide's outline,
about 44 pt, a stroke gliding along it in a 1.2 s loop; a slow breathing mark with Reduce Motion),
in the theme's text color. It fades in over 180 ms only after 400 ms, and out over 150 ms, so a
fast pane shows nothing. "Connecting…" under it waits 2.5 s. Core Animation runs it: no
main-thread work per frame. A pane that has a screen never shows it.

### The early socket

A fresh start opens its data socket in the same turn it asks for the ticket, and sends the HELLO
when both are there (`EarlySocket`, `TerminalStream.openEarly`). The server ends a socket that
has sent no HELLO 5 s after its upgrade (REJECT `0x05`, close 1002), pinged or not. So:

- The HELLO goes on the early socket only while it is younger than 4 s (`EarlySocket.ageLimit`)
  and has not ended. The stream listens on it from the start, so it knows when the server ended
  it.
- A ticket for a socket that ended or grew too old goes on a new socket. That is not a failed
  start and counts toward no backoff.
- A ticket refused with `conflict` keeps the socket open through the wait for the session's
  attach (Reconnect), for what is left of the 4 s; the ticket asked after the attach goes on it.
  The age limit, the wait's cap and a cancelled wait close it.
- Any other ticket failure closes the socket at once, and the start fails.
- `stop()`, `park()`, `restart()`, a newer start and the background close it. No socket outlives
  its start.
- It goes through the same gate as every data socket (`mayOpen`, `RexControl.openDataSocket`):
  none without a control welcome, none in the background. A dropped computer takes it along.
- The handshake's one deadline starts when the socket opens and covers the wait for the ticket.
- A RESUME needs no ticket and opens its socket directly. A busy terminal's retries (REJECT
  `0x02`) ask for the ticket first and open the socket after it.

REJECT `0x02` means this client still has a connection to the terminal. Right after a `restart()`
that is the old socket, whose close the server hasn't handled yet, so the first start asks again
with a new ticket up to 6 times, 50 ms apart.

### If the snapshot can't be restored

The host returns false for a part, the snapshot ends incomplete, or the restore fails afterwards
(`TerminalStream.snapshotRestoreFailed()`). The data stream stays open. Once the snapshot's bytes
have gone by, the stream reads `terminal.size` and `terminal.format` (`vt`, then `blob_read` until
`eof`: the screen and the newest 1 MB of scrollback as escape sequences) and the host resets and
feeds that. Output during the read is dropped. From then on that stream reads the screen this way
on every start, and `resync()` re-reads it on the open stream. The host refuses a snapshot over
16 MiB (`SnapshotBuffer`), so a huge history takes this path too.

## Output

- Rex messages are APC sequences, `ESC _ rex1;<nonce>;<json> ESC \`, and can split across frames.
  `APCFilter` removes them in stream order: `resize {cols, rows, owner}`, `theme`,
  `child_exited {exit_code}`. Everything else goes to the engine unchanged, as views into the
  received chunk.
- The host passes each chunk to the engine at once; the engine copies it to its feed queue and
  parses there. The main thread does no parsing and no pacing.
- **Backpressure.** Over 4 MB unparsed the engine says so (`GhosttyCore.isBackedUp`) and the host
  calls `TerminalStream.pauseReading()`: the stream takes the message it is waiting for and asks
  the socket for no other. Below 1 MB, `resumeReading()`. So a fast writer fills the socket's and
  the server's buffers, not the phone's memory. Input and control calls are not held, and a
  RESUME still counts only the bytes taken. Past 64 MB unparsed (a source that never pauses) the
  engine drops the backlog (`GhosttyCore.droppedBytes`).
- A `resize` applies at its place in the stream: the grid changes between the bytes before and
  after it.

## Reconnect

`RexControl` is the only thing that retries a lost control connection, by `ReconnectPolicy`
([architecture.md](architecture.md), Offline). A stream never retries on its behalf and opens no
socket to a host whose control connection has no welcome; it waits on
`RexControl.observeConnected`.

- Close code 4000: the pane closed. The stream ends (`.ended`).
- Any other drop of the data socket: one RESUME, 400 ms later, with
  `0x02 + token + bytes received (UInt64 LE)`. It needs no ticket and goes on from the first byte not yet received: no new
  snapshot. It waits for the control connection like every socket (no welcome, in the
  background, or back before that connection answered), keeping its token. Not tried after close
  1013 (the server dropped the stream) or past the server's keep time.
- **No RESUME for a stream whose client has left the server** (`ClientContinuity`). A control
  connection lost without a close frame leaves its client on the server for a while; the next
  hello carries the last welcome's reconnect token, and a welcome with `resumed: true` continues
  it, streams included. A welcome that gives another client ID or says `resumed: false` started a
  new client (revision 18 leaves `resumed` out, so the ID decides). The server stops a departed
  client's streams, so the RESUME is skipped and the fresh start follows at once.
  `RexControl.clientGeneration` counts clients; a stream notes it at its WELCOME and resumes only
  under the same one. A server that doesn't say changes nothing: the RESUME is tried. A fresh
  start keeps the fence up throughout, so nothing typed at the old screen is sent, and input that
  had left is never sent again.
- If the RESUME fails or can't be tried: a fresh start (ticket, HELLO, snapshot). That needs the
  control connection. Without one the stream shows "Reconnecting…" and does nothing; when
  `RexControl` is back it makes exactly one start: a RESUME if the server can still have the
  stream, else a fresh one.
- A fresh start that fails with the control connection up (a refused ticket or HELLO, a socket
  that won't open) is retried after 3, 6, 12, 24 and 30 s, then every 30 s, one ticket each. The
  next WELCOME resets that.
- **A handshake does not wait for ever.** A HELLO or RESUME has one deadline, the connect deadline
  of the current path: 10 s on Wi-Fi, 15 s on cellular (`RexControl.dataHandshakeDeadline`,
  `HandshakeClock`). One scheduled wait, ended by the first answer, inert for a stream that has
  moved on.
  - A RESUME with no answer is dropped without a status 1000 close, so the server keeps the
    stream and the token stays good; the fence is already up. The stream asks the control
    connection whether the host is there (`RexControl.checkLiveness`, a ping with the pong
    deadline). No pong drops the host, and its next welcome resumes the stream. After a pong the
    stream retries itself after 3, 6, 12, 24, then every 30 s: a RESUME within the keep time, a
    fresh start after. One retry waits at a time; the control connection's verdict or welcome,
    or a fresh start, replaces it.
  - A HELLO with no answer is closed with status 1000, which also ends a stream the server may
    have opened. It is a failed start, and the control connection is asked the same way.
  - In the background a handshake under way is given up at once: nothing waits or fires there.
    After the return the stream waits for the control connection's verdict; its next handshake
    has its own deadline.
  - A file's socket (`FileUploader`, `FileDownloader`) and a tunnel's connection
    (`TunnelSession.open`) have the same deadline: no answer is a lost connection.
- `stop()`, `park()`, `restart()` and a newer start end whatever was waiting.
- `resync()` (a fresh stream, for its snapshot) does nothing while a start is under way or owed.
- **A ticket refused with `conflict`** right after a reconnect (the app hasn't attached the session
  again yet) waits for that attach and asks again the moment it is answered
  (`TerminalStream.awaitAttach`, `AttachWaits`), not every 250 ms. `RexControl` learns of an
  attach from the answer to its own `session.attach` or `session.bootstrap`; a new client is
  attached to nothing.
  - The wait only waits: nothing is opened or asked until the ticket, which goes through the
    usual gate. The refused start's early socket stays open while young enough and takes the
    HELLO after the attach (Start, The early socket).
  - Hard cap 2 s. At the cap, or with nothing to wait for (the session is attached, so the
    refusal has another reason), the start retries after 250 ms, up to 8 times, then backs off.
  - `stop()`, `park()`, `restart()`, a lost control connection, the background and a removed
    computer end the wait; the next start finds no connection and waits for it.
- Back from the background the host calls `wake()`: the stream pings its data socket. A socket
  that fails is dropped without a status 1000 close and resumes. One that doesn't answer (half
  open after a suspension) has no deadline of its own: if the control connection gets no pong,
  the data socket is dropped with it; if it does, the data socket has 0.5 s more. Transient chips
  ("Reconnecting…") wait out the wake's grace (`ForegroundWake.grace`). The fence is up from the
  wake until the socket has answered and the stream is quiet.
- When the control socket gets no answer (a missed pong, a timeout), every data socket to the
  host is dropped at once, without a status 1000 close: the token stays good, the fence goes up,
  and the welcome brings each stream back with only the bytes it missed.
- URLSession can call a pong handler twice (the second time with an error, when the socket drops
  while the ping waits), so the ping and the socket's receive resume through `ResumeOnce`
  (`URLSessionStreamSocket.ping`): only the first call counts. A second resume of a checked
  continuation is a fatal error.

## The catch-up fence

Input has no sequence number and is never sent twice (Input), so a key typed at a screen that is
behind the program can't be taken back. `CatchUpFence` (RexKit, one per stream) keeps input away
from a program state the user has not seen.

- **Up**: from `start()` until the first screen, and on every data socket drop, wake, return from
  the park and fresh restart. Raising it while up keeps the same fence.
- **Down**, only when all hold:
  1. the stream has arrived: a RESUME's WELCOME, the end of a fresh snapshot (or the screen read
     that stands in for it), or a wake's pong. A snapshot still coming in has not arrived,
     whatever else answers;
  2. no fit claim is on its way (`TerminalStream.setClaimPending`, set by the host from the
     request until the resize returned, the claim is released or the pane is lost);
  3. no byte and no Rex message for 40 ms, or 60 ms once our own `resize` came back in the
     stream. After our resize changed the size over a screen the user saw, the wait for the
     redraw's first byte is 700 ms (Our resize's redraw, below);
  4. the engine has parsed everything fed (`streamWhenParsed`), and nothing came meanwhile.
- **A pane that never goes quiet** (`yes`, a build log) would never pass 3, not even for Ctrl-C.
  So 300 ms after 1 and 2 hold, the fence comes down once the engine has parsed what it has.
- **Keys and pastes while it is up** are held as their encoded bytes, in order.
  - Fence down with nothing received since it went up, over a screen the user saw: the screen was
    exact, and the held bytes go out in order through the one input queue. The common case (an
    idle shell, a waiting agent); it feels local.
  - Something arrived meanwhile (a byte, a resize, a snapshot, any message): they go only if the
    parsed screen is the one on show when the fence went up: same text and styles in every row,
    same cursor, modes and keyboard modes, same grid (`GhosttyCore.showsHeldScreen`, asked once
    as the fence comes down). That is a program that only redrew, as an agent does for a resize.
    Otherwise they are dropped with one notice: "The pane changed. Nothing was sent." Key bytes
    depend on modes that may have changed, so they never go to another screen.
  - They live 1 s at most from the first, or until the redraw's cap while the fence waits for our
    resize's redraw; then they are dropped with "Not sent: the pane was still reconnecting."
  - Both notices are neutral (`TerminalStream.onFenceNotice`): nothing failed.
  - After a drop, every later key of the same fence is dropped silently: the rest of a line must
    not arrive alone. At most one notice per fence, none when nothing was typed.
  - A pane that shows nothing yet has no screen to type at: keys before its first screen are
    dropped ("Not sent: the pane was still reconnecting."). Keys typed during a fresh start go
    only if its snapshot restores the screen they were typed at.
- **Input still queued when it goes up** (typed offline, or behind a request that is out) waits
  in the queue: sent if the screen was exact, dropped with the notice otherwise. A request that
  had left is never sent again.
- **Dropped while up, never held**: mouse and wheel reports, focus reports and the keys a tap or
  drag makes (`engineSendReport`, `TerminalStream.send(report:)`), silently; key-bound server
  actions, forwarded keys, palette runs and Insert Path, with the notice; `sendOnce` (the watch)
  is told it never left.
- **Said again when it comes down**: the focus report. A program that asked for focus reports
  (mode 1004) is told where its pane is, ahead of any held keys (`GhosttyTerminalView.sayFocus`):
  a report made before may never have arrived.
- **A program's focus is the front pane's** (`PaneFront`, `ProgramFocus`), not the keyboard's:
  the tab's active pane, on screen, in the app in front, with no agent board, sheet, alert, menu
  or palette over it. It hears `CSI I` when its pane becomes the front pane and `CSI O` when it
  stops (`TerminalHost.refreshProgramFocus`).
  - The keyboard says nothing: hiding it, a scrollback drag that puts it away, and a hardware
    keyboard's quiet hold leave the program focused. Only the cursor (solid or hollow) follows
    the keyboard.
  - In a split only the active pane's program has the focus.
  - The app leaving the front takes the focus: another app, the Home Screen, and Control Center,
    Notification Center and the app switcher, which make the app inactive. It returns when the
    app is active again.
  - A pane that leaves its window says so only after 0.5 s away, so a fold says nothing. A pane
    that parks says so before its stream parks. A tab switch does not wait: the old tab's pane
    loses focus as the new one gains it (`TerminalHost.leftForAnother`).
  - Accepted: two programs can both hold the focus while a narrow window's split panes slide
    (the leaving pane keeps it until the other is active), and with the app in two windows
    (each window's active pane counts; the rule knows the app, not the window).
  - A program that turns focus reports on while front is told `CSI I`. One that never asked is
    told nothing.
  - The right to write the pasteboard (OSC 52) asks the same question, so a covered pane has
    neither.
- **A file send** waits for the fence, then goes: the user picked a file, not a place on screen
  (`whenCurrent`). At most 10 s; if the pane is still behind, leaves the screen or closes first:
  "Didn't send <files>: the pane was still reconnecting. Try again in a moment." with Try Again.
- **Always allowed**: scrolling, selection, copy, find, opening links, menus.
- **Look**: the screen as it was, no dimming or badge; only the cursor is hollow. The engine holds
  the screen on show and draws what arrived as one frame when the fence comes down
  ([ghostty-engine.md](ghostty-engine.md), From bytes to a frame, the catch-up hold), for 1 s at
  most; after that the screen follows the bytes while the fence stays up. A pane that opens at
  the size it will keep draws its first screen at the size report after its snapshot; after a
  resize of its own from another size it does not (that report may be the echo, redraw still to
  come) and waits for the fence. A scroll, a selection and find draw through the hold, and so
  does a new keyboard cover while the grid is unchanged; once the grid changed under the hold,
  the frame that ends it takes the cover.
- **Our resize's redraw.** A program redraws for a new size; an agent reprints its whole
  transcript (Claude Code clears screen and history and rewrites everything at the new width,
  after laying it out first). When our own resize changed the size behind a fence over a screen
  the user saw (its echo shows another size than the stream had, or the claim's answer came while
  the fence was up, as when a fresh snapshot already has the new size), the fence waits for that
  redraw: up to 700 ms for its first byte, then 60 ms quiet, 2.5 s after the resize at most. The
  screen holds still and draws the redraw as one frame. A resize to the size the pane had costs
  those 700 ms once, losing nothing. A pane that opens does not wait.
  - Why: with only the 60 ms quiet wait the fence fell while the program was still laying out its
    reprint; a key typed then reached the program first, and the reprint scrolled under the
    user's typing.
- A fence over a screen still up after 2.5 s shows "Reconnecting…".
- A `resize` from another client counts as "Resized on another screen" only on a current stream
  or after our own resize has come by: a size from before ours can arrive after the claim's
  answer. A claim whose resize was left out (the server had the size) has no echo, so its answer
  counts as the echo.

### Back from the background

The screen the user left stays on show when the app comes back, at its own size, until the
return has caught up (`AwayFrame`, `GhosttyTerminalView.holdWhileAway`).

- **Why.** A fitted pane goes back to the Mac 10 s after the app leaves (below), and the Mac's
  size and redraw can arrive while the app still runs in the background, where nothing draws.
  Without the hold iOS shows the last frame stretched to the Mac's grid on return, then the
  Mac's grid, then the pane's.
- **What it does.** As the app leaves, a pane showing a screen keeps that screen's grid for its
  view and the engine holds the frame: the catch-up hold, with no time limit. Everything that
  comes meanwhile is parsed in stream order, resizes included. Back in front the wake raises the
  fence and the claim takes the pane again; the frame stays until the stream's hold ends or its
  fence comes down, and the caught-up screen shows as one frame. With no stream running the
  terminal shows at once.
- A snapshot restored under it (a fresh start after a long absence) keeps the held rows on show
  until the hold ends: never an empty frame.
- With the control connection down the frame stays, with "Reconnecting…" after 2.5 s. Scrolling,
  a selection and find draw through it.
- **A short absence sends nothing** (`BackgroundGrace`). A fitted pane on screen keeps its claim
  for 10 s after the app leaves the front, inside a background task, so a quick return finds the
  pane at its size: no take, resize or redraw, and the wake's fence comes down over the screen
  the user left. After 10 s the claim is given back (as a parked pane's claim grace, Parking) and
  the task ends once the give-back has left. The Mac's own take wins at any moment: the phone
  shows the chip on return instead of taking the pane back. A claim still on its way as the app
  leaves is given up at once.
- Back after the grace, the one claim and its resize go out, and the fence waits for the redraw
  (Our resize's redraw, above).
- A pane that parks, warms, stops or leaves the screen drops it.

## A tab that moves

A tab moved to another session of its computer (docs/sidebar.md, Move to Session) keeps its
panes' hosts: terminals, screens, history, scroll positions and compose drafts, now under the new
session (`TerminalHostPool.moved`). Only the session the stream and the pane's calls use changes.

- **Before the phone's own move** each stream is told (`TerminalStream.expectMove`): the server
  ends streams opened through the old session, and that end, whatever its close code, neither
  ends the stream ("This pane closed.") nor resumes it. The fence goes up; the screen stays.
- **After it** (`TerminalStream.moved(to:)`) a stream on screen or warm starts afresh through the
  new session: one ticket, one HELLO, one snapshot (a RESUME could only be refused). The old
  screen stays under the catch-up hold until the new snapshot, and the fence comes down by its
  usual rules. A parked stream does this when shown again.
- **Input.** Keys typed meanwhile are held and then dropped with the fence's notice, as for any
  fresh start; queued input named the old session and is dropped. A request that had left is
  never sent again.
- **Fit.** The claim stays; the size is the same, so the fresh size report needs no resize.
  Files, sharing and ports go through the new session.
- **A failed move** (`moveFailed()`) leaves the stream where it was; an end that came meanwhile
  is treated as a drop (RESUME or fresh start).
- **Another client's move** ends the streams first, with a close's status (4000). Where the
  server moves tabs (revision 22) a close waits like a moving stream, fence up and screen kept,
  for `TerminalStream.closeHold` (0.8 s) at most: the app's word normally comes first. A
  `window_created` naming the tab in another session, or the tab on screen leaving its session's
  view, makes it a move (`expectMove`); the view showing the tab in its new session starts the
  stream afresh, and the pane hears its owner and typing-aid news again
  (`TerminalHost.moved(to:)`). With no such view the wait ends as a close: "This pane closed.",
  in the turn the app moves off a tab on screen, so the words never show on it. Below revision 22
  a close ends at once.

## Parking

A pane that leaves the screen (a pane or tab switch) parks instead of stopping, so coming back
is not a cold start.

- **Parking** (`TerminalHost.park`, 0.5 s after the pane left its window, since a fold moves a
  pane within that): the host, its terminal, and the stream's resume token, byte count and place
  stay. The data socket is dropped without a status 1000 close (the server keeps the stream 60
  s), the input queue is dropped, the drawables are freed, find closes, and no timer or ping
  runs: no CPU, no network.
- **The 0.5 s wait holds the host** (`TerminalHost.scheduleStop`): its main-queue timer keeps a
  host that left its window alive until it runs, so the stream is parked or stopped even when
  nothing else owns the host. A test that takes a host out of a window sees it freed only after
  that.
- **Coming back**: the same host is on screen in its first frame with its last screen and no
  loader. The fence goes up and one RESUME starts at once (no ticket, no control call); only the
  missed bytes arrive. Keys typed on an idle pane go as the fence comes down; on a changed screen
  they are dropped with the notice.
- **RESUME refused or past its window**: a fresh start, keeping the old screen until the new
  snapshot begins; the fence stays up throughout.
- **Claim grace**: a parked pane keeps its fit claim 10 s after it left the screen
  (`LeaveTiming.claimGrace`), so switching back and forth resizes neither pane and the screen can
  be exact. Then the Mac gets its size back, and a later return claims again beside its RESUME.
  Going to the background releases a parked pane's claim at once; a pane on screen keeps its own
  10 s (Back from the background).
- **How many** (`TerminalHostPool`, `ParkPolicy`): the 4 panes parked last, within 96 MB of
  terminal memory by the engine's own figure (`GhosttyCore.memoryBytes`, read when a pane leaves
  the screen and again if a warm pane parks: `TerminalHost.keptBytes`). Oldest goes first. Panes
  on screen don't count.
- **Warm panes** (`WarmPolicy`, `TerminalHost.warm`): the 2 panes left last don't park. Their
  streams go on off screen, parsed and never drawn (no drawables, find or timers), so the screen
  is current the moment one is back: no RESUME, no round trip. They count toward the 4 and the
  96 MB.
  - Foreground only. The background, Low Power Mode and a thermal state of serious or worse park
    every warm pane at once; on an expensive network (`NWPath.isExpensive`) one stays warm, not
    two.
  - A warm pane writing over 64 KB/s on average over 2 s parks (`WarmRate`, checked as bytes
    arrive, no timer): a build log is not followed unseen.
  - A warm pane comes back with no fence when nothing will change (`WarmReturn`): a mirror pane
    always, and a fitted pane still holding its claim at the size that fits, inside its 10 s
    grace. It streamed at that size throughout, so typing goes at once, even on a busy pane. A
    fitted pane whose claim lapsed, or that fits another grid now, is fenced
    (`TerminalStream.returned`) until the new claim's resize landed and the stream is quiet.
  - A warm pane whose stream drops reconnects as a pane on screen does, behind its fence.
- **All of them go** on a memory warning, on return after 10 minutes in the background, when
  their server is left or removed, and when their session closes (`ParkWatcher`). A pane let go
  stops: status 1000, claim released.

## Fit and mirror

- Fit: after layout settles (120 ms), `session.own_block` (take), then `terminal.resize` to the
  largest grid that fits (`TerminalLayout.fitGrid`, at least 12×4), while the stream starts
  beside it. `session.disown_block` goes at once on a switch to mirror, 10 s after the app goes
  to the background (Back from the background), and 10 s after the pane is left (Parking, claim
  grace); the Mac then gets its size back. If another client resizes the pane, the host stops and offers "Resized
  on another screen · tap to fit here", showing the server's grid as mirror does until then. A
  pinch there fits the pane here too (Gestures).
- Ownership. A pane follows its owner's size; a resize from a non-owner is answered and only kept
  for later ([rex-protocol.md](rex-protocol.md), Block ownership). The Rex Mac app takes the
  panes it shows. So:
  - Every claim moment takes the pane before it sizes it: the pane comes on screen (a first view,
    a return from park or warm, a fold), the app comes back, the chip is tapped. A refit of a pane
    that stayed on screen (the keyboard on the alternate screen, find's hold) resizes under its
    claim, and a return inside the grace at the size in place sends nothing
    (`FitClaim.request(reassert:)`).
  - A resize to the size the pane has is not sent (`FitResize`). After a take, the claim compares
    with the size the server last reported in the pane's stream, never the size the phone last
    sent: a pane another client resized is resized back, and one already at the size gets the
    take alone. The server's word counts only from a live stream that said the size since its last
    fresh start; a parked pane's stream is down as it returns, so its resize is sent. If the server
    then reports another size for a pane still ours, the resize goes after all
    (`FitClaim.serverReported`).
  - Nothing counts as claimed that the server didn't answer. A take or resize the connection lost
    is asked again, take first, once the control connection is back; until then the claim is on
    its way and the fence waits. `conflict` (session not attached again yet) is retried after
    250 ms, up to 8 times; a server's no ends the claim with the chip; a server from before
    ownership (`method_not_found`) is resized only.
  - No take, resize or disown leaves before the pane's session is attached on the connection
    (`AttachGatedFitTransport`, `RexControl.mayCall`, `AttachWaits`). After a reconnect that
    started a new client, the server answers an early take with `conflict` before the app's
    `session.bootstrap`, and with a plain `bad_request` between the bootstrap and the attach,
    which can't be told from a real no and would end the claim. So the call waits for the attach's
    answer, 2 s at most (`TerminalStream.attachWaitCap`). A wait that ends without the attach
    (connection dropped, background, cap) counts as `conflict`. After a wait that hit its cap the
    next call for that session is not held, so an attach the connection's calls don't show (an
    older server) still ends in a take. With no connection nothing waits: the call fails unsent.
  - Answered is not applied. 1 s after a claim's answer, a size from another client, or the fence
    coming down (`checkFit`, `FitCheck`), a pane on screen with nothing on its way checks its
    grid: a claimed size the server doesn't have, or another owner in the session's view, shows
    the chip with the server's grid scaled. A pane at another grid with nothing claimed (no path
    should leave it so) claims once and logs `FIT_GUARD`; if that fails too, the chip. Never per
    frame.
  - Not fought over: a pane another client asked for is never taken back by itself, not at a later
    claim moment either; the chip's tap or a pinch does. It also leaves the line (`disown_block`,
    which changes nothing for the owner), so the pane never passes back to a phone that isn't
    asking. Mirror never takes, resizes or gives back.
  - Lost to an absence, not to a client (`FitTenure`). When the phone's client drops or ends, the
    server passes its panes to the next client in line (the Mac app when it shows the pane), and
    the pane takes that client's size ([rex-protocol.md](rex-protocol.md), Block ownership).
    Nobody asked, so a pane on screen gets its size back on return, with no chip. Events from the
    time away are lost, so the pane goes by what it can know:
    - The control connection never dropped since the claim's answer: another client's size or
      name on the pane is that client's doing. The chip.
    - Another client asked for the pane (`block_owner_changed` with `take` or `request`, heard on
      the connection) and the phone has not taken it since: the chip, whatever else happened,
      also when the other client's size equals the phone's and no resize comes.
    - The connection dropped and the server started a new client: the phone was away longer than
      the server keeps a client (60 s), or the app itself closed the socket (missed pong, route
      change, timeout), which ends the client at once. Its panes went on because it was gone
      (`disconnect`), and no event says whether anybody asked since. The return is a claim
      moment: the pane is taken again at the size that fits (`FIT_TAKE_BACK`).
    - The connection dropped and the server kept the same client (no close frame, back within
      60 s): the server gives it its panes back at its size unless their owner changed again. The
      client isn't told, but its stream replays the time away: the other size, then its own. So
      the other size is history until the pane has caught up, and nothing is sent. Still there
      after that (`checkFit`): the owner changed again, which only a client's own call does. The
      chip.
    - Which of the two it was is `RexControl.clientGeneration`'s word (it goes up at a welcome
      that started a new client).
    - The connection is down now: nothing is decided or sent. The welcome looks again
      (`TerminalHost.controlCameBack`), and so does the fence coming down.

    A take back is one reasserting claim: one take, and a resize unless the server has the size.
    If the connection loses it, it is asked again once when the connection is back; the pane makes
    no attempt of its own. Its answer starts a new tenure, so a later other size is another
    client: the chip, never a second take back. Only a pane the user is looking at is taken back:
    not one that left the screen (parked, warm, past its grace), one under the agent board, or one
    in a backgrounded app.
  - A pane showing the chip that the server gives back at the size that fits here is the phone's
    again, with no call (`FIT_BACK`).
- The software keyboard covers a fitted pane; it doesn't resize it. The grid stays the one that
  fits with the keyboard down (`TerminalLayout.fitSize`, from the tab's canvas measured with the
  keyboard down, `PaneLayout`), so a program on the main screen gets no resize and nothing to
  redraw when the keyboard moves. The engine view keeps the grid's height, the pane shows its top
  part, and the engine draws the rows shifted up so the last row with content sits above the key
  bar, or the cursor's row when the rows below it don't fit (`GhosttyScrollState`, "The cover"
  and "The cursor"). The scroll view has that much more room at the bottom: dragging down shows
  the covered rows, then the scrollback, in one motion. Typing returns to the bottom. A view in
  the scrollback doesn't move when the keyboard shows or hides.
  - Stick to the bottom, as chat apps and terminals do. At the pin the view follows the screen:
    output, a cover change and a refit keep the newest rows and the cursor above the key bar. Any
    scroll off the pin leaves it, and output never brings the view back: new rows take the shift
    down by as much, so what the user reads holds still, and past the covered rows the view goes
    into the scrollback, where output leaves it alone. A drag a row or more past the covered rows
    puts the keyboard away (Gestures).
  - The view sticks again at the pin: a scroll there, a drag or fling resting within a row of it
    (UIKit ends it at the pin; a nudge while tapping sticks too), any key or paste, the
    jump-to-bottom button, and the keyboard showing again over a view at the bottom. The button
    counts rows from the pin, so it shows for a view half a screen up among the covered rows too.
  - The cursor's row stays in view. A program can draw rows below the typing row (Claude Code's
    status lines and a row per running subagent), enough to fill what shows above the key bar.
    When the rows below the cursor don't fit, the pin keeps the cursor's row a third of the way
    down what shows, so a wrapped prompt's lines above it show too, and the rows below stay
    covered until scrolled to (`GhosttyScrollMath.pin(cover:rows:contentRows:cursorRow:cellHeight:)`).
    A drag past that pin shows them and holds under output, no further than the last row with
    content; a key or paste returns to the pin. A shell's cursor is on its last row: its pin is
    the content's.
    - Only a cursor at rest counts: shown, on the same row two frames in a row
      (`GhosttyScrollState.noteCursor`). Claude Code doesn't use synchronized output: each redraw
      hides the cursor, passes through the rows below the prompt, and shows it on the prompt at
      the end, so a mid-redraw frame finds it hidden or passing, and neither moves the view. A
      hidden cursor keeps its resting row for half a second (`hiddenCursorHold`); a program that
      hides it for good, or a shown cursor that keeps moving, gets the content's pin. The row
      counts only if rows with content were below it when the cursor last showed there, so a
      shell prompt's row never holds the view while output streams. On the alternate screen the
      cursor doesn't count.
  - Whether a view at the bottom follows is decided against the pin of the frame that applies the
    scroll, so a cover change in the same frame (the keyboard's top measured again, the emoji
    keyboard) can't leave the shift short.
  - On the alternate screen (an editor, a pager) the grid fits above the keyboard, since its rows
    can't scroll: one resize when the program enters or leaves it with the keyboard up, and one
    when the keyboard moves while it is there. The host hears of the screen from each frame
    (`alternateScreenHook`), and of a snapshot's screen once restored, from the parsed terminal
    (`GhosttyScroller.screenRestored`): a fenced pane draws no frame, and would otherwise claim
    the keyboard-down grid first and the above-keyboard grid second. When the snapshot is in
    before the claim's settle time ends, the first claim is right; on a slow link the claim can
    still go first.
  - The key bar alone (hardware keyboard) takes room from the layout; the grid fits above it.
  - The keyboard-down canvas is worked out from each layout, never kept (`PaneLayout.restCanvas`):
    the canvas plus the room the keyboard takes from the root's bottom (`KeyboardInset`, handed
    down as `keyboardRoom`) and as much of the home indicator under it as the window's corners
    allow (`PaneBottom`, [duo-layout.md](duo-layout.md), Bottom edge), less a title bar or strip
    that stepped aside for it, and in tabletop no taller than the region above the crease. Both
    are read with the size they made, each taking whichever comes first as the keyboard moves, so
    no in-between layout gives another size. So a fold, rotation or Split View with the keyboard
    up is one resize (new columns, keyboard-down rows), and the keyboard going down sends none. A
    kept height would give the old posture's rows, then a second resize.
  - Only rows the pane is meant to have count as covered
    (`TerminalLayout.cover(terminal:fits:pane:)`). Right after a fold or rotation the old grid can
    be taller than the new pane until the resize lands; nothing is shifted for that.
  - The shift under a cover is corrected once. When a cover shrinks, the render side puts the
    shift inside it and moves the terminal itself; each snapshot names the cover its shift was
    decided against (`GhosttyScrollState.Snapshot.covered`), and the main thread corrects only
    from a snapshot of the cover it set. Otherwise a late snapshot takes the shift off twice,
    leaving the view rows up in the scrollback.
  - A pane laid out outside a window (the view a fold leaves) claims nothing; back in a window it
    lays out again. A layout that finds the claimed size while another request settles asks for
    the claimed size again, superseding it, so an in-between size is never sent.
  - Another client's size after our resize's echo but before the claim's answer (the echo comes
    first in the stream) counts as "Resized on another screen", as one after the answer does.
    Taken silently, the claim would answer "ours" over a wider server grid, and later layouts
    would send nothing: lines cut at the right edge.
- Mirror: never claims or resizes; shows the server's grid scaled to the view's width; drag pans.
  Users always get fit; mirror is only the `-sizing mirror` launch argument.
- Fit really resizes panes on the Mac. Test it only in `zz-` sessions you created.

## Gestures

- **Tap**: focus the pane, clear a selection, raise the keyboard on the first tap. A tap on a pane
  that is not active only makes it active and focuses it, as does every tap under VoiceOver.
  `TerminalTap.swift` has the order, `Ghostty/GhosttyTap.swift` the engine's part.
  - In a program that tracks the mouse the first tap on the active pane is also its click, as on
    a Mac terminal. The keyboard comes up once the server has taken the click, so the resize the
    keyboard can bring never passes it. A click that can't go (catching up, no connection, a
    scrollback row) is dropped and the keyboard comes up at once.
  - A click less than 0.45 s after the program was told it gained focus waits out the rest:
    programs drop a press that soon as the focusing click. The time runs from when that report
    left (a write of its own). The click waits in the input queue from the tap, so keys typed
    meanwhile go behind it; it is dropped if the stream caught up again, the pane left the front
    or the program stopped tracking the mouse. The keyboard after a click comes only while the
    pane is still front with no sheet over it, nothing else was done to it, and the answer came
    within 2 s.
  - A tap on a link (OSC 8 or a web address in the text) opens it every time, also on the first
    tap and with the keyboard down; the keyboard stays as it was. In a mouse-tracking program a
    link tap opens the link and sends no click (the phone's Cmd-click); a tap anywhere else is the
    click. A program that wants clicks on its own URLs loses them; a long press still selects.
  - On a focused pane a tap elsewhere moves the shell's cursor on its prompt.
  - A tap that catches moving scrollback, or within 0.15 s of it stopping, only stops it: no
    keyboard, link, Paste menu or click (`TerminalScrollTouch`).
  - A tapped link that can't open says why in a short notice (a malformed hyperlink, Safari
    refusing it, every failure under Ports); none fails silently.
- **Vertical drag** scrolls the scrollback (a native scroll view). On the alternate screen or when
  the program tracks the mouse it sends wheel reports, and arrow keys on the alternate screen with
  mode 1007 and no tracking. A drag into the scrollback with the software keyboard up puts the
  keyboard away, as the hide key does; nothing moves under the finger, and the covered rows come
  into view below. A tap brings the keyboard back.
- **Jump to bottom**: while the view is half a screen or more (at least 3 rows) into the
  scrollback, a small glass down-arrow button shows in the pane's bottom trailing corner, and goes
  within a row of the bottom (`JumpToBottomRule`). A tap only returns to the newest line (no
  keyboard, no focus). The arrow takes the cursor's color once output arrived below. None during
  a selection or pinch, or while the program takes drags (mouse tracking, the alternate screen).
- **Horizontal swipe**: next or previous pane, only for a drag at least twice as sideways as
  vertical that doesn't catch moving scrollback. Past the last pane it goes on to the session's
  next tab and before the first to the previous, wrapping (`TabNav.step`, `TabNav.wrapped`). A tab
  with one pane or with its splits laid out goes straight to the tab beside; a session with one
  tab bumps. The panes' area slides the swipe's way (crossfade with Reduce Motion), with the pane
  swipe's haptic. A paging tab shows its first pane going forward and its last going back, on the
  phone only: the Mac hears only the tab change. A tab with a float on screen, and the float
  sheet, keep to their own panes, bumping at either end. A swipe on the title bar is Next or
  Previous Tab, no wrap.
- **Two-finger tap**: zoom the pane (phone-only zoom, `PhoneState`).
- **Long press**: select a word (haptic, loupe), drag to extend; on release copy (copy-on-select,
  shimmer, confirming haptic), handles, and Copy / Paste / Select All. Double tap selects a word,
  triple tap a line. Mouse or trackpad drags select directly. [selection.md](selection.md).
- **Pinch** sets the text size in every state (`TerminalPinch`). The text scales under the
  fingers; on release the size is stored (`Prefs.fontSize`) and applied, and fit claims one new
  grid. On a pane resized elsewhere it also fits the pane here, as the chip does. Mirror draws the
  server's grid at the new size, still scaled to the width. No pinch starts during a selection
  drag. The canvas never zooms.
- **Split borders** on the unfolded Duo are draggable (`SplitGeometry`), with a detent at 50%; in
  book mode the border on the crease has no handle ([duo-layout.md](duo-layout.md), Book mode).
  A border drag only resizes, once on release: no pane becomes active, the keyboard stays. The
  border's touch area (44 pt) reaches over the panes beside it, as the sidebar's edge does; there
  a pane's taps and drags wait for the grip, which starts only on a drag across the strip
  (`HandleStrips`). Taps, long presses and drags along the strip are the pane's.
- A tab shows its splits as the Mac lays them out while every pane keeps 40×8 cells
  (`SplitGeometry.legible`); otherwise one pane at a time, with dots in the title bar and sideways
  swipes between panes.
- Resizing or toggling the sidebar changes the tab's frame once (on release, or after the slide),
  never per frame, so fit claims one new size ([duo-layout.md](duo-layout.md)).
- A width change (fold, unfold, rotation, resize) claims the new size and nothing else: the
  engine reflows as the server does, so nothing is read again.
- `TerminalHostPool` keeps each pane's `TerminalHost` alive while a fold swaps the view tree; the
  new `PaneView` takes the host over, so stream, screen and keyboard focus carry over. It also
  keeps the panes that left the screen last (Parking).

## Input

Every byte goes through `TerminalStream.send`. The rules follow from the server's
`com.superlogical.terminal.write` (API revision 14): one argument, `data`, a string; no sequence
number or idempotency key; and the server doesn't order block methods ("wait for the first
call's response before you send the second").

- **One request at a time, in order.** Typed text and key-bound server calls
  (`perform(action:)` → `client.action`, `forward(key:)` → `client.key`) share one queue. Text
  typed while a request is out goes together as the next write. An action waits for the text
  typed before it, and text after it waits for the action, at most 1.5 s (a Lua action can run
  for seconds).
- **A key typed at an idle queue leaves in its own turn.** With no request out, its write is
  handed to the control socket before `send` returns (`StreamLink.start`, `RexControl.start`): no
  task first, no wait for the rest of the main thread's turn. The item is marked in flight before
  the hand-off; its answer comes later through the same `finished` as every request. Everything
  else starts in a task: what waited behind a request, keys the fence held and what a reconnect
  releases, a retry, a key-bound server call, `sendOnce`, and text on a link that can't take it
  now (no connection, a simulated delay, a missing method; `call` then says why it never left).
- **Long text goes as several writes.** A request over the server's `limits.max_message_bytes`
  would close the control connection with 1009 (docs/rex-protocol.md, Message size). Text at the
  queue's front that one write can't carry (a paste) gives up its first piece and the rest stays
  first; each piece leaves once the previous was answered, and keys typed meanwhile join the rest
  (`TerminalStream.cutFront`). A write carries at most 64 KiB, request included, whatever the
  limit, so the control connection's pings never wait long behind one (`URLSessionWebSocketTask`
  sends a message whole, in one frame). Cuts fall between grapheme clusters (never inside an
  emoji, a flag, a letter with its accents or CR LF); a single cluster too long for a write is
  cut between scalars (`WriteChunks`). Only the last piece acknowledges its input for predicted
  echo. A connection lost mid-paste drops the rest, as for any write.
- **Held while offline.** Without a control connection nothing is sent; the queue waits. When
  `RexControl` is back it goes out in order once the stream has caught up, only if the screen it
  was typed at is still exact (The catch-up fence); otherwise it is dropped with the fence's
  notice.
- **Nothing leaves behind the fence.** The queue is not pumped while the fence is up.
- **Never sent twice.** A request that fails:
  - never left this client (no connection, or the socket didn't take it; `RexError.neverSent`):
    it stays first in the queue and goes when the connection is back;
  - was refused by the server (the pane closed): dropped;
  - was sent and the connection broke before the answer: nobody knows whether it ran. Sending
    `rm x⏎` again could run it twice, worse than a visible lost keystroke. It is dropped with
    everything queued behind it (typed assuming it arrived), with a notice ("The connection
    dropped while sending. Check the pane before typing that again.").
- **`stop()` and `park()` drop the queue**: a closed or left pane must not get old keys when
  opened again. `restart()` leaves it to the fence, whose new snapshot drops it.
- **UTF-8 only.** `data` is a JSON string, so invalid UTF-8 can't be typed. `send` drops such a
  call whole and returns false rather than type U+FFFD. In practice that is a legacy X10 mouse
  report beyond column 95 (the column is one raw byte ≥ 128). The mouse encoder uses the format
  the program asked for; programs that track wide screens ask for SGR (1006) or UTF-8 (1005).
- **Pixel reports are in the pane's pixels on the server.** A program that asked for SGR-Pixels
  (mode 1016) divides a report by the cell size it was told: the server pane's (8 x 16 on Rex),
  not the phone's. The stream keeps the newest one Rex sends (`TerminalStream.cellPixels`, from
  `terminal.size` and each `resize`), and the touch's place in cells, fractions included, is
  scaled to it (`PanePixelMap`), at any zoom and in any split. While the server doesn't say (an
  older server, or 0), the report is an SGR cell report. The phone never sends a cell size in
  `terminal.resize`: that would change how the program sizes images, on the Mac too.

Before the stream, on the main thread, the engine view keeps a shadow of the line being typed for
the keyboard (`GhosttyInputDocument`) and reports every change as `UITextInput` asks:
`selectionWillChange` and `textWillChange` before, `textDidChange` and `selectionDidChange`
after. The keyboard spends about 20 ms per key on the last two, so the send's place among these
calls decides how long a key waits:

- **One plain key is sent before the keyboard is told**: the two will-change calls, the shadow's
  edit, the send, the two did-change calls. A plain key (`GhosttyPlainInsertion`) is text from
  `insertText` that is one character (an emoji or wide character counts as one), typed at the
  program's cursor with nothing selected, no composition before or after it, not dictated, and
  leaving the shadow within its 4096 units. A hardware key that types and a letter after the key
  bar's one-shot ctrl or alt are plain keys too.
- **Everything else tells the keyboard first, then sends**: an input method's updates and commit,
  dictation, a replacement (`replace(_:withText:)`, over a selection or away from the program's
  cursor), several characters at once (a suggestion, a swipe, a keyboard paste), Backspace,
  Return, the key bar's printable keys (kept in the shadow; Typing aids, below), and keys that
  reset the shadow (other key bar keys, raw sends, a paste, hardware keys encoded here).
- **Dictated** means text from `insertDictationResult`, or from `insertText` while the input
  mode's `textInputMode?.primaryLanguage` is `dictation` (read once per mode, again after the
  mode changes or the keyboard comes or goes). Untested: what a real keyboard reports there while
  dictating. If it reports another language, one dictated character goes as a plain key; the
  bytes are the same, only the order differs.
- Both orders send the same way: the fence holds or drops it, a guess is drawn (Predicted echo)
  before it is queued, and an idle queue hands the write to the socket in the same turn, so a
  plain key is on the wire before the did-change calls begin. Both halves are needed: a send
  first but in a task waits for the turn to end; a hand-off in the turn after telling the
  keyboard still waits for the keyboard.

**Typing aids: corrections in an agent's prompt.** A terminal takes what is typed as is, so the
system keyboard's aids are off, except while an agent is the program in front, where people type
prose (`TypingAids`). Nothing to set.

| Trait | Agent | Everything else |
| --- | --- | --- |
| Autocorrection, spell checking | on | off |
| Capitals at a sentence's start | off | off |
| Smart quotes, smart dashes, smart insert and delete, inline predictions | off | off |

- **Which panes.** The foreground program is an agent (`AgentKind.fromProgram`), or, while `ssh`,
  `mosh` or a program the server can't name is in front, the agent's own OSC 7501 record says so.
  A shell in front is never one, whatever an agent left behind, and a title never counts (it
  outlives the agent; over `ssh` before its record arrives the pane types raw). A shell command
  the agent runs (`!ls` in Claude Code) runs under it, so the agent stays in front. The rule runs
  only when the program in front or the record changes (`TypingAidsWatch`), never per key.
- **Why only agents.** In a shell, editor or pager a correction is another command (`ls` →
  `last`, `npm` → `mom`).
- **Why no capitals.** The shadow is empty after every Return, so every line's first letter would
  be capitalized: `y` at an agent's question, a `j` in vim mode. Autocorrection still capitalizes
  `i` and names.
- **When the keyboard changes.** Either aid brings the suggestion bar (27 pt). Changed under a
  keyboard that is up (`reloadInputViews`), the keyboard snaps 27 pt through a frame without the
  key bar, moving the bar and resizing the panes on the computer. So the keyboard reads a pane's
  aids only as it comes up (from no keyboard, or from a hardware keyboard's quiet hold). A pane
  that takes the keyboard from another keeps that keyboard's aids, so switching between an agent
  and a shell moves nothing.
- **Until then the pane's own want holds corrections back.** A shell pane under an agent's
  keyboard makes no correction (the bar may still show one); an agent pane under a shell's
  keyboard corrects nothing until the keyboard next comes up.
- **How a correction is sent.** The keyboard replaces the word with `replace(_:withText:)` as the
  space, punctuation or Return after it comes, before that key's `insertText`: the word's
  Backspaces and the new word go as one write, then the key. A tapped suggestion and the period
  shortcut (double space) come the same way. No revert bubble (the view draws no underline); the
  bar shows the typed word in quotes, and a Backspace into the word offers it back.
- **Not corrected** (`TypingAids.keepsTyped`), whatever the keyboard offered: a word touching a
  code mark (`/`, `\`, `.`, `@`, `-`, `_`, `~`, `:`, `=`, `$`, `#`, a backtick, `*`, `<`, `>`,
  `|`; the keyboard would make `src/compnent.tsx`'s `tsx` `tax`), a word with digits or symbols,
  a line starting with `!` (a command for the agent), and text the shadow no longer holds (reset
  since the keyboard read it; its place is unknown). Nothing is sent and the keyboard is told the
  text changed, so it rereads. Dictation's revisions are made. A plain word (`npm`, `ls` alone)
  is the keyboard's call: the bar offers the correction first, and tapping the typed word keeps
  it. The key bar's printable keys (`/`, `-`, `~`, `|`) are shadow text, not a reset, so the
  keyboard sees `src/` before the next word.
- **The other gates apply.** A correction is a multi-character write, so predicted echo takes it
  as a boundary, and the fence holds or drops it whole.
- **Hardware keyboards** type through the same text system. iOS corrects their keys only under its
  own Hardware Keyboard setting, through `replace(_:withText:)` and the same rules.

Around that:

- Paste goes through the engine's `pasteText`, so programs that asked for bracketed paste get it.
- **Key bar** (`KeyBar`): three glass capsules above the keyboard.
  - **Left, fixed:** ⌘ opens the command palette (`RexCommand.goTo(.commands)`, as
    `client.palette.toggle`); ✎ opens or closes Compose (below), with a pill while open; the
    attach key (paperclip) opens the attach menu where the pane's computer takes files (Files).
  - **Middle:** the keys arranged in Settings → Keyboard (`KeyBarSetup`, below), then Shift-Return
    (⇧⏎, when shown) and Return, pinned past a hairline. They scroll sideways when they don't fit
    and fade over 18 pt at an edge with more keys past it; the fade's mask changes only when which
    edges fade changes. On a wide window (Duo unfolded, iPad) the capsule shows more keys and,
    when all fit, hugs them.
  - **Right, fixed:** the arrows key (✥, a trackpad) and the hide key. Beside the Duo's vertical
    bar the hide key is that bar's Hide Keyboard ([duo-layout.md](duo-layout.md), Key bar).
  - ctrl, option, shift and cmd: tap for one key, double-tap to lock. Shift applies to bar keys:
    ⇧⇥ is Shift-Tab; ⇧ with an arrow, Home, End, PgUp, PgDn, Delete or a function key is that
    key's shift chord (`KeyInput.bytes`); ⇧ Return is Shift-Return; a letter becomes its capital.
    The system keyboard has its own shift; a one-shot shift ends with any key.
  - Bytes are in `KeyBar.bytes(for:appCursor:)`: Backspace sends DEL (0x7f), Delete `CSI 3 ~`.
    Keys send on release; a sideways drag scrolls the middle capsule and cancels the key.
  - Keys are at least 40 pt wide, 2 pt apart, in capsules 6 pt apart and 6 pt from the sides.
  - Room for one key: the scrolling keys always keep at least 40 pt, or all their width when
    fewer (`KeyBarPlacement.tightening`). A bar short of that (a 375 pt iPhone with the attach
    key) takes it, in order, from the spaces between and beside the capsules (6 to 4 pt), then
    Shift-Return's margins (down to a 44 pt key), then the spaces down to 2 pt. No key gets
    narrower. A bar with the room (390 pt and up, the Duo, an iPad) gives up nothing. Below any
    iPhone's width (320 pt) with the attach key, the fixed keys stay whole and the scrolling keys
    get what is left.
- **Key bar setup** (`KeyBarSetup`, Settings → Keyboard): the middle capsule in three sections, in
  an order the user drags: **Primary** (esc, ctrl, option, shift, tab, then Shift-Tab and Command,
  hidden at first), **Shortcut Groups** and **Editing** (Backspace and Paste, then Delete, Home,
  End, Page Up, Page Down and the four arrows, hidden at first). A tap shows or hides a key, a
  drag moves it within its section; Reset Layout restores. Shift-Return is Editing's last row,
  shown at first: a tap shows or hides it, but it doesn't move, since it is pinned beside Return
  (Key bar Return, below).
  - Built-in groups: **Characters** (`~ | / - \ _ $ * . .. ? & :` and `1 2 3` for an agent's
    numbered menus), **Shortcuts** (^C ^D ^Z ^L ^R ^A ^E ^U ^W ^K, each named for what it does)
    and **Function Keys** (F1–F12). A group in the bar is one key opening a menu of its turned-on
    shortcuts; expanded, each is a key. Inside a group a tap toggles a shortcut and a drag
    reorders. Add Shortcut makes one: a label and either text, sent exactly as written (new lines
    included), or a key with ctrl, option and shift. Reset restores one group, Reset Shortcut
    Groups all.
  - The first setup is for agents: esc, ctrl, option, shift, tab, Characters expanded with
    `~ | / -`, Backspace, Paste.
  - A shortcut a bar key also sends (a character, a control letter, a function key, a plain named
    key) goes through that key's path with the bar's modifiers and cmd; other text is written as
    is, and another key as its chord with the bar's ctrl, option and shift added (`KeyStroke.bytes`,
    `pane.send_key`'s encoding). All through `TerminalStream.send` and the fence.
  - Stored in `Prefs` as versioned JSON (`keyBarSetup`), normalized on read: a missing key, section
    or group is added hidden, an unknown one dropped. Shift-Return is stored as Editing's last key;
    only its `shown` counts (`showsShiftReturn`).
  - Version 2 added Shift-Return (`KeyBarSetup.addingShiftReturn`): an older setup gets the key
    shown, nothing else changes, and `Prefs.upgradeKeyBarSetup` saves it as version 2 at once so a
    key the user hides stays hidden. A setup saved by a newer version is left as is.
  - Older installs stored a layout (`KeyBarLayout`, `Prefs.migrateKeyBar`). Once, the picked layout
    (Agents, Shell or Vim), a key list the removed editor saved (matched to its layout, or taken as
    is), or, on an install that ran with no choice saved, Agents, becomes a setup with the same
    keys (`KeyBarSetup.migrating`). Each key goes to its section in order; sections come in the
    order they first appear; characters and control keys become their group's shortcuts (group
    shown and expanded, the layout's ones on and first); a key no group has becomes its own
    shortcut. ✥, attach and Return have fixed places; Shift-Return is added shown. Only a fresh
    install starts on the first setup.

    | Layout | Primary | Shortcut Groups (expanded) | Editing |
    |---|---|---|---|
    | Agents | esc ⇧⇥ ⇥ ctrl cmd | Characters `/ 1 2 3`, Shortcuts ^C | ↑ ↓ Paste |
    | Shell | esc ⇥ ⇧⇥ ctrl option cmd | Shortcuts ^R ^C, Characters `\| ~ / -` | ↑ ↓ ← → Paste |
    | Vim | esc ctrl cmd | Characters `: / $ ~`, Shortcuts ^D ^U ^R ^W | PgUp PgDn Paste |

    Agents and Vim order their sections Primary, Shortcut Groups, Editing; Shell (arrows before
    its control keys) Primary, Editing, Shortcut Groups.
- **Key bar trackpad** (✥) takes a drag as the space bar's trackpad does on the iOS keyboard
  (`TrackpadEngage`). Nothing scrolls under it, so 10 pt of travel in any direction engages it,
  as does a still hold of 0.3 s (within 10 pt). Engaging plays the step tick and draws a
  cursor-colored ring; one arrow per 14 pt across or 18 pt up or down, from where the finger
  rested at the hold, or from touch-down for a drag. A tap sends nothing.
- **Key bar repeat**: arrows and PgUp/PgDn repeat while held, and stop once the finger moves more
  than 10 pt from touch-down or off the key (`RepeatSlop`). The release sends a tap's bytes if
  nothing repeated yet.
- **Keyboard room**: the root keeps clear of the keyboard's last reported frame
  ([duo-layout.md](duo-layout.md), Keyboard room) and, with the keyboard up, of the key bar's own
  top. The keyboard is sometimes reported last without its accessory (after an input-mode switch,
  ES/EN or emoji, or when a sheet, menu or the palette hands it back), which would put the typed
  line behind the bar. So the bar reports itself when it enters or leaves a window, is shown or
  hidden, or moves by a point or more (`KeyBar.frameChanged`), and `KeyboardInsetReader` reads its
  frame live and pads by the larger of the two (`KeyboardInset.padding(…keyBar:…)`). Only while
  the keyboard is shown or showing, and only for a bar in a window of this scene that the
  keyboard's top reaches and that sits above the root's bottom: hiding, the palette's or find's
  keyboard (no key bar) and a bar beside the root (Split View, the Duo's other side) leave the
  keyboard's frame in charge. An iPad's floating keyboard takes no room, but its key bar stays
  docked at the window's bottom, and the root keeps clear of it (`KeyboardInset.floats`). The
  padding is measured again 0.3 s after the keyboard's last frame change and on each input-mode
  change, unanimated and only if changed; the palette's hold (`PadHold`) ends with a fresh
  measure, not the kept value.
- **Key bar Return**: pinned at the end of the middle capsule past a hairline, in every setup (not
  part of it), so it never scrolls away. A tap sends CR, ESC CR with alt, CR with ctrl (Ctrl-M),
  and with cmd the `cmd+enter` binding; it never repeats. Held half a second (`KeyCap.holdDelay`,
  medium haptic) it sends Shift-Return through the engine's encoder as a hardware Shift-Return:
  `CSI 27;2;13~`, or `CSI 13;2u` under the Kitty protocol, which agents such as Claude Code take as
  a new line without sending; with cmd it runs `shift+cmd+enter`. VoiceOver offers it as the
  "Shift-Return" action.
- **Key bar Shift-Return** (⇧⏎, "Shift-Return" to VoiceOver): when shown, pinned right before
  Return past the same hairline; the scrolling keys get one key less. A tap sends what the held
  Return sends (`KeyBar.shiftReturn`). It never repeats; held, it is a slow tap.
- While an input method composes, Return (tap or hold) and ⇧⏎ type the composition as it stands
  and send nothing else, as the system keyboard's return does: sending Return would drop text not
  yet at the program. Under the agent board no bar key sends.
- **Key bar cmd**: ⌘ for the next key, as on a Mac keyboard; that key is never typed. A bar key
  (`KeyInput.press(barKey:mods:)`) or a key typed on the system keyboard (the engine view's
  `commandModifier` hands it to `commandKeyHook`; `KeyInput.press(typing:mods:)`) becomes the press
  a hardware keyboard reports for it, with ⌘, the bar's ctrl and alt, and shift where the US key
  needs it (`D`, `?`, `|`). `TerminalHost.keyBarShortcut` runs it through the hardware lookup
  (`KeymapStore.resolve(press:)`) and the same `perform`, so app commands, `pane.send_key`,
  `perform(action:)` and `forward(key:)` behave as for ⌘ on a keyboard. An unbound chord sends
  nothing and plays an error haptic. A held arrow or a trackpad drag runs the binding once, then
  again only if it repeats on a hardware keyboard.
- **Hardware keyboard**: the engine view's `keyHook` sees each press first. `KeymapStore` matches
  it against Rex's keymap (`KeyChord` spellings like `shift+cmd+d` or `cmd+[Digit1]`), and
  `AppAction` turns the binding into an app command, a key to send (`KeyInput.bytes`), a server
  action or a forwarded key. Unbound keys go to the engine's key encoder.
- A press is matched in tiers (`KeyInput.chordTiers`): what the key types and its position, then
  the character typed with shift (on a Spanish or German keyboard `/` is shift+7, so `cmd+/`
  arrives as shift+cmd+7), then the key's US name when what it types can't be spelled (`ñ`). A
  later tier never takes a key from a binding that names an earlier one.
- Option on a hardware keyboard is Alt (Meta) unless the layout needs it. If Option makes a
  printable ASCII character other than the key's own (`@ [ ] { } | \ ~ #`), that character is
  typed. Otherwise, on an English layout Option is always Alt, dead keys included. On other
  layouts a letter or digit key is Alt unless Option makes it a dead key, which composes (German
  and French Option+N, Space gives `~`); any other key types the layout's character.
  Option+Space, Option+Return, Option+Delete and Control+Option are always Alt. The layout's
  language comes from the keyboard's input mode.
- **Who has the keyboard** (`KeyboardFocusPolicy`): with a hardware keyboard the active pane's
  terminal is first responder, as on a Mac, and takes it back when it comes free (pane switch,
  fold, a text field done, the app active again). Never from a text field, under a sheet, or
  after the key bar's hide key. Without a hardware keyboard a pane only keeps what it had.
- The keymap's app commands are also menu shortcuts (`AppShortcutCommands`), so ⌘/ and the rest
  work with no terminal first responder (no tab open, keyboard put away). The menu replaces the
  system's Settings item, whose ⌘, would open the Settings app before the keymap sees it.

## Compose

The key bar's ✎ opens Compose for the pane: a glass card above the bar's capsules, with a grab
handle, a plain iOS text field, + at bottom left and ↑ (Send) at bottom right (`ComposeCard`,
`TerminalHost+Compose.swift`). For writing a whole message the iOS way: autocorrect, capitals,
selection, dictation and editing are the system's. Smart quotes and dashes are off, so commands
and paths stay as typed. Only a tap on ✎ opens it.

- **Empty text** says where the message goes (`ComposePlaceholder`): "Message", the agent by the
  name it goes by or else the program in front, and the pane's folder with home as ~ ("Message
  Claude Code ~/pteron"). Read when compose opens and when the field takes the keyboard.
- **Send** (↑, or ⌘Return on a hardware keyboard), enabled while the field has text, writes the
  message through the pane's one input queue (`TerminalStream.send`) as the program takes a
  paste: bracketed (`ESC [200~ … ESC [201~`) when it asked for bracketed paste (agents and modern
  shells do), so it arrives whole and the following Return is a Return; plain text otherwise.
  Return (CR) goes as its own write after the message's write was answered
  (`TerminalStream.send(_:thenAlone:)`), so a program reading a quick burst as a paste can't
  swallow it. Single-line text to a shell without bracketed paste is the text and CR. A message
  with a line end to a program without bracketed paste would run each line, so it is asked about
  first, as such a paste is (`PasteConfirmation`). An input method's composition is committed
  first. Emoji, CJK and long text (10,000 characters) go as one write of their UTF-8 bytes. The
  text is sent as typed, whatever the program shows (a permission prompt, a menu).
- **The catch-up fence** applies as to any key: the message and its Return are held together and
  go as one write only over an exact screen. If the fence drops them, the message returns to the
  field (if empty) and compose reopens with it, so it is never lost (`composeInputDropped`).
- **After a send** the field is empty and compose closes exactly as ✎ closes it: the terminal
  takes the keyboard back in the same key bar, no flicker, and the panes get one resize back to
  the keyboard-up grid. A send waiting for a paste confirmation closes compose only once it goes;
  declined, compose stays open with the draft.
- **Keyboard focus.** Opening compose gives the field the keyboard inside the key bar on screen,
  as find's accessory field does: the field gets the terminal's input view and the key bar as its
  accessory, so the keyboard doesn't go down or up. Closing gives it back the same way. While
  compose is open, whenever the pane's terminal takes the keyboard (a tap, the pane becoming
  active, a cover going), the field takes it back once the bar is shown (`refocusComposeSoon`).
  Every path that puts the keyboard away or hands it on (the hide key, Hide Keyboard in the
  vertical bar, a sheet, menu or agent board over the pane, another pane becoming active, find
  opening) first hands it to the terminal (`yieldComposeToTerminal`). Another pane takes the
  keyboard from a compose field as from a terminal (`KeyboardFocusPolicy.Holder.composeField`);
  app shortcuts don't run from it, as from any text field.
- **One keyboard height.** The field's keyboard has the suggestion bar (27 pt). While compose is
  open the terminal brings the keyboard up with the same aids (`TypingAids.prose`,
  `GhosttyTerminalView.composeOpen`), and a terminal taking the keyboard from the field keeps them
  until it next comes up (Typing aids), so handing it between the two never changes its height.
  The terminal's corrections still follow its own program.
- **Bar keys while the field has the keyboard.** A key that types text (a character, a text
  shortcut, with shift its capital), Backspace, and Paste with text on the pasteboard edit the
  message. Every other key goes to the pane: esc, tab, the arrows, Return, a control shortcut. A
  keyboard key typed with the bar's ctrl, option or cmd on goes to the pane too (ctrl then c
  interrupts).
- **+** opens the attach menu (Files). The server types the files' paths into the pane, so they
  arrive before the message that follows them.
- **Open until closed.** Compose stays open for its pane across tab and pane switches until a
  send, ✎ or the handle closes it. Each pane has its own (`ComposeSlot`), open or not, with its
  draft, kept in memory while the app runs in `TerminalHostPool`, so a parked or evicted pane
  keeps it. A draft stays with its pane's session or computer; a pane closing or a connection
  dropping does nothing to it.
- **Closing.** A send, ✎ again, or the handle dragged down. The handle is a 30 pt strip across the
  card's top (the compact card too), under the field's top edge but not under + or ↑
  (`ComposeDrag`). A drag starting there that goes down more than sideways is the handle's,
  however slow: the movement since touch-down decides and velocity only breaks a tie, because
  UIKit begins a pan only after about 10 pt and counts from there. A drag lower in the field is
  the field's; the field's scrolling waits for the handle's drag to fail. Released past 32 pt or
  on a flick down (700 pt/s), compose closes as ✎ closes it, draft kept; short of that the card
  settles back in 0.18 s. The card follows the finger; with Reduce Motion it stays put. VoiceOver:
  "Close Compose" (the handle), the field (labeled by its empty text), "Attach", "Send".
- **Size.** Fixed: 112 pt, or one 52 pt row (+, field, ↑) under a short window. Longer text
  scrolls inside, so writing resizes nothing. The key bar grows by the card and 8 pt, so the
  keyboard's frame includes the card: the root keeps clear of it (Keyboard room) and a fitted
  pane's last rows sit above it. Opening or closing changes that height once: the bar's height is
  flexible, and the responder showing it reloads its input views (`KeyBar.onHeightChange`). The
  panes end at the card's top, title bar unmoved. While Compose is open the card stays, as the key
  bar alone does, so a fitted grid fits above it; the room under the card is the keyboard's and
  is given back (`EnvironmentValues.composeRoom`, `PaneLayout.restCanvas`). Opening sends one
  resize to a grid the card's rows shorter, closing one back; the cover keeps the newest rows and
  the cursor above the card (Fit and mirror). With the keyboard down the card is down and the grid
  full. Where the card would leave fewer than three rows (`PaneLayout.composeMinRows`: a phone on
  its side with large text) the panes still end at its top but the grid keeps its size, covered
  as by the keyboard: a grid that short would show next to nothing on the Mac too. The agent
  board's software-keyboard test measures the card out (`TentModel.Input.softwareKeyboard`), so
  Compose over a hardware keyboard's key bar is still the key bar alone.
- **Postures.** The card spans the width the key bar's capsules may use: inside the safe area and
  short of the Duo's vertical bar. With a hardware keyboard the card and the bar show on their own
  at the bottom.

## Predicted echo

On a slow link a typed character shows at once, before the program's echo comes back, as mosh
does. Nothing sent changes: the guess is drawn over the grid, never written to the terminal, and
the program's output always wins. On a fast link there is no predictor and the key path is the
one without it.

**When it is on.** `EchoGate` (RexKit, one per server: its panes share one control connection)
keeps a smoothed round trip (α 1/8) of the `terminal.write` calls typing already makes, from the
write leaving to its answer. Nothing is sent to measure.

| Change | When |
| --- | --- |
| off → on | 5 samples since the last reset, and the smoothed round trip over 60 ms or two writes of 250 ms within 10 s. One spike does not turn it on. |
| on → slow | Over 80 ms, or a drawn guess still unconfirmed 300 ms after it was typed. |
| slow → on | 50 ms or less, the last 10 samples each under 250 ms. |
| → off | 40 ms or less with no spike in the last 10 samples. |
| reset to off | A new control connection, a change of route (`RexControl.observeRoute`). Every guess goes too. |

A pane shows more at once; it shows less (slow → on, → off) only once nothing is pending, so the
look never changes mid-word (`EchoPaneLevel`). 80 and 50 ms are mosh's marks; 60 and 40 are not
(mosh starts at 30) because the off path must cover a nearby computer on Wi-Fi, where an echo
lands within a few frames anyway.

**Where a key may be a guess.** Only at a shell's prompt, and every gate must agree:

- The stream classifies every input call (`EchoInputClassifier`): one printable ASCII byte or one
  Backspace can be a guess; everything else (Enter, control keys, escape sequences, a paste, a
  modified key, several characters, a report, an action) is a boundary that ends the line.
- The pane's gate on the main thread (`EchoHostGate`): a shell is in front
  (`EchoForeground.shells`), no agent runs in the pane (`BlockMeta.agentKind`), the fence is down,
  no composition, no selection, Find closed, the view at the bottom. Anything else makes the key
  a boundary. A pane whose program is unknown guesses nothing.
- The predictor on the feed queue (`EchoPredictor`), against the grid: the primary screen, the
  cursor visible, room ahead on the row.
- Proof that the program echoes. With OSC 133 marks, the prompt's `B` mark of the line being
  typed. Without them the line's first key is tracked, not drawn; once echoed, the tty's state is
  read (`terminal.input_mode`, one call per line, slow links only), and the rest of the line is
  drawn only if echo and canonical mode are both off with a local shell in front: a line editor
  reading a line. Echo off with canonical on is a password reader. Echo on proves nothing: it is
  the tty's resting state or a script reading keys, and echo can go off at any moment. No reading
  is asked when the program in front could prove nothing. Over `ssh` the reading describes the
  local client, so an `ssh` pane predicts only with OSC 133 marks from the remote shell.

So a password prompt (`sudo`, `read -s`), an editor, a pager, an agent's input box and anything
on the alternate screen draw no guess, typed ahead or not.

**Confirming.** mosh's rules. A line being guessed is an epoch. It starts only once every earlier
input is answered and 50 ms have passed, so guesses never build on output still on its way. A key
is confirmed only from the screen after its own write's answer, in typing order, never from a
grid that looks like the state before it. Only contrary screen content removes guesses: the whole
epoch's overlay goes in the frame that first draws the proof, with no notice. After wrong guesses
(30% or fewer of the last 24 judged keys right) lines are tracked undrawn until 60% are right
again. A late echo removes nothing, nor does Enter: while the prompt is not open no new key is
drawn, but what is on screen stays until confirmed. Guesses go at once when the program leaves
their screen (the alternate screen, a hidden cursor). A program's synchronized-output hold keeps
the guesses of its start with its rows; the catch-up hold of a returning pane draws none. A guess
unconfirmed 1.5 s after its write's answer is cleared silently (counted as `vanished` if drawn).
A resize, a reset, a restored snapshot, a theme, dropped output, a lost write, the fence, a park,
a stop and a reconnect clear every guess.

**Not watched, not trusted.** A park or stop, a new control connection, a restored snapshot, a
terminal reset and dropped output mean the screen was not watched being written: another program
may be in front. The proof goes with the guesses (`EchoPredictor.unprove`): no earlier
`input_mode` reading or `133;B` counts. A pane back from the park guesses nothing until the shell
announces a new prompt or, without OSC 133, a new line's first key was echoed and the tty read
again. A resize keeps the proof.

**Nothing is kept of a pane that is gone.** The stream holds its observers weakly, the core's
event handler and the gate's closures hold the host weakly, and the host's watch on the gate
(`EchoGateWatch`) leaves the gate however the host goes: closed, evicted from the park, or its
computer removed.

**How a guess looks.** The glyph the program will draw: same font and atlas, the colour and bold
of the typed cell to its left, else the theme's foreground. No background over a blank cell, so a
prompt's own background shows; a cell holding a character a pending Backspace removes gets a mask
in that cell's background. The cursor is drawn after the last guess, in the terminal's cursor
style. While the link is slow every unconfirmed character, spaces too, has a solid underline in
its own colour at half strength (full with Increase Contrast), lost in the frame that draws the
program's character. Nothing animates. VoiceOver reads the grid: confirmed text only.

- A program's own underline (a syntax highlighter's path style) looks like an unconfirmed
  character. Accepted.
- With an underline cursor the cursor sits in the cell after the trail at full strength.
- A prompt tap that moves the cursor with arrow keys goes at once while guesses are drawn,
  counted from the cursor on screen (`EchoPromptClick`): the engine's count plus pending keys on
  text the program has, the columns to the cursor on a guessed cell. Its arrows queue behind the
  typed keys. On a wrapped input line or a row with a wide character it counts from the program's
  cursor. A pending key that doesn't land as guessed leaves the cursor off by that much.
- Known limit: prompt marks are forgotten for a new program in front at the next key, not when
  the computer reports the change.

**Threads.** The main thread only hands on what it learned (a key's kind and number, a write's
answer, a clear), in order with the bytes; the predictor and its overlay live on the feed queue
(docs/ghostty-engine.md, Predicted echo). The host listens to its stream (`inputObserver`,
`writeObserver`) only while its gate is on; when the gate turns off with nothing pending, the
predictor retires and the host stops listening.

**Limits.** ASCII and Backspace only: no IME text, emoji, cursor keys or completion. No guess in
a row's last cells, on a wrapped line's next row, or beside a right-hand prompt the line reaches.
An agent still running after its status record is gone is kept out only by the other gates.

**Measuring and testing.** `-predict never|always` (Debug only) forces the gate; `-echoTest`
reports `predictedMs` and the counters; the benchmark's `predict` scenario plays a recorded
typing session on a scripted link (docs/debug-args.md, docs/ghostty-engine.md, Measurements).
Recorded real-shell sessions (`PteronTests/Fixtures/echo`, from `scripts/record-echo-fixtures.py`)
run through the real core in `EchoScriptTests`.

## Find

Find in Pane, as on the Rex Mac app: type a needle, every match on screen is tinted, the current
one stands out, and Next and Previous step through the pane's screen and history.

- **Where it searches.** The pane's own terminal, with libghostty-vt's search
  (`GhosttyCore+Find.swift`; [ghostty-api-notes.md](ghostty-api-notes.md), Search). No server
  call: the phone holds the newest 10,000 lines, and an older match has no row to show. Matching
  is the library's: byte for byte, ASCII letters folded (no regex, no case option, as on the
  Mac). The needle is the field's first line, NFC, at most 1 KB (`FindQuery`). With the history at
  its cap and nothing found, the count says "No matches in recent history".
- **Opening.** ⌘F (the keymap's `client.find.open`), "Find…" in the pane menu's section above
  Close (key text from the keymap, `KeyLabel`, hidden when nothing runs it), "Find Selection" in
  the edit menu (a one-row selection of at most 200 bytes), or another client performing
  `client.find.open`. The field starts with the last needle used in any pane, selected.
- **Keys.** Return and ⌘G: next (older, `chevron.up`); ⇧Return and ⇧⌘G: previous (newer,
  `chevron.down`). With find closed ⌘G and ⇧⌘G do nothing. Escape with text gives the keyboard to
  the terminal; with none it closes. Return and Escape belong to an input method while it
  composes. While the field edits, only app commands and the find keys stay with the pane (an
  allowlist, `FindKeys`): ⌘V, ⌘A, arrows and Delete with any modifier edit the field. ⌘W closes the
  pane, as on the Mac.
- **Two bars, one model.** `FindAccessoryBar` sits in the keyboard's accessory slot (the key bar's
  height function, so the keyboard keeps its frame) and holds the keyboard while the system
  keyboard or the key bar shows. `FindOverlayBar` floats in the pane (bottom; top on the alternate
  screen, below the status chip) whenever the field isn't in the accessory slot, and holds the
  keyboard when the terminal held it quietly (after the hide key, with a hardware keyboard). No
  view moves between the keyboard's window and the pane.
- **The hand-over** (checked on the Duo). Terminal to field: the terminal shows the find bar in
  its accessory slot (`reloadInputViews`); once the bar is in the keyboard's window its field
  becomes first responder with the terminal's input views, and the key bar is the terminal's
  accessory again at once, without a reload. Field to terminal: the terminal takes the keyboard
  back as panes do; one more reload of the same views a turn later restores the 2 pt the window is
  otherwise off by. With the keyboard down (no hardware keyboard) it rises as for a tap.
  `FindHandover.shipped` is the one switch to the fallback (the floating field with an empty
  accessory of the key bar's height, `FindSpacer`).
- **No resize.** The keyboard's frame is the same before and after every hand-over (a rise and a
  fall when it was down). Fit's grid while the field holds a rising keyboard is the newest one
  asked for (`FitClaim.wanted`, the *fit hold*), taken before the keyboard moves and released at
  once when the field stops editing, find closes, the font, width or sizing changes, or the pane
  is lost. While another surface holds the layout (the Go To palette, `FitHoldDeferral`) the
  release waits until it clears. A layout that finds the claimed size while another request
  settles asks for it again, superseding it (Fit and mirror).
- **Tints.** Every match: the theme's yellow at 30%. The current one: opaque bright yellow, text
  black or white by contrast (at least 4.5:1 on every theme), on its first four rows. Drawn
  between the backgrounds and the cursor, so a block cursor and underlines stay on top
  ([ghostty-engine.md](ghostty-engine.md), From bytes to a frame).
- **Scrolling.** A step scrolls only when the match isn't in view, putting its first row a third
  of the way down (`.reveal`). The bottom bar's height counts like the keyboard's cover for the
  last rows (`setFindInset`) but never as reading: a drag under it doesn't hide the keyboard. The
  jump-to-bottom button sits above it. On the alternate screen under the hold the keyboard hides
  the program's bottom rows, and a match there lifts the grid until the next step.
- **Focus.** The pane's own field holding the keyboard counts as the pane holding it: no reclaim
  takes it. Another pane becoming active takes it (the bar stays open there). A sheet, menu or the
  agent board takes it as from the terminal and gives it back. A fold gives the floating field its
  keyboard back.
- **Compatibility.** Local only: no method, event or capability. Keys and label come from each
  pane's server keymap, and from `KeyDefaults` (⌘F, ⌘G, ⇧⌘G) where `client.keymap` fails (any
  revision). Copy-mode actions (`pane.copy_mode.*`) stay unbound on the phone.

## Files

A pane takes files as the Rex Mac app's terminal takes a dropped file: they are copied to the
pane's computer and the server types their paths into the pane as if pasted. Enter is never sent,
so it works in a shell and in an agent alike. Open brings a file the terminal names to the phone,
and the file browser lists the folders of the pane's computer. Wire rules:
[rex-protocol.md](rex-protocol.md), The fs block, Folders and Files.

- **Sending.** The attach key (paperclip) sits in the key bar's left capsule after ⌘ and ✎, so it
  never scrolls away; Compose's + opens the same menu. One short list, no titles, subtitles or
  switches: Paste Image or Paste File (when the clipboard has one), Photos, Camera (where the
  device has one) and Files, then, after a divider, "Files on <computer>" with Browse Files… and
  Insert Path… (Browse). The send's progress and result name where the files go: the agent
  working in the pane (OSC 7501), else the computer ("Sent Photo… to Claude"). The same rows are
  under Attach in the pane menu right after Share (subtitle "or 📎 on the key bar"), for a pane
  whose keyboard is down (`AttachMenuItem`, from `PaneFiles.sections`). Close Pane and Close Tab
  stay last.
  - Paste, the paste key, ⌘V and the edit menu's Paste paste text whenever the clipboard has
    text; they send an image or files only from a clipboard with no text at all
    (`ClipboardChoice`). The edit menu also offers Paste Image (Paste File for copied files)
    whenever the clipboard has one and the host takes uploads, even with text; deciding checks
    the clipboard's types only, and the content is read when the row is picked.
  - The palette finds Insert Photo…, Insert File…, Browse Files… and Insert Path… by image, photo,
    picture, screenshot, attach, upload, file and send.
  - Images, movies and files dragged in from another app can be dropped on a pane (`PaneDrop`);
    a drag of text or a link is refused (never sent as a `.txt`), and the app's own drags, such
    as a selection, are left alone. Nothing is sent without one of these actions.
- **One batch.** One action's files go as one `upload_begin` batch, a single file included, one
  file at a time, each with a ticket asked for just before its connection (`FileUploader`,
  RexKit). The server types all the paths together, in order, escaped, once the last file
  arrived. A notice shows progress with Cancel, then the result. A connection lost before the
  last file went out whole resends the batch from the start under a new ID, at most twice (the
  server deleted the aborted batch and can't resume). Once the last file's end has gone out the
  server may type at any moment, so nothing is resent and Cancel no longer applies; a lost
  confirmation then says to check the pane.
- **Cancel** cuts off the file on its way; the server deletes the batch's earlier files and types
  nothing. Between files, when the server may hold finished files and nothing is on its way, the
  next file is reserved and cut off at once to the same effect (`FileUploader.abort`).
- **Folders and several items** (`SendRoute`, `FileSender.sendTree`). Where the pane's computer
  has an fs block (Rex at revision 24, the pane on the computer's own host, not Windows), a
  folder, two or more items, or a file over 100 MiB go as one archive in one stream; a single
  file goes as above. Files offers folders beside files and reads what is picked in place, under
  its security scope, so a large folder is never copied first; a dropped or pasted folder is the
  system's copy. Without an fs block the picker offers files only and a dropped folder is refused
  ("Couldn't read what was dropped.").
  - **Where they land.** A new folder, `/tmp/pteron-<12 hex>` (mode 0700), made by the upload, so
    nothing there is ever replaced and no question is needed. The server places the archive only
    once all of it arrived: a cancel, lost stream or refused archive leaves nothing. The folder
    stays until the computer clears `/tmp`.
  - **The paths.** The server types nothing for an fs upload: once it confirms, the app writes the
    items' absolute paths into the pane as Insert Path does (`PathInsert`: escaped for a shell,
    as is for an agent, "Insert anyway?" for another program), with a space and never Enter.
    Where Insert isn't offered (ssh and the like in front) nothing is written, and the notice
    offers Copy Path.
  - **Before it goes.** The walk counting `roots`, `entries` and `size` runs off the main thread,
    with "Preparing …" and Cancel; a file-provider item is read through a file coordinator first,
    which downloads a cloud-only folder. Links are never followed: a link inside a chosen folder
    goes as a link when its target is relative and stays inside that folder; any other link, a
    chosen link, and sockets or FIFOs are left out, and the result says how many. The cellular
    question covers the whole archive. Too little room on the computer (Rex wants the size and
    2 GiB to spare) is said before anything goes.
  - **On the way.** The archive is read and framed as it goes, at most 64 KiB at a time, off the
    main thread; the main thread takes a pacing turn per 128 KiB (`UploadPacer`, same rate and
    window as single files) and shows whole percents. A file that changes size while read stops
    the send ("… changed while it was read"); a lost stream starts over, at most twice; after the
    end has gone out a lost confirmation says to check the pane.
  - **While the server places it.** The server takes the archive far faster than it writes the
    entries (about 210 a second on an M-series Mac) and shows no sign of that work
    (rex-protocol.md, The fs block). So the confirmation wait scales with the plan
    (`FsUploader.confirmWait`: 60 s, plus 50 ms an entry and 8 MiB of content a second, a server
    ten times slower than probed), and the percent is the lesser of bytes sent and entries likely
    placed at 200 a second (`FsUploader.shown`), stopping at 99% until the server confirms.
    Cancel applies throughout. Out of background time the send stops ("stopped in the
    background", Try Again), and the fs block's close leaves nothing.
  - **Cancel frees the sender at once.** `FsUploader.cancel` ends the send wherever it waits (the
    start's answer, the handshake, the pause before a retry, the stream, the confirmation), says
    "Didn't send what." and lets the next send start on a block of its own while the cancelled
    one's block closes behind it. Whatever that task does later (a late start answer, whose ticket
    is never used; a late data connection, which is closed; the close's end) shows nothing and
    types no path. After the end has gone out, closing the data connection doesn't stop the
    server's placing but the fs block's close does, leaving nothing; only a server that finished
    before the close leaves the whole folder in `/tmp/pteron-<12 hex>`, with no path typed. The
    next send's progress replaces the note.
  - **The fs block.** One per transfer, made in the pane's session (`session.new_block`) and
    closed when the transfer ends; detached, in no view. Rex never removes one, so each is
    remembered (`TreeBlocks`) and the next sync closes any a killed app left, as the ports' sweep
    does for tunnels.
- **Pacing** (`UploadPacer`, RexKit). A socket's send returns once the system has the bytes, so an
  unpaced file fills the uplink queue at once and the control connection's pings, calls and keys
  wait behind it, past every wake ping's 2.5 s. So messages go at a rate set from the control
  connection's ping round trip, as LEDBAT does: the queue the upload adds is kept near 100 ms, and
  messages shrink to about 100 ms of the rate (at least 8 KiB). On a fast network the rate climbs
  past what the link takes within a few round trips. On top, a window: at most 256 KiB handed to
  the socket beyond what an answered control ping vouches for, so the network never gets a
  burst. On an iPhone a burst queues inside the Tailscale extension, which iOS kills past about
  50 MB, losing the tunnel for 30 to 60 s (tailscale/tailscale#17967). The upload's own socket
  can't confirm bytes (Rex answers a ping there only after the file ended). The pacing ping
  (`RexControl.paceProbe`) is its own ping and only measures: no pong within the pong deadline
  (10 s, 20 s on cellular) is a slow sample and halves the rate; it never drops the host. In the
  background or on a lost connection its wait ends with no sample. No control connection, or no
  answer in 5 s, leaves the rate alone in charge: never a stall.
- **Where files land**: the server's uploads folder, readable by the shell and any agent in the
  pane, deleted when the pane closes (rex-protocol.md, Files, Landing folder).
- **Names** (`UploadName`). One path component, NFC, at most 200 bytes with the extension kept,
  without control characters, bidi embeddings, overrides and isolates (U+202A–202E,
  U+2066–2069) or the zero-width space. The zero-width joiner and non-joiner stay (emoji,
  Persian). A nameless photo gets `Photo 2026-11-17 17.31.jpg`, a pasted image `Pasted Image …`.
- **Photos** (`ImagePrep`): fixed values for the agents that read them (Claude Code, Codex: JPEG,
  PNG, GIF, WebP, no HEIC) and for the tunnel. Photos, camera, pastes and drops are prepared
  alike, with no switch. A screenshot (a PNG, or EXIF "Screenshot") stays PNG at full size up to
  3,000 px on its long side, the most Claude takes once a conversation holds more than 20 images,
  so its text stays crisp. A photo becomes JPEG at 0.85, at most 2,048 px on its long side:
  Claude reads at most 2,576 px and 4,784 patches of 28 px, GPT-5.5 at most 2,048 px, so more
  pixels would be thrown away. HEIC, HEIF and every other still format are converted (PNG where
  there is transparency). A prepared image is about 5 MB at most (lower JPEG qualities, then a
  smaller PNG). Scaling uses ImageIO thumbnails off the main thread with the EXIF orientation
  applied; location and other metadata are always left out. A small upright JPEG or PNG is copied
  without decoding. It fails closed: each copy is checked for GPS, IPTC and XMP place names; one
  that can't be stripped is drawn again, and one that can't be drawn either is sent only after
  "Couldn't remove location. Send anyway?". Live Photos send the still; videos, moving GIFs and
  files picked in Files go as they are (Files sends a photo's exact bytes).
- **Limits.** Files up to 100 MiB (`too_large`); larger is refused before anything is sent. On an
  expensive network (cellular, a hotspot) a send over 25 MB asks first; a second send meanwhile
  is turned away with a notice. A send keeps running briefly in the background; cut off, its
  notice offers Retry.
- **Typing during a send.** The server types the paths itself, outside the input queue, so keys
  typed while a batch is on its way land first. The app never sends keys for the paths; the
  progress notice is the cue to wait.
- **Support.** `upload_begin`, `download_begin` and `list_dir` are each known per host
  (`ServerConnection.fileSupport`; [rex-protocol.md](rex-protocol.md), Folders): two panes of one
  tab can differ when one is on a remote host with an older Rex. The attach key shows where the
  host takes uploads or lists folders. Sending rows, Paste Image, drops and the two insert keys
  need `upload_begin`; Open, Preview, Share and Save need `download_begin`; the browser and Insert
  Path need `list_dir`. Without a method its rows are absent, silently; a host with none shows no
  attach key.
- **Open.** When a small selection (at most 4 rows and about 1 KB, all in view, checked before
  its text is read) reads as a path (`PathGuess`: absolute, `~`, relative, or a name with an
  extension; shell escapes and quotes undone, `:line:column` dropped, a wrapped path joined), the
  edit menu offers Open. It downloads with `download_begin` (relative to the foreground process's
  directory) into the app's temporary folder, with progress in 1% steps and Cancel, up to 100 MB,
  writing off the main thread, and shows Quick Look (Share, Save to Files). The copy is deleted
  when Quick Look goes, so nothing is left when the pane closes or the app backgrounds. Not
  found, a folder, a device and an unreadable file each get a plain message.
- **Folder download.** With an fs block, a folder's long press in the browser also has Share… and
  Save to Files…. The folder comes as one archive (`FsDownloader`, RexKit; the path taken
  literally, never as a pattern), written into the app's `tmp/Incoming` as it arrives, off the
  main thread, in pieces of at most 64 KiB, never held whole; progress in whole percents with
  Cancel. Save to Files then moves it to the picked folder (moved, so a large folder needs its
  room on the phone once) and the share sheet gets it as a folder. The phone's room is checked
  first (the size and 200 MB to spare). Links are left out and said so; an entry with `..` or an
  absolute path stops the download as unsafe. A cancel, lost stream or early-ending archive
  deletes what arrived (no half folder) and offers Try Again where it can help.
  - **Cancel frees the browser at once.** The server answers `download_begin` only after walking
    the whole folder (seconds for a large one) and holds the fs block's `block.close` until then.
    So Cancel waits for neither: `FsDownloader.cancel` ends the download wherever it waits (the
    begin, the handshake, the archive), says "Didn't save name." and lets the next Save or Share
    start on a block of its own while the cancelled one's closes behind it. Whatever that task
    does later (the walk's late answer, by then `not_found` with no ticket; a late data
    connection, closed; the close's end) shows nothing and hands no sheet on. The next download's
    progress replaces the note.
- **Browse.** "Browse Files…" (the attach menu's "Files on <computer>", and the palette's commands
  with Insert Path…, Insert File… and Insert Photo…; [goto.md](goto.md)) opens a sheet over the
  pane at the folder the pane's program is in (`PaneBrowser`, `BrowserModel`): folders first,
  Finder's name order, hidden files out until "Show Hidden Files" in the title's menu (⇧⌘.),
  which also has the parent folders, Home and Copy Path.
  - A tap opens a folder or previews a file in Quick Look, by Open's download; a file with no
    extension that reads as text, up to 1 MB, shows as text (`TextHint`). A long press offers
    Preview, Insert Path, Copy Path, Share… and Save to Files…, which keep the file's own name.
  - The download's notice ("Saving name · 23%" with Cancel) and any error show on the browser,
    under its title and filter, not under the sheet (`noticeHost`;
    [notifications.md](notifications.md), Notices). It stays at 100% while the system's Share or
    Save sheet loads and goes once that sheet is in; Cancel meanwhile takes the sheet back and
    deletes the copy.
  - The filter matches anywhere in a name; one starting with `/` or `~` is a path, and Return goes
    there. A folder over 2,000 entries says "Showing the first N. Search to find others.", and its
    filter also asks the server for names starting with the text, 250 ms after the last key.
  - Each folder keeps its listing while the sheet is up; pull-down lists it again, as does a
    return from the background. Open on a selected folder path opens the browser there. Hardware
    keys: ↑ ↓ move, Return opens, Space previews, ⌘↑ goes up, ⌘↓ opens, Esc closes.
  - A listing is parsed, sorted and filtered off the main thread, newest request winning; the main
    thread only swaps rows in. Rows are a lazy stack identified by position, so a filter keystroke
    updates the rows on screen in place.
  - One line and at most one button for each state: an empty folder, "Only hidden files here."
    (Show Hidden Files), a folder Rex may not read (on macOS under Desktop, Documents or Downloads,
    with where to allow it) or that is gone (Go Up), a lost connection (Retry; it relists by
    itself when the connection is back). If a reconnect lands on a server without `list_dir`, or
    the pane closes, the listing stays to read under a line, nothing in it opens or inserts, and
    nothing is sent.
- **Insert Path.** "Insert Path…" opens the browser in insert mode: a tap on a file writes its path
  into the pane and closes the sheet, the bottom button inserts the folder on screen, and "Recent"
  lists the last 8 paths inserted on that server and host. What is written, and whether, is
  decided by `PathInsert` from the foreground program's name and bracketed paste only, never from
  a title, a status record or a reported directory:
  - `ssh`, `mosh`, `tmux`, `screen`, a container tool and the like in front: Insert isn't offered,
    and the browser says whose files it shows (`ProcessNames.remoteWrappers`).
  - A shell (`sh bash zsh fish dash ksh mksh`): escaped for a shell (`ShellEscape`, RexKit: a
    backslash before each character a shell reads as syntax, every `~` but a leading `~/`, and a
    leading `=`). A macOS test reads escaped names back through zsh (plain, `extendedglob`,
    `equals`, `magicequalsubst`), bash, bash `--posix`, dash, ksh and sh, and fish where installed.
  - An agent by program name, or any program that asked for bracketed paste: the path as is.
  - Anything else: "htop isn't taking text. Insert anyway?", then the path as is.
  - The path is relative to the program's folder when under it (`./-x` for a name starting with a
    dash), `~/…` under home, absolute otherwise, then a space. Never Enter. A name with a control
    character or direction mark isn't inserted. Scalars go out as listed, unnormalized, through
    `TerminalHost.paste` (bracketed where asked). A Windows server has Browse only.
  - Known limits: a cursor inside an open quote gets the escaped text literally; under `sudo -s`,
    `~/` means root's home.
- **Keys.** The Mac's `pane.go_to_directory` (browse), `pane.insert_path`, `pane.insert_file` (the
  Files picker) and `pane.insert_photo` (the Photos picker) are declared with the Mac's titles and
  default keys (⌃⌘I for Insert Path; the others none, and the Mac's ⇧⌘G stays Find Previous
  here), so an init.lua binding does on the phone what it does on the Mac where the host has the
  method, and nothing elsewhere. They are pane actions (`AppAction.files`, `FilesCommand`): they
  run while a terminal has the keyboard, not from the find field.
- **The keyboard** goes back when the browser closes to whoever held it: the terminal shown or
  quiet, nobody, or the pane's find field (`KeyboardRecord`). With a hardware keyboard the sheet
  makes the key bar leave, as the Settings sheet does.
- **Temporary copies** live in the app's `tmp/Outgoing` and `tmp/Incoming` (downloaded folders
  too); a finished send or closed preview removes its own, and launch removes the rest.
- `-filesTest` drives all of this in the simulator, which can't tap through a picker
  ([debug-args.md](debug-args.md)). Debug builds log the SHA-256 of each file sent (`FILES_SENT`)
  and opened (`FILES_OPENED`), to check against the computer's copy.

## Share

A pane's output goes to the share sheet, as text or as a styled HTML file in the theme's colors
(`Features/Files/ShareOutput.swift`). Nothing new shows on a pane, and nothing runs until a Share
item is chosen.

- **Where.** "Share…" is last in the selection's edit menu, after Select All, on any non-empty
  selection: the selection as plain text, as Copy takes it. "Share ▸" sits in the pane menu after
  Find…: one submenu, sections Plain and Styled, each with Screen and All Output. Screen is the
  viewport as drawn (scrolled rows and rows under the keyboard included), one line per row. All
  Output is the screen and scrollback as the server holds it (the active screen for a
  full-screen program).
- **Sources.** The selection and the screen come from the pane's own terminal through the
  libghostty-vt formatter (`GhosttyCore.format(scope:emit:)`) in one `termLock` section, so only
  that pane's parsing waits. The selection is formatted at the tap, so clearing it a moment later
  changes nothing; the screen on a detached task. Both work offline and on any server. All Output
  asks the server: `terminal.format` (`text` with `trim` and `unwrap`, or `html`) with
  `max_bytes`, then `blob_read` with the same `id` until `eof` or `total` (rex-protocol.md,
  Share's All Output).
- **Chunks** (`ChunkSizer`). The first request is 64 KiB; each later one is sized to take about
  100 ms at the previous throughput, between 64 and 256 KiB. One request is out at a time, and
  before each the reader waits while any pane on that server has typed input on its way
  (`TerminalStream.hasPendingInput`, gathered in `RexControl.inputActivity`; observed, not
  polled). A stream leaves that count when it stops or goes. A dropped connection ends the wait,
  and the read checks the connection before and after it, so a drop with input queued ends the
  read at once. A keystroke's reply waits behind at most one chunk: about 100 ms, up to about
  250 ms at 2 Mbps. The reconnect `readScreen` uses 900 KB chunks.
- **Retry and connections.** A `not_found` mid-read (a concurrent `format` evicted the id, or it
  expired) restarts the read once with a new `format`. A second one, a lost connection, or a new
  connection (`connectionSerial`; the id belongs to the old one) ends the read, deletes its folder
  and shows "Couldn't read the output." with Retry, or "The pane has closed." when it is gone.
  `method_not_found` ends it without Retry and hides All Output on that connection.
- **Styled.** The document (`ShareHTML`) puts a Content Security Policy right after
  `<meta charset>` (`default-src 'none'; style-src 'unsafe-inline'; form-action 'none';
  base-uri 'none'`), the theme's 256 colors as `--vt-palette-N` custom properties marked
  `!important` (server HTML has no palette, and the local formatter's palette block loses to
  them), the theme's background and foreground over the wrapper's inline defaults, and Menlo
  (`ui-monospace`) over the wrapper's inline `monospace`, which iOS draws in Courier. Colors are
  `#rrggbb` from components clamped to 0...1. RGB colors programs set stay; a cell the server
  writes with an explicit hex of the computer's default colors keeps it. Inverse video comes as
  `filter: invert(100%)` on a run with no background, which would flip only the text to a color
  near the page's; such a run gets the theme's background, so both flip.
- **Links** (`LinkSanitizer`). Each `href` is decoded once as a browser does, tabs and line breaks
  removed, C0 controls and spaces trimmed at its ends, and kept only if it starts with `http:`,
  `https:` or `mailto:` in any case; otherwise the attribute goes and the text stays. The
  formatter escapes `<` and `>` in text and attributes, so a chunk holds back from its last `<`
  without a `>` and a split tag comes out whole. Non-ASCII URLs arrive as Latin-1 byte entities
  and stay so.
- **Forms and files.** Plain text up to 256 KiB goes as text; above that, and every styled share,
  as a file `<Tab title> <yyyy-MM-dd HH.mm>.txt|html` in its own folder under `tmp/Shared`,
  deleted when the sheet goes and swept at launch. Files are written off the main thread
  (`ShareFile`), styled ones through the link cleaning.
- **Limits.** All Output text over 32 MiB keeps the newest 32 MiB (`TextCap`): it reads from
  `total - 32 MiB`, drops the U+FFFD the server sends for each byte of a character the offset cut
  through, starts after the first line break (or at the first whole character) and begins with
  `[Earlier output not included: N MB]`. Styled output over 8 MiB is refused from the first
  reply's `total`, before reading on: "Too much output to share styled." offers Share Plain.
  Without a `total` in the first reply, the first `blob_read`'s total, else the bytes read so
  far, decide. On an expensive network a read over 25 MB asks first.
- **Progress** (`Notice` job lane). A read of more than one chunk shows "Reading the output · N%"
  with Cancel in the notice's job lane: a plain notice meanwhile shows its full time, then the
  progress and Cancel return, and a transfer's progress (`showProgress`) never replaces a plain
  notice that is up. One job at a time: a second share waits for the first to end or be
  cancelled. Cancel deletes the folder.
- **In the background.** An All Output read runs inside a `BackgroundTask`. When time runs out the
  read stops, the folder is deleted, the lane clears and no sheet follows; nothing resumes on
  return. A read that finishes in the background keeps its file and presents the sheet on return
  if the pane still exists.
- **Offline.** Selection and Screen work. All Output says "Needs a connection to the computer."
  and its rows stay, so the menu keeps its shape. Empty output or selection: "Nothing to share."
- **The sheet** comes from the topmost controller, always with a popover source (an iPad and
  `-simulateDuo` make it a popover): the edit menu's target for a selection, the pane's
  top-trailing corner under the title bar's menu, or the middle of the window's edge facing away
  from the system's vertical bar (`ShareAnchor`). It carries the tab's title as subject and
  header. The selection is formatted first and cleared once the sheet is up.
- **Compatibility.** Selection and Screen need no server method. All Output needs `format` and
  `blob_read` (both at revision 13 and below); its rows hide only when the pane's creator on its
  host is known to lack one, or a read on this connection found one missing.

## Arrange

The Mac's pane commands, in the pane menu and on the keymap's keys
(`Features/Tab/PaneArrange.swift`, `PaneMenuItems.swift`, `State/ServerConnection+Panes.swift`).
Nothing new shows on a pane.

- **Where.** The pane menu's middle section is Find…, Share ▸, Attach ▸, Arrange ▸ and Ports, in
  that order. "Arrange ▸" shows on a tab with two or more panes: one submenu of inline titled
  sections, Swap With (the other panes), Move to Tab (the session's other tabs, then New Tab),
  Balance Splits, and Close Other Panes… in a destructive section of its own. Floating Windows is
  a separate pane-menu section while the tab has a float (Floating windows, below). No shortcut
  text and no `.keyboardShortcut`: the keymap stays the only key dispatch.
- **Names.** A pane is named by its label when someone gave one (on the Mac, from the CLI or a
  layout; not `shell` or `Block 89abcdef`), else its agent, else its program, else "Pane N" by
  place (`PaneName.menu`). Never its title, which an agent's spinner changes ten times a second:
  the names' parts live in their own per-block table (`ServerConnection.paneNames`), written only
  when the agent or program changes and read only by `PaneMenuItems`, so a spinning title
  rebuilds neither the menu nor the tab screen. Two panes of the same name say "Pane N" too. A
  tab is its label, else "Tab N", with the name of the pane a moved pane goes beside. Labels never
  become titles; there is no Rename Pane.
- **Which panes.** The tiled panes in reading order, then the floats' panes, front first, the
  minimized last. Every such list and count reads `PaneScope.arrangeable(window:)`.
- **Swap With** is `session.swap_blocks`. The pane on screen stays the one shown; with one pane at
  a time only the dots move. A minimized float's pane isn't listed: the swapped-in pane would
  vanish with it.
- **Move to Tab** is `session.move_block` beside the target tab's focused tiled pane (else its
  first), along its longer side, so a pane doesn't land in a floating layer while the tab has a
  tiled one; a tab of floats only takes it beside its focused (else front) float (`MoveAnchor`).
  When the call returns the session's view is read at once (`reloadView`, no 80 ms wait) and the
  target tab opens in the same update as the layout holding the pane, so its terminal, stream and
  fit claim carry over (well inside `scheduleStop`'s 0.5 s). If no view shows it there within 2 s
  the tab stays; if this tab is gone too, "Moved the pane to <tab>." with Open. A full target:
  "That tab can't take another pane."
- **Move to New Tab** (hidden for a tab's only pane): `session.new_window` with `focus: false` and
  no label, so the new tab's title follows its pane; then, in one turn and in order
  (`RexControl.callInOrder`), `move_block` beside the placeholder, `block.close` of the
  placeholder, and `move_window` right after this tab (left out from the last tab). A failed move
  is rolled back by the close (it empties the new tab), and the place call's `not_found` is
  expected; only the move's error shows. A suspend between the two steps leaves a tab with a
  fresh shell, visible and harmless. Nothing is resent after a reconnect.
- **Balance Splits** gives each pane in a row or column of same-direction splits the same share
  (`SplitBalance`: a split's weight is the sum of its sides' when they split the same way, else
  1), clamped to 0.05–0.95. Every changed split goes at once (`resize_pane` isn't ordered and sets
  one split outright), then one view read and at most one notice: each pane sees one layout change
  and sends one `terminal.resize`. Disabled when every split is within 0.005 of even.
- **Close Other Panes…** always asks: "Close 3 other panes?", adding "The agents running there
  stop, on the Mac too." when one runs. Panes and the agent check are taken at the tap; the dialog
  closes exactly those, in order in one turn, and a pane already gone is fine.
- **Keys** (the Mac's action names and titles): `pane.balance`, `pane.close_others`,
  `pane.move_to_tab` (a list of the tabs), `pane.move_to_new_tab`, `client.tab.move.backward` and
  `.forward` (the tab one place along). No default keys. `pane.rename` and `pane.move.<dir>` stay
  unbound and fall through. Where a command doesn't apply (one pane, the last tab) the key bumps.
- **Compatibility.** One check, `PaneArrange.isAvailable`, for the menu, the keys and the shortcut
  list: revision 13 or later (every method exists from 13), and no call on this connection found
  the command's method missing (`method_not_found`). A missing method hides only the commands
  using it, at once; the tap that found it shows the usual failure notice. Below 13 nothing shows,
  keys fall through and the pane menu has no Arrange. An open menu is a snapshot: each item checks
  again at the tap and bumps if the server can't.

## Floating windows

A tab's floating layers (Rex's floating panes, "floating windows" in the Mac's menus) are drawn
above its tiled panes where the Mac places them in a wide window, and one at a time in a sheet
over the tab in a narrow one. View-only: the phone raises, focuses, minimizes and shows them
again, never moves or resizes one (`Features/Tab/TabPresentation.swift`, `FloatLayout.swift`,
`FloatSheet.swift`, `State/ServerConnection+Floats.swift`).

- **No float, no change.** Only a tab with a floating window on screen has a `TabPresentation`.
  Every other tab, one with only minimized floats included, runs the split-or-page logic over its
  tiled panes, drawn exactly as a tab without floats.
- **One decision per body.** `TabPresentation.decide` is read by the canvas, the floats, the dots,
  the Waiting pill and Zoom. Book mode's sidebar collapse still asks about the tiled splits alone,
  with the sidebar collapsed: beside the sidebar they may show as pages under a float, and the
  float must not keep the sidebar open. Zoom (the phone's, a float's on the server, or before
  revision 21 any server zoom) gives pages: one pane at a time, tiled panes then floats' panes
  front first, minimized left out, with dots and swipes. From revision 21 a window has two zooms
  (docs/rex-protocol.md, Zoom): the tiled layer's zoomed pane is drawn alone in the tiled layer's
  place, behind the floats (wide) or under the float sheet (narrow), and stays while a float has
  focus. A narrow window gives the float sheet. A wide window draws floating windows when the
  tiled splits are legible and every float can be placed; else pages.
- **The float sheet** (narrow windows: folded, iPhone portrait, SE, half the inner screen;
  `FloatSheet`). A float is never one of the tab's pages there: the tiled panes show as in a
  narrow tab without floats (legible splits, else one at a time with title-bar dots counting tiled
  panes only), and one float at a time shows in a sheet over them, as Maps and Music do.
  - *One rule.* The sheet shows exactly while the tab's active pane is a drawn float's. Showing a
    float makes its pane active; going back to the tab makes the tiled pane under the sheet active
    again (`PhoneState.sheets` keeps which, and the size), on the phone only. Every path that
    points the phone at a pane (a tap, the Waiting pill, a link, the palette, a server focus on a
    float at open) shows or hides the sheet with it, and a hidden sheet's float never takes the
    keyboard (`ActivePane`).
  - *Sizes.* Large leaves about 15 % of the tab above it (24 pt at most while typing); Medium
    about 55 %. Compact height and a tab with no tiled pane have Large only, and a tab with no
    tiled pane can't hide it. Typing or a tap on the float lifts it to Large; Medium while typing
    puts the keyboard down.
  - *Look.* The canvas less 4 pt each side, top corners 12, the terminal's color with a stroke and
    soft shadow, running under the home indicator. A 36 pt grabber strip in the title bar's color:
    the handle, the shown pane's status and name (never its title), page dots when the float pages
    its panes, the floats' dots when there are several, and a 44 pt chevron back to the tab. No
    badge, nothing on the panes.
  - *Gestures, on the grabber only* (the panes keep theirs): up and down change the size, and a
    drag down past Medium goes back to the tab, by where the drag would coast; sideways shows the
    next or previous float, front first, no wrap; a tap switches Large and Medium. A drag picks
    its axis once, past 10 pt. A tap on the tab above goes back to it, with that pane active. A
    float whose splits keep 40 × 8 cells in the sheet shows them; else one pane at a time, walked
    by a sideways swipe on the pane. Next and Previous Pane walk the active pane's group (tiled or
    the float's), never across.
  - *The Mac.* A tap or the floats' menu raises as a tap does (`FloatTap`); a grabber swipe
    changes only the phone, unless the keyboard is up and typing goes there next. Going back to
    the tab sends nothing.
  - *No resize.* The sheet's panes claim their grid once, at Large with the keyboard down
    (`FloatSheet.Geometry.rest`). A size change moves the sheet by position only: at Medium the
    part below the screen counts as covered, as by the keyboard (`TerminalHost.setSheetCover`, set
    once the sheet rests), so the program's writing row stays in view and nothing is sent. The
    keyboard covers the sheet as any pane.
  - *Floats' control.* One glyph (`macwindow.on.rectangle`) with the count in the title bar (in tab
    mode, in the strip's slot beside the pane menu), and last in the vertical bar with the keyboard
    down when the sidebar navigates, only while the tab has a float to list. Its menu: the drawn
    floats front first (the shown one ticked), those minimized on the Mac (shown again there, then
    in the sheet), and Back to the Tab. Its own view, so tab mode's strip can host it.
  - *Motion.* The sheet slides up and between floats as pages do; Reduce Motion fades instead, a
    size change included. Only the shown float is in the view tree: the others park as off-screen
    panes do.
  - *VoiceOver.* The grabber is one adjustable element ("Floating window, <name>", "2 of 3"):
    swiping up or down shows another float; its actions switch the size and go back to the tab.
    The control says how many floating windows there are.
- **Where a float is drawn** (`FloatLayout.place`). Rex's rects are window fractions, mapped to
  the area the splits use (the canvas inset by 3 pt). A layer grows as one unit around its center
  until each of its panes keeps 40 × 8 cells, then stays inside the area. Across a vertical
  crease (`CreaseSettle`, book mode or not) it moves onto the page holding its center, narrowed if
  it must be; illegible there, the tab shows pages. The tiled layer under it is laid out exactly
  as without floats, a single pane across the fold included. A big enough float is drawn at the
  Mac's own rect.
- **Look.** Radius 8 and the split panes' stroke (1 pt, 1.5 pt active), over a backing of the
  terminal's color with one soft shadow (radius 12, y 4, black at 25 %, 35 % in Dark Mode) that
  takes no touches and never sits on the Metal view. No title strip, no buttons. A single tiled
  pane under floats keeps its 6 pt inset and radius 10. With no tiled pane left, the floats sit on
  the terminal's background.
- **View tree.** The floats are an overlay beside the tiled canvas, so one coming or going never
  rebuilds the panes below; panes keep their hosts by block, so a raise or a moved rect rebuilds
  nothing.
- **Taps** (`FloatTap`). A tap, long press, two-finger tap or pointer drag on a float makes its
  pane active. A float behind another is raised: `set_layer_state` with `focus`, then
  `focus_block` for the tapped pane when the layer holds several, in one turn. It shows in front
  at once and holds there until the server's view agrees, at most 1 s, on that connection only. A
  front float only takes focus; a front, focused one sends nothing. Without `set_layer_state` a
  tap focuses as on a tiled pane. A failed raise says nothing.
- **Active pane** (`ActivePane`). Never one in an undrawn float (minimized on the Mac, say): the
  next pane on screen takes the keyboard instead.
- **Floating Windows**, the pane menu's own section while the tab has a float
  (`FloatMenuSection`): Minimize (the active pane's float; hidden when it holds the tab's last
  panes on screen, which the server refuses), Minimize All when it does more than Minimize, and
  each minimized float by its first pane's name, which shows it again in front
  (`set_layer_state` normal with `focus`). In a narrow window the drawn floats not in the sheet
  are rows too, so the sheet stays in reach where the title bar steps aside. Keys:
  `pane.minimize_floating` and `pane.minimize_all_floating` ("Minimize Floating Window(s)", no
  default keys). Minimize All sends every drawn float's minimize in order in one turn, keeping the
  front one when no tiled pane is left; a refusal shows one notice.
- **Waiting agents.** The pill and the toasts count a drawn float as on screen, a minimized float
  or a page a swipe away as not. Jumping to an agent in a minimized float shows the float again
  first.
- **Fit.** A float claims the grid of the frame it is drawn at (grown or narrowed), as a split
  pane does, and in the sheet the sheet's grid at Large; one no longer drawn parks after 0.5 s
  (`scheduleStop`) and lets its claim go 10 s after it left (Parking). A claim resizes the float's
  pane only: the layer's bounds on the Mac stay.
- **Compatibility.** Drawing is data-driven: no `layers`, a null `layer_id` (an ID from the
  layer's first block, stable across raises) and an unknown kind (floating) or state (normal) all
  draw; a float without usable bounds is skipped. Minimize, the rows, the keys and the raise
  follow `PaneArrange.isAvailable` (revision 13 or later, and `set_layer_state` not found missing
  on this connection); without them floats still draw.

## Ports

A program in a local pane that listens on a TCP port (`npm run dev` on `localhost:5173`) opens on
the phone, in the app's own browser, through a Rex dial tunnel; servers bound to 127.0.0.1 only
work too. No port opens on the computer, and the phone listens on its own loopback only while the
page is up. Nothing shows on a pane. Each machine's sidebar header opens every such port of the
machine, so nobody scrolls a pane's history for a link (`State/ServerConnection+Ports.swift`,
`State/PortForward.swift`, `State/PortActions.swift`, `Features/Ports/`). Wire rules:
[rex-protocol.md](rex-protocol.md), Ports and dial tunnels.

- **Where.** The pane menu's last row in the section above Close: `localhost:5173` with the
  program under it for one web port, `Ports ▸` for several, nothing for none.
  - A tapped loopback link (`localhost`, `127.0.0.1`, `[::1]`, `0.0.0.0`, `[::]`) in a local pane
    opens through Rex: at once when a program in the pane listens on that port, else after "Open
    localhost:3000 from <computer>?" (not asked again when the link policy already asked).
    Debugger ports (9229, 9222, 9230) never open. Offline a notice says so; such a link never goes
    to Safari, which would reach the phone itself.
  - A link to a private address (10/8, 172.16/12, 192.168/16, 169.254/16, fd00::/8), such as
    `next dev`'s `Network: http://10.0.0.246:3000`, opens the same way (dialed at that address,
    named `localhost` in the browser) only when a program in the pane listens on that port;
    otherwise (another machine's address, an unknown port, no port list, offline) it goes to
    Safari, which reaches it on the same network.
  - Every other link, and every link on a server without tunnels or in a remote pane, opens as
    any link does.
- **Never silent.** A page that can't open says why, once, in a calm notice, only after a tap:
  "Couldn't open localhost:3000: …" when the pane closed before its question could show, the app
  has no forward, the phone can't listen, the pane left the screen before the page came up, or
  the tunnel's request never reached the computer.
- **Ports.** After each sync every local terminal reads `terminal.ports` once per connection,
  panes on screen first, four calls at a time; then `ports_changed` (the whole list each time)
  keeps it, applied in the 150 ms metadata flush and written only when changed. Nothing polls:
  Rex watches ports itself. An event counts as the pane's read; a new pane's event that beats its
  view waits for the view; a dropped `ports_changed` reads the list again. On a new connection the
  old lists stay until read again, so nothing flickers on a reconnect; a failed read takes that
  pane's list. Web ports are all but debuggers, SSH, mail, DNS, databases, queues and caches, by
  number and by program (`PortRules`). The dial address is the program's loopback address;
  `0.0.0.0` dials 127.0.0.1 and `::` dials ::1.
- **Which ports show** (`PortProbe`, `PortProbeBook` in RexKit;
  `State/ServerConnection+PortProbe.swift`, `PortForward.probe`). A web port by `PortRules` may
  still be no web page: an editor plugin's WebSocket server (Claude Code's IDE link in nvim
  answers "Bad WebSocket upgrade request"), or a raw TCP service on an unknown port. So each one
  is asked once what it answers, and the Ports list, its count on the globe, the palette and the
  pane menu's row leave out only a port that gave positive evidence. A tapped link never looks at
  the probes: a link to a hidden port still opens, since the user asked. A typed address finds the
  shown rows, as the list does.
  - The question: a dial block of its own (same label, ledger and sweep as the browser's, no
    `client_address`), one data connection, `GET /` with `Host: localhost:<port>`, `Accept: */*`
    and `Connection: close`, no cookies. At most 4 KB of the reply, for at most 2 s, then the
    connection drops and the block closes. Nothing reaches a pane, nothing is kept or shown on
    failure, and the log has the verdict and reply size only, never content.
  - No web page, hidden: 426; a 400 whose headers or body say "upgrade" and "websocket" (any
    case); bytes that aren't HTTP (Redis's `-ERR`, an SSH banner, an HTTP/2 frame). A web server,
    shown: every other HTTP status, 401, 403, 404 and 500 included (a dev server's 404 at `/` is
    still one), and an HTTP/0.9 page. Unknown, shown: no reply (refused, empty close, timeout), a
    tunnel that couldn't be made, offline, and a TLS record (0x15 or 0x16 first: an HTTPS-only
    server such as `vite --https`; the browser opens `http://` only, but it keeps its row).
  - A verdict belongs to the process's port (pid, port, dial address), per computer, kept across
    reconnects while the lists stay: one port in two panes is asked once, and a dev server
    restarting under a new pid is asked again. It goes when no list holds that port for that pid.
    An answer for a port that went, or for an older ask, is dropped. Web and no-web are final;
    unknown is asked once more at the next new list of a pane holding the port (a read on a new
    connection or a `ports_changed`), so a server still starting isn't hidden or stuck. Nothing
    asks on a timer.
  - No jump. A new port is held (no list, no count) until its answer or 1.5 s, whichever comes
    first; then it shows unless the answer was no web page. One wake, set for the earliest hold,
    shows it; the globe counts shown rows only. A port replacing a shown row on the same port
    within a minute (a restart, Restart's own) isn't held. While probes can't run (offline, no
    tunnels) a new port shows at once and is asked at its next listing. After an update every
    port is new once at the first launch.
  - Cost. At most 2 asks at once per computer, only while it is online with tunnels and synced;
    the rest wait in order. Debugger and service ports are left out by `PortRules` and never
    dialed. The asks bypass `CallGate`, on cellular too: the dial tunnel is separate from the
    sync's calls, and each ask is one small request per new port. A test launch
    (`-autoOpen <label>`) asks only that session's ports.
- **A machine's ports** (`Features/Ports/MachinePorts.swift`, `PortsGroup.swift`; the UI is
  [sidebar.md](sidebar.md), Ports). The rows are `ServerConnection.portRows`: the web ports of the
  machine's local terminals in sidebar order, set only when they change. A port an agent holds
  itself (its sign-in or editor link) gets no row; a server an agent started does. A row is named
  by what runs, then its folder ("Next.js · anchor") (`PortNames`: a small table of known
  programs, else the program's name). A tap opens the page in the app, as the pane menu's row
  does. The palette lists the same ports as "Open localhost:3000 · Next.js" ([goto.md](goto.md)).
- **Stop** (`PortStop`, `PortActions`) types one Ctrl-C into the port's pane.
  - From Rex alone it is offered only when the port's holder is itself the pane's foreground
    process and the pane runs no agent: Rex names the foreground's parents, never the holder's, so
    a server started through a wrapper (`npm run dev`: `npm` in front, its child holds the port)
    can't be told from one beside the foreground.
  - Where the computer's Beacon names a port's process (**The Beacon**, below), a wrapped server
    gets Stop too: the pane's foreground process must be the holder, the leader of the holder's
    process group, or a parent of the holder in that group; the foreground group of the holder's
    terminal must be that group where the Beacon names it; and no process of the group may be an
    agent (`PortOwner.interruptReaches`, `PortStop.agentInGroup`). A server left in the
    background, one its starter put in its own group, one an agent started and a port whose
    process nobody could name get only Show Pane.
  - On the tap the pane's processes are read again (`terminal.process`), and for a wrapped server
    the Beacon is asked again, so nothing is decided from what the row showed; no longer a yes:
    nothing is typed and a notice offers Show Pane. Stop never shows the pane.
  - The Ctrl-C goes once: through the pane's input queue when it is on screen or warm
    (`sendOnce`), as one call otherwise (a parked pane has no running stream). One that doesn't
    leave the phone (the pane behind its fence, say) is a calm notice with Show Pane, never a
    later send. The row says "Stopping…"; a port still held 5 s later says "Still running" with
    Stop to tap again. The phone never sends a signal and never a second interrupt by itself. The
    row goes when Rex says the port is gone.
- **Restart** (`RestartCommand`, `PortRestart` in RexKit; `PortActions.restartNow`). Rex gives no
  command line (`terminal.process` returns each process's first argument only, and no event
  carries a shell's command marks), so Restart exists only where the Beacon names the job. It is
  offered when all hold:
  - Stop's rule above;
  - the leader of the holder's process group is in the Beacon's answer with its parent, and that
    parent is a shell (`ProcessNames.isShell`);
  - the leader's arguments are there, whole and text (`argv` not null, not `truncated`, not
    `argv_lossy`), not the shell's own (a subshell or function runs as a copy of the shell), and
    not a title the program wrote over them (`npm run dev` reports one string with the whole line
    and empty strings after it: no argument is empty, a single argument has no whitespace, and
    the first argument's last part names the process or its executable, a version suffix or
    cut-short name aside: `RestartCommand.isRetitled`);
  - the leader's folder is the shell's, so no `cd` is ever typed;
  - one command, no pipeline (the Beacon's `job_members` is 1; a pipeline's leader holds only its
    first part, and an answer without the field gives no Restart);
  - every argument has a one-line spelling (`ShellEscape`, a literal `~` kept literal; an empty
    argument, a control character or a first word with `=` gives no Restart), the line is at most
    300 characters, and no agent is in the pane or the group.

  More:
  - It is not what the user typed: variables set in front (`PORT=4000 npm run dev`) and aliases
    are not in a process's arguments, so nothing claims the command is the same. The row asks
    first, in place (sidebar.md, Ports), showing the command whole, never with a part left out: a
    program started under its full path (Homebrew's `python3`) reads as that path.
  - After the tap, in order, nothing twice (`PortRestart`): the Beacon is asked again and the
    command must read exactly as shown; the pane is shown if it isn't on screen, and nothing is
    typed until it is on screen with its fence down (5 s at most); one Ctrl-C goes as Stop sends
    it, with Stop's checks; within 10 s the port must go and the pane's processes
    (`terminal.process`, read at most three times) and Rex's events must name the very shell that
    started the job as the foreground; the command and Return go once through `sendOnce`, after a
    last look (port still gone, the events' foreground still that shell, no agent, the screen
    current); the row says "Restarting…" until the port is back, 30 s at most, keeping its place in
    the list meanwhile (`ServerConnection.holdPortRow`).
  - Its waits are events with one deadline each, never a repeating timer: the pane's host says
    when the pane shows and its stream when the fence is down (`ServerConnection.whenPaneCurrent`);
    the port lists and foreground processes are observed state written by Rex's `ports_changed`
    and `process_changed`.
  - Any step that fails ends it: one notice with Show Pane, the row says "Couldn't restart" with
    Show Pane for 30 s, and nothing is typed afterwards. A command that didn't leave is never sent
    later; one that left without an answer is never sent again.
- **Open in Browser** (`PortBrowser`, `PortActions.openInBrowserNow`): the page in the iPhone's own
  browser, at an address the computer's Beacon hands out for that port and this iPhone
  (`port_share`; [helper.md](helper.md)). The item is in a row's menu and the browser's menu only
  while all hold: the Beacon's status says the computer can (`helper_status`' `share_possible`,
  read where the app already reads the status, never for this alone; missing field means no); the
  Beacon has answered `port_owner` on this connection; no answer said otherwise
  (`not_supported`, `not_registered` and `not_your_phone` for the connection; `not_available`,
  which can only follow a yes, until the next status is read); the iPhone has a tailnet address
  (`PrivateNetwork.address`: 100.64.0.0/10 on a tunnel, or fd7a:115c:a1e0::/48); and the port is
  80 or from 1024 up on the computer's loopback. A tap asks the Beacon, then opens the address in
  the system's browser. Nothing else asks: showing a row or opening a page in the app never makes
  such an address, and a tap is never how someone learns their computer can't (the item isn't
  shown).
  - A row whose page is out there adds "In browser" to its address line, and its Copy Link gives
    that address. The app treats the address as live until a minute before the Beacon would end it
    unused (`idle_seconds`), on this connection and for the process that held the port; then the
    words go and the next tap asks again.
  - One site. While the address exists, a page opened in the app loads from it too, not from the
    phone's listener, so a login in one is the same site in the other. The app asks for it again
    at that moment, which keeps it alive and finds out if it ended (then the page loads from the
    listener). The chrome still shows the computer's address (`localhost:3000`); Copy Link and
    Share give the address that works outside the app.
  - A tap that opens nothing says why in one line (`PortBrowser.notice`), in the open browser's own
    line when tapped there; "Nothing is running on localhost:3000 now." for a port that stopped.
- **The Beacon** (`PortActions.learnOwner`, `PushRegistrar.ask`). Open in Browser, Stop for a
  wrapped server and Restart need Beacon 0.7 on the computer, holding this iPhone (notifications
  set up there). No setting. A shown row asks `port_owner` for its process once per process and
  connection; a computer with no Beacon is asked nothing, and one answering `not_supported`,
  `not_registered` or `refused` is not asked again on that connection. Nothing is asked while the
  computer's ports list is closed (it has no row then), nor on a timer. Without a Beacon all of
  the above is absent and Ports works without it, plain Stop included.
- **The browser.** `PreviewBrowser`: the app's own view, one `WKWebView` made when the page opens
  and let go when it closes, never kept warm. It loads `http://localhost:<port>/` from the menu or
  a Ports row, or the tapped link's scheme and path. The phone listens on 127.0.0.1 on the same
  port when it is free and above 1024, else on a free one, and forwards **only the opened port**:
  a frontend on 5173 can't reach its API on 3000 (open that one on its own). Done or a swipe down
  ends the forward, and the pane that had the keyboard gets it back.
  - Nothing of it exists before a page opens. The sheet's first frame is the sheet alone; its
    bars are shown on the next turn, while the sheet has only begun to rise (laying out bars is
    most of a barred sheet's main-thread cost); the web view (which WebKit makes on the main
    thread only) is made the turn after, loads at once, and joins the view a turn later. The error
    page is built on the first failed load. Pages keep cookies and storage in the app's one WebKit
    store, so a dev server login survives to the next open. Debug and benchmark builds mark an
    open's steps as signpost intervals (`PreviewTrace`: subsystem `dev.abrahamgonzalez.rexduo`,
    category `PreviewBrowser`).
  - Chrome: Done, the page's title over its address, a menu (Copy Link, Share…), and back, forward
    and reload. No bar is the system's: the browser is the sheet itself, with no navigation
    controller, and both bars are its own views, placed and drawn as a navigation bar's and a
    toolbar's are. Why: on iOS 27.2 the system's bars outlive the sheet, one set per page opened
    (the Duo's navigation bar model is kept by a global observer with Done, the menu and their
    views; a `UIToolbar` keeps its items, buttons and model, about 90 KB). 100 opens must cost
    what 30 do (`-portsLoop`, `scripts/bench/ports-loop.sh`).
  - `PreviewBarLayout` puts each control where the system's bars would: Done, the title and the
    menu in an opaque top strip with a hairline (`PreviewBarLayout.top`; on the Duo, Done and
    the menu in the vertical bar, top down), the arrows under the page (on the Duo, in the vertical bar, bottom up, so the page
    keeps its height). Text and symbols grow up to Extra Extra Large, as a navigation bar's do;
    VoiceOver reads Done, the title and the menu first, and the arrows say Back, Forward, Reload
    and when they are off, and show large on a long press at accessibility sizes.
  - Open in Browser is in the menu only while the computer can hand the page to the iPhone's
    browser (**Open in Browser**), looked up each time the menu opens, never for another site's
    page; otherwise no button leaves for another app, since the shown address only works inside
    this one. It is a menu item, never a bar item.
  - The loop's reading sits at one of two levels in the simulator, about 32.4 MB or about 37.9 MB,
    and some runs climb from the first to the second in their first 25 or so opens. In `vmmap` the
    app had written the same amount at both levels; only at the high level were some of its pages
    compressed by the Mac. A sheet with only a `WKWebView` (`-portsLoopBare`) has not been seen at
    a high level, so whether it has one too is not known.
  - The address shown is the one the user knows from the computer (`PreviewAddress`,
    `LocalhostLink.shown`): a tapped link's own host and port as written (`localhost:3000`,
    `127.0.0.1:5173`, `0.0.0.0:8000`, `[::1]:4000`, a LAN address), and `localhost:<port>` from
    the pane menu, a Ports row or the palette. What loads underneath (the phone's listener, whose
    port may differ) is never shown, the error page included. Copy Link and Share give that
    address with the page's path. A link that leaves the server shows its own host.
  - A response the page can't show, or an attachment, downloads to the phone's temporary folder
    and goes to the share sheet. A new-window link opens in the same view. Basic or Digest auth
    gets a small form, kept for the session only. A failed load shows "Couldn't load
    localhost:3000" with Try Again. Light and dark come from the page's own CSS.
  - A tap on the address edits it, as in Safari: the field holds the shown address and the path,
    and Go resolves it with `PortAddress`, which reads only the port lists the app holds (no call,
    no network). Forms: `localhost:3000`, `127.0.0.1:3000`, `:3000`, `[::1]:3000` and
    `0.0.0.0:3000`, with or without `http://` or `https://`, path and query kept. One connected
    computer listens there: its page opens (in place when it is the server on screen). Several: a
    list asks which, one row a computer ("Desk · Next.js · anchor"). None: "Nothing is running on
    localhost:3000 on your computers." Offline computers are left out. The address shown afterwards
    is the one typed. An address that isn't a computer's own (`example.com`, another machine's IP)
    is never loaded here: it opens in the system's browser. The same port on two computers is two
    rows in the Ports group, and a tap there opens that one with no question.
  - Not in this view, unlike Safari's: Reader, the passwords AutoFill bar, content blockers and
    Safari's cookies. None matters for a dev server's page.
- **Why one listener.** A `WKWebView` with a loopback HTTP CONNECT proxy
  (`WKWebsiteDataStore.proxyConfigurations`, iOS 17) sends `localhost` through the proxy but never
  `127.0.0.1` or `[::1]`, with or without `matchDomains`: loopback IP literals always go direct, to
  the phone. So no proxy forwards every port, and the view loads from one listener for the opened
  port.
- **The tunnel.** One dial block (`session.new_block`, `com.superlogical.tunnel.dial`, options
  `host`, `port`, `client_address`), detached, in the pane's session, labeled `Pteron #<tag>`,
  made on the browser's first connection. The tag is 8 hex characters in the Keychain, this device
  only, never synchronized. Each browser connection is its own data connection (`data.connect`,
  `conn:<uuid>`, `rex.data.bytes.v1`), at most 16 at once; more wait for a slot. Connections made
  while the server isn't synced wait for it, up to 30 s. A refused target resets the browser's
  connection. A block a new client ID can't use (after a long drop) is dropped and remade; a 4006
  before any byte came back, even while the request is still going up, resends the request once
  on a new block. A full server (`conflict`), a refused block and a block request that never left
  (the connection dropped) show one notice per browser. A probe (**Which ports show**) makes its
  own block the same way, without `client_address`, and shows no notice.
- **Cleanup.** Rex never removes a tunnel block. Every block made is remembered in UserDefaults,
  and a session where one is about to be made is marked first. On each sync of a server with
  remembered blocks or a mark, and before each `new_block`, the sweep lists the session's blocks
  and closes every dial block with this phone's label that no open browser or running probe uses,
  whoever owns it. When the app goes to the background (not merely inactive), a background task
  begins at once, then `block.close` goes for the browser's block (ending its streams with 4000)
  before the listener and connections close; back in front with the page still up, the phone
  listens on the same port again and a new block is made when the page connects. A server removed
  in Settings has its blocks closed if connected, else forgotten.
- **Gates** (per server, re-read on every connection). Ports need revision 15 (`terminal.ports`)
  and no `method_not_found` from it. Tunnels need revision 14 and the dial flavor in the creator
  list for the server's host. The row needs both and a local pane (`isLocal`: the block names the
  server's host or none; on a server that names none, only blocks that name none). Without ports
  a tapped link still opens through Rex and always asks; without tunnels nothing changes. A gate
  that closes while a page is up stops the listener with one notice; when it opens again the phone
  listens again.
- **Metadata of new panes.** A block's metadata read starts when the block reaches a view, no
  sooner than 300 ms after its `block_created`. A detached tunnel never reaches one, so it costs
  no terminal calls. This app's tunnel events (`block_created` while it makes one,
  `block_owner_changed`, `block_closed`) read no view.
