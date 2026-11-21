# Pteron Beacon

Sends Pteron push notifications for the Rex server on the same machine. Rex has no push
support of its own, so Beacon connects to Rex as an ordinary client (named `rex-push-relay`,
which is what the iOS app looks for), watches every session, and sends a push when:

| Event | Category | Interruption level |
| --- | --- | --- |
| An agent becomes `blocked` (OSC 7501: question, permission, sign-in) | `AGENT_BLOCKED_ACT`, or `AGENT_BLOCKED` when the push can't name the wait (step 7) | `time-sensitive`, sound |
| An agent reports `done` or `error` | `AGENT_DONE` | `passive`, no sound |
| A terminal raises a desktop notification (OSC 9 / OSC 777) | `NOTICE` | `active`, sound |

It skips a phone while Pteron is open on it, since the app shows its own toasts then.
Phones register through Rex itself (client actions), so Beacon listens on nothing for that. Every
machine that runs a Rex server needs its own helper.

Since 0.7.0 Beacon also does two things for the app's Ports list, both only when a registered
phone asks: it lets that phone's browsers open a dev server of this computer over Tailscale
(`port_share`, the one case in which it listens on a port, step 8), and it says which processes
are behind a listening port (`port_owner`, step 9).

Beacon holds no Apple key and never sees a phone's APNs token. Each phone registers with
the push gateway (`Gateway/`), mints one secret per Beacon there, and hands that secret to the
helper. For every event Beacon sends one `POST <gateway>/v1/push` with that phone's secret;
the gateway, which holds the APNs key and the token, passes the payload to Apple. A Beacon can
push only to the phones that gave it a secret.

Any client of the Rex server can call Beacon's actions, so two things guard them:

- **Identity.** On first run Beacon makes an ed25519 key (`identity.key` in the state
  folder, PKCS#8, mode 0600) that never leaves the computer. A phone asks `helper_identity`
  before it hands over anything, pins the public key the first time, and refuses a Beacon whose
  key changed until its user says to trust it. Another client that calls itself
  `rex-push-relay` can't answer for the helper.
- **Authorization.** Every action reads who the Rex server says the caller is (the `principal`
  of the server-filled `requester`: kind plus `uid`, `sid` or Tailscale `user_id`). A caller the
  server did not identify (`anonymous`) is refused everything. A registration belongs to the
  identity that made it; "What the app must do" lists what each action allows.

One Rust program, `rex-duo-helper`, runs on macOS and Linux. On a Mac it ships inside
**Pteron Beacon.app**, whose only executable is that same binary.

## Install

**From Pteron.** After a computer is added, the app offers to install Beacon on it. The app
checks the signed release list on the phone, then runs `Relay/setup.sh`, which it carries, in a
tab on the computer, with 12 arguments: `2`, the version, the oldest version it accepts, the
SHA-256 and size of the Mac file and of each of the two Linux files, the keys it trusts (1 to 6,
with commas between them), `ask` or `skip` for lingering, and `-`. Its one-time setup code is
not an argument. The script turns the terminal's echo off, reports a record with the title
`code`, and reads one line from the terminal for up to 60 s: the app types the code (64 hex
digits and Return) when it sees that record. The script never prints the code. It writes it to
a file of mode 0600 in its own staging folder (mode 0700) and passes Beacon that file's
path (step 4).

**With one command**, on a Mac or on Linux. This is the same `setup.sh`, published as
`install.sh`; run without arguments, it reads the release list itself:

```sh
curl -fsSL https://github.com/theabecaster/pteron/releases/download/helper-latest/install.sh | sh
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
   asked to update itself. One that can't is renamed to `Pteron Beacon.previous.app` beside
   the new one, and removed once the new Beacon runs (step 4). If anything after that rename
   fails, or the terminal closes, the new app is removed, the previous one gets its name back
   and is started again, and the exit code is the failure's.
   **The Mac app's folder names.** The app is `Pteron Beacon.app`. It was
   `Rex DUO Beacon.app` in version 0.3.1 and `Rex DUO Helper.app` in version 0.3.0, and those
   three are the one list of folder names the script accepts, in a download and where the app
   is installed (`APP_NAMES` in `setup.sh`; the updater has the same list). A release has the
   Mac app in three zips, one for each name ([Releases](#releases)). The script asks for them
   newest first (`Beacon-macOS.zip`, `Rex-DUO-Beacon.zip`, `Rex-DUO-Helper.zip`) until one has
   the size and SHA-256 it was given. The unzipped download must hold one entry and no more,
   a real folder (not a link) whose name is on the list; then come the checks of step 2. The
   app is placed under the folder name it came in: a version from before a name looks for
   itself under the name it knows, and a version that knows a newer name renames its own
   folder when it is started (`src/rename.rs`), after which the script finds the app again
   under the allowed names. An app under any of the names is the installed app in all of
   this: it is the one asked to update itself, set aside and put back (under the name it
   had), and with several names there the newest is the installed one. Once Beacon runs from
   `Pteron Beacon.app`, what the earlier names left in the two Applications folders is
   deleted: the app, its `….previous.app` and `.….app.new-*`.
4. It runs `rex-duo-helper install --server <the tab's Rex server>`, from the app with
   `--setup-nonce-file <path>` too, and waits up to 20 s for `status.json` to name a running
   Beacon of that version or newer.
5. On a Mac it opens the app with `phone-setup`, which asks for the notification permission. On
   Linux, when lingering is off, it runs `loginctl enable-linger`, which may ask for the
   account's password in the terminal.

It prints plain sentences and an OSC 7501 record (`id` and `app` `rexduo-setup`; `title` is
`code`, `download`, `verify`, `install`, `start`, `notify`, `linger`, `done` or
`fail:E_<CODE>`). Exit codes: 0 done, 10 `E_ARGS` (arguments, or no setup code), 11 `E_ARCH`, 12 `E_NO_DOWNLOADER`, 13 `E_NET`, 14 `E_VERIFY`,
15 `E_WRITE`, 16 `E_BUSY`, 17 `E_SERVICE`, 18 `E_NO_GUI`, 19 `E_NO_SYSTEMD`, 20 `E_APP_MGMT`,
21 `E_OLD_MACOS`. One install runs at a time per account (`setup.lock` in the state folder).

**Removing it.** The same script with exactly the two arguments `3` and `-` removes the helper.
Pteron runs it so in a tab for "Remove Helper"; by hand it is
`curl -fsSL …/helper-latest/install.sh | sh -s -- 3 -`. It reads no setup code and downloads
nothing. Any other arguments after `3` end with 10. The steps:

1. It takes the lock an install takes (16 when another run holds it). While Beacon updates
   itself (`update.lock` in the state folder names a live process) it waits up to 30 s, then
   ends with 16.
2. On a Mac it looks for the app only where an install puts it: `Pteron Beacon.app`, then
   its earlier names (`Rex DUO Beacon.app`, `Rex DUO Helper.app`), in `/Applications`, then
   `~/Applications`: a real folder that passes the code signature check an install makes of
   an app that is already there (bundle id and team). On Linux nothing that is installed is run.
3. `stop`: on a Mac it runs that app's `uninstall`, with no other argument, which stops the
   service and removes its launchd entry, under the label `dev.abrahamgonzalez.rexduo.agent`
   and the earlier ones, `….rexduo.beacon` and `….rexduo.helper`. With no app that passes
   step 2, when `uninstall` fails, or when a LaunchAgent file of any of the labels is left
   afterwards (an app from before a label knows the earlier ones alone), the script does it
   with `launchctl bootout gui/<uid>/<label>` for all three labels and deletes the plists. On Linux it runs
   `systemctl --user disable --now rex-duo-helper`, deletes
   `~/.config/systemd/user/rex-duo-helper.service` and runs `systemctl --user daemon-reload`.
   It then waits up to 20 s for launchd or
   systemd to have no such service; one that still runs ends with 15 and no file is deleted.
4. `remove`: it deletes, each by its full name and one at a time: on a Mac the app,
   `Pteron Beacon.previous.app`, `.Pteron Beacon.app.new-*` and `.beacon-failed-*` (a version
   an update could not start) in both Applications folders, the same under the two earlier
   names, `~/Library/Logs/Rex DUO Helper.log` and `Rex DUO Helper.old.log` (the log and the
   state folder keep the name the program first had); on Linux the binary,
   `rex-duo-helper.previous` and `.rex-duo-helper.new*` in `~/.local/bin`; then the state folder
   (registered phones, the identity key, the lock and status files). A link is deleted as a
   link and what it points to stays. A state folder that is itself a link is left: the script
   ends with 15 before it stops anything.
5. `done`, exit 0, also when no Beacon was there. When something could not be deleted the exit
   code is 15 and the sentence names what stayed. Lingering on Linux is not changed.

**By hand, Mac**

1. Unzip `Beacon-macOS.zip` (`Rex-DUO-Beacon.zip` in a release before 0.4.0) and drag **Pteron Beacon** to Applications.
2. Open it once. A small dialog says it's on. It keeps running and starts at every login.
3. Open Pteron on the iPhone and turn on notifications.

Open the app again to see whether it's connected, or click **Turn Off** to stop it. Then drag the
app to the Trash to remove it. macOS lists it under System Settings > General > Login Items.

**By hand, Linux**

```sh
chmod +x rex-duo-helper-linux-x86_64     # or -aarch64
./rex-duo-helper-linux-x86_64 install
```

`install` copies itself to `~/.local/bin/rex-duo-helper`, adds a systemd user service, starts
it, turns on lingering so it survives logout (or says how, if it can't), and prints one line such
as `Pteron Beacon 0.3.0 is running and connected to Rex at https://….` Without systemd it
says how to start it by hand. Then `rex-duo-helper status` and `rex-duo-helper uninstall`.
Logs: `journalctl --user -u rex-duo-helper`.

The same three commands work on a Mac (from
`/Applications/Pteron Beacon.app/Contents/MacOS/rex-duo-helper`).

## How it finds Rex

Before each connection attempt, in order:

1. `REX_SERVER`, which Rex sets in its terminals (when run from a Rex shell).
2. The default socket: macOS `~/Library/Application Support/rex/server.sock`, Linux
   `$XDG_RUNTIME_DIR/rex/server.sock` (`/run/user/<uid>/rex/server.sock`). The control WebSocket
   (`rex.control.v1`) runs over it.
3. `rex --autostart=false server status --json` (never starts a server): its `endpoint`, else
   its Tailscale HTTPS URL (over TLS).

Pushes name the server by its Tailscale HTTPS URL, read from `session.bootstrap`, because that's
how Pteron knows it.

## Running in the background

- **Mac:** opening the app writes `~/Library/LaunchAgents/dev.abrahamgonzalez.rexduo.agent.plist`
  (runs the binary in the app with `run --log-file`, `KeepAlive` on crash, tied to the app in
  Login Items) and loads it with `launchctl`. If the app was updated, opening it restarts the
  helper. A LaunchAgent under an earlier label, `….rexduo.beacon` or `….rexduo.helper`, is moved
  to this one (`src/label.rs`; docs/helper.md, Mac). Log: `~/Library/Logs/Rex DUO Helper.log` (rotated at 1 MB).
- **Linux:** `~/.config/systemd/user/rex-duo-helper.service`, `Restart=on-failure`, `Nice=5`.
- **From Pteron's setup** the Mac app is opened with `open -g -a "Pteron Beacon" --args
  phone-setup`. That starts Beacon as above and asks for the notification permission, and
  shows no dialog of its own: the person is at their phone.
- Beacon starts every other program by its full path. System tools (`systemctl`,
  `loginctl`, `systemd-run`, `notify-send`, `id`) are looked up in `/usr/bin`, `/bin`,
  `/usr/sbin`, `/sbin` and `/run/current-system/sw/bin`, never on `PATH` (`src/tools.rs`;
  the folders are `TOOL_DIRS` in `src/platform/unix.rs`).
- Either way only one Beacon runs per user (a lock in the state folder), and it writes
  `status.json` there for `status` and the Mac dialog.
- **Upgrading from the old name** (`src/legacy.rs` lists it): on first run Beacon stops the
  old service, removes its LaunchAgent or unit and its `~/.local/bin` copy, and moves its state
  folder (the registered phones in `devices.json`) to the new one. Then drag the old app to the
  Trash.

## Performance

Event driven, on one thread (tokio's current-thread runtime). While connected, nothing runs until
Rex sends something: Rex pings every 120 s and Beacon answers; a local server that quits
closes the socket. The only timers are the reconnect backoff (1 s to 60 s, while Rex is down), the
30 s debounce for a block that flaps, per-request timeouts, and a 330 s silence check on remote
(HTTPS) servers, and the update check (once after start, then about every 12 hours, sooner
after a check that could not reach the release list). A push
opens one HTTPS connection to the gateway, sends one request and closes it; nothing is kept
open in between. Idle: about 3.5 MB of memory and no CPU.

A port share (step 8) adds one listener and at most one timer, set to the earlier of its two
ends (30 minutes after its last connection closed, 10 minutes after its port stopped
listening). While a connection is open and the port listens it has no timer at all, and
nothing about a share is polled: it learns that its port went from Rex's `ports_changed` and
`block_closed` events and from a connection that finds nothing there. Each connection holds
two buffers of at most 64 KB (one head of up to 32 KB plus one 16 KB read, per direction), and
all shares together have at most 64 connections, so they hold at most about 8 MB however much
passes through them, and at most 136 sockets (two per connection and eight listeners). At
start Beacon raises its limit of open files to 1024, or as near as the system allows; it
starts all the same when it can't. A connection has one timer of its own while it waits for
a request (30 s). A `port_share` that makes a new share runs `tailscale status`, `tailscale
whois` and `lsof` or `ss` once each; a `port_owner` that names no `pid` runs `lsof` or `ss`
once. Each has 5 s and a cap on what it may print (256 KB, 64 KB for `lsof` and `ss`); none
runs otherwise.

## Updates

Beacon updates itself from the releases of this repository
(`github.com/theabecaster/pteron`). It looks once between 0 and 10 minutes after it starts, then
about every 12 hours, and installs a newer version when it finds one. `"auto_update": false`
in `config.json` turns that timer off; `rex-duo-helper update` and the app's update button
still work.

A check that could not download the release list (no connection, a timeout, a 404, a 5xx) is
tried again after about 15 minutes, then 1 hour, then 3 hours, each plus a few minutes picked
at random; after that the 12-hour schedule carries on. A check that passes goes back to the
12-hour schedule and clears the error. A list that arrived and did not pass its checks
(signature, expiry, rollback) keeps the 12-hour schedule: only a newly published list changes
that. The wait counts from the last check, whoever ran it.

`rex-duo-helper update` and `update --check` run in a process of their own. When their check
has ended they write its result to `update_check.json` in the state folder (mode 0600, written
to a temporary file and renamed into place):

```json
{"checked_at": "2026-11-17T12:00:00Z", "latest_version": "0.3.1", "min_version": "0.3.0",
 "manifest_expires_at": "2027-05-16T12:00:00Z", "error": null}
```

`error` is null or the `last_error` sentence of a failed check; the versions and the expiry
are null when no list was accepted. The running service reads the file when it answers
`helper_status` and before each scheduled check, and takes the result when it is newer than
its own last check and not from the future, so the app shows what the command found without
a restart, and the next scheduled check is a normal wait after it. A file that is not a
regular file, is larger than 1024 bytes or has a field off is ignored. It holds nothing that
`helper_status` doesn't show.

```sh
rex-duo-helper update --check     # say whether a newer version exists
rex-duo-helper update             # download it, check it, install it, restart into it
```

What happens, in order. Any step that fails stops the update and leaves the installed Beacon
as it was:

1. Get `helper-latest/manifest.json` and `manifest.json.sig` over HTTPS. Only addresses under
   `https://github.com/theabecaster/rexduo/releases/download/` are asked for (the repository's
   earlier name, which GitHub redirects to `theabecaster/pteron`), and a redirect is
   followed only to `github.com`, `objects.githubusercontent.com` or
   `release-assets.githubusercontent.com`, over HTTPS.
2. Verify the manifest's signature. The signature file holds one or more base64 ed25519
   signatures, one per line; one that verifies under a trusted key is enough. Trusted are the
   two keys compiled in from `Relay/update-key.pub` (`primary`, which signs releases, and
   `recovery`, kept apart from it) and keys received by handover (below). Only then read it.
3. Refuse a manifest that has expired (`expires_at`; "the release list is out of date"), and
   one whose `version` is lower than the highest this Beacon has accepted before
   (`update_high_water.json` in the state folder): an old, validly signed list played back.
4. Go on only if the manifest's version is strictly newer than the running one
   (`major.minor.patch`; anything else is refused), and every address in it is under the
   releases prefix.
5. Download this platform's file (`linux-x86_64`, `linux-aarch64`; on a Mac
   `macos-app`, else `macos-universal-beacon`, else `macos-universal`: the newest entry the list has) into
   the folder of the installed helper. The transfer stops at the size the manifest gives (and
   at 64 MB whatever it says); the file is kept only if its size and SHA-256 match.
6. The platform's own check:
   - **Linux:** the detached signature `<file>.sig`, from a trusted key, over the text
     `rex-duo-helper|<version>|<platform>|<sha256>`. It names the version and the platform, so a
     signed file can't be served as another version or for another architecture.
   - **Mac:** unzip with `ditto` into a scratch folder only this account can open. That folder
     must then hold one entry and no more, a real folder (not a link) whose name is on the
     list of allowed names (`Pteron Beacon.app`, `Rex DUO Beacon.app`, `Rex DUO Helper.app`:
     the one list, `allowed_app_name` in `src/update.rs`), with this program inside as a real
     file; anything else is refused before another check looks at it. Then
     `codesign --verify --deep --strict`; a designated
     requirement that pins the bundle id `dev.abrahamgonzalez.rexduo.helper` and the team
     `R2PVQ496X7` on a Developer ID certificate; `spctl --assess --type execute`, which must
     accept the app as a notarized Developer ID; and the bundle's version must be the
     manifest's. Each tool is called by its absolute path with an argument list.
7. Swap. Linux: the current binary stays as `rex-duo-helper.previous` and the new one is
   renamed into place. Mac: the current app, under any of its names, moves to
   `Pteron Beacon.previous.app` beside it and the new one becomes `Pteron Beacon.app`,
   whatever folder name the zip gave it. The
   previous version stays there until step 8 has
   confirmed the new one. Nothing downloaded has run up to here.
8. Restart the background service (`systemctl --user restart`, `launchctl kickstart -k`; when
   the app's path changed, the LaunchAgent is written for the new path and loaded again), wait
   up to 15 s for the old Beacon to exit, then up to 20 s for the new version to report itself
   in `status.json`. When it does, remove the previous version (`rex-duo-helper.previous`,
   `Pteron Beacon.previous.app`, and a `….previous.app` of an earlier name if one is there), so one
   copy is installed. If it doesn't, put the previous
   version back, under the name it had, and restart again (the version that did not start
   waits as `.beacon-failed-<pid>.app` for the moment that takes, then is deleted). The old
   program does this step from outside the service, so the restart doesn't stop it: as a
   transient systemd unit (`systemd-run --user`), or on a Mac as a launchd job of its own
   (`dev.abrahamgonzalez.rexduo.helper.update`, loaded from a one-shot plist in the state
   folder). A version that was rolled back is not tried again by the timer.

One update runs at a time (`update.lock` in the state folder holds the pid; a lock whose
process is gone is taken over). An update that failed or timed out leaves no lock behind, so
the next attempt is not held up.

**The Mac app's name.** The app is `Pteron Beacon.app`. It was `Rex DUO Helper.app` in
version 0.3.0 and `Rex DUO Beacon.app` in version 0.3.1 (`EARLIER_APP_NAMES` in
`src/update.rs`). The name people read is in one place, `src/brand.rs`. The bundle id, the
state folder, the log and the binary's name are the same as before, so macOS keeps what the
user allowed and nothing is set up again. The LaunchAgent's label moves with the app, to
`dev.abrahamgonzalez.rexduo.agent` from `….rexduo.beacon` (0.3.1) or `….rexduo.helper`
(0.3.0), because Login Items names and draws a job after the app it found when the job's file
first appeared (`src/label.rs`). An updater that shipped looks for the folder name it knows:
version 0.3.0 reads the manifest's `macos-universal` entry and wants `Rex DUO Helper.app` in
the zip, version 0.3.1 prefers `macos-universal-beacon` and wants `Rex DUO Beacon.app`. So a
release has a zip for each, and a Mac that updates with one ends with the new version in a
folder of the earlier name, restarted by the old program under the earlier label. From there
the program moves itself (`src/rename.rs`): about 30 s after the background service started,
and once no update or installer run holds a lock, it starts the updater's launchd job as
`finish-move`. That job renames the bundle to `Pteron Beacon.app` where it sits, tells Launch
Services, writes the new label's LaunchAgent for the new path, boots the earlier jobs out,
loads the new one, and waits up to 20 s for `status.json` to name a Beacon whose `exe` is in
the new bundle and whose `label` is the new one; then it deletes the earlier labels' files,
every one that is there, and removes a `….previous.app` of an earlier name if one is there.
It is one restart, from either earlier version. If the Beacon does not come up there, the
bundle gets its earlier name back, the new job is booted out and its file removed, and the
earlier job is loaded again from its file, which was not changed. `install` and opening the
app do the same steps themselves before they set up the LaunchAgent. The bundle is moved only
when it is a real folder directly in `/Applications` or `~/Applications`. When
`Pteron Beacon.app` is already there, whole, ours and of the same version or a newer one,
nothing is renamed: Beacon is started from that app and the folder of the earlier name is
removed. Anything else at that name leaves everything as it is. A move that did not happen
writes one line to the log. The start that the way back causes leaves it at that
(`move.failed` in the state folder), and the start after it tries again.

**The manifest** also carries `min_version` and `next_key`:

```json
{"version": "0.3.1", "min_version": "0.3.0", "released_at": "2026-11-17T12:00:00Z",
 "expires_at": "2027-11-17T12:00:00Z", "next_key": null, "assets": {"linux-x86_64": {"url": "…", "sha256": "…", "size": 1}}}
```

`assets` has five entries: `linux-x86_64`, `linux-aarch64`, and the Mac app three times, the
same bundle under each folder name it has had: `macos-universal` (`Rex-DUO-Helper.zip`, as
`Rex DUO Helper.app`, for the updater of version 0.3.0), `macos-universal-beacon`
(`Rex-DUO-Beacon.zip`, as `Rex DUO Beacon.app`, for the updater of version 0.3.1) and
`macos-app` (`Beacon-macOS.zip`, as `Pteron Beacon.app`, which everything newer takes). The
three entry names and the three file names are fixed for good: installed copies and the phone
app ask for them by name, and the phone app checks each listed address to the letter. Neither
`macos-app` nor `Beacon-macOS.zip` says what the app is called, so they stay when that
changes; a new folder name is then added to the list of allowed names. Every
reader takes each entry of `assets` that has a `url` under the releases prefix, a `sha256` and
a `size`, whatever its name, and picks its own by name.

- `min_version`: a Beacon older than this reports `"update_required": true`.
- `expires_at`: 180 days after signing (`EXPIRES_DAYS`). `Relay/release.sh --resign` signs the
  current list again with a new date, without building; do it before the date passes.
- Every reader ignores a field it doesn't know, so older Beacons, the app and `setup.sh` read
  a list with a new field as before. (`desk` and `signed_at` were a switch that never shipped;
  `release.sh --resign` drops them from a list.)
- `next_key` (handover): a manifest that passed steps 2 and 3 and names a base64 32-byte key
  adds that key to Beacon's trusted set, kept in `trusted_keys.json` (mode 0600) in the
  state folder. At most 4 are kept; a fifth pushes out the oldest. A `next_key` in a manifest
  Beacon did not accept is never read. To replace a signing key, publish a list that names
  the new key, signed with a key Beacons already trust, then sign with the new one.

Beacon doesn't update itself when it can't do so safely, and says why (`rex-duo-helper
status`, Beacon's log): a `--dry-run`, a debug build or one run from a cargo `target`
folder, a Mac Beacon that isn't running from `Pteron Beacon.app` (or a folder of one of its earlier names) or that macOS runs from a
translocated copy, a Linux binary that isn't the installed `~/.local/bin/rex-duo-helper`, no
background service, a folder it can't write to, or a build whose `update-key.pub` holds only
placeholders (32 zero bytes). With placeholders Beacon never asks GitHub for anything.

`status.json` carries what the last check found: `latest_version`, `min_version`,
`update_available`, `update_required`, `checked_at`, `updating`, `can_update`, `last_error`,
`failing_since`, beside `version` / `helper_version`. `last_error` is one of a few fixed sentences ("The release
list is out of date.", "The downloaded update did not pass its checks."); paths, addresses and
what a tool or server said go to Beacon's log only, because any Rex client can ask for the
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
tests-setup/make-fixtures.sh       # write Relay/fixtures again (test data for the app and Beacon)
```

`release.sh` signs with `UPDATE_KEY`, which must be the primary or the recovery key of
`update-key.pub`; `MIN_VERSION`, `NEXT_KEY` and `EXPIRES_DAYS` (default 180) set the manifest's
`min_version` (default: the release; docs/release.md says when to set it), `next_key` and
`expires_at`. Only `--publish` uploads. It makes the three Mac zips from the one in `dist`,
and refuses an app that is not alone in that zip, that is not in a folder of the name its own
binary gives (`brand`), or whose Info.plist or `setup.sh`'s `BEACON=` line say another name. It
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
(`tests-setup/mirror.py`) and a stand-in Beacon (`tests-setup/fake-helper.sh`), under
`bash --posix`, `/bin/sh` and `/bin/dash`. A run as the app starts it happens in a
pseudo-terminal (`tests-setup/pty-run.py`), which types the setup code when the script asks.
A removal runs only in the copies whose `launchctl`, `systemctl` and `codesign` are stand-ins,
in a home folder made for that test.
The copies for a run by hand on a Mac come from the `install.sh` its copy of `release.sh`
wrote. `setup.sh` itself has no setting that moves a
download, skips a check or changes a key, and the tests check that.

Output in `Relay/dist/` (gitignored): `Beacon-macOS.zip` (universal, the app as `Pteron Beacon.app`; `release.sh` makes the two other release zips from it) and
`rex-duo-helper-linux-x86_64` / `-aarch64` (static musl, cross-compiled with `cargo zigbuild`;
set `ZIG=/path/to/zig` if zig isn't on PATH). The script:

- asks the binary it built what the app is called (`rex-duo-helper brand`, which prints
  `brand::BEACON` from `src/brand.rs`) and names the bundle, `CFBundleName` and
  `CFBundleDisplayName` so;
- wraps the universal Mac binary in a bundle (`LSUIElement`, bundle id
  `dev.abrahamgonzalez.rexduo.helper`), with the icon compiled by `xcrun actool` from
  `Brand/BeaconIcon.icon`, an Icon Composer document: `Assets.car` (the layered icon and its
  flattened sizes) and `AppIcon.icns` in `Contents/Resources`, `CFBundleIconName` in the
  Info.plist;
- signs with the Developer ID Application identity (`IDENTITY`), hardened runtime, no
  entitlements, and notarizes with `xcrun notarytool` and an App Store Connect API key
  (`ASC_KEY`, `ASC_KEY_ID`, `ASC_ISS`), staples, then checks `spctl`.

## Commands and options

| Command | Meaning |
| --- | --- |
| `install` / `status` / `uninstall` | Run in the background, report, or stop and remove it. |
| `install --server <addr>` | Also adds that Rex server to `config.json`'s `servers` (Config). It takes the `unix://` address of a socket that is there and belongs to this user, or an `https://` address; anything else is refused before anything changes, with exit status 2. |
| `install --setup-nonce-file <path>` | For Pteron's setup: reads the setup code from that file, removes the file, and keeps the code for 30 minutes to answer `setup_challenge` ("What the app must do", 2). The file is a regular file of this user that no one else can open (no group or other permissions), at most 128 bytes: 64 lowercase hex digits, with or without one newline after them. Any other file is removed too, and the command is refused with exit status 2 before anything else changes. The code is never an argument. |
| `version` | Print the version. `version --json` prints `{"version":"x.y.z"}` and nothing else. Every installer that shipped reads that by its exact shape, so it never gains a field. |
| `brand` | Print what the program is called, on one line (`brand::BEACON` in `src/brand.rs`). `package.sh` and `release.sh` name the Mac app and the release from it. |
| `run` | Run in the foreground (what the service runs). |
| `update` | Look for a newer version and install it. `update --check` only looks. See Updates. |
| `forget <device id>` | Remove a phone's registration, whoever registered it. Alone, `forget` lists the phones. The running Beacon notices. |

`run` takes `--dry-run` (log each push, priority, collapse id and payload, instead of sending
it: no request goes to the gateway, and a dry run never updates; `REX_DUO_DRY_RUN=1` works too), `--verbose` (also log working/idle reports and every "no push"
decision), `--server ADDR` (repeatable, `unix:///…` or `https://…`), `--state-dir`, `--config`,
and `--log-file`. Only with `--dry-run`, to try desk presence (Desk presence) without the real
helper noticing:

- `--idle-away SECS`: the desk is away after SECS without input instead of 300.
- `--client-name NAME`: connect as NAME instead of `rex-push-relay`, so the phone app never
  takes the run for the helper.
- `--session ID` (repeatable): attach to this Rex session only, with `session.attach`, instead
  of watching every session: the run gets no other session's events.
- `--desk-file FILE`: at the desk or away as FILE says (`present` or `away`), read at every
  look; anything else is the computer's own reading.
- `--hold-cap SECS`: hold a question SECS at most instead of 600.
- `--send-local`: send pushes and leases for real to a gateway on this machine
  (`http://127.0.0.1:…`, as a test runs one). Any other gateway still gets nothing.

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

`servers` replaces discovery, unless the list has the word `"discover"`: then Beacon
watches the server it finds and the ones the list names, each once. `install --server` adds an
address to the list and never a second time. Where there was no list it writes `["discover",
"<addr>"]`, so discovery stays on, and it writes nothing when the address is Rex's default
socket, which discovery finds anyway. `auto_update: false` turns the update timer off
(Updates).

`gateways` adds push gateways to the allowlist. A phone names its gateway when it registers,
and Beacon sends that phone's secret there, so it only takes a gateway it already knows:
the built-in `https://rexduo-push.keptday.workers.dev`, or an entry of `gateways`. An entry is
an origin (`https://host[:port]`, no path). Plain `http://` is taken only for `127.0.0.1` or
`localhost`, and only from this list (tests run a gateway there). A registration whose gateway
is no longer on the list is dropped when Beacon starts.

`devices.json` in the same folder holds the registered phones, one per `device_id`: the
gateway's origin, the phone's push secret, its environment and name, `owner`, the identity
that registered it, and `paused` (true while the phone's user has notifications from this
computer switched off; an entry without the field is not paused). It is written through a temporary file and readable by its owner only
(mode 0600), because the secrets in it are what lets this Beacon push. An entry Beacon
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
- `429`, `5xx` or a network error: that one push is lost; Beacon logs a line and does not
  send it again. A request has 10 seconds.

A phone whose registration was removed is not left without pushes in silence: its next
`push_presence` or `helper_status` answers `"registered": false`, and registering the refused
secret again fails with `secret_dropped`, so the app mints a new secret and registers again.
Neither a secret nor the text of a push is written to the log, and no action's result or
error carries any part of a secret.

The first time a phone registers, the computer shows one desktop notification: "Pteron
connected", "<device name> can now open your sessions on this computer." It shows once per
`device_id`: `seen_devices.json` in the same folder keeps the ids that have registered, so
a new secret, a reconnect, a Beacon restart or an unregister followed by a register shows nothing.
The file holds at most 512 ids, oldest first; a new id past that pushes out the oldest one that
is not registered now, and a phone pushed out gets a notice again if it comes back.
At most 3 notices show in any 60 seconds; a new phone past that is still registered and
remembered, and the log says its notice was held back.
Phones already in `devices.json` when Beacon is upgraded count as seen, old entries
included. On a Mac it comes from Pteron Beacon itself: `rex-duo-notify`
(`Packaging/notify.swift`), a small program beside Beacon in the app, posts it, and macOS
asks once, when the app is first opened, whether Beacon may show notifications. Answer no,
or run Beacon outside its app, and no notice is shown. On Linux it goes through `notify-send`, and only if it is installed and a desktop session is there
(otherwise Beacon logs a line and carries on), with `&`, `<` and `>` in the name escaped,
because Linux notification servers read the text as markup. `--dry-run` logs `DRY-RUN notice`
instead, once per new phone per run, and never writes `seen_devices.json`, so the real Beacon
still shows that phone's notice.

## What the app must do

### 1. Put a device id in the Rex client label

Pick a stable per-install id of 8 lowercase hex characters, e.g. the first 8 hex digits of
`identifierForVendor`. End the `label` in the hello with ` #<device_id>`:

```json
{"type": "hello", "api_revision": 13,
 "client": {"kind": "app", "platform": "ios", "name": "Pteron", "version": "1.0",
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
<Beacon's own Rex client id>
<the caller's Rex client id, as the server reports it>
<device_id>
```

Verify it, check that `client_id` is the client you called and that line 4 is your own client
id, and compare `public_key` with the one pinned for this server (pin it the first time). Both
client ids are signed so that a client in between can't pass your challenge on to the real
helper. A challenge that isn't 32 bytes of base64url, or a `device_id` that isn't 8 lowercase
hex digits, fails with `bad_request`. `not_supported` means a Beacon too old for this.

A phone that installed this Beacon through Pteron's setup adds `"setup_challenge":
"<base64url of 32 random bytes>"` to the args. While Beacon holds the setup code that
setup gave `install --setup-nonce-file`, the result also has

```json
{"setup_proof": "<base64, 32 bytes>"}
```

which is HMAC-SHA256, keyed by the 32 bytes the code's hex stands for, over these four lines
joined by `\n`, with no newline at the end:

```
rexduo-setup-v1
<setup_challenge exactly as sent>
<Beacon's own Rex client id>
<the caller's Rex client id, as the server reports it>
```

A code makes up to three proofs for one requester identity and ten in all. Beacon keeps it
in `setup_nonce.json` in the state folder (mode 0600) as `{"nonce", "expires_at", "proofs"}`,
where `proofs` lists the identity of the requester each proof went to, and reads that file on
every call, so a Beacon that was already running answers for a code `install` stored a moment
ago. The code is removed when `register_push` succeeds with a `setup_seal` (step 3) for a
requester that was given a proof, and 30 minutes after `install` stored it, whichever is
first. Without a code, or past either count, the field is absent and the rest of the answer is
as usual. A `setup_challenge` that isn't 32 bytes of
base64url fails with `bad_request` and uses nothing up. The code, the proofs and the seal are
never logged and never in `status.json`.

### 3. Register

First the app registers its APNs token with the push gateway (`POST /v1/devices`) and mints a
secret for this Beacon (`POST /v1/devices/{id}/secrets`). Then it gives that secret to the helper:

```json
{"type": "request", "id": "7", "method": "client.perform", "payload": {
  "client_id": "client:<relay id>",
  "action": "register_push",
  "args": {"gateway": "https://rexduo-push.keptday.workers.dev", "push_secret": "<43 characters>",
           "environment": "sandbox", "device_name": "Alex's iPhone", "device_id": "a1b2c3d4",
           "presence_key": "<43 characters>"},
  "timeout_ms": 5000}}
```

- `gateway`: the gateway's origin. It must be on Beacon's allowlist (Config, `gateways`).
- `push_secret`: what the gateway returned. Beacon sends it as the bearer token of every
  push to this phone and to nothing else.
- `environment`: `sandbox` or `production`. Informational; the gateway knows the real one.
- `device_name`: shown in Beacon's log and in the desktop notice.
- `presence_key`: optional, 32 bytes as base64url (43 characters). The phone's key for desk
  presence across computers (Desk presence), sent only to computers the phone confirmed as its
  owner's own. Without it, or with something that is not such a key, this phone gets no desk
  presence across computers and is pushed to as before. Kept in devices.json, never logged;
  each registration sets it anew, so leaving it out takes it away.
- `device_id`: the id from step 1, 8 lowercase hex digits. The caller's label must end with
  ` #<device_id>`. Registrations are kept by it: a new secret for the same id replaces the old
  one, if the same identity asks.
- `setup_seal`: optional, and sent only by a phone that holds the setup code of the setup that
  installed this Beacon, with the registration that completes it. It is the base64 of
  HMAC-SHA256, keyed by the 32 bytes the code's hex stands for, over these three lines (UTF-8)
  joined by `\n`, with no newline at the end:

  ```
  rexduo-setup-register-v1
  <push_secret>
  <device_id>
  ```

  When Beacon holds that code, gave this requester's identity a `setup_proof`, and the seal
  is the one the code makes for this registration, the setup is complete and the code is
  removed. The registration and its result are the same with a seal, without one, or with one
  that does not match; only a matching seal removes the code.
- `paused`: optional boolean. `true` registers the phone paused and `false` resumed (step 5).
  Left out, a registration with the secret Beacon already holds for this phone keeps the
  value it has, and any other (a first one, or a new secret) is resumed.

Result: `{"result": {"registered": true, "devices": 1, "push_enabled": true, "helper_version": "0.3.0"}, "performed_by": "client:<relay id>"}`.
`push_enabled` is false while Beacon runs with `--dry-run`.

Errors arrive as normal `client.perform` errors:

| Code | Meaning |
| --- | --- |
| `refused` | The Rex server did not identify the caller (`anonymous`). |
| `bad_request` | A gateway that is not on the allowlist, a malformed secret, environment or device id, or a device id that is not the one at the end of the caller's label. |
| `not_your_device` | That device id is registered to another identity. On the computer: `rex-duo-helper forget <device id>`. |
| `secret_dropped` | The gateway already refused that secret. Mint a new one. |
| `not_saved` | The registration could not be written to `devices.json`: `Pteron Beacon couldn't save that. Try again.` Nothing changed, in the file or in memory. `set_push_paused` and `unregister_push` answer the same way. |
| `not_supported` | An app that predates the gateway (a `token`, no `push_secret`): `This Pteron Beacon needs a newer Pteron app.` |

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
works too: the client then leaves at once. Only a claim counts: send `{"active": true}` again
at least every 3 minutes while in front (the app does every 60 s). A connection alone, or a
claim older than 3 minutes, is not in front.

Result: `{"registered": true|false}`, whether the caller's phone (the device id in its label)
has a registration here that the caller's identity made. `false` means register again; if the
secret the app holds is then refused with `secret_dropped`, mint a new one first.

### 5. Pause, resume, unregister

A switch in the app that turns this computer's notifications off and on is a pause:
`action: "set_push_paused"`, `args: {"paused": true}`, and `{"paused": false}` to resume.
Result `{"paused": true|false, "registered": true}`. It applies to the caller's own phone, and
only the identity that registered the phone may ask, as in `push_presence`; anyone else, and a
phone with no registration here, gets the error `not_registered`. `paused` must be a boolean
(`bad_request` otherwise).

A paused phone is sent nothing: Beacon composes no notification for it and makes no
request to the gateway for it, for an agent's event or for `send_test`. Its registration stays
whole, secret included, so resuming needs nothing from the gateway. The value is kept in
`devices.json` and survives a restart. `push_presence` is taken as usual while paused, and
`helper_status` reports the value as `paused`.

To remove the phone from this helper: `action: "unregister_push"`, `args: {"device_id": "a1b2c3d4"}`.
Result `{"removed": true|false}`. Only the identity that registered the phone can remove it;
anyone else gets `false`. A `token` argument is ignored; alone it removes nothing.

### 6. Show and update Beacon

`action: "helper_status"`, no args. Result:

```json
{"version": "0.3.0", "latest_version": "0.3.1", "min_version": "0.3.0", "update_available": true,
 "update_required": false, "checked_at": "2026-11-17T12:00:00Z", "updating": false,
 "can_update": true, "last_error": null, "failing_since": null, "registered": true,
 "manifest_expires_at": "2027-05-16T12:00:00Z", "notices": "allowed", "linger": null,
 "os": "macOS 15.5", "devices": 2, "other_phones": 1, "last_push_at": 1794950000, "paused": false,
 "share_possible": true}
```

`latest_version`, `min_version` and `checked_at` are null until Beacon has checked.
`update_required` is true when Beacon is older than the newest release's `min_version`.
`can_update` is false when Beacon can't replace itself (Updates lists when). `last_error`
is one of a few fixed sentences, never a path, an address or raw error text. `failing_since`
is when the first of the current run of failed checks ended, in seconds since 1970: a check
fails when the release list could not be downloaded or was not accepted. It is null when the
last check passed or none ran. `registered` is as in `push_presence`. `paused` is whether the
caller's phone is paused here (step 5); false when it has no registration.

`manifest_expires_at` is when the release list Beacon last accepted stops being valid
(null until it has checked since it started). Within 30 days of that time Beacon also logs
one line at every check. `notices` is whether macOS lets Beacon show its "Pteron
connected" notice: `"allowed"`, `"denied"` or `"undetermined"`, read from `rex-duo-notify
status`, which never asks; null on Linux, and when Beacon can't tell. `linger` is whether
the Linux service keeps running after logout (`loginctl show-user <user> -p Linger --value`):
true or false; null on a Mac, and when `loginctl` doesn't say. Both are read when a phone asks
and reused for 5 seconds. Neither is in `status.json`.

`os` is this computer's system in one line of at most 64 printable ASCII characters, read once
when Beacon starts: `"macOS "` and the product version (`sw_vers -productVersion`), or on
Linux the `PRETTY_NAME` of `/etc/os-release` without its quotes, `"Linux"` when there is none.
`devices` is how many phones are registered on this Beacon, whoever registered them.
`other_phones` is how many of them the caller's identity did not register.
`last_push_at` is the unix time in seconds of the last notification the gateway accepted from
this Beacon for the caller's phone (a test counts), for the identity that registered it; null
when there was none since Beacon started. It is kept in memory only.

`share_possible` (from 0.7.0) is whether `port_share` could work on this computer now: the
Tailscale command line is found (step 8, the same fixed paths and the same check of whose
program it is) and says it is running with an address. Why not is not said. A Beacon before
0.7.0 does not send the field; a reader treats that as false. The answer is looked up at
most once in 60 seconds, however often `helper_status` is asked, and waits at most 2 seconds
for the command (no answer in that time is `false`, also kept 60 seconds). Without the
command line nothing is started at all. It says nothing about the caller's phone: whether
that phone is a device of this computer's Tailscale user is checked by `port_share` itself.
It is not in `status.json`.

`action: "update_helper"`, no args. Only an identity that has a phone registered on this
Beacon may call it; anyone else gets `refused`. Beacon checks now. Result `{"started":
true, "version": "0.3.1"}` when an update began (Beacon answers first, then downloads,
checks, swaps and restarts, so expect it to drop off Rex for a few seconds), or `{"started":
false, "version": "0.3.0"}` when it is up to date. A Beacon that can't update, or a check that
failed, answers with the error `update_failed` and one of the fixed sentences. At most one
such check runs per 10 minutes, whoever asks: a second answers `update_cooldown`, and its
message says how many seconds are left. Beacon's own timer is separate.

`action: "send_test"`, no args. Beacon sends one notification to the caller's own phone
through the gateway, whether or not Pteron is open on it. Only the identity that registered
the phone may ask, as in `push_presence`. Result `{"sent": true}`. Errors, each with a plain
sentence as `message`:

| `code` | When |
|---|---|
| `not_registered` | The caller's phone has no registration here that the caller's identity made. |
| `paused` | The caller's phone is paused here (step 5). Nothing is sent and the test allowance is not used. |
| `test_too_soon` | A test went to this phone less than 10 seconds ago. An attempt counts whatever came of it. |
| `phone_gone` | The gateway no longer has the phone (`410`), or does not know the secret Beacon holds for it (its own `401`). The registration fares as after any push with that answer: dropped at once on `410`, and on the second `401` a minute or more after the first. Register again with a new secret. |
| `limit_reached` | The gateway answered `429`. |
| `no_connection` | The gateway could not be reached, or gave any other answer. |

The notification: title `Pteron`, body `Test notification from <first part of the host in server>`, sound
`default`, category `NOTICE`, thread id `rexduo-test`, level `active`, and `server` as in
every push. It has no `session_id`, `window_id` or `block_id`, and no collapse id.

### 7. Handle the push

```json
{
  "aps": {
    "alert": {"title": "Claude · api", "subtitle": "work", "body": "Which database should I use?"},
    "interruption-level": "time-sensitive",
    "sound": "default",
    "thread-id": "block:<uuid>",
    "category": "AGENT_BLOCKED_ACT"
  },
  "server": "https://my-mac-rex.example.ts.net",
  "session_id": "session:<uuid>",
  "window_id": "window:<uuid>",
  "block_id": "block:<uuid>",
  "record": "claude",
  "fp": "d110a7daf17e741b"
}
```

- `server` is the server's Tailscale HTTPS URL, as entered in the app's server list.
- `window_id` is left out when the block isn't in a window.
- Title is `<agent> · <tab>`, subtitle is the session when it differs from the tab.
- A collapse id is set for agent pushes (`collapse_id` in the gateway request, which becomes
  `apns-collapse-id`), so a later state of the same block replaces the earlier notification.
- The time-sensitive level needs the Time Sensitive Notifications capability in the app.
- `record` and `fp` name the wait a question is about, so the app can answer it from the
  notification with Enter or Interrupt (docs/notifications.md, Answering from a notification).
  `record` is the id of the status record that reports it. `fp` is the wait's fingerprint
  (`policy::fingerprint`): FNV-1a, 64 bits, as 16 hex characters, over the record's `state`,
  `kind` and `msg` as Rex gave them, not trimmed as the push's words are, with a missing
  value apart from an empty one. The app makes the same from the record it reads before it
  types (`ActionGuard.fingerprint`), and types only when the two are equal;
  `fixtures/fingerprints.json` holds the cases both are tested against.
- Only a question carries the two, with the category `AGENT_BLOCKED_ACT`, and only when it
  can name its wait: the record's state is exactly `blocked`, and its id is not empty, at
  most 128 bytes and written as an identifier (ASCII letters, digits and `. _ : -`). The id
  is the reporting program's own and goes into the push as it is, so one that could be text
  is not sent; `fp` is a hash. Beside its title and body a push carries none of the
  record's words. Any other question is `AGENT_BLOCKED` with
  no `record` and no `fp`, as every question was before 0.6.0, and the app shows no action
  on it. A question held at a desk, or sent at the end of the debounce window, goes with its
  own wait; one that 0.5.0 parked has none.
- A gateway from before these fields refuses such a question whole (`400`). Beacon then
  sends it once more as `AGENT_BLOCKED` without `record` and `fp`, so the phone still gets
  the question, with no actions. It says so in its log once per run. That is the only case
  in which a push is sent twice; any other answer stands, and so does the second request's.
- The payload is at most 4096 bytes, Apple's limit. The title is cut to 120 characters and
  the body to 1000; a body that would still take the payload over the limit (wide
  characters, or ones JSON escapes) is cut further, and no other field is.
- The app registers the categories `AGENT_BLOCKED`, `AGENT_BLOCKED_ACT`, `AGENT_DONE` and
  `NOTICE`; only `AGENT_BLOCKED_ACT` has actions.

### 8. Open a port in the phone's browsers (`port_share`, from 0.7.0)

The app shows a dev server's page inside itself through a Rex tunnel, which ends when the app
leaves the screen. For a page any browser on the phone can open, it asks Beacon for a share.

`action: "port_share"`, args:

```json
{"block": "block:12", "port": 3000, "phone_ip": "100.64.0.2"}
```

- `port`: the port the dev server listens on, on this computer: 80, or 1024 to 65535.
- `phone_ip`: the phone's own Tailscale address, IPv4 or IPv6, as the phone reads it from its
  Tailscale interface. It is the only address that may connect. An IPv4 address written as
  an IPv6 one (`::ffff:100.64.0.2`) is the IPv4 address.
- `block`: the pane the server runs in (optional). Beacon uses it only to follow Rex's events
  about that pane.

Result:

```json
{"url": "http://desk.example.ts.net:3000", "ip_url": "http://100.64.0.1:3000",
 "port": 3000, "same_port": true, "idle_seconds": 1800, "waiting_seconds": 600}
```

- `url` is what to open: the computer's MagicDNS name when its tailnet gives names, else its
  Tailscale address (then `url` equals `ip_url`). `ip_url` always names the address, for a
  phone that can't look the name up. An IPv6 address is in brackets.
- `port` is the port the share listens on. On a Mac it is the dev server's own number when
  nothing else has it on the Tailscale address (`same_port: true`), else one the system
  picked. A server that listens on every address of the computer (`0.0.0.0`, `[::]`) holds
  its number there too, so its share gets another one. On Linux it is always one the system
  picked: there a share on the server's number would keep a server that later asks for that
  number on every address from starting. (On a Mac such a server still starts, and each
  keeps its own address.)
- Asking again for a port that is shared returns the same addresses and starts its idle time
  over. The same phone asking from another address gets a new share in the old one's place.
  Requests are settled one at a time, so two at once for the same port make one share.

Errors, each with a plain sentence as `message`:

| `code` | When |
|---|---|
| `not_supported` | A Beacon before 0.7.0: it has no such action. Hide "Open in Browser". |
| `refused` | The Rex server did not identify the caller; or the port is below 1024 and not 80; or it is a usual port of something that is no page for a phone (2181, 2375, 3306, 5432, 5672, 6379, 8001, 8384, 9092, 9222 to 9239, 11211, 11434, 27017); or what listens on it is not a process of the user Beacon runs as. |
| `not_your_phone` | Tailscale does not say that `phone_ip` is a device of the same tailnet user as this computer: it is another user's, a tagged device, an address it does not know, or it did not answer. A computer that is itself a tagged device answers this for every phone. |
| `not_registered` | The caller's phone has no registration here that the caller's identity made. |
| `bad_request` | `port` is no port number, `phone_ip` is no Tailscale address (`100.64.0.0/10`, `fd7a:115c:a1e0::/48`), or `block` is longer than 200 characters. |
| `not_available` | The computer doesn't run the regular Tailscale client, the client is not running, or it has no address of the kind `phone_ip` is. Hide "Open in Browser" for this computer. |
| `not_listening` | Nothing listens on `localhost:<port>` now. |
| `busy` | Eight shares are open. |
| `failed` | The system gave no port to listen on. |

Whose port it is: Beacon asks the system which sockets listen on the port (`lsof -Fptn` on a
Mac, `ss -ltnp` on Linux), reads each process named, and keeps the loopback addresses where
it runs as the user Beacon runs as: `127.0.0.1` for an IPv4 socket, `::1` for an IPv6 one.
Both tools name only that user's processes, so a port of another user or of the system has
no listener as far as a share goes. A share connects only to the addresses kept. It asks
again whose the port is when a connection there finds nothing, when Rex says the port left
its pane, and once a minute while it is in use (at most every 2 s); a port that another
user's process holds by then gets no connection, and the phone the waiting page. Between two
of those looks a share relies on the last one.

Whose phone it is: before a new share is made, Beacon runs `tailscale whois --json
<phone_ip>` and reads `Node.User`, `Node.Tags` and `UserProfile.ID`. The two ids have to
agree with each other and with `Self.UserID` of this computer's own status, and neither
device may be tagged (`Tags` absent, `null` or empty means untagged). The ids are read as
whole numbers, exactly. A client that gives no answer to this in time makes the answer
`not_available`, not `not_your_phone`.

How Beacon reads Tailscale: it runs the client's own command line, `tailscale status --json
--peers=false`, as the user it runs as, with a 5 s limit, once per `port_share`. It looks for
the command line at fixed full paths, in this order, and runs the first that passes. No
`PATH` is searched. A path passes when the file can be run and only root, Beacon's own user
or the computer's administrators can change it or put another in its place: the file and
every folder on the way to it belong to root or to that user, none can be written to by
everyone, and none by its group unless the group is macOS's `admin` (whose members can act
as root; the system itself makes `/Applications` writable by it). On Linux no group may. A
link is followed, and both the folders the link is in and the folders the file is really in
are held to this. A path that does not pass is skipped for the next.

| System | Paths, in order |
|---|---|
| macOS | `/Applications/Tailscale.app/Contents/MacOS/Tailscale` (the app's own program, which is the command line too), `/opt/homebrew/bin/tailscale`, `/usr/local/bin/tailscale` |
| Linux | `/usr/bin/tailscale`, `/usr/sbin/tailscale`, `/run/current-system/sw/bin/tailscale` (NixOS), `/usr/local/bin/tailscale` |

When none passes, or the one that does gives no answer to either question in time, the
answer is `not_available`. A default Homebrew has its folders owned by the user with group
`admin` (`/opt/homebrew/bin` on Apple silicon, `/usr/local/bin` on Intel), so its link passes
on a Mac; a folder there that everyone or another group can write to does not.

From the status it reads `BackendState` (must be `Running`),
`Self.TailscaleIPs` (only addresses in Tailscale's two ranges count), `Self.DNSName`,
`Self.HostName`, `Self.UserID`, `Self.Tags` and `CurrentTailnet.MagicDNSEnabled`. Nothing is changed and no other device
is listed. Without that answer there is no share: no address is taken from the network
interfaces, because an address in `100.64.0.0/10` on another network is not a tailnet.

What a share is:

- **One listener, on the computer's Tailscale address only**, never on a LAN or public
  address or on every address. It is made without address reuse, so it never takes a port
  from a program that has it.
- **For one phone.** A connection from any address but `phone_ip` is closed before a byte is
  read, and reaches nothing.
- **HTTP only, to one loopback port.** Each connection is piped to `127.0.0.1:<port>` or
  `[::1]:<port>` (the one that answered last is tried first; the share never connects to
  itself). What is not an HTTP/1.x request is answered `400` by the share and reaches
  nothing; a head over 32 KB or 100 header lines gets `431`. Also `400`: `CONNECT`, a first
  line that names anything but a path (`GET http://…`, `OPTIONS *`), and `Transfer-Encoding`
  in HTTP/1.0.
- **The dev server sees a local visitor.** Dev servers turn away a request for a name they
  don't know (Vite's `server.allowedHosts`, Next.js's `allowedDevOrigins`,
  webpack-dev-server), so the share rewrites the head of each request and answer, and only
  the head:

  | Direction | Header | Becomes |
  |---|---|---|
  | request | `Host` | `localhost:<port>` |
  | request | `Origin`, `Referer` | `http://localhost:<port>…` when they name the shared address (by name or by address) |
  | answer | `Location`, `Access-Control-Allow-Origin` | the shared address, as the browser asked for it, when they name `localhost`, `127.0.0.1` or `[::1]` with the port |
  | answer | `Set-Cookie` | loses a `Domain` of `localhost`, `127.0.0.1` or `::1`, so the cookie belongs to the host the browser is on |
  | answer | `X-Pteron-Waiting` | taken out (see the waiting page) |

  A dev server's host check is also what keeps a page of another site from reading it
  through a name that site points at the computer. The share keeps that check in the
  server's place: a request whose `Host` is not the share's own (the computer's MagicDNS
  name, that name's first part, or the Tailscale address, each with the share's port) is
  answered `421` and passed nowhere. An `Origin` from elsewhere stays as it is, so a server
  that checks origins still sees it.

  Every other header and every body passes as it came. Bodies are streamed, never held
  whole: by `Content-Length`, in chunks (sizes, extensions and trailers untouched), or until
  the server closes (an event stream). A request whose body has two ends (`Content-Length`
  with `Transfer-Encoding`, two different lengths) is answered `400`. Chunk sizes are read
  strictly (hex digits, then an extension or the line's end; no spaces): a body that is not
  written so ends the connection, with a `400` when nothing has been answered on it yet.
- **WebSockets pass.** After a `101` answer to a request that asked to change protocols,
  both directions carry every byte untouched, so live reload works. A `101` nobody asked for
  ends the connection and is not passed on.
- **Limits.** Eight shares at once, whoever asked; 32 connections per share and 64 for all
  shares together (one more is closed at once); 64 requests waiting for their answer on one
  connection.
- **Quiet connections.** A connection has 30 s to send its first request, and is closed
  after 30 s between two requests with nothing asked and nothing being answered. One that
  waits for an answer, receives one (an event stream) or carries a WebSocket is in use and
  stays. Every connection is probed by the system after 60 s of silence, every 10 s, and
  ends after three probes without an answer, so a phone that vanished holds nothing for
  longer than about a minute and a half.

When a share ends. Its listener and all its connections close:

- 30 minutes after its last connection closed (`idle_seconds`). A connection in use keeps
  it; the probes above end one whose phone vanished.
- 10 minutes after its port stopped listening (`waiting_seconds`), unless it listens again.
- When the phone is no longer registered: it unregistered, the gateway no longer knows it
  (`410`, the second `401`), or `rex-duo-helper forget` removed it. Beacon sees a `forget`
  the next time it reads its registrations, and a share asks again before it takes a
  connection, before it passes on each request and every 30 s on a quiet connection or a
  WebSocket, so a removed phone gets nothing more and its open connections end.
- When Beacon stops. A restarted Beacon has no shares.

**The waiting page.** A share whose dev server stopped does not go at once. Beacon learns
that the port went from Rex (`ports_changed` without the port on a whole list, `block_closed`
of the pane) or from a connection that finds nothing there; it learns that it is back the
same two ways. Meanwhile every request is answered by the share itself, and the connection
closed:

- status `503`, `Retry-After: 5`, `Cache-Control: no-store`, `X-Pteron-Waiting: 1`;
- for a `GET` that is no WebSocket handshake, a page of about 4 KB with nothing loaded from
  anywhere: the glyph (inline SVG), "Nothing is running on localhost:<port> on <machine>
  right now." and a button "Open Pteron" (`rexduo://open`). It follows the browser's light or
  dark appearance. `<machine>` is the computer's host name as Tailscale has it, shown as text
  (HTML-escaped, cut at 64 characters);
- for every other request the status alone, with no body.

The page's script asks for its own address again every 5 s (`cache: "no-store"`) and reloads
only when the answer no longer carries `X-Pteron-Waiting`. A dev server can't keep the page
there or fake it: the share takes that header out of everything it passes on. The next
request after the port listens again is piped as before.

### 9. Who holds a port, and how it was started (`port_owner`, from 0.7.0)

Rex's `terminal.ports` names the process that holds a port, but not its parent, its process
group or its arguments. A server started through a wrapper (`npm run dev` starts a shell that
starts `node`) is not the process the pane started, so the app can't tell that Ctrl-C in the
pane would reach it, nor what to type to start it again. `port_owner` says what it needs for
both. It only reports: Beacon signals no process and starts none. It asks Rex nothing, so it
works with every Rex server.

`action: "port_owner"`, args `{"pid": 4242}`, the `pid` of the port's entry in
`terminal.ports`. Without a `pid`, `{"port": 3000}` makes Beacon ask the system which process
listens there (`lsof -nP -iTCP:<port> -sTCP:LISTEN -Fp` on a Mac, `ss -H -ltnp sport = :<port>`
on Linux, the first process listed). `pid` wins when both are there.

Result:

```json
{"pid": 4242, "pgid": 4200, "tty_foreground_pgid": 4200, "foreground": true, "job_members": 1,
 "ancestry": [
   {"pid": 4242, "ppid": 4201, "pgid": 4200, "sid": 900, "group_leader": false, "session_leader": false,
    "name": "node", "path": "/usr/local/bin/node",
    "argv": ["node", "/app/node_modules/.bin/next", "dev"], "argv_lossy": false, "truncated": false, "cwd": "/app"},
   {"pid": 4200, "ppid": 900, "pgid": 4200, "sid": 900, "group_leader": true, "session_leader": false,
    "name": "npm", "path": "/usr/local/bin/node",
    "argv": ["npm", "run", "dev"], "argv_lossy": false, "truncated": false, "cwd": "/app"},
   {"pid": 900, "ppid": 850, "pgid": 900, "sid": 900, "group_leader": true, "session_leader": true,
    "name": "zsh", "path": "/bin/zsh",
    "argv": ["-zsh"], "argv_lossy": false, "truncated": false, "cwd": "/home/alex"}
 ]}
```

- `pid`, `pgid`: the holder and its process group.
- `tty_foreground_pgid`: the process group in the foreground of the holder's terminal, or
  `null` when it has none. `foreground` is true when that is the holder's own group, which is
  the group a Ctrl-C typed into that terminal reaches.
- `job_members`: how many processes of the holder's process group were started by the
  job's shell, which is the process that started the group's leader. A shell with job
  control starts the stages of a pipeline side by side in one group, so this is 1 for a
  plain command (`npm run dev`: what npm started itself is not counted) and 2 or more for a
  pipeline (`npm run dev | tee log`), which typing the leader's arguments again would not
  bring back. `null` when it can't be said: the leader has ended or is not this user's, its
  parent is pid 1, the group can't be listed, it has more than 1024 processes, or any
  process in it is another user's or ended while it was counted. On Linux the group is found
  by reading `/proc/<pid>/stat` of every process, and with more than 32768 processes it is
  `null`. Only the count is given: nothing else about the other stages. A Beacon that
  does not send the field is to be read as `null`.
- `ancestry`: the holder first, then the process that started it, and so on up. The list
  ends before pid 1, before the first process of another user or one that can't be read, at a
  process already listed, and after 32 entries. Per entry:
  - `pid`, `ppid`, `pgid`, `sid` (the session; 0 when the system does not say);
  - `group_leader` (`pid == pgid`): the job a shell started leads its group. `session_leader`
    (`pid == sid`): the shell a terminal started leads its session;
  - `name` (the last part of `path`) and `path` (the program's file; empty on Linux when it
    can't be read);
  - `argv`: the arguments as an array, the program's own name first, each exactly as it is
    (spaces, quotes and empty arguments included), never joined. `null` when they could not
    be read, when the process ended or was replaced while it was read, and on a Mac when
    they can't be told from the environment (below);
  - `argv_lossy`: true when an argument was not UTF-8. JSON holds text, so such bytes come
    as U+FFFD, and the array is not what was typed;
  - `truncated`: true when the arguments did not fit 8192 bytes or 256 arguments, or ended
    early. `argv` then holds only the whole arguments before the cut;
  - `cwd`: the process's working directory now, or `null`.

Errors: `not_supported` (a Beacon before 0.7.0), `refused` (the server did not identify the
caller), `not_registered` (the caller has no phone registered here), `bad_request` (no `pid`
and no `port`, or one that is no process id above 1 or no port number), `not_available` (no
such process, it belongs to another user, or nothing of this user listens on the port; the
answer is the same for all three).

**Stop.** Offer it when the pane's foreground process (from Rex's `terminal.process`) is in
`ancestry` and has the holder's `pgid`, or is the holder; look again right before sending the
Ctrl-C.

**Restart.** What to type again is the `argv` of the job the pane's shell started: the entry
that is a `group_leader` with the holder's `pgid` and whose parent is the pane's shell. It is
not the holder's own (`node …/next dev`). Refuse when that entry has `argv: null`,
`argv_lossy` or `truncated`, and quote each argument for the shell yourself. What the
arguments can't tell, so a restart may differ from what was typed:

- Variables set in front of the command (`PORT=4000 npm run dev`) are in the environment,
  not in the arguments, and the environment is never read out.
- An alias or a shell function shows as what it ran, a pipeline, `&&` list or subshell as
  its separate processes, and redirections not at all.
- A program started through an interpreter shows the interpreter's arguments: `npm` is
  `node` running a script, so `argv[0]` is what the script called itself and `path` is the
  interpreter.
- A program can write over its own arguments. Node's `process.title = "x"` leaves `["x"]`
  on a Mac; nothing marks that. An `argv[0]` whose last part is not `name`, or a single
  argument with spaces, is a hint and no proof.
- `cwd` is where the process is now, which is not where it was started if it changed
  directory. The shell's own entry has the shell's.
- A process may end, and its id go to another, at any moment after the answer.

**What is kept private.** Arguments can hold secrets (a token in a flag). They are returned
only in this action's result, to the caller, over the Rex connection that carries every
action. Beacon never logs them, writes them to a file, puts them in an error, or sends them
to the push gateway. The environment is never returned: on a Mac the kernel hands it over
in the same block as the arguments (`KERN_PROCARGS2`); Beacon reads only the counted
arguments out of it and wipes the block. The block gives the count of arguments and where
they begin, not where they end. A program that wrote over its arguments and their NULs (a
title set in place) has fewer strings there than the count, and the count then runs on into
the environment and, when that is short, into the NULs behind it. The rule: take the last
of the counted strings that is not empty. When it has the form `NAME=value`, or holds an
`=` and is the first string or has empty strings behind it, nothing is returned: `argv` is
`null`. That also costs a process whose real last argument has that form (`make CC=clang`)
its arguments, and with them Restart. What the rule can't catch: a program that wrote over
the NUL of its last argument only, so that this argument runs on into a variable and the
result does not have the form `NAME=value` (`--port=3000` with `PATH=…` behind it); and a
variable that was set without that form. No program is known to do the first; the block has
nothing that would show it.

On a Mac the processes are read from the kernel (`proc_pidinfo`, `proc_pidpath`, `getsid`,
`proc_listpgrppids`, `sysctl kern.procargs2`); on Linux from `/proc/<pid>/stat`, `status`, `cmdline` and the `exe`
and `cwd` links.

## Desk presence

While the person sits at a computer whose Rex app shows the agent's server, the pushes they
would see there anyway are held, so the phone's Lock Screen doesn't fill up while they work.
An urgent question still reaches the phone: when they leave, or after 10 minutes at most.

It works at two places:

- **This computer's desk** (local): Beacon reads whether someone is at this computer, and holds
  the pushes of a server whose Rex app runs here.
- **A desk elsewhere** (through the push gateway): a Beacon on a computer nobody sits at
  (workdesk) learns from the gateway that the person is at a desk that shows its server (the
  MacBook, whose Rex app shows workdesk over SSH). The desk's Beacon writes leases at the
  gateway; the agent's Beacon names the desks that show its server in `hold_if_desk`, and the
  gateway holds the push while one of them has a lease (Gateway/README.md, Desk presence).
  This needs the phone's presence key (`presence_key` in step 3), which the app gives only to
  computers it confirmed as its owner's own, and a gateway that has presence. Without either,
  the phone is pushed to as before, as by Beacon 0.4.0.

There is no switch.

**At this computer's desk** means all of these, read when an event comes, every 30 s while a
question is held, and every 30 s while a Rex desktop app runs here and a phone has a presence
key; anything unknown means not at the desk:

- macOS only. On Linux nothing is known, so pushes go out as before.
- Input within the last 5 minutes (IOHIDSystem's `HIDIdleTime`, no permission needed).
- The window server gives a session (`CGSessionCopyCurrentDictionary`), the screen is not
  locked, this user has the console (not switched away from), and the main display is awake
  (`CGDisplayIsAsleep`), so a dark wake or Power Nap never counts.
- The server has a connected Rex desktop app client (kind `app`, not iOS) whose
  `principal.pid` is the main program of an app bundle (`….app/Contents/MacOS/…`), runs as
  Beacon's user and was started by launchd. The Mac app of another computer reaches a server
  through SSH as a bridge process that sshd started, so it doesn't count here; it is that
  computer's desk, which its own Beacon leases.
- Not between "will sleep" and wake (`IORegisterForSystemPower`, on a dispatch queue of its
  own). On "will sleep" Beacon sends what it holds and removes its leases, and then allows the
  sleep, 3 s at most.

| Event | Nobody at a desk | At this computer's desk | At a desk elsewhere (the gateway holds it) |
|---|---|---|---|
| `blocked` | push | **held**; pushed when the desk goes, or after 10 min held, once | **held**; pushed when a probe finds nobody there, or after 10 min held, once |
| `blocked`, new words for the held record | push | the held text is updated; the 10 minutes run on | the same |
| `blocked`, new record of a held pane | push | held anew; its 10 minutes start now | the same |
| `blocked`, new record while the phone shows this pane's earlier question | push | **push** (it replaces the stale one) | push, which a desk elsewhere may hold |
| `done` / `error`, last thing the phone got for the pane was its question | push (passive) under that question's collapse id, so it replaces it | **the same** | **the same**; never holdable |
| `done` / `error`, otherwise | push (passive) | dropped | dropped |
| desktop notification | push | dropped | dropped |
| test notification | push | push | push |
| Pteron in front (a live claim, below) | skip | skip | skip |

A question held for a desk elsewhere is asked about again once a minute per phone and server
(the push itself, with `hold_if_desk` once more: a **probe**). Held again, it waits on; sent,
nobody is at that desk now, and the phone's other questions of that server go too. A server
Beacon can't ask names no desk, so its probe is sent.

A held question stops being held when its agent moves on (works, idles, finishes, its record
is removed, the pane closes), when the phone is paused or unregistered, or when it is sent. One
that could not be sent (rate limit, no network) stays held and is tried again 30 s later; so
does one for a phone whose app is in front then, which goes once the app has left the front.
Questions read back from `parked.json` at start are watched from then on, before Rex is
reached, so their 10 minutes hold whatever Rex does.

Holding takes no rate-limit token; only a send does (a push the gateway held gives its token
back). Only a fresh event and a probe may be held at the gateway (`hold::SendKind::may_hold`).
The sends that end a hold (10 minutes, this computer's desk going, sleep, a `done` that
replaces a question) are never holdable anywhere, so a desk that wrongly looks present
(Screen Sharing, a mouse jiggler, someone else at the Mac) delays a question by 10 minutes at
most.

**Leases** (`src/presence.rs`). While someone is at this computer, Beacon holds a lease at the
gateway of each phone that has a presence key, for each Rex desktop app that runs here (its tag
is `base64url(HMAC-SHA256(presence key, "rexduo-desk-v1\n" + the app's label))[:22]`): 10
minutes, written on arrival and again every 5 minutes, removed (`ttl: 0`) as soon as nobody
is here (lock, 5 minutes without input, another user, display asleep, sleep, the app quit). A
removal that fails is tried again every 30 s until the lease would have ended by itself; none
is renewed while the display sleeps. The gateway's answers:

| Answer | Then |
|---|---|
| `200 {"stored": true}` | held, or removed |
| `200 {"stored": false}` | the gateway doesn't count this computer as the phone owner's: no lease for that phone until it registers again |
| `404` | a gateway without presence: asked again in a day |
| `429` | waits `Retry-After` |
| `401` (the gateway's own) or `410` | as for a push: the secret counts a strike, or the phone is gone |
| anything else (no network, `503`) | tried again at the next look |

The leases are kept in memory: after a restart, one left at the gateway ends within 10 minutes.
A dry run sends none (but with `--send-local`, to a gateway on this machine).

**In front means a live claim.** `push_presence {active: true}` claims the front for 3
minutes; the app renews it every 60 s. A connection alone, or a claim older than 3 minutes,
`{active: false}`, `client_left`, a client the list shows as `lost` (removed then) and a Beacon
restart all end it. A renewal is logged only at `--verbose`.

**One stack per server.** `thread-id` is the server's address (at most 256 bytes), and a
pane's notices share the collapse id `<block>-n`, so a second replaces the first.

**No notices from status panes.** A desktop notification is looked at after 1 s: from a pane
that has an OSC 7501 record now (`terminal.program_status`) or lost one less than 10 s ago, it
is not pushed; that agent says the same through its status. A pane that runs an agent but
reports no status, and one Rex can't tell about, push as before. An OSC 9;4 progress report an
older Rex passes on as a notification is not pushed either.

Kept in the state folder, written as `devices.json` is (mode 0600, through a rename), never by a
dry run:

- `parked.json`: the held questions, each with the phone, the event, when it was held and
  whether a desk elsewhere holds it (`remote`). After a restart or a reconnect Beacon asks Rex
  (`terminal.program_status`) whether each one's agent still waits and drops the ones that
  don't; one Rex can't answer for stays held. Times are counted on both the wall clock and a
  monotonic one, and the longer count wins; a wall clock set back makes a wait over. So no clock
  change or missed sleep lengthens a hold.
- `delivered.json`: per phone and pane, what was last sent (category, record id, collapse id),
  at most 512 entries, the oldest out. An entry changes when something new is sent for the pane
  (a `done` replaces its question), and goes when its record is removed or the pane closes. An
  agent that was answered and works again keeps it, so its `done` still replaces the question.

A file that doesn't read in full is logged, kept as `parked.json.bad` (or `delivered.json.bad`)
and read for what it can be; Beacon carries on.

Fixed choices (`src/desk.rs`, `src/hold.rs`, `src/presence.rs`): away after 5 minutes without
input; a hold lasts 10 minutes at most; the desk is read every 30 s while it matters; a claim
lasts 3 minutes; sleep waits 3 s at most; at most 256 questions are held (past that one is
sent); a notification waits 1 s, and a pane that lost a record counts as having one for 10 s;
a lease lasts 10 minutes and is renewed every 5; a question held elsewhere is asked about once
a minute; a push names at most 8 desks; a gateway without presence is asked again after a day.

Idle time, lock and display state never leave the computer: only "present until T" does, as a
tag the gateway can't read back, and only to the gateway of a phone that gave this computer its
key. The log says "desk present", "desk away (why)" and "desk lease for <phone>: present /
removed", with no labels, tags or keys.

To try it by hand, with the background Beacon left running: a dry run with its own state folder,
under another client name so the phone app never takes it for the helper, attached to a
throwaway session only, with the desk as a file says.

```sh
rex new zz-desk-try --json -- sh -c 'sleep 3600'       # note its session_id
mkdir -p /tmp/desk-try && echo present > /tmp/desk-try/desk
rex-duo-helper run --dry-run --state-dir /tmp/desk-try --client-name rex-push-relay-test \
  --session session:<id> --desk-file /tmp/desk-try/desk --idle-away 20
rex kill zz-desk-try
```

With `--send-local`, a gateway run by `wrangler dev` on this machine gets the pushes and leases
for real; nothing else does. `--idle-away`, `--client-name`, `--session`, `--desk-file`,
`--hold-cap` and `--send-local` are refused without `--dry-run`.

## Debounce and rate limits

- **Blocked:** pushed when a record enters `blocked`, or reports a new message while blocked.
  At most one push per block per 30 s. A block that flaps (blocked, working, blocked) inside the
  window gets one trailing push when the window ends, and only if it's still blocked then.
- **Done / error:** pushed on entering the state, once per block and state per 30 s.
- **Notifications:** identical title and body from the same block within 30 s are dropped.
- **Rate limit:** per device, a burst of 10, then 10 per minute.
- Re-reports of an unchanged state never push.

## Verify by hand

Stop the background Beacon (only one runs per user), run a dry run in the foreground, and drive a
throwaway session from another terminal:

```sh
# Mac: launchctl kill TERM gui/$(id -u)/dev.abrahamgonzalez.rexduo.agent
# Linux: systemctl --user stop rex-duo-helper
rex-duo-helper run --dry-run
rex new zz-push-test -- sh -c 'sleep 2
  printf "\033]7501;state=blocked:app=claude:msg=%s\033\\\\" "$(printf "Ready?" | base64)"
  printf "\033]9;Build finished\a"; sleep 30'
rex kill zz-push-test
# Mac: launchctl kickstart gui/$(id -u)/dev.abrahamgonzalez.rexduo.agent
# Linux: systemctl --user start rex-duo-helper
```

The dry run logs one `AGENT_BLOCKED` and one `NOTICE` push, and sends nothing to the gateway. `rex client list` shows Beacon as
`rex-push-relay` over unix.
