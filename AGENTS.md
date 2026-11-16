# Rex Connect

iOS remote for Rex, a terminal multiplexer. The app connects to a Rex server's control API and
terminal data stream over the server's Tailscale HTTPS address, draws panes with SwiftTerm or
libghostty-vt (two engines behind one seam), and
creates, splits, resizes and types into real Rex sessions. It is built for the iPhone Duo (unfolded,
it shows the sidebar beside the tab's splits) and works on any iPhone. `Relay/` holds Rex Connect
Helper, a signed Mac app that sends push notifications for Rex events.

Stack: Swift 6 language mode (app and RexKit; Relay is still Swift 5 mode), SwiftUI + UIKit,
iOS 18, Xcode 27.2, XcodeGen, SwiftTerm 1.99.3 (exact pin), libghostty-vt (static xcframework built
by `scripts/build-ghostty.sh`), Swift Testing (the engine and stream-snapshot tests are XCTest).
Bundle id `dev.abrahamgonzalez.rexduo` predates the name and stays: App Store Connect and the
APNs topic depend on it.

## Map

- `Packages/RexKit`: the protocol layer. `RexControl` (control socket and RPC), models,
  `TerminalStream` (data socket, `APCFilter`, `DataFrame`). Foundation only, so it tests on macOS.
  Relay uses its JSON helpers too.
- `RexConnect/State`: `AppModel` (selection, servers), one `ServerConnection` per server
  (sessions, layouts, block metadata, server events, actions), `Prefs`, `AgentNotifier`,
  `PushRegistrar` (push registration with the Mac helper).
- `RexConnect/Features/<Feature>`: Sidebar, Tab (window screen, title bar gestures,
  split math), Terminal (`PaneView` → UIKit `TerminalHost` → `TerminalEngineView`: `Engine/` has the
  seam and the SwiftTerm adapter, `Ghostty/` the libghostty-vt engine), KeyBar, Keyboard
  (hardware keys and Rex's keymap), Agents, Settings, Notifications (in-app toasts, permission card).
- `RexConnect/App`: entry point, `RootView` (layout by size class and the fold, `Arrangement` in `State/Posture.swift`), launch transition.
- `RexConnect/DesignSystem`: terminal themes and chrome colors derived from them, fonts.
- `RexConnectTests`: app logic tests. `Relay/Tests`: relay tests.
- Glossary: Rex's *window* is a tab in the UI, *block* is a pane, *layer* is a tiled or floating
  group. Code keeps Rex's names (`WindowInfo`, `blockID`) because they match the server's
  `/llms.txt`; user-facing text says tab and pane.

## Build, run, test

`RexConnect.xcodeproj` is generated and not tracked. Run `xcodegen generate` after cloning and after
adding, moving or deleting a file; edit `project.yml`, never the project.

```sh
scripts/build-ghostty.sh                       # once: builds Vendor/GhosttyVt.xcframework (gitignored)
xcodegen generate
xcrun simctl list devices available            # pick a simulator id
xcodebuild -project RexConnect.xcodeproj -scheme RexConnect -destination id=<sim-id> \
  -derivedDataPath build/dd -skipPackagePluginValidation -skipMacroValidation build
xcodebuild ... test                             # same flags: RexConnectTests in the simulator
swift test --package-path Packages/RexKit       # protocol tests on macOS, about a second
swift test --package-path Relay                 # helper and push policy tests
```

- Use a concrete simulator id and pass `-skipPackagePluginValidation -skipMacroValidation`.
  SwiftTerm's build plugin fails validation in command-line builds otherwise, and
  `generic/platform=iOS Simulator` fails with it.
- The app builds with zero warnings from our code; keep it that way.
- After a change, run the tests for the layer you touched. For UI changes, run the app and look at a
  screenshot (`xcrun simctl io <id> screenshot --display=LCD out.png` on the Duo simulator; it shows
  the folded screen only). For other layouts use `-simulateDuo` on an iPad simulator, building with
  `TARGETED_DEVICE_FAMILY=1,2` on the command line so the app runs at full size there.

## Debug launch arguments

Pass after the bundle id: `xcrun simctl launch <id> dev.abrahamgonzalez.rexduo -autoOpen zz-test -sizing mirror`.
Each is a UserDefaults key for that run only.

- `-autoOpen <session label>`: open that session's first tab. A label that doesn't exist opens nothing.
- `-sizing fit|mirror`: override the Pane Size setting.
- `-terminalEngine ghostty|swiftTerm`: override the Engine setting.
- `-ghosttyDemo <path>`: no server; replay a capture file in a full-screen Ghostty view
  (`GhosttyDemoScreen`).
- `-typeTest 'text\n'`: type the text into the active pane once it is live.
- `-hinge closed|partial|full`: pretend the hinge reports this. It only tints the crease; layout never reads it.
- `-simulateDuo <posture>[,<posture>…]` (Debug builds): lay the root out at that window size, with its
  size classes and a fake fold drawn as a red dashed line, at the bottom-left of a bigger screen.
  Postures: `unfolded` (951×669, flat crease), `book` (951×669, bent), `unfoldedPortrait` (669×951),
  `tabletop` (669×951, bent), `folded` (466×678), `halfWindow` (475×669, one half of the unfolded
  screen), `iPhone` (402×874), `iPhoneLandscape` (874×402), `proMaxLandscape` (956×440). A list
  cycles every `-simulateDuoEvery` seconds (default 10), to check what a fold keeps.
- `-focus none` (Debug builds): don't give the active pane the keyboard at launch.
- `-overlaySidebar YES` (Debug builds): start with the unfolded-portrait sidebar overlay open.
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
- `scripts/install-duo.sh`, `scripts/ship-macdesk.sh` and `Relay/package.sh` (without
  `--no-notarize`) install, upload or notarize. Run them only when asked.
- `.asc.env` and `~/.appstoreconnect/private_keys/` hold App Store Connect and APNs keys. Don't
  print, copy or commit them. `Relay/dist` holds a build with the APNs key inside; it is gitignored.

## Conventions

- Inject dependencies through `init` or `@Environment`; avoid new `static let shared`. `Prefs.shared`
  is left only where SwiftUI doesn't reach (UIKit key bar and terminal host, the `Haptic` helper).
- Put pure logic (parsing, byte encoding, layout math) in its own type with tests, not in views.
- RexKit must not import UIKit or SwiftUI; the app passes in what it needs (`ClientInfo`).
- UI and state types are `@MainActor`. Don't silence concurrency checks with `@unchecked Sendable`
  or `nonisolated(unsafe)` unless a comment says why it is safe.
- Socket callbacks check they still belong to the current connection (generation counters) before
  touching state; a stale socket would otherwise overwrite fresh state after a reconnect.
- Send terminal input through `TerminalStream.send`. It keeps one `terminal.write` in flight because
  Rex doesn't order concurrent block calls, so parallel writes reorder keystrokes.
- Other sessions work in parallel worktrees (Ghostty engine work is on branch `ghostty-engine`).
  Keep diffs to what the task needs, and move files with `git mv`.
- Commits: imperative subject, plain message, no AI attribution or trailers (no `Co-Authored-By`,
  "Generated with", or session links).
- Clean up what you create: delete simulators you made (`xcrun simctl delete <id>`), `build/`,
  `.build/` and finished worktrees.

## Docs

Read the one for the area you touch:

- [docs/architecture.md](docs/architecture.md): data flow, state, concurrency, where new code goes.
- [docs/rex-protocol.md](docs/rex-protocol.md): control API methods and events the app uses.
- [docs/terminal.md](docs/terminal.md): data stream, engines, fit and mirror, gestures, keyboard input.
- [docs/ghostty-engine.md](docs/ghostty-engine.md): the Ghostty engine's plan, design and status;
  [docs/ghostty-api-notes.md](docs/ghostty-api-notes.md): libghostty-vt API notes.
- [docs/notifications.md](docs/notifications.md): local notifications, the helper, the relay contract.
- [docs/release.md](docs/release.md): device installs, TestFlight via macdesk, helper packaging.
