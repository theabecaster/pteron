# Rex Connect

iOS remote for Rex, a terminal multiplexer. The app connects to a Rex server's control API and
terminal data stream over the server's Tailscale HTTPS address, draws panes with libghostty-vt
and its own Metal renderer, and creates, splits, resizes and types into real Rex sessions. It is built for the iPhone Duo (unfolded,
it shows the sidebar beside the tab's splits) and works on any iPhone. `Relay/` holds Rex Connect
Helper, a Rust program for macOS and Linux that sends push notifications for Rex events (on a Mac
it ships as a signed app).

Stack: Swift 6 language mode, SwiftUI + UIKit, iOS 18, Xcode 27.2, XcodeGen, libghostty-vt (static
xcframework built by `scripts/build-ghostty.sh`), Swift Testing (the engine and stream tests are
XCTest). No other app dependencies. The helper in `Relay/` is Rust (tokio, tokio-tungstenite, h2,
rustls, ring, serde; `Cargo.lock` pins them).
Bundle id `dev.abrahamgonzalez.rexduo` predates the name and stays: App Store Connect and the
APNs topic depend on it.

## Map

- `Packages/RexKit`: the protocol layer. `RexControl` (control socket and RPC), models,
  `TerminalStream` (data socket, reconnect, the input queue, `APCFilter`, `DataFrame`). Foundation
  only, so it tests on macOS.
- `RexConnect/State`: `AppModel` (selection, servers), one `ServerConnection` per server
  (sessions, layouts, block metadata, server events, actions), `Prefs`, `AgentNotifier`,
  `PushRegistrar` (push registration with each server's helper).
- `RexConnect/Features/<Feature>`: Sidebar, Tab (window screen, title bar gestures,
  split math), Terminal (`PaneView` → UIKit `TerminalHost` → `GhosttyTerminalView`; `Ghostty/` is
  the terminal engine: libghostty-vt and our Metal renderer), KeyBar, Keyboard
  (hardware keys and Rex's keymap), Agents, Settings, Notifications (in-app toasts, permission card),
  Offline (the "signal lost" screen and its static backdrop), Pairing ("Pair via QR Code": the
  scanner and the check before a server is added; logic in `State/Pairing.swift`).
- `RexConnect/App`: entry point, `RootView` (sidebar + tab for the window's width and the fold, `Arrangement`
  and `SidebarWidth` in `State/Posture.swift`, `SidebarSplit` in Features/Sidebar), launch transition.
  Bars and the Duo's vertical bar: [docs/duo-layout.md](docs/duo-layout.md).
- `RexConnect/DesignSystem`: terminal themes and chrome colors derived from them, fonts.
- `RexConnectTests`: app logic tests. Helper tests live next to the code in `Relay/src`.
- Glossary: Rex's *window* is a tab in the UI, *block* is a pane, *layer* is a tiled or floating
  group. Code keeps Rex's names (`WindowInfo`, `blockID`) because they match the server's
  `/llms.txt`; user-facing text says tab and pane.

## Build, run, test

`RexConnect.xcodeproj` is generated and not tracked. Run `xcodegen generate` after cloning and after
adding, moving or deleting a file; edit `project.yml`, never the project.

```sh
scripts/build-ghostty.sh                       # once per clone, before xcodegen: see below
xcodegen generate
xcrun simctl list devices available            # pick a simulator id
xcodebuild -project RexConnect.xcodeproj -scheme RexConnect -destination id=<sim-id> \
  -derivedDataPath build/dd build
xcodebuild ... test                             # same flags: RexConnectTests in the simulator
swift test --package-path Packages/RexKit       # protocol tests on macOS, about a second
cargo test --manifest-path Relay/Cargo.toml     # helper: push policy, payloads, JWT, devices
```

- `scripts/build-ghostty.sh` builds libghostty-vt into `Vendor/GhosttyVt.xcframework` (51 MB:
  iOS, iOS Simulator and macOS slices). Apple silicon only. A fresh clone must run it before
  `xcodegen generate` and the first build.
  - A cold run takes about 130 s and 1.3 GB, all under `Vendor/` (gitignored, nothing installed
    system-wide): Zig from ziglang.org (51 MB download, SHA-256 checked) in `Vendor/zig-<version>/`,
    the Ghostty checkout in `Vendor/ghostty/`, Zig's package cache in `Vendor/zig-global-cache/`.
  - It records what it built in `Vendor/GhosttyVt.stamp` and does nothing when that matches the
    pins. `scripts/build-ghostty.sh --force` rebuilds anyway. A new framework is checked in a
    staging folder first and the stamp is written last, so a build that fails a check never
    replaces a good framework or gets a stamp.
  - To re-pin: change `GHOSTTY_COMMIT` in `scripts/ghostty.version` (and the Zig version and hash,
    if Ghostty's `minimum_zig_version` moved), run the script, and check
    `RexConnect/Resources/Acknowledgements.txt` against the entries marked `"use": "linked"` in
    `Vendor/ghostty/deps/libghostty-vt-third-party.json`.
  - `scripts/check-ghostty.sh` compares the stamp with the pins, and checks that the iOS
    deployment target in `project.yml` is 17.4 or later, which the patched library needs. The
    app target runs it on every build, before compiling, and the macdesk scripts run it before
    copying or archiving, so a missing or stale framework stops the build with one line that
    says to run `scripts/build-ghostty.sh`.
  - `scripts/ghostty-patches/*.patch` are applied to the checkout and are part of the stamp, so
    a new patch makes every existing framework stale. List each patch file in `project.yml`
    (the check's `inputFiles`): the script sandbox lets the check read only listed files, and
    the build stops with that instruction until it is. What each patch does:
    docs/ghostty-engine.md, Patches.
  - `scripts/check-symbols.sh` fails when the framework (or an app or archive given as argument)
    imports a private system symbol, which App Store review rejects. The build script runs it
    on the framework, `ship-macdesk.sh` on the framework and on the archived app.
  - An agent worktree can symlink another checkout's `Vendor` instead of building its own.
- Use a concrete simulator id as the destination: libghostty-vt's simulator slice is arm64 only,
  and `generic/platform=iOS Simulator` also builds x86_64. A Release build for the simulator
  needs `ONLY_ACTIVE_ARCH=YES` for the same reason.
- The app builds with zero warnings from our code; keep it that way.
- `scripts/bench/run.sh <sim-id>` measures the terminal on generated output (about 5 minutes, no
  server) and fails when a number passes its budget in `scripts/bench/budgets.mjs`. Run it after
  a change to the feed path, the renderer or the host's main-thread work
  (docs/ghostty-engine.md, Measurements).
- After a change, run the tests for the layer you touched. For UI changes, run the app and look at a
  screenshot (`xcrun simctl io <id> screenshot --display=LCD out.png` on the Duo simulator; it shows
  the folded screen only). For other layouts use `-simulateDuo` on an iPad simulator, building with
  `TARGETED_DEVICE_FAMILY=1,2` on the command line so the app runs at full size there.

## Debug launch arguments

Pass after the bundle id: `xcrun simctl launch <id> dev.abrahamgonzalez.rexduo -autoOpen zz-test -sizing mirror`.
Each is a UserDefaults key for that run only.

- `-autoOpen <session label>`: open that session's first tab. A label that doesn't exist opens nothing.
- `-sizing mirror`: keep the Mac's pane sizes for this run instead of fitting panes to the phone.
- `-ghosttyDemo <path>`: no server; replay a capture file in a full-screen terminal view with no
  host around it (`GhosttyDemoScreen`).
- `-replay <file>`: no server; feed a capture or scenario file to a real pane
  (`ReplayScreen`; more arguments there). `-perfLog <name>`: measure the pane and write
  `Documents/perf/<name>.json` (`PerfProbe`). `scripts/bench/run.sh` uses both.
- `-selectionDemo <steps>`: play a selection gesture by program, for screenshots of the loupe and
  handles; `-selectionLoupe off` (docs/selection.md).
- `-typeTest 'text\n'`: type the text into the active pane once it is live. With `-scrollBackTest
  <seconds>`, scroll two pages into the scrollback first and type that much later (checks that input
  returns the view to the bottom).
- `-tapTest col,row[;col,row…]` (Debug builds): tap those viewport cells as a
  focused finger would, `-tapTestAfter` seconds after the pane is live (default 3), and write what
  each did to `Documents/tapTest.txt`. `-tapTestType <text>` types the text after the last tap.
- `-hinge closed|partial|full`: pretend the hinge reports this. Layout never reads it.
- `-simulateDuo <posture>[,<posture>…]` (Debug builds): lay the root out at that window size, with its
  size classes, rough safe-area insets (the 84 pt vertical bar on the trailing edge, status bar, home
  indicator) and a fake fold drawn as a red dashed line, at the bottom-left of a bigger screen.
  Postures: `unfolded` (951×669, flat crease), `book` (951×669, bent), `unfoldedPortrait` (669×951),
  `tabletop` (669×951, bent), `folded` (466×678), `foldedLandscape` (678×466), `halfWindow` (475×669, one half of the unfolded
  screen), `iPhone` (402×874), `iPhoneLandscape` (874×402), `proMaxLandscape` (956×440). A list
  cycles every `-simulateDuoEvery` seconds (default 10), to check what a fold keeps.
- `-focus none` (Debug builds): don't give the active pane the keyboard at launch.
- `-sidebar closed` (Debug builds): start with the sidebar hidden (it starts open).
- `-servers 'Name=https://…,Other=http://127.0.0.1:8765'` (Debug builds): use these servers for this run
  instead of the saved ones. Point one at a missing `.ts.net` host, a closed port or a server that
  answers 403 to see the real offline screens.
- `-simulateOffline <kind>` (Debug builds): every server shows that offline screen and none connects.
  Kinds: `noInternet`, `offPrivateNetwork`, `hostNotFound`, `notAnswering`, `notAllowed`, `insecure`,
  `badAddress`, `unknown`. Add `-simulateRetrying YES` to hold Try Again in its "Trying…" state.
- `-simulateNetwork offline|offPrivate|onPrivate` (Debug builds): pretend the phone's network is in that
  state (no path, off the tailnet, on it), so real connection errors classify as they would there.
- `-settings main|addServer|darkTheme|lightTheme` (Debug builds): open Settings at launch, at that page.
- `-simulateScan <payload>` (Debug builds): open "Pair via QR Code" at launch and read this payload as
  if the camera had (the simulator has no camera). `open` only opens the scanner. With `-settings
  addServer` it scans from that page. `-simulateOffline <kind>` makes the check fail that way.
  `-simulateCamera denied` shows the scanner with camera access refused.
- `-pushToken <hex>` (debug builds): use this APNs token and skip the permission check, to test
  push registration in a simulator.

## Safety: the app drives real sessions

The simulator connects to the owner's real Rex servers, where real agent sessions run. Fit mode
claims the pane you view and resizes it on the Mac, and the key bar and `-typeTest` type into a real
shell. So:

- Test only in throwaway sessions you create, named `zz-…` (`rex new zz-test`), and close them
  afterwards. Don't open, type into, resize, rename, split or close any other session.
- For a launch check that touches no panes, use `-autoOpen zz-none -sizing mirror`.
- Unit tests run inside the app, which doesn't connect while it hosts tests.
- `scripts/install-duo.sh`, `scripts/ship-macdesk.sh <build>` and `Relay/package.sh` (without
  `--no-notarize`) install, upload or notarize. Run them only when asked. `ship-macdesk.sh`
  with any well-formed build number archives for real; only a missing or malformed one stops it
  early. `scripts/sync-macdesk.sh` overwrites the build copy on macdesk (a `rexconnect-build*`
  folder in its home, nothing else); `-n` only lists what it would change.
- The helper runs on this Mac, macdesk and workdesk next to other agents' sessions. Test it with a
  foreground `--dry-run` after stopping the service (`Relay/README.md`, "Verify by hand"), and
  never restart Rex.
- `.asc.env` and `~/.appstoreconnect/private_keys/` hold App Store Connect and APNs keys. Don't
  print, copy or commit them. `build.rs` embeds the APNs key in every helper binary, so
  `Relay/target` and `Relay/dist` hold it, and so does `Relay/.stage` while `Relay/package.sh`
  runs; all are gitignored and never copied to macdesk.

## Conventions

- Inject dependencies through `init` or `@Environment`; avoid new `static let shared`. `Prefs.shared`
  is left only where SwiftUI doesn't reach (UIKit key bar and terminal host, the `Haptic` helper).
- Put pure logic (parsing, byte encoding, layout math) in its own type with tests, not in views.
- RexKit must not import UIKit or SwiftUI; the app passes in what it needs (`ClientInfo`).
- UI and state types are `@MainActor`. Don't silence concurrency checks with `@unchecked Sendable`
  or `nonisolated(unsafe)` unless a comment says why it is safe.
- Socket callbacks check they still belong to the current connection (generation counters) before
  touching state; a stale socket would otherwise overwrite fresh state after a reconnect.
- Send terminal input through `TerminalStream.send`, and key-bound server calls through its
  `perform(action:)` and `forward(key:)`. They share one queue with one request in flight,
  because Rex doesn't order concurrent block calls, and a request that left is never sent again,
  because `terminal.write` has no sequence number (docs/terminal.md, Input).
- `RexControl` is the only thing that retries a lost connection. Code that depends on it waits
  for `observeConnected` instead of polling or looping.
- Other sessions work in parallel worktrees. Keep diffs to what the task needs, and move files with `git mv`.
- Commits: imperative subject, plain message, no AI attribution or trailers (no `Co-Authored-By`,
  "Generated with", or session links).
- Clean up what you create: delete simulators you made (`xcrun simctl delete <id>`), `build/`,
  `.build/`, `Relay/target/` and finished worktrees.

## Docs

Read the one for the area you touch:

- [docs/architecture.md](docs/architecture.md): data flow, state, concurrency, where new code goes.
- [docs/rex-protocol.md](docs/rex-protocol.md): control API methods and events the app uses.
- [docs/terminal.md](docs/terminal.md): data stream, reconnect, fit and mirror, gestures, input.
- [docs/selection.md](docs/selection.md): touch selection (loupe, handles, haptics): research, design.
- [docs/ghostty-engine.md](docs/ghostty-engine.md): the terminal engine: architecture, threads and
  locks, snapshot restore, toolchain and patches, gotchas, measurements and the benchmark;
  [docs/ghostty-api-notes.md](docs/ghostty-api-notes.md): libghostty-vt API notes.
- [docs/terminal-checklist.md](docs/terminal-checklist.md): what the terminal must do, row by row,
  with the test or the manual step that checks it; the device scripts.
- [docs/notifications.md](docs/notifications.md): local notifications, the helper, the relay contract.
- [docs/release.md](docs/release.md): device installs, TestFlight via macdesk, helper packaging.
