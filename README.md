# Rex Duo

A native iOS remote for [Rex](https://rex.superlogical.com) servers, built for the iPhone Duo
(works on any iPhone). It speaks Rex's own documented API (`/llms.txt` on any Rex server) over
the server's built-in Tailscale HTTPS address.

## What it does

- Rex-style sidebar: hosts → sessions → tabs, with agent icons (Claude, Codex, …) and live
  status (working / waiting / done) from OSC 7501 program status.
- Live terminals rendered with SwiftTerm, Rex's theme (GitHub Dark Dimmed by default, plus all
  of Rex's built-in themes) and MesloLGS Nerd Font.
- Unfolded Duo (≥ 600 pt wide): sidebar beside the tab, splits drawn the way Rex lays them out,
  draggable split borders. Folded / other iPhones: one pane at a time with a pane strip.
- Fit to phone: while you view a pane, Rex Duo owns it and resizes it to the phone; leaving the
  pane or backgrounding the app hands it back to the Mac. Mirror mode keeps the Mac's size.
- Create/close sessions, tabs, splits; zoom, rename, clear; customizable key bar (esc, ctrl,
  alt, arrows, …); Agents screen; local notification when an agent starts waiting for you.

## How it talks to Rex

| Piece | Endpoint |
| --- | --- |
| Control (JSON, `rex.control.v1`) | `wss://<server>/api/control` |
| Terminal output (`rex.data.terminal.v1`) | `wss://<server>/api/data` with a ticket from `data.connect` |
| Typing | `com.superlogical.terminal.write`, one write at a time |

The data stream starts with a binary Ghostty snapshot. Rex Duo skips it up to the first
`ESC _ rex1;<nonce>;…` marker and seeds the screen with `terminal.format` (`vt`) instead.

## Reaching other machines

Only servers with Rex's built-in Tailscale on are reachable from the phone. On each machine:
`rex server tailscale enable`, sign in, then add `https://<name>.<tailnet>.ts.net` in
Settings → Servers. The phone must run Tailscale as the same user.

## Build

```sh
xcodegen generate
xcodebuild -project RexDuo.xcodeproj -scheme RexDuo -destination 'id=<simulator id>' \
  -skipPackagePluginValidation -skipMacroValidation build
```

Use a concrete simulator id: SwiftTerm's build-tool plugin fails with `generic/platform=iOS Simulator`.
Debug launch args: `-autoOpen <session label>`, `-sizing fit|mirror`, `-typeTest 'text\n'`.

## Ship (macdesk)

`scripts/ship-macdesk.sh` archives and uploads. Code signing needs the GUI login session, so
run it through `sudo launchctl asuser $(id -u) sudo -u $USER zsh -lc '~/rexduo-build/ship.sh <build>'`.
`scripts/testflight-when-ready.sh <build>` waits for the App Store Connect record, uploads, then
deletes macdesk's copy. `.asc.env` (gitignored) holds the API issuer id.
