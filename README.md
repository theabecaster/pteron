# Rex DUO

A native iOS remote for [Rex](https://rex.superlogical.com) terminal servers, built for the iPhone
Duo and fine on any iPhone. It speaks Rex's documented API (`/llms.txt` on any Rex server) over the
server's built-in Tailscale HTTPS address.

- Rex-style sidebar (hosts → sessions → tabs) with agent icons and live status (working, waiting,
  done) from OSC 7501 program status.
- Live terminals drawn by Ghostty's terminal core (libghostty-vt) and a Metal renderer, with Rex's
  themes and MesloLGS Nerd Font.
- Unfolded Duo: sidebar beside the tab, splits laid out as Rex lays them out, draggable borders.
  Folded or other iPhones: one pane at a time.
- Fit to phone: the pane you view is resized to the phone and handed back to the Mac when you
  leave.
- Sessions, tabs and splits; zoom, rename, clear; a key bar with Agents, Shell and Vim layouts; hardware keyboard
  shortcuts from your Rex keymap; an Agents screen; a notification when an agent waits for you.
- **Rex DUO Helper** (`Relay/`): a small Mac app or Linux service that sends push
  notifications while the app is closed.

## Connect a server

On each machine: `rex server tailscale enable` and sign in. In the app, add
`https://<name>.<tailnet>.ts.net` under Settings → Servers. The phone must run Tailscale as the
same user.

## Build

Needs an Apple silicon Mac with Xcode 27.2 and XcodeGen (`brew install xcodegen`).

```sh
scripts/build-ghostty.sh   # once: builds the terminal engine into Vendor/ (about 130 s, not committed)
xcodegen generate          # the Xcode project is generated, not committed
xcodebuild -project RexDuo.xcodeproj -scheme RexDuo -destination id=<simulator id> build
```

Tests, debug launch arguments and the rules for working on the code are in [AGENTS.md](AGENTS.md).

Licences of the bundled open source code are in `RexDuo/Resources/Acknowledgements.txt`, shown
in the app under Settings → About → Acknowledgements.

## More

- [AGENTS.md](AGENTS.md): product principles, commands, debug launch arguments, safety rules, conventions.
- [docs/](docs/): architecture, Rex protocol, terminal engine, layout, notifications, release.
- [Relay/README.md](Relay/README.md): the helper app.
