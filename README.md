# Rex Connect

A native iOS remote for [Rex](https://rex.superlogical.com) terminal servers, built for the iPhone
Duo and fine on any iPhone. It speaks Rex's documented API (`/llms.txt` on any Rex server) over the
server's built-in Tailscale HTTPS address.

- Rex-style sidebar (hosts → sessions → tabs) with agent icons and live status (working, waiting,
  done) from OSC 7501 program status.
- Live terminals with SwiftTerm, Rex's themes and MesloLGS Nerd Font.
- Unfolded Duo: sidebar beside the tab, splits laid out as Rex lays them out, draggable borders.
  Folded or other iPhones: one pane at a time.
- Fit to phone: the pane you view is resized to the phone and handed back to the Mac when you
  leave.
- Sessions, tabs and splits; zoom, rename, clear; a key bar with Agents, Shell and Vim layouts; hardware keyboard
  shortcuts from your Rex keymap; an Agents screen; a notification when an agent waits for you.
- **Rex Connect Helper** (`Relay/`): a small Mac app that sends push notifications while the app is
  closed.

## Connect a server

On each machine: `rex server tailscale enable` and sign in. In the app, add
`https://<name>.<tailnet>.ts.net` under Settings → Servers. The phone must run Tailscale as the
same user.

## Build

```sh
brew install xcodegen
scripts/build-ghostty.sh   # once, before xcodegen: builds Vendor/GhosttyVt.xcframework (not committed)
xcodegen generate          # the Xcode project is generated, not committed
xcodebuild -project RexConnect.xcodeproj -scheme RexConnect -destination id=<simulator id> \
  -skipPackagePluginValidation -skipMacroValidation build
swift test --package-path Packages/RexKit
```

Or open `RexConnect.xcodeproj` in Xcode 27.2 after `xcodegen generate`.

`scripts/build-ghostty.sh` builds the Ghostty terminal engine (libghostty-vt) from the commit pinned
in `scripts/ghostty.version`. It needs an Apple silicon Mac. The first run downloads the Zig
compiler (51 MB) and Ghostty with its dependencies, takes about 130 seconds and leaves 1.3 GB in
`Vendor/`, which is gitignored; nothing is installed system-wide. Later runs do nothing unless the
pins changed. `scripts/build-ghostty.sh --force` rebuilds. To move to another Ghostty commit, edit
`scripts/ghostty.version` and run the script again. A build with a missing or out-of-date framework
stops with a message that says to run it.

Licences of the bundled open source code are in `RexConnect/Resources/Acknowledgements.txt`, shown
in the app under Settings → About → Acknowledgements.

## More

- [AGENTS.md](AGENTS.md): working conventions, commands, debug launch arguments and safety rules.
- [docs/](docs/): architecture, Rex protocol, terminal, notifications, release.
- [Relay/README.md](Relay/README.md): the helper app.
