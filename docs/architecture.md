# Architecture

## Layers

App → Features → State → RexKit. Features also use DesignSystem. Nothing points back up.

| Layer | Owns | Doesn't |
|---|---|---|
| `Packages/RexKit` | sockets, RPC, JSON → models, terminal byte stream | import UIKit or SwiftUI, read settings |
| `RexConnect/State` | `AppModel`, one `ServerConnection` per server, `Prefs`, `AgentNotifier` | build views |
| `RexConnect/Features` | screens, and UIKit where SwiftTerm needs it | talk to `RexControl` for session changes (go through `ServerConnection`) |
| `RexConnect/DesignSystem` | `TermTheme`, chrome colors, fonts | hold state |

`Relay/` is a separate Swift package (the Mac helper). It depends on RexKit for JSON and
`RexError` only; its connection code speaks the control protocol over Rex's Unix socket.

## Data flow

1. `RexConnectApp` owns `Prefs` and `AppModel` as `@State` and injects both with `.environment`.
2. `AppModel` builds a `ServerConnection` per configured server (Settings → Servers, plus hosts
   from `hostURLs`). Each owns one `RexControl` and a `KeymapStore`.
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

Phone-only view state (zoomed tabs, when agents started waiting) lives in `PhoneState` and never
goes to the server, so the Mac's layout doesn't change because of the phone.

## Concurrency

- Swift 6 language mode for the app and RexKit. Relay is still Swift 5 mode.
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
- New setting: a property on `Prefs` (saved in `didSet`), read with `@Environment(Prefs.self)`.
- Pure logic: its own type, with tests in `RexConnectTests` or `Packages/RexKit/Tests`.
