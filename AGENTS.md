# Rex Connect

iOS remote for Rex, a terminal multiplexer. The app connects to a Rex server's control API and
terminal data stream over the server's Tailscale HTTPS address, draws panes with libghostty-vt and
its own Metal renderer, and creates, splits, resizes and types into real Rex sessions. It is built
for the iPhone Duo and works on any iPhone. The home screen shows it as "Rex DUO"; the code and
docs say Rex Connect. `Relay/` holds Rex Connect Helper, a Rust program for macOS and Linux that
sends push notifications for Rex events.

Stack: Swift 6 language mode, SwiftUI + UIKit, iOS 18, Xcode 27.2, XcodeGen, libghostty-vt (a
static xcframework built locally), Swift Testing and XCTest. No other app dependencies. The helper
is Rust (tokio, rustls, h2; `Relay/Cargo.lock` pins them). Bundle id `dev.abrahamgonzalez.rexduo`
predates the name and stays: App Store Connect and the APNs topic depend on it.

## Product principles

- **Mac-like.** The app is the Rex Mac app on a phone: a sidebar beside or over the tab, splits laid
  out as the Mac lays them out, Rex's keymap. Keep chrome off the terminal: no toolbars, badges or
  standing overlays on a pane, only short-lived notices, because every point of chrome costs rows
  of text.
- **Few settings.** Settings holds only what a user would choose and understand: servers, a theme
  for Light and Dark Mode, text size, the key bar layout, notifications. Pick the best value for
  everything else and record it under "Fixed choices" in `Prefs`.
- **Performance first.** The main thread only hands bytes on; parsing and drawing run elsewhere.
  `scripts/bench/budgets.mjs` holds the budgets, and a change to a measured path runs the benchmark.
- **Postures come from the window and the fold.** Layout follows the window's size and the fold's
  reserved region (`Arrangement` in `State/Posture.swift`), never the orientation, the device model
  or the hinge, so it also works in Split View and on other iPhones.

## Map

- `Packages/RexKit`: the protocol layer. `RexControl` (control socket and RPC), models,
  `TerminalStream` (data socket, reconnect, input queue, `APCFilter`, `DataFrame`). Foundation only,
  so it tests on macOS.
- `RexConnect/State`: `AppModel`, one `ServerConnection` per server, `Prefs`, `AgentNotifier`,
  `PushRegistrar`, `Posture.swift` (arrangement, sidebar state), `ConnectionProblem`, `NetworkWatch`.
- `RexConnect/Features/<Feature>`: Sidebar, Tab (window screen, title bar gestures, split math),
  Terminal (`PaneView` → UIKit `TerminalHost` → `GhosttyTerminalView`; `Ghostty/` is the engine,
  `Selection/` the touch selection UI, `Perf/` the benchmark's replay and probe), KeyBar, Keyboard
  (hardware keys, Rex's keymap), Agents, Settings, Notifications (toasts, permission card), Offline.
- `RexConnect/App`: entry point, `RootView` (sidebar and tab for the window and the fold), launch
  transition.
- `RexConnect/DesignSystem`: terminal themes, chrome colors derived from them, fonts.
- `RexConnectTests`: app tests, run in the simulator. Helper tests live in `Relay/src`.
- `scripts/`: the Ghostty build and checks, the benchmark (`bench/`), release to macdesk.
- Glossary: Rex's *window* is a tab in the UI, *block* is a pane. Code keeps Rex's names
  (`WindowInfo`, `blockID`) to match the server's `/llms.txt`; user-facing text says tab and pane.

## Build, run, test

`RexConnect.xcodeproj` is generated and untracked: edit `project.yml`, and run `xcodegen generate`
after cloning and after adding, moving or deleting a file. `Vendor/` (gitignored) holds
libghostty-vt, which a fresh clone builds once before anything else (Apple silicon, about 130 s
and 1.3 GB). An agent worktree can symlink another checkout's `Vendor` instead.

```sh
scripts/build-ghostty.sh                  # builds Vendor/GhosttyVt.xcframework; no-op when current
xcodegen generate
xcrun simctl list devices available       # pick a simulator id
xcodebuild -project RexConnect.xcodeproj -scheme RexConnect -destination id=<sim-id> \
  -derivedDataPath build/dd build         # `test` instead of `build` runs RexConnectTests (~1 min)
swift test --package-path Packages/RexKit         # protocol and stream tests on macOS, ~15 s
cargo test --manifest-path Relay/Cargo.toml       # helper: push policy, payloads, JWT, devices
```

- Every app build runs `scripts/check-ghostty.sh` first. A missing or stale framework stops the build
  with one line saying to run `scripts/build-ghostty.sh`. How the build, patches and symbol check
  work: [docs/ghostty-engine.md](docs/ghostty-engine.md), Toolchain.
- To re-pin Ghostty, change `GHOSTTY_COMMIT` in `scripts/ghostty.version` (and the Zig version and
  hash if Ghostty's `minimum_zig_version` moved), run the build script, and check
  `RexConnect/Resources/Acknowledgements.txt` against the `"use": "linked"` entries in
  `Vendor/ghostty/deps/libghostty-vt-third-party.json`, because the app must ship every linked
  licence.
- Use a concrete simulator id: the framework's simulator slice is arm64 only, and
  `generic/platform=iOS Simulator` also builds x86_64. A Release simulator build needs
  `ONLY_ACTIVE_ARCH=YES` for the same reason.
- The app builds with zero warnings from our code. Keep it that way.
- After a change, run the tests for the layer you touched. For UI, run the app and look at a
  screenshot (`xcrun simctl io <id> screenshot --display=LCD out.png` on the Duo simulator shows the
  folded screen only). For other postures use `-simulateDuo` on an iPad simulator, built with
  `TARGETED_DEVICE_FAMILY=1,2` on the command line so the app runs full size there.
- After a change to the feed path, the renderer or the host's main-thread work, run
  `scripts/bench/run.sh <sim-id>` (about 5 minutes, no server). It fails when a number passes its
  budget (docs/ghostty-engine.md, Measurements).
- Releases (device installs, TestFlight, the helper's packaging): [docs/release.md](docs/release.md).

## Debug launch arguments

Pass them after the bundle id: `xcrun simctl launch <id> dev.abrahamgonzalez.rexduo -autoOpen zz-test`.
Use `-autoOpen <label>` to open a throwaway session and `-simulateDuo <posture>` to check Duo layouts.
The full list (offline, network, layout, input, replay and perf arguments) is in `docs/debug-args.md`.

## Safety: the app drives real sessions

The simulator connects to the owner's real Rex servers, where real agent sessions run. Fit mode
claims the pane you view and resizes it on the Mac, and the key bar and `-typeTest` type into a real
shell.

- Test only in throwaway sessions you create, named `zz-…` (`rex new zz-test`), and close them
  afterwards. Don't open, type into, resize, rename, split or close any other session.
- For a launch check that touches no pane, use `-autoOpen zz-none -sizing mirror`.
- Unit tests run inside the app, which doesn't connect while it hosts tests.
- `scripts/install-duo.sh`, `scripts/ship-macdesk.sh <build>` and `Relay/package.sh` (without
  `--no-notarize`) install on a phone, upload or notarize. Run them only when asked.
  `scripts/sync-macdesk.sh` overwrites only a `rexconnect-build*` folder in macdesk's home; `-n`
  lists what it would change.
- The helper runs on this Mac, macdesk and workdesk next to other agents' sessions. Test it with a
  foreground `--dry-run` after stopping the service (Relay/README.md, "Verify by hand"). Never
  restart Rex.
- `.asc.env` and `~/.appstoreconnect/private_keys/` hold App Store Connect and APNs keys. Don't
  print, copy or commit them. `build.rs` embeds the APNs key in every helper binary, so
  `Relay/target`, `Relay/dist` and `Relay/.stage` hold it; all are gitignored and never sent to
  macdesk.

## Conventions

- Inject dependencies through `init` or `@Environment`; don't add a `static let shared`.
  `Prefs.shared` is the app's one instance, read directly only where SwiftUI doesn't reach (the
  UIKit key bar and terminal host, the replay screen).
- Put pure logic (parsing, byte encoding, layout math) in its own type with tests, not in views.
- RexKit doesn't import UIKit or SwiftUI; the app passes in what it needs (`ClientInfo`).
- UI and state types are `@MainActor`. Use `@unchecked Sendable` or `nonisolated(unsafe)` only with a
  comment that says why it is safe.
- Socket callbacks check their generation counter before touching state, so a stale socket can't
  overwrite fresh state after a reconnect.
- Send terminal input through `TerminalStream.send`, and key-bound server calls through its
  `perform(action:)` and `forward(key:)`. They share one queue with one request in flight because
  Rex doesn't order concurrent block calls, and a request that left is never resent because
  `terminal.write` has no sequence number (docs/terminal.md, Input).
- `RexControl` is the only thing that retries a lost connection. Code that needs it waits for
  `observeConnected` instead of polling.
- Other sessions work in parallel worktrees. Keep diffs to what the task needs; move files with `git mv`.
- Commits: imperative subject, plain message, no AI attribution or trailers.
- Clean up what you create: simulators (`xcrun simctl delete <id>`), `build/`, `.build/`,
  `Relay/target/` and finished worktrees.

## Docs

Read the one for the area you touch:

- [docs/architecture.md](docs/architecture.md): layers, data flow, offline handling, concurrency,
  where new code goes.
- [docs/rex-protocol.md](docs/rex-protocol.md): the control API methods and events the app uses.
- [docs/terminal.md](docs/terminal.md): data stream, reconnect, fit and mirror, gestures, input.
- [docs/ghostty-engine.md](docs/ghostty-engine.md): the engine, threads and locks, snapshot restore,
  toolchain and patches, measurements. [docs/ghostty-api-notes.md](docs/ghostty-api-notes.md):
  libghostty-vt rules the engine relies on.
- [docs/selection.md](docs/selection.md): touch selection (loupe, handles, haptics).
- [docs/terminal-checklist.md](docs/terminal-checklist.md): what the terminal must do, the test for
  each row, and the manual device scripts.
- [docs/duo-layout.md](docs/duo-layout.md): sidebar, postures and the Duo's vertical bar.
- [docs/notifications.md](docs/notifications.md): toasts, permission, push through the helper.
- [docs/release.md](docs/release.md): device installs, TestFlight via macdesk, helper packaging.
