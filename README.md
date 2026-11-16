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
  leave. Mirror mode keeps the Mac's size.
- Sessions, tabs and splits; zoom, rename, clear; a customizable key bar; hardware keyboard
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
scripts/build-ghostty.sh   # once: builds Vendor/GhosttyVt.xcframework (libghostty-vt, not committed)
xcodegen generate          # the Xcode project is generated, not committed
xcodebuild -project RexConnect.xcodeproj -scheme RexConnect -destination id=<simulator id> \
  -skipPackagePluginValidation -skipMacroValidation build
swift test --package-path Packages/RexKit
```

Or open `RexConnect.xcodeproj` in Xcode 27.2 after `xcodegen generate`.

## More

- [AGENTS.md](AGENTS.md): working conventions, commands, debug launch arguments and safety rules.
- [docs/](docs/): architecture, Rex protocol, terminal, notifications, release.
- [Relay/README.md](Relay/README.md): the helper app.
