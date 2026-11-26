# Pteron

An iOS remote for Rex, a terminal multiplexer. The app connects to a Rex server's control API and
terminal data stream over the server's Tailscale HTTPS address, draws panes with libghostty-vt and
its own Metal renderer, and creates, splits, resizes and types into real Rex sessions. It is built
for the iPhone Duo and works on any iPhone and iPad. `Relay/` holds Pteron Beacon, a Rust program for
macOS and Linux that sends push notifications for Rex events, and `Gateway/` the Cloudflare Worker
that passes them to Apple.

Stack: Swift 6 language mode, SwiftUI + UIKit, iOS 18, Xcode 27.2, XcodeGen, libghostty-vt (a
static xcframework built locally), Swift Testing and XCTest. No other app dependencies. Beacon
is Rust (tokio, rustls; `Relay/Cargo.lock` pins them) and the gateway is TypeScript on Cloudflare
Workers with D1. Bundle id `dev.abrahamgonzalez.rexduo`
stays fixed: App Store Connect and the APNs topic depend on it.

## Product principles

- **Mac-like.** The app is the Rex Mac app on a phone: a sidebar beside or over the tab, or, in
  tab mode, the Mac's tabs above in the title bar's place with no sidebar; splits laid
  out as the Mac lays them out, Rex's keymap. Keep chrome off the terminal: no toolbars, badges or
  standing overlays on a pane, only short-lived notices and controls that show just while they
  apply (the jump-to-bottom button, only while scrolled into history), because every point of
  chrome costs rows of text.
- **Few settings.** Settings holds only what a user would choose and understand: servers, a theme
  for Light and Dark Mode, text size, the key bar layout, notifications. Pick the best value for
  everything else and record it under "Fixed choices" in `Prefs`.
- **Performance first.** The main thread only hands bytes on; parsing and drawing run elsewhere.
  `scripts/bench/budgets.mjs` holds the budgets, and a change to a measured path runs the benchmark.
- **Postures come from the window and the fold.** Layout follows the window's size and the fold's
  reserved region (`Arrangement` in `State/Posture.swift`), never the orientation, the device model
  or the hinge, so it also works in Split View and on other iPhones. The hinge is read in one
  place, `TentDetector`, and only to decide when the agent board comes and goes while the phone
  stands as a tent; the board lays itself out from its own size like everything else.

## Map

- `Packages/RexKit`: the protocol layer. `RexControl` (control socket and RPC), models,
  `TerminalStream` (data socket, reconnect, input queue, `APCFilter`, `DataFrame`), file transfer,
  folder listing (`DirLister`), `ShellEscape`, the connection log (`ConnectionLog`) and the reconnect rules (`ReconnectPolicy`, `RouteWatch`,
  `ReconnectGovernor`; docs/architecture.md, Offline). Foundation only,
  so it tests on macOS.
- `Packages/RexGlance`: what the app shares with its extensions (docs/glance.md). `GlanceModel`
  holds `Brand` (the product's names), the `rexduo:` links that open the app (`DeepLink`,
  `PaneLink`), and the snapshot of the agents that the app writes and the widgets read, with
  everything decided from it. Foundation only, so it tests on macOS. `GlanceUI` holds what the
  widgets draw with (colors, the ring, type): SwiftUI only.
- `PteronWidgets`: the app extension with the agents widget (Home Screen sizes and Lock Screen
  accessories), which only reads the snapshot, and the controls ("Open Pteron", "Jump to
  Waiting") for Control Center, the Lock Screen and the Action button, which only open the app
  with a link; `OpenLinkIntent.swift` there is compiled into the app as well, where the system
  runs it. `Views/` is compiled into the app's tests too, which draw every size and state.
- `PteronWatch`: the watch app: the agents as the iPhone app last saw them, from the snapshot
  the phone sends (docs/glance.md, The watch). It connects to nothing, and sends the phone one
  thing: Enter or Interrupt for a waiting agent, after a confirmation. `PteronWatchWidgets`: its complications and Smart Stack widget, which reuse the
  Lock Screen views and the timeline of `PteronWidgets`. `PteronWatchTests`: their tests, run
  on a watchOS simulator with the scheme `PteronWatch`.
- `Pteron/State`: `AppModel`, one `ServerConnection` per server, `Prefs`, `AgentNotifier`,
  `PushRegistrar`, `Posture.swift` (arrangement, sidebar state), `ConnectionProblem`, `NetworkWatch`,
  `ConnectionDiagnostics` (the connection log's file and the file Send Diagnostics shares;
  docs/architecture.md, The connection log), `DiagnosticReports` (the system's crash and hang
  reports, the newest 20), `StartStagger` (which computer a launch starts first),
  `TunnelProbe` (asks Tailscale's own service on the phone, for that log only),
  `GlanceWriter` (the snapshot's one writer), `GlanceBridge` (sends each written snapshot to the
  watch), `GlanceActions` (answers the watch's Enter and Interrupt: status read, guard, one
  write), `NotificationActions` (the same two on a question's notification, through
  `GlanceActions`), `ScenePhases` (what each scene phase asks; servers
  start at the first one that shows the app), `CloseNext` (what shows when the tab on screen
  closes; docs/architecture.md).
- `Pteron/Features/<Feature>`: Sidebar (machines, sessions and tabs, folding, and the Agents
  mode; docs/sidebar.md), Tab (window screen, title bar gestures, split math, floating windows, and tab mode's strip:
  `TabStrip`, its layout `StripLayout`, the chips, the session popover, `StripRoutes` and
  `DismissalWait`; docs/tab-mode.md),
  Terminal (`PaneView` → UIKit `TerminalHost` → `GhosttyTerminalView`; `TerminalHostPool` keeps the panes on screen and parks the ones that left it last (docs/terminal.md, Parking); `Ghostty/` is the engine,
  `Selection/` the touch selection UI, `Predict/` predicted echo on a slow link (docs/terminal.md, Predicted echo), `Find/` find in history (docs/terminal.md, Find), `Perf/` the benchmark's replay and probe), KeyBar (the key bar's three capsules, the setup Settings arranges and Compose; docs/terminal.md, Input and Compose), Keyboard
  (hardware keys, Rex's keymap, `TypingAids`: the system keyboard's corrections in an agent's prompt), Settings, Notifications (toasts), Offline, Onboarding (the
  first-run guide and Setup Guide's checklist; docs/architecture.md, First run),
  Pairing ("Pair via QR Code": the scanner and the check before a server is added; its logic is
  `State/Pairing.swift`), Board (the agent board of tent mode; docs/duo-layout.md, Tent mode), Files (sending photos and files to a pane, drops, Open from a selection, the file
  browser of a pane and Insert Path; docs/terminal.md, Files), Ports (a computer's dev server in the app's own browser through a Rex dial
  tunnel: the pane menu's row and tapped `localhost` links; docs/terminal.md, Ports), GoTo (Go to
  Anything, Change Session and the command palette, and the questions of actions the phone ran;
  docs/goto.md).
- `Pteron/App`: entry point, `RootView` (sidebar and tab for the window and the fold), launch
  transition.
- `Pteron/DesignSystem`: terminal themes, chrome colors derived from them, fonts, glass, the
  window controls' room (`WindowControls`).
- `PteronTests`: app tests, run in the simulator. Beacon tests live in `Relay/src`.
- `Gateway/`: the push gateway. It holds the APNs key and the phones' APNs tokens; a Beacon holds
  only a per-phone secret (`Gateway/README.md`). `Relay/release.sh` publishes Beacon releases and
  `Relay/setup.sh` is the installer: the app runs it in a tab on the computer to install the
  Beacon from the phone, and it is published as `install.sh` for a manual install (docs/helper.md).
- `Brand/`: the brand art under neutral names: the app's and Beacon's icons (Icon Composer
  documents), the launch art and its outline, the glyph, and `make-launch-art.swift`, which
  writes the launch image and `Pteron/App/LaunchArt.swift` from them.
- `scripts/`: `check-brand.sh` (no earlier product name outside the places that must keep
  one), the Ghostty build and checks, the benchmark (`bench/`), release through a build Mac.
- Glossary: Rex's *window* is a tab in the UI, *block* is a pane. Code keeps Rex's names
  (`WindowInfo`, `blockID`) to match the server's `/llms.txt`; user-facing text says tab and pane.

## Build, run, test

`Pteron.xcodeproj` is generated and untracked: edit `project.yml`, and run `xcodegen generate`
after cloning and after adding, moving or deleting a file. `Vendor/` (gitignored) holds
libghostty-vt, which a fresh clone builds once before anything else (Apple silicon, about 130 s
and 1.3 GB). An agent worktree can symlink another checkout's `Vendor` instead.

```sh
scripts/build-ghostty.sh                  # builds Vendor/GhosttyVt.xcframework; no-op when current
xcodegen generate
xcrun simctl list devices available       # pick a simulator id
xcodebuild -project Pteron.xcodeproj -scheme Pteron -destination id=<sim-id> \
  -derivedDataPath build/dd build         # `test` instead of `build` runs PteronTests (~1 min)
swift test --package-path Packages/RexKit         # protocol and stream tests on macOS, ~15 s
swift test --package-path Packages/RexGlance      # links, the snapshot, the watch's rules and the widgets' colors, on macOS
xcodebuild -project Pteron.xcodeproj -scheme PteronWatch -destination id=<watch-sim-id> \
  -derivedDataPath build/dd-watch test    # the watch app's tests; needs a watchOS simulator runtime
cargo test --manifest-path Relay/Cargo.toml       # helper: push policy, payloads, gateway client, updates
(cd Gateway && npm ci && npx vitest run)          # gateway: API, limits, the APNs call (mocked)
```

- Every app build runs `scripts/check-ghostty.sh` first. A missing or stale framework stops the build
  with one line saying to run `scripts/build-ghostty.sh`. How the build, patches and symbol check
  work: [docs/ghostty-engine.md](docs/ghostty-engine.md), Toolchain.
- To re-pin Ghostty: [docs/ghostty-engine.md](docs/ghostty-engine.md), Toolchain (it includes the
  licence check).
- Use a concrete simulator id: the framework's simulator slice is arm64 only, and
  `generic/platform=iOS Simulator` also builds x86_64. A Release simulator build needs
  `ONLY_ACTIVE_ARCH=YES` for the same reason.
- The app builds with zero warnings from our code. Keep it that way.
- After a change, run the tests for the layer you touched. For UI, run the app and look at a
  screenshot (`xcrun simctl io <id> screenshot --display=LCD out.png` on the Duo simulator shows the
  folded screen only). For other postures use `-simulateDuo` on an iPad simulator. An iPad
  window is laid out as the Duo's open screen when wide and as its folded screen when narrow;
  check a small window too (window controls, docs/duo-layout.md, iPad).
- After a change to the feed path, the renderer or the host's main-thread work, run
  `scripts/bench/run.sh <sim-id>` (about 5 minutes, no server). It fails when a number passes its
  budget (docs/ghostty-engine.md, Measurements).
- Releases (device installs, TestFlight, Beacon's packaging): [docs/release.md](docs/release.md).
- CI (`.github/workflows/ci.yml`) runs on GitHub's own machines; the owner's Macs are not used.
  Job `build` runs RexKit, RexGlance and app tests on GitHub's `xcode-27` macOS runner (Xcode 27.2),
  for pushes to main, pull requests and manual runs. It builds the Ghostty framework there and
  caches it, keyed on the pins and patches. Job `helper` runs `scripts/check-brand.sh` and
  `cargo test` on GitHub's Linux runners. `build` is required for merging into main for outside contributors;
  their fork pull requests only run after the owner approves them. The owner and their agents may merge straight to main (admin bypass)
  after building and testing locally; don't wait on CI.

## Debug launch arguments

Pass them after the bundle id: `xcrun simctl launch <id> dev.abrahamgonzalez.rexduo -autoOpen zz-test`.
Use `-autoOpen <label>` to open a throwaway session and `-simulateDuo <posture>` to check Duo layouts.
The full list (offline, network, layout, input, replay and perf arguments) is in `docs/debug-args.md`.

## Safety: the app drives real sessions

A fresh install has no servers. A simulator connects to the servers saved in it or passed with
`-servers`, which are real Rex servers where real agent sessions run. Fit mode
claims the pane you view and resizes it on the Mac, and the key bar and `-typeTest` type into a real
shell.

- Test only in throwaway sessions you create, named `zz-…` (`rex new zz-test`), and close them
  afterwards. Don't open, type into, resize, rename, split or close any other session.
- For a launch check that touches no pane, use `-autoOpen zz-none -sizing mirror`.
- Unit tests run inside the app, which doesn't connect while it hosts tests.
- `scripts/install-duo.sh`, `scripts/ship-macdesk.sh <build>` and `Relay/package.sh` (without
  `--no-notarize`) install on a phone, upload or notarize. Run them only when asked.
  `scripts/sync-macdesk.sh` overwrites only a `rexduo-build*` folder in the build Mac's home; `-n`
  lists what it would change.
- Beacon runs on the developer's machines next to other agents' sessions. Test it with a
  foreground `--dry-run` after stopping the service (Relay/README.md, "Verify by hand"). Never
  restart Rex.
- `.asc.env` and `~/.appstoreconnect/private_keys/` hold App Store Connect and APNs keys, and
  `~/.config/rexduo/helper-update.key` signs Beacon releases. Don't print, copy or commit them.
  This repository is public: no key, token or secret goes into a commit. The APNs key lives only
  in the gateway's Workers Secret; Beacon binaries hold no key.
- `Gateway/scripts/deploy.sh` changes the live gateway every Beacon depends on, and
  `Relay/release.sh --publish` ships a version every installed Beacon then installs by itself.
  Run them only when asked.

## Conventions

- Inject dependencies through `init` or `@Environment`; don't add a `static let shared`.
  `Prefs.shared` is the app's one instance, read directly only where SwiftUI doesn't reach (the
  UIKit key bar and terminal host, the replay screen).
- Put pure logic (parsing, byte encoding, layout math) in its own type with tests, not in views.
- The product name lives in GlanceModel's `Brand` and `Relay/src/brand.rs`, the brand art in `Brand/`.
  Code and folders say Pteron. These keep the old spelling, because shipped apps, installed Beacons,
  App Store Connect, Gateway data and release downloads hold them (never rename one):
  - bundle ids (`dev.abrahamgonzalez.rexduo*`), the APNs topic, the App Group, the widget and control
    kinds, the `rexduo:` URL scheme, the keychain services;
  - hash and signature domains (`rexduo-*-v1`, `rex-duo-helper|…`), the setup marker `rexduo-setup`,
    the test push thread `rexduo-test`;
  - the gateway Worker, host and D1 database `rexduo-push`, and the GitHub release URL
    `github.com/theabecaster/rexduo` with its asset names;
  - the Beacon crate, binaries, launchd labels, `REXDUO_LABEL`, `REX_DUO_DRY_RUN`, state dirs and
    `~/.config/rexduo/helper-update.key`;
  - log subsystems and queue labels, the UTType, test fixtures, and the macdesk lock
    `~/rexduo-build.lock` with the `~/rexduo-build*` folders.
- RexKit doesn't import UIKit or SwiftUI; the app passes in what it needs (`ClientInfo`).
- UI and state types are `@MainActor`. Use `@unchecked Sendable` or `nonisolated(unsafe)` only with a
  comment that says why it is safe.
- Socket callbacks check their generation counter before touching state, so a stale socket can't
  overwrite fresh state after a reconnect.
- Send terminal input through `TerminalStream.send`, and key-bound server calls through its
  `perform(action:)` and `forward(key:)`. They share one queue with one request in flight because
  Rex doesn't order concurrent block calls, and a request that left is never resent because
  `terminal.write` has no sequence number (docs/terminal.md, Input). Input that answers from
  elsewhere (the watch) goes through the same queue with `sendOnce`: now or not at all.
- Nothing reaches a program state the user did not see. While a stream catches up its fence
  holds typed bytes and sends them only over an exact screen; reports and actions are dropped
  (docs/terminal.md, The catch-up fence). Bytes made from a place on the screen go through
  `engineSendReport`, never `engineSend`.
- `RexControl` is the only thing that retries a lost connection. Code that needs it waits for
  `observeConnected` instead of polling.
- Other sessions work in parallel worktrees. Keep diffs to what the task needs; move files with `git mv`.
- Commits: imperative subject, plain message, no AI attribution or trailers.
- Clean up what you create: simulators (`xcrun simctl delete <id>`), `build/`, `.build/`,
  `Relay/target/` and finished worktrees.

## Docs

[docs/development.md](docs/development.md) is the entry point for human developers; the README
is for users. Read the one for the area you touch:

- [docs/architecture.md](docs/architecture.md): layers, data flow, offline handling, concurrency,
  where new code goes.
- [docs/rex-protocol.md](docs/rex-protocol.md): the control API methods and events the app uses.
- [docs/terminal.md](docs/terminal.md): data stream, reconnect, fit and mirror, gestures, input.
- [docs/ghostty-engine.md](docs/ghostty-engine.md): the engine, threads and locks, snapshot restore,
  toolchain and patches, measurements. [docs/ghostty-api-notes.md](docs/ghostty-api-notes.md):
  libghostty-vt rules the engine relies on.
- [docs/selection.md](docs/selection.md): touch selection (loupe, handles, haptics).
- [docs/goto.md](docs/goto.md): the palette (Go to Anything, Change Session, commands), its
  ranking, the keyboard hold, and questions from the phone's own runs.
- [docs/terminal-checklist.md](docs/terminal-checklist.md): what the terminal must do, the test for
  each row, and the manual device scripts.
- [docs/duo-layout.md](docs/duo-layout.md): sidebar, postures and the Duo's vertical bar.
- [docs/tab-mode.md](docs/tab-mode.md): tab mode: the strip, the chips, the session popover,
  where the sidebar's things are, the crease, the dismissal wait.
- [docs/sidebar.md](docs/sidebar.md): the sidebar's levels, folding, Agents mode, not-added hosts.
- [docs/notifications.md](docs/notifications.md): toasts, permission, push through the helper.
- [docs/glance.md](docs/glance.md): the widgets, the snapshot they read, the watch app, the
  controls, the `rexduo:` links and what each does.
- [docs/release.md](docs/release.md): device installs, TestFlight via a build Mac, Beacon releases.
- [docs/helper.md](docs/helper.md): installing Beacon, how it updates and what it checks.
