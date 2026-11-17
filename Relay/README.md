# Rex DUO Helper

Sends Rex DUO push notifications for the Rex server on the same machine. Rex has no push
support of its own, so the helper connects to Rex as an ordinary client (named `rex-push-relay`,
which is what the iOS app looks for), watches every session, and sends a push when:

| Event | Category | Interruption level |
| --- | --- | --- |
| An agent becomes `blocked` (OSC 7501: question, permission, sign-in) | `AGENT_BLOCKED` | `time-sensitive`, sound |
| An agent reports `done` or `error` | `AGENT_DONE` | `passive`, no sound |
| A terminal raises a desktop notification (OSC 9 / OSC 777) | `NOTICE` | `active`, sound |

It skips a phone while Rex DUO is open on it, since the app shows its own toasts then.
Phones register through Rex itself (client actions), so the helper opens no ports. Every
machine that runs a Rex server needs its own helper.

The helper holds no Apple key and never sees a phone's APNs token. Each phone registers with
the push gateway (`Gateway/`), mints one secret per helper there, and hands that secret to the
helper. For every event the helper sends one `POST <gateway>/v1/push` with that phone's secret;
the gateway, which holds the APNs key and the token, passes the payload to Apple. A helper can
push only to the phones that gave it a secret.

Any client of the Rex server can call the helper's actions, so two things guard them:

- **Identity.** On first run the helper makes an ed25519 key (`identity.key` in the state
  folder, PKCS#8, mode 0600) that never leaves the computer. A phone asks `helper_identity`
  before it hands over anything, pins the public key the first time, and refuses a helper whose
  key changed until its user says to trust it. Another client that calls itself
  `rex-push-relay` can't answer for the helper.
- **Authorization.** Every action reads who the Rex server says the caller is (the `principal`
  of the server-filled `requester`: kind plus `uid`, `sid` or Tailscale `user_id`). A caller the
  server did not identify (`anonymous`) is refused everything. A registration belongs to the
  identity that made it; "What the app must do" lists what each action allows.

One Rust program, `rex-duo-helper`, runs on macOS and Linux. On a Mac it ships inside
**Rex DUO Helper.app**, whose only executable is that same binary.

## Install

**From Rex DUO.** After a computer is added, the app offers to install the helper on it. The app
checks the signed release list on the phone, then runs `Relay/setup.sh`, which it carries, in a
tab on the computer, with 12 arguments: `2`, the version, the oldest version it accepts, the
SHA-256 and size of the Mac file and of each of the two Linux files, the keys it trusts (1 to 6,
with commas between them), `ask` or `skip` for lingering, and `-`. Its one-time setup code is
not an argument. The script turns the terminal's echo off, reports a record with the title
`code`, and reads one line from the terminal for up to 60 s: the app types the code (64 hex
digits and Return) when it sees that record. The script never prints the code. It writes it to
a file of mode 0600 in its own staging folder (mode 0700) and passes the helper that file's
path (step 4).

**With one command**, on a Mac or on Linux. This is the same `setup.sh`, published as
`install.sh`; run without arguments, it reads the release list itself:

```sh
curl -fsSL https://github.com/theabecaster/rexduo/releases/download/helper-latest/install.sh | sh
```

On Linux it checks the release list's signature with openssl 3. macOS's own `openssl` does not
check such a signature, so on a Mac Apple's checks of the app decide (code signature, team and
bundle id, notarization), and the script says so. It goes by two values that `release.sh`
writes into the published copy: it installs no version older than the release it was published
with, and nothing after the release list's expiry date. `Relay/setup.sh` as committed has both
values empty and, run by hand on a Mac, installs nothing and names the Releases page.

Either way `setup.sh` does the same steps, and nothing runs as an administrator:

1. It takes its tools (`curl` or `wget`, `openssl` or `sha256sum`, `codesign`, `spctl`, …) only
   from the system's folders, and only when they belong to root.
2. It downloads the one file for this computer and checks its size and SHA-256. On Linux it
   also checks the file's signature when openssl 3 is there; run by hand it needs openssl 3 for
   the release list's signature. On a Mac it checks the app's code signature (bundle id, team,
   Developer ID), its notarization and its version, with the same arguments as the updater.
3. It copies the file beside its place (`~/.local/bin/rex-duo-helper`; `/Applications`, or
   `~/Applications` when that can't be written), checks the copy again and renames it. The same
   version already there is not downloaded again, and a newer one stays. An older Mac app is
   asked to update itself. One that can't is renamed to `Rex DUO Helper.previous.app` beside
   the new one, and removed once the new helper runs (step 4). If anything after that rename
   fails, or the terminal closes, the new app is removed, the previous one gets its name back
   and is started again, and the exit code is the failure's.
4. It runs `rex-duo-helper install --server <the tab's Rex server>`, from the app with
   `--setup-nonce-file <path>` too, and waits up to 20 s for `status.json` to name a running
   helper of that version or newer.
5. On a Mac it opens the app with `phone-setup`, which asks for the notification permission. On
   Linux, when lingering is off, it runs `loginctl enable-linger`, which may ask for the
   account's password in the terminal.

It prints plain sentences and an OSC 7501 record (`id` and `app` `rexduo-setup`; `title` is
`code`, `download`, `verify`, `install`, `start`, `notify`, `linger`, `done` or
`fail:E_<CODE>`). Exit codes: 0 done, 10 `E_ARGS` (arguments, or no setup code), 11 `E_ARCH`, 12 `E_NO_DOWNLOADER`, 13 `E_NET`, 14 `E_VERIFY`,
15 `E_WRITE`, 16 `E_BUSY`, 17 `E_SERVICE`, 18 `E_NO_GUI`, 19 `E_NO_SYSTEMD`, 20 `E_APP_MGMT`,
21 `E_OLD_MACOS`. One install runs at a time per account (`setup.lock` in the state folder).

**By hand, Mac**

1. Unzip `Rex DUO Helper.zip` and drag **Rex DUO Helper** to Applications.
2. Open it once. A small dialog says it's on. It keeps running and starts at every login.
3. Open Rex DUO on the iPhone and turn on notifications.

Open the app again to see whether it's connected, or click **Turn Off** to stop it. Then drag the
app to the Trash to remove it. macOS lists it under System Settings > General > Login Items.

**By hand, Linux**

```sh
chmod +x rex-duo-helper-linux-x86_64     # or -aarch64
./rex-duo-helper-linux-x86_64 install
```

`install` copies itself to `~/.local/bin/rex-duo-helper`, adds a systemd user service, starts
it, turns on lingering so it survives logout (or says how, if it can't), and prints one line such
as `Rex DUO Helper 0.3.0 is running and connected to Rex at https://….` Without systemd it
says how to start it by hand. Then `rex-duo-helper status` and `rex-duo-helper uninstall`.
Logs: `journalctl --user -u rex-duo-helper`.

The same three commands work on a Mac (from
`/Applications/Rex DUO Helper.app/Contents/MacOS/rex-duo-helper`).

## How it finds Rex

Before each connection attempt, in order:

1. `REX_SERVER`, which Rex sets in its terminals (when run from a Rex shell).
2. The default socket: macOS `~/Library/Application Support/rex/server.sock`, Linux
   `$XDG_RUNTIME_DIR/rex/server.sock` (`/run/user/<uid>/rex/server.sock`). The control WebSocket
   (`rex.control.v1`) runs over it.
3. `rex --autostart=false server status --json` (never starts a server): its `endpoint`, else
   its Tailscale HTTPS URL (over TLS).

Pushes name the server by its Tailscale HTTPS URL, read from `session.bootstrap`, because that's
how Rex DUO knows it.

## Running in the background

- **Mac:** opening the app writes `~/Library/LaunchAgents/dev.abrahamgonzalez.rexduo.helper.plist`
  (runs the binary in the app with `run --log-file`, `KeepAlive` on crash, tied to the app in
  Login Items) and loads it with `launchctl`. If the app was updated, opening it restarts the
  helper. Log: `~/Library/Logs/Rex DUO Helper.log` (rotated at 1 MB).
- **Linux:** `~/.config/systemd/user/rex-duo-helper.service`, `Restart=on-failure`, `Nice=5`.
- **From Rex DUO's setup** the Mac app is opened with `open -g -a "Rex DUO Helper" --args
  phone-setup`. That starts the helper as above and asks for the notification permission, and
  shows no dialog of its own: the person is at their phone.
- The helper starts every other program by its full path. System tools (`systemctl`,
  `loginctl`, `systemd-run`, `notify-send`, `id`) are looked up in `/usr/bin`, `/bin`,
  `/usr/sbin`, `/sbin` and `/run/current-system/sw/bin`, never on `PATH` (`src/tools.rs`).
- Either way only one helper runs per user (a lock in the state folder), and it writes
  `status.json` there for `status` and the Mac dialog.
- **Upgrading from the old name** (`src/legacy.rs` lists it): on first run the helper stops the
  old service, removes its LaunchAgent or unit and its `~/.local/bin` copy, and moves its state
  folder (the registered phones in `devices.json`) to the new one. Then drag the old app to the
  Trash.

## Performance

Event driven, on one thread (tokio's current-thread runtime). While connected, nothing runs until
Rex sends something: Rex pings every 120 s and the helper answers; a local server that quits
closes the socket. The only timers are the reconnect backoff (1 s to 60 s, while Rex is down), the
30 s debounce for a block that flaps, per-request timeouts, and a 330 s silence check on remote
(HTTPS) servers, and the update check (once after start, then about every 12 hours). A push
opens one HTTPS connection to the gateway, sends one request and closes it; nothing is kept
open in between. Idle: about 3.5 MB of memory and no CPU.

## Updates

The helper updates itself from the releases of this repository
(`github.com/theabecaster/rexduo`). It looks once between 0 and 10 minutes after it starts, then
about every 12 hours, and installs a newer version when it finds one. `"auto_update": false`
in `config.json` turns that timer off; `rex-duo-helper update` and the app's update button
still work.

```sh
rex-duo-helper update --check     # say whether a newer version exists
rex-duo-helper update             # download it, check it, install it, restart into it
```

What happens, in order. Any step that fails stops the update and leaves the installed helper
as it was:

1. Get `helper-latest/manifest.json` and `manifest.json.sig` over HTTPS. Only addresses under
   `https://github.com/theabecaster/rexduo/releases/download/` are asked for, and a redirect is
   followed only to `github.com`, `objects.githubusercontent.com` or
   `release-assets.githubusercontent.com`, over HTTPS.
2. Verify the manifest's signature. The signature file holds one or more base64 ed25519
   signatures, one per line; one that verifies under a trusted key is enough. Trusted are the
   two keys compiled in from `Relay/update-key.pub` (`primary`, which signs releases, and
   `recovery`, kept apart from it) and keys received by handover (below). Only then read it.
3. Refuse a manifest that has expired (`expires_at`; "the release list is out of date"), and
   one whose `version` is lower than the highest this helper has accepted before
   (`update_high_water.json` in the state folder): an old, validly signed list played back.
4. Go on only if the manifest's version is strictly newer than the running one
   (`major.minor.patch`; anything else is refused), and every address in it is under the
   releases prefix.
5. Download this platform's file (`macos-universal`, `linux-x86_64`, `linux-aarch64`) into
   the folder of the installed helper. The transfer stops at the size the manifest gives (and
   at 64 MB whatever it says); the file is kept only if its size and SHA-256 match.
6. The platform's own check:
   - **Linux:** the detached signature `<file>.sig`, from a trusted key, over the text
     `rex-duo-helper|<version>|<platform>|<sha256>`. It names the version and the platform, so a
     signed file can't be served as another version or for another architecture.
   - **Mac:** unzip with `ditto`, then `codesign --verify --deep --strict`; a designated
     requirement that pins the bundle id `dev.abrahamgonzalez.rexduo.helper` and the team
     `R2PVQ496X7` on a Developer ID certificate; `spctl --assess --type execute`, which must
     accept the app as a notarized Developer ID; and the bundle's version must be the
     manifest's. Each tool is called by its absolute path with an argument list.
7. Swap. Linux: the current binary stays as `rex-duo-helper.previous` and the new one is
   renamed into place. Mac: the current app moves to `Rex DUO Helper.previous.app` beside it
   and the new one takes its place. The previous version stays there until step 8 has
   confirmed the new one. Nothing downloaded has run up to here.
8. Restart the background service (`systemctl --user restart`, `launchctl kickstart -k`), wait
   up to 15 s for the old helper to exit, then up to 20 s for the new version to report itself
   in `status.json`. When it does, remove the previous version (`rex-duo-helper.previous`,
   `Rex DUO Helper.previous.app`), so one copy is installed. If it doesn't, put the previous
   version back and restart again. The old
   program does this step from outside the service, so the restart doesn't stop it: as a
   transient systemd unit (`systemd-run --user`), or on a Mac as a launchd job of its own
   (`dev.abrahamgonzalez.rexduo.helper.update`, loaded from a one-shot plist in the state
   folder). A version that was rolled back is not tried again by the timer.

One update runs at a time (`update.lock` in the state folder holds the pid; a lock whose
process is gone is taken over). An update that failed or timed out leaves no lock behind, so
the next attempt is not held up.

**The manifest** also carries `min_version` and `next_key`:

```json
{"version": "0.3.1", "min_version": "0.3.0", "released_at": "2026-11-17T12:00:00Z",
 "expires_at": "2027-11-17T12:00:00Z", "next_key": null, "assets": {"linux-x86_64": {"url": "…", "sha256": "…", "size": 1}}}
```

- `min_version`: a helper older than this reports `"update_required": true`.
- `expires_at`: 180 days after signing (`EXPIRES_DAYS`). `Relay/release.sh --resign` signs the
  current list again with a new date, without building; do it before the date passes.
- `next_key` (handover): a manifest that passed steps 2 and 3 and names a base64 32-byte key
  adds that key to the helper's trusted set, kept in `trusted_keys.json` (mode 0600) in the
  state folder. At most 4 are kept; a fifth pushes out the oldest. A `next_key` in a manifest
  the helper did not accept is never read. To replace a signing key, publish a list that names
  the new key, signed with a key helpers already trust, then sign with the new one.

The helper doesn't update itself when it can't do so safely, and says why (`rex-duo-helper
status`, the helper's log): a `--dry-run`, a debug build or one run from a cargo `target`
folder, a Mac helper that isn't running from `Rex DUO Helper.app` or that macOS runs from a
translocated copy, a Linux binary that isn't the installed `~/.local/bin/rex-duo-helper`, no
background service, a folder it can't write to, or a build whose `update-key.pub` holds only
placeholders (32 zero bytes). With placeholders the helper never asks GitHub for anything.

`status.json` carries what the last check found: `latest_version`, `min_version`,
`update_available`, `update_required`, `checked_at`, `updating`, `can_update`, `last_error`,
beside `version` / `helper_version`. `last_error` is one of a few fixed sentences ("The release
list is out of date.", "The downloaded update did not pass its checks."); paths, addresses and
what a tool or server said go to the helper's log only, because any Rex client can ask for the
status.

## Build and ship

```sh
cd Relay
cargo test                         # policy, payload, gateway, devices, identity, authorization, updates; ~2 s
cargo run -- run --dry-run         # foreground relay, logs pushes instead of sending them
./package.sh                       # Mac app (sign, notarize, staple) + Linux binaries
./package.sh --no-notarize         # sign only, for a quick local test
./package.sh --mac-only | --linux-only
```

Building needs no key and no secret: `cargo build` is all there is. The one thing compiled in
is `update-key.pub`: two lines, `primary <base64>` and `recovery <base64>`, each the 32 raw
bytes of an ed25519 public key (`#` lines are comments). The private halves never enter the
repository.

```sh
./release.sh                       # package, sign, write dist/release. Publishes nothing.
./release.sh --resign              # sign the current release list again, with a new expiry date
bash test-install.sh               # release.sh and setup.sh, on this Mac alone, with its own keys; ~2 min
tests-setup/make-fixtures.sh       # write Relay/fixtures again (test data for the app and the helper)
```

`release.sh` signs with `UPDATE_KEY`, which must be the primary or the recovery key of
`update-key.pub`; `MIN_VERSION`, `NEXT_KEY` and `EXPIRES_DAYS` (default 180) set the manifest's
`min_version` (default: the release), `next_key` and `expires_at`. Only `--publish` uploads. It
refuses when the keys in `setup.sh` differ from `update-key.pub`, and publishes `setup.sh` as the
`install.sh` of `helper-latest` with two lines filled in: `MANUAL_MAC_FLOOR` (the release's
version) and `MANUAL_MAC_EXPIRES` (the manifest's `expires_at`). It only reads `setup.sh`, so
the committed file and the copy in the app stay the same bytes. It prints the SHA-256 of that
`install.sh` and writes it into `docs/helper.md` between `<!-- install-sha -->` and
`<!-- /install-sha -->`, on every run; commit that change with the release you publish.
`--resign` writes `install.sh` again with the new date, and `--resign --publish` uploads it
with the list. Run by hand on Linux, `setup.sh` prints the SHA-256 fingerprints of the two
release keys, then checks the manifest's signature and expiry, the download's size and SHA-256
against the signed manifest, and the binary's signature text.

Test data: `release.sh` also writes `dist/release/fixtures/` (the release list, its signature
and the x86_64 Linux signature, signed by a key made for that run, whose public half is
`test-key.pub`). `Relay/fixtures/` is a small committed set of the same shape with a list that
expires in 2099, an expired one, an older one and a signature by another key; its keys were made
by `tests-setup/make-fixtures.sh` and their private halves deleted.

`test-install.sh` runs copies of `setup.sh` in which `sed` replaced the download address, the
keys and a few other constant lines, against a download site on 127.0.0.1
(`tests-setup/mirror.py`) and a stand-in helper (`tests-setup/fake-helper.sh`), under
`bash --posix`, `/bin/sh` and `/bin/dash`. A run as the app starts it happens in a
pseudo-terminal (`tests-setup/pty-run.py`), which types the setup code when the script asks.
The copies for a run by hand on a Mac come from the `install.sh` its copy of `release.sh`
wrote. `setup.sh` itself has no setting that moves a
download, skips a check or changes a key, and the tests check that.

Output in `Relay/dist/` (gitignored): `Rex DUO Helper.zip` (universal) and
`rex-duo-helper-linux-x86_64` / `-aarch64` (static musl, cross-compiled with `cargo zigbuild`;
set `ZIG=/path/to/zig` if zig isn't on PATH). The script:

- wraps the universal Mac binary in a bundle (`LSUIElement`, bundle id
  `dev.abrahamgonzalez.rexduo.helper`, icon made from the iOS app icon by
  `Packaging/make-iconset.swift`);
- signs with the Developer ID Application identity (`IDENTITY`), hardened runtime, no
  entitlements, and notarizes with `xcrun notarytool` and an App Store Connect API key
  (`ASC_KEY`, `ASC_KEY_ID`, `ASC_ISS`), staples, then checks `spctl`.

## Commands and options

| Command | Meaning |
| --- | --- |
| `install` / `status` / `uninstall` | Run in the background, report, or stop and remove it. |
| `install --server <addr>` | Also adds that Rex server to `config.json`'s `servers` (Config). It takes the `unix://` address of a socket that is there and belongs to this user, or an `https://` address; anything else is refused before anything changes, with exit status 2. |
| `install --setup-nonce-file <path>` | For Rex DUO's setup: reads the setup code from that file, removes the file, and keeps the code for 30 minutes to answer `setup_challenge` ("What the app must do", 2). The file is a regular file of this user that no one else can open (no group or other permissions), at most 128 bytes: 64 lowercase hex digits, with or without one newline after them. Any other file is removed too, and the command is refused with exit status 2 before anything else changes. The code is never an argument. |
| `version` | Print the version. `version --json` prints `{"version":"x.y.z"}` and nothing else. |
| `run` | Run in the foreground (what the service runs). |
| `update` | Look for a newer version and install it. `update --check` only looks. See Updates. |
| `forget <device id>` | Remove a phone's registration, whoever registered it. Alone, `forget` lists the phones. The running helper notices. |

`run` takes `--dry-run` (log each push, priority, collapse id and payload, instead of sending
it: no request goes to the gateway, and a dry run never updates; `REX_DUO_DRY_RUN=1` works too), `--verbose` (also log working/idle reports and every "no push"
decision), `--server ADDR` (repeatable, `unix:///…` or `https://…`), `--state-dir`, `--config`,
and `--log-file`.

## Config (optional)

`config.json` in the state folder: macOS `~/Library/Application Support/Rex DUO Helper/`,
Linux `~/.local/state/rex-duo-helper/` (`$XDG_STATE_HOME`). The normal install has none.
Every field is optional.

```json
{
  "servers": ["unix:///Users/me/Library/Application%20Support/rex/server.sock"],
  "label": "rex-push-relay",
  "gateways": ["https://push.example.com"],
  "auto_update": true,
  "debounce_seconds": 30,
  "rate_limit_burst": 10,
  "rate_limit_per_minute": 10
}
```

`servers` replaces discovery, unless the list has the word `"discover"`: then the helper
watches the server it finds and the ones the list names, each once. `install --server` adds an
address to the list and never a second time. Where there was no list it writes `["discover",
"<addr>"]`, so discovery stays on, and it writes nothing when the address is Rex's default
socket, which discovery finds anyway. `auto_update: false` turns the update timer off
(Updates).

`gateways` adds push gateways to the allowlist. A phone names its gateway when it registers,
and the helper sends that phone's secret there, so it only takes a gateway it already knows:
the built-in `https://rexduo-push.keptday.workers.dev`, or an entry of `gateways`. An entry is
an origin (`https://host[:port]`, no path). Plain `http://` is taken only for `127.0.0.1` or
`localhost`, and only from this list (tests run a gateway there). A registration whose gateway
is no longer on the list is dropped when the helper starts.

`devices.json` in the same folder holds the registered phones, one per `device_id`: the
gateway's origin, the phone's push secret, its environment and name, and `owner`, the identity
that registered it. It is written through a temporary file and readable by its owner only
(mode 0600), because the secrets in it are what lets this helper push. An entry the helper
can't use (written by an older helper: an APNs token and no secret, or no owner) is dropped
when the file is read; that phone registers again the next time its app connects.

What the gateway's answer to a push does:

- `410`: Apple dropped the phone's token and the gateway deleted the phone. The registration
  is removed and the secret's SHA-256 is remembered in `dropped_secrets.json` (hashes only, at
  most 256).
- `401` with the gateway's own body (`"error": "unauthorized"`): that push is dropped and the
  registration stays. A second such answer at least 60 s after the first removes it, as for
  `410`. A `200` in between starts the count over. Any other `401` (a proxy, a sign-in page)
  counts for nothing.
- `429`, `5xx` or a network error: that one push is lost; the helper logs a line and does not
  send it again. A request has 10 seconds.

A phone whose registration was removed is not left without pushes in silence: its next
`push_presence` or `helper_status` answers `"registered": false`, and registering the refused
secret again fails with `secret_dropped`, so the app mints a new secret and registers again.
Neither a secret nor the text of a push is written to the log, and no action's result or
error carries any part of a secret.

The first time a phone registers, the computer shows one desktop notification: "Rex DUO
connected", "<device name> can now open your sessions on this computer." It shows once per
`device_id`: `seen_devices.json` in the same folder keeps the ids that have registered, so
a new secret, a reconnect, a helper restart or an unregister followed by a register shows nothing.
The file holds at most 512 ids, oldest first; a new id past that pushes out the oldest one that
is not registered now, and a phone pushed out gets a notice again if it comes back.
At most 3 notices show in any 60 seconds; a new phone past that is still registered and
remembered, and the log says its notice was held back.
Phones already in `devices.json` when the helper is upgraded count as seen, old entries
included. On a Mac it comes from Rex DUO Helper itself: `rex-duo-notify`
(`Packaging/notify.swift`), a small program beside the helper in the app, posts it, and macOS
asks once, when the app is first opened, whether the helper may show notifications. Answer no,
or run the helper outside its app, and no notice is shown. On Linux it goes through `notify-send`, and only if it is installed and a desktop session is there
(otherwise the helper logs a line and carries on), with `&`, `<` and `>` in the name escaped,
because Linux notification servers read the text as markup. `--dry-run` logs `DRY-RUN notice`
instead, once per new phone per run, and never writes `seen_devices.json`, so the real helper
still shows that phone's notice.

## What the app must do

### 1. Put a device id in the Rex client label

Pick a stable per-install id of 8 lowercase hex characters, e.g. the first 8 hex digits of
`identifierForVendor`. End the `label` in the hello with ` #<device_id>`:

```json
{"type": "hello", "api_revision": 14,
 "client": {"kind": "app", "platform": "ios", "name": "Rex DUO", "version": "1.0",
            "label": "Alex's iPhone #a1b2c3d4"}}
```

Rex caps labels at 64 bytes, so shorten the device name, never the suffix.

### 2. Find the relay and check it is the real one

Call `client.list` with no arguments. The relay is the client whose `info.name` is
`rex-push-relay`, whose `connection_state` isn't `lost`, and whose server-asserted
`principal.kind` is `peer` or `windows_peer` (it runs on the server's own machine). If there
are several, use the last one (clients are listed in connection order).

Don't rely on `target.resolve` with the label: a relay that just restarted can linger for 60 s as
`lost` under the same label, which makes the lookup ambiguous. If no relay is connected, skip
registration quietly and try again on the next connect.

Then ask it who it is: `action: "helper_identity"`, `args: {"challenge": "<base64url of 32
random bytes>", "device_id": "a1b2c3d4"}`. Result:

```json
{"public_key": "<base64, 32 bytes>", "signature": "<base64, 64 bytes>", "client_id": "client:<relay id>"}
```

The signature is ed25519 over the UTF-8 bytes of these five lines joined by `\n`, with no
newline at the end:

```
rexduo-helper-identity-v1
<challenge exactly as sent>
<the helper's own Rex client id>
<the caller's Rex client id, as the server reports it>
<device_id>
```

Verify it, check that `client_id` is the client you called and that line 4 is your own client
id, and compare `public_key` with the one pinned for this server (pin it the first time). Both
client ids are signed so that a client in between can't pass your challenge on to the real
helper. A challenge that isn't 32 bytes of base64url, or a `device_id` that isn't 8 lowercase
hex digits, fails with `bad_request`. `not_supported` means a helper too old for this.

A phone that installed this helper through Rex DUO's setup adds `"setup_challenge":
"<base64url of 32 random bytes>"` to the args. While the helper holds the setup code that
setup gave `install --setup-nonce-file`, the result also has

```json
{"setup_proof": "<base64, 32 bytes>"}
```

which is HMAC-SHA256, keyed by the 32 bytes the code's hex stands for, over these four lines
joined by `\n`, with no newline at the end:

```
rexduo-setup-v1
<setup_challenge exactly as sent>
<the helper's own Rex client id>
<the caller's Rex client id, as the server reports it>
```

A code makes up to three proofs for one requester identity and ten in all. The helper keeps it
in `setup_nonce.json` in the state folder (mode 0600) as `{"nonce", "expires_at", "proofs"}`,
where `proofs` lists the identity of the requester each proof went to, and reads that file on
every call, so a helper that was already running answers for a code `install` stored a moment
ago. The code is removed when `register_push` succeeds with a `setup_seal` (step 3) for a
requester that was given a proof, and 30 minutes after `install` stored it, whichever is
first. Without a code, or past either count, the field is absent and the rest of the answer is
as usual. A `setup_challenge` that isn't 32 bytes of
base64url fails with `bad_request` and uses nothing up. The code, the proofs and the seal are
never logged and never in `status.json`.

### 3. Register

First the app registers its APNs token with the push gateway (`POST /v1/devices`) and mints a
secret for this helper (`POST /v1/devices/{id}/secrets`). Then it gives that secret to the helper:

```json
{"type": "request", "id": "7", "method": "client.perform", "payload": {
  "client_id": "client:<relay id>",
  "action": "register_push",
  "args": {"gateway": "https://rexduo-push.keptday.workers.dev", "push_secret": "<43 characters>",
           "environment": "sandbox", "device_name": "Alex's iPhone", "device_id": "a1b2c3d4"},
  "timeout_ms": 5000}}
```

- `gateway`: the gateway's origin. It must be on the helper's allowlist (Config, `gateways`).
- `push_secret`: what the gateway returned. The helper sends it as the bearer token of every
  push to this phone and to nothing else.
- `environment`: `sandbox` or `production`. Informational; the gateway knows the real one.
- `device_name`: shown in the helper's log and in the desktop notice.
- `device_id`: the id from step 1, 8 lowercase hex digits. The caller's label must end with
  ` #<device_id>`. Registrations are kept by it: a new secret for the same id replaces the old
  one, if the same identity asks.
- `setup_seal`: optional, and sent only by a phone that holds the setup code of the setup that
  installed this helper, with the registration that completes it. It is the base64 of
  HMAC-SHA256, keyed by the 32 bytes the code's hex stands for, over these three lines (UTF-8)
  joined by `\n`, with no newline at the end:

  ```
  rexduo-setup-register-v1
  <push_secret>
  <device_id>
  ```

  When the helper holds that code, gave this requester's identity a `setup_proof`, and the seal
  is the one the code makes for this registration, the setup is complete and the code is
  removed. The registration and its result are the same with a seal, without one, or with one
  that does not match; only a matching seal removes the code.

Result: `{"result": {"registered": true, "devices": 1, "push_enabled": true, "helper_version": "0.3.0"}, "performed_by": "client:<relay id>"}`.
`push_enabled` is false while the helper runs with `--dry-run`.

Errors arrive as normal `client.perform` errors:

| Code | Meaning |
| --- | --- |
| `refused` | The Rex server did not identify the caller (`anonymous`). |
| `bad_request` | A gateway that is not on the allowlist, a malformed secret, environment or device id, or a device id that is not the one at the end of the caller's label. |
| `not_your_device` | That device id is registered to another identity. On the computer: `rex-duo-helper forget <device id>`. |
| `secret_dropped` | The gateway already refused that secret. Mint a new one. |
| `not_supported` | An app that predates the gateway (a `token`, no `push_secret`): `This Rex DUO Helper needs a newer Rex DUO app.` |

`not_found` or `client_unavailable` mean the relay left; `timeout` that it didn't answer.

Registering is idempotent. Send it after every successful connect once the app has a secret,
and again whenever the app has a new one.

### 4. Report background and foreground

When iOS suspends the app, its WebSocket isn't closed. Rex keeps the client `connected` for
several minutes until its keepalive pings fail, and the relay would keep skipping pushes. So:

- On `scenePhase == .background`, inside `beginBackgroundTask`, call
  `client.perform` with `action: "push_presence"` and `args: {"active": false}`.
- On `scenePhase == .active`, send `{"active": true}`.

The relay keys this on the calling client's id, which Rex fills in and can't be faked. A
reconnect with a new client id counts as foreground. Closing the control socket on background
works too: the client then leaves at once.

Result: `{"registered": true|false}`, whether the caller's phone (the device id in its label)
has a registration here that the caller's identity made. `false` means register again; if the
secret the app holds is then refused with `secret_dropped`, mint a new one first.

### 5. Unregister

When the user turns notifications off: `action: "unregister_push"`, `args: {"device_id": "a1b2c3d4"}`.
Result `{"removed": true|false}`. Only the identity that registered the phone can remove it;
anyone else gets `false`. A `token` argument is ignored; alone it removes nothing.

### 6. Show and update the helper

`action: "helper_status"`, no args. Result:

```json
{"version": "0.3.0", "latest_version": "0.3.1", "min_version": "0.3.0", "update_available": true,
 "update_required": false, "checked_at": "2026-11-17T12:00:00Z", "updating": false,
 "can_update": true, "last_error": null, "registered": true,
 "manifest_expires_at": "2027-05-16T12:00:00Z", "notices": "allowed", "linger": null}
```

`latest_version`, `min_version` and `checked_at` are null until the helper has checked.
`update_required` is true when the helper is older than the newest release's `min_version`.
`can_update` is false when the helper can't replace itself (Updates lists when). `last_error`
is one of a few fixed sentences, never a path, an address or raw error text. `registered` is
as in `push_presence`.

`manifest_expires_at` is when the release list the helper last accepted stops being valid
(null until it has checked since it started). Within 30 days of that time the helper also logs
one line at every check. `notices` is whether macOS lets the helper show its "Rex DUO
connected" notice: `"allowed"`, `"denied"` or `"undetermined"`, read from `rex-duo-notify
status`, which never asks; null on Linux, and when the helper can't tell. `linger` is whether
the Linux service keeps running after logout (`loginctl show-user <user> -p Linger --value`):
true or false; null on a Mac, and when `loginctl` doesn't say. Both are read when a phone asks
and reused for 5 seconds. Neither is in `status.json`.

`action: "update_helper"`, no args. Only an identity that has a phone registered on this
helper may call it; anyone else gets `refused`. The helper checks now. Result `{"started":
true, "version": "0.3.1"}` when an update began (the helper answers first, then downloads,
checks, swaps and restarts, so expect it to drop off Rex for a few seconds), or `{"started":
false, "version": "0.3.0"}` when it is up to date. A helper that can't update, or a check that
failed, answers with the error `update_failed` and one of the fixed sentences. At most one
such check runs per 10 minutes, whoever asks: a second answers `update_cooldown`, and its
message says how many seconds are left. The helper's own timer is separate.

### 7. Handle the push

```json
{
  "aps": {
    "alert": {"title": "Claude · api", "subtitle": "work", "body": "Which database should I use?"},
    "interruption-level": "time-sensitive",
    "sound": "default",
    "thread-id": "block:<uuid>",
    "category": "AGENT_BLOCKED"
  },
  "server": "https://my-mac-rex.example.ts.net",
  "session_id": "session:<uuid>",
  "window_id": "window:<uuid>",
  "block_id": "block:<uuid>"
}
```

- `server` is the server's Tailscale HTTPS URL, as entered in the app's server list.
- `window_id` is left out when the block isn't in a window.
- Title is `<agent> · <tab>`, subtitle is the session when it differs from the tab.
- A collapse id is set for agent pushes (`collapse_id` in the gateway request, which becomes
  `apns-collapse-id`), so a later state of the same block replaces the earlier notification.
- The time-sensitive level needs the Time Sensitive Notifications capability in the app.
- Categories `AGENT_BLOCKED`, `AGENT_DONE`, and `NOTICE` exist so the app can register actions.

## Debounce and rate limits

- **Blocked:** pushed when a record enters `blocked`, or reports a new message while blocked.
  At most one push per block per 30 s. A block that flaps (blocked, working, blocked) inside the
  window gets one trailing push when the window ends, and only if it's still blocked then.
- **Done / error:** pushed on entering the state, once per block and state per 30 s.
- **Notifications:** identical title and body from the same block within 30 s are dropped.
- **Rate limit:** per device, a burst of 10, then 10 per minute.
- Re-reports of an unchanged state never push.

## Verify by hand

Stop the background helper (only one runs per user), run a dry run in the foreground, and drive a
throwaway session from another terminal:

```sh
# Mac: launchctl kill TERM gui/$(id -u)/dev.abrahamgonzalez.rexduo.helper
# Linux: systemctl --user stop rex-duo-helper
rex-duo-helper run --dry-run
rex new zz-push-test -- sh -c 'sleep 2
  printf "\033]7501;state=blocked:app=claude:msg=%s\033\\\\" "$(printf "Ready?" | base64)"
  printf "\033]9;Build finished\a"; sleep 30'
rex kill zz-push-test
# Mac: launchctl kickstart gui/$(id -u)/dev.abrahamgonzalez.rexduo.helper
# Linux: systemctl --user start rex-duo-helper
```

The dry run logs one `AGENT_BLOCKED` and one `NOTICE` push, and sends nothing to the gateway. `rex client list` shows the helper as
`rex-push-relay` over unix.
