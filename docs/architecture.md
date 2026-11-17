# Architecture

## Layers

App → Features → State → RexKit. Features also use DesignSystem. Nothing points back up.

| Layer | Owns | Doesn't |
|---|---|---|
| `Packages/RexKit` | sockets, RPC, JSON → models, terminal byte stream | import UIKit or SwiftUI, read settings |
| `RexConnect/State` | `AppModel`, one `ServerConnection` per server, `Prefs`, `AgentNotifier`, `PushRegistrar` | build views |
| `RexConnect/Features` | screens, and UIKit where the terminal needs it | talk to `RexControl` for session changes (go through `ServerConnection`) |
| `RexConnect/DesignSystem` | `TermTheme`, chrome colors, fonts | hold state |

`Relay/` is a separate Rust crate (the push helper for macOS and Linux). It shares no code with
the app; it speaks the same control protocol over Rex's Unix socket.

## Data flow

1. `RexConnectApp` owns `Prefs` and `AppModel` as `@State` and injects both with `.environment`.
2. `AppModel` builds a `ServerConnection` per configured server (Settings → Servers). Each owns one `RexControl` and a `KeymapStore`.
3. On connect, `ServerConnection.bootstrap` calls `session.bootstrap`, attaches every session,
   loads block metadata (program status, title, process), hosts and the keymap.
4. Server events update `ServerConnection`. Block events are coalesced (about 150 ms) and a status
   stays on screen at least a second, except a new "blocked", which shows at once. Each block's
   metadata sits in its own observable box, so one pane's change re-renders only its readers.
5. User actions call `ServerConnection` methods, then re-read the session's view. The server's
   `session_view_changed` is the truth for layout; nothing guesses a layout locally.
6. Each visible pane is `PaneView` → `TerminalHost` (UIKit) → `TerminalStream` (RexKit).
   Settings and theme are pushed into the host from `updateUIView`.
7. Reconnects, returning to the foreground and an event `seq` gap all trigger a full resync.

## Offline

- `RexControl` owns retries: after any failure, the first connect included, it backs off 1 s → 15 s
  and reports each failure as a `ConnectionFailure` (error domain and code, the POSIX or TLS code
  under it, the upgrade's HTTP status, the close code). `kick()` retries now.
- `ServerConnection` turns failures into `ConnectionProblem`s (`State/ConnectionProblem.swift`):
  no internet, off the private network, host not on the tailnet, not answering (asleep, refused, or
  not Rex), not allowed, insecure, bad address, unknown. `NetworkWatch` (`NWPathMonitor` off the main
  thread) says whether there's a path and whether the phone has a Tailscale address; a path change
  retries every down server.
- Offline holds still: retries never show as "connecting", only a real connection leaves `.offline`,
  and `ProblemGate` changes the message only for a decisive kind or the same new kind twice.
  `recovering` keeps the screen up, saying the signal is back, until the sessions have reloaded.
- `Features/Offline`: `OfflineScreen` takes over the tab area only when no server is up (one down
  server among several is a line in the sidebar). Over a tab whose server dropped, it dims the stale
  tab and blocks touches. `SignalStatic` is Core Animation only (one noise texture, discrete
  `contentsRect` jumps, looping keyframes), off while not in a window, still with Reduce Motion.

## Pairing

`rex server tailscale pair` shows the server's https address as a QR code: no credential, nothing
else. `Features/Pairing` scans it (AVFoundation; the camera permission is asked for when the scanner
opens) and `PairingModel` (`State/Pairing.swift`) takes it from there: parse and normalize
(`PairingCode`), stop at a server that is already saved, check that Rex answers
(`ServerProbe` in RexKit: a plain `GET /api/control`, which Rex answers with 426, so no client ever
shows on the server), then name and add. A failed check goes through `ConnectionProblem.classify`
and is worded by `PairingProblem`. A server added this way connects and registers for pushes like
any other.

Phone-only view state (zoomed tabs, when agents started waiting) lives in `PhoneState` and never
goes to the server, so the Mac's layout doesn't change because of the phone.

## Concurrency

- Swift 6 language mode for the app and RexKit.
- UI, state, `RexControl` and `TerminalStream` are `@MainActor`.
- `RexControl` decodes control messages on URLSession's queue, then handles them on the main
  actor. A screen read reply is up to ~1 MB and takes ~4 ms to parse; events take microseconds.
  `DecodedJSON` carries the decoded value across; it is `@unchecked Sendable` because
  JSONSerialization returns immutable values.
- Models and pure helpers (`APCFilter`, `DataFrame`, `TerminalLayout`, `SplitGeometry`) are
  value types.
- Reconnects bump a generation counter; every socket callback checks it before touching state.

## Where new code goes

- New server call: a method on `ServerConnection` using `control.call` or `blockCall`, then
  `refreshView`. Add it to [rex-protocol.md](rex-protocol.md).
- New server event: `ServerConnection.handle(event:)` or `handle(sessionID:event:)`.
- New screen: `RexConnect/Features/<Name>/`. Shared view pieces: `DesignSystem/`.
- New setting: only for a choice a user would understand and want to make; otherwise pick the best
  value and add it to "Fixed choices" in `Prefs`. A setting is a property on `Prefs` (saved in
  `didSet`), read with `@Environment(Prefs.self)`; clear a removed one's key in `Prefs.migrate`.
- Pure logic: its own type, with tests in `RexConnectTests` or `Packages/RexKit/Tests`.
