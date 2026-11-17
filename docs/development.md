# Development

How to build, test and change Rex DUO. [AGENTS.md](../AGENTS.md) is the full working guide (the
code map, the safety rules for testing against real sessions, and the conventions), written for
coding agents and just as useful to people. This page is the short way in.

The repository holds three programs:

- `RexDuo/` and `Packages/RexKit/`: the iOS app (Swift, SwiftUI and UIKit).
- `Relay/`: Rex DUO Helper, which sends push notifications from a computer (Rust).
- `Gateway/`: the push gateway that passes them to Apple (TypeScript on Cloudflare Workers).

## Requirements

- An Apple silicon Mac with Xcode 27.2 and XcodeGen (`brew install xcodegen`).
- Rust and Cargo, for the helper.
- Node and npm, for the gateway.
- To run the app against something real: a computer with Rex and Tailscale serving on (see the
  [README](../README.md)).

## Build the app

```sh
scripts/build-ghostty.sh   # once: builds the terminal engine into Vendor/ (about 130 s, not committed)
xcodegen generate          # the Xcode project is generated, not committed
xcrun simctl list devices available
xcodebuild -project RexDuo.xcodeproj -scheme RexDuo -destination id=<simulator id> \
  -derivedDataPath build/dd build
```

- Run `xcodegen generate` again after adding, moving or deleting a file. Change build settings
  in `project.yml`, never in the generated project.
- Every app build first checks that `Vendor/GhosttyVt.xcframework` matches the pins in
  `scripts/ghostty.version`, and stops with one line saying to run `scripts/build-ghostty.sh`
  when it doesn't. How the engine is built and patched, and how to re-pin it:
  [ghostty-engine.md](ghostty-engine.md), Toolchain.
- Use a concrete simulator id. The engine's simulator slice is arm64 only, so
  `generic/platform=iOS Simulator` fails to link.
- The app builds with zero warnings from our code.

## Test

```sh
xcodebuild -project RexDuo.xcodeproj -scheme RexDuo -destination id=<simulator id> \
  -derivedDataPath build/dd test                  # app tests in the simulator, about 1 minute
swift test --package-path Packages/RexKit         # protocol and stream tests on macOS
cargo test --manifest-path Relay/Cargo.toml       # the helper
(cd Gateway && npm ci && npx vitest run)          # the gateway
```

- A change to the terminal's feed path, renderer or main-thread work also runs the benchmark,
  `scripts/bench/run.sh <simulator id>` (about 5 minutes, no server needed). It fails when a
  number passes its budget ([ghostty-engine.md](ghostty-engine.md), Measurements).
- [terminal-checklist.md](terminal-checklist.md) lists what the terminal must do, the test for
  each item, and the manual scripts to run on a device.
- Launch arguments for testing (simulated postures, offline screens, replays, the helper setup
  sheet) are in [debug-args.md](debug-args.md).

**The app drives real sessions.** A simulator connects to real Rex servers, resizes the pane you
look at, and types into real shells. Test only in throwaway sessions you create, named `zz-…`
(`rex new zz-test`), and close them afterwards. AGENTS.md, "Safety", has the rest.

## Project layout

AGENTS.md, "Map", says where each part of the app lives. [architecture.md](architecture.md)
covers the layers, the data flow and where new code goes. The other documents:

- [rex-protocol.md](rex-protocol.md): the parts of Rex's control API the app uses.
- [terminal.md](terminal.md): the data stream, reconnecting, sizing, gestures and input.
- [ghostty-engine.md](ghostty-engine.md) and [ghostty-api-notes.md](ghostty-api-notes.md): the
  terminal engine and the libghostty-vt rules it relies on.
- [selection.md](selection.md): touch selection.
- [duo-layout.md](duo-layout.md) and [sidebar.md](sidebar.md): layout, postures and the sidebar.
- [notifications.md](notifications.md): in-app toasts, push notifications, the contract between
  the app and the helper, and installing the helper from the app.
- [helper.md](helper.md): installing the helper by hand and how it updates.
  [Relay/README.md](../Relay/README.md): the helper's internals.
  [Gateway/README.md](../Gateway/README.md): the gateway's API, limits and deploy.

## CI

`.github/workflows/ci.yml` runs two jobs:

- `build`: RexKit tests on every pull request, on GitHub's macOS runner. Pushes to main and
  manual runs also build the engine and run the app tests, on a self-hosted Mac runner.
- `helper`: `cargo test` on GitHub's Linux runner.

Pull requests from forks run only after the owner approves them.

## Releases

Device installs, TestFlight uploads, helper releases and gateway deploys:
[release.md](release.md). They sign, upload or publish, so they are for the maintainer.

## Contributing

Read [CONTRIBUTING.md](../CONTRIBUTING.md) for the licence terms of contributions. Commits use an
imperative subject and a plain message.
