# Release

Device builds and TestFlight uploads run on a build Mac over ssh, because signing needs its unlocked
GUI keychain. Run these only when asked: they install on a real phone or upload to App Store Connect.

The scripts default to the maintainer's setup. Point them at yours with `PTERON_BUILD_HOST` (the
build Mac's ssh host), `PTERON_DEVICE` (the phone's UDID), and `ASC_KEY_ID` and `ASC_KEY` (the App
Store Connect key). The scripts' file names still say `macdesk`; any build Mac works.

- Bundle id `dev.abrahamgonzalez.rexduo` (fixed: App Store Connect and the APNs topic depend on
  it), team `R2PVQ496X7`, automatic signing. Display name "Pteron" (`CFBundleDisplayName`, from `APP_DISPLAY_NAME` in project.yml),
  product `Pteron.app`.
- The build number is passed as `CURRENT_PROJECT_VERSION`; it must be higher than the last upload.
- The project is generated and the build Mac needs no XcodeGen, so every flow generates it
  locally and copies the result.

## Copying the tree to the build Mac

`scripts/sync-macdesk.sh [-n] [remote-dir]` does the copy for both flows below. It checks the
Ghostty framework (`scripts/check-ghostty.sh`), runs `xcodegen generate` and rsyncs the tree to
`~/rexduo-build/` on the build Mac (or `remote-dir`). `-n` is a dry run.

- The copy uses `rsync --delete`, so the script refuses any `remote-dir` that is not a single
  folder name starting with `rexduo-build` under the build Mac's home.
- Keys never go across: `.asc.env` and other `.env` files, `Relay/dist`, `Relay/.stage` and
  `Relay/target` (Beacon builds from before the push gateway embedded the APNs key), and any `*.p8`, `*.p12`, `*.pem`, `*.key`, `*.cer`, `*.mobileprovision` or
  `*.provisionprofile`.

- libghostty-vt is built on the developer's Mac by `scripts/build-ghostty.sh` and copied; the
  build Mac never builds it. The binary that ships is then the one the tests and benchmarks ran against, and
  the build Mac needs no Zig, no Ghostty checkout and no network access to them. Building on the build Mac
  would not make the binary reproducible either: `build-ghostty.sh` runs there (92 s cold), but
  two builds of the same pin differ byte for byte. `Vendor/GhosttyVt.stamp` travels with the
  framework and records the Ghostty commit, Zig version and patches it came from.
- From `Vendor/` only `GhosttyVt.xcframework` and `GhosttyVt.stamp` are sent, 51 MB once per
  rebuild; unchanged files are skipped. The copy works when `Vendor` is a symlink (agent worktrees).
- All three slices are sent although device builds link only `ios-arm64` (13 MB). Dropping the
  others would need a rewritten `Info.plist` in a second copy of the framework, to save 38 MB once
  per re-pin.
- `ship-macdesk.sh` and the app target's pre-build phase run the same check on the build Mac, so a
  copy with a missing or stale framework fails with one line instead of a link error. The check
  also fails if `project.yml`'s iOS deployment target is below 17.4, which the framework needs.

## Install on the iPhone Duo

With the phone paired to the Mac you work on, `scripts/install-duo.sh [build]` builds Release
there and installs it with `devicectl`; the build log is `build/install-duo.log`.
`VIA=<ssh host> scripts/install-duo.sh` does the same on that host (after `sync-macdesk.sh`) for
when the phone is paired there.

## The gate

`scripts/gate.sh` is the check before a release, run on the developer's Mac. It creates a fresh
simulator (`GATE_DEVICE`, default iPhone 17 Pro, on the newest plain iOS runtime or
`GATE_RUNTIME`), runs the app's tests and a Release build on it, fails on any warning from our
code, and runs `scripts/check-brand.sh`. The tests run in one process
(`-parallel-testing-enabled NO`): with parallel workers the Mac's load makes about 20 of them
miss their time limits. It prints the load before the tests, the test summary and the failure lines, then
deletes the simulator and `build/` (only its own folders there when `build/` was there before).
When a step fails it copies the two logs to a temporary folder first and prints the path, and it
exits 1.

## TestFlight

```sh
scripts/testflight.sh notes.txt               # ship this checkout as build `date +%y%m%d%H%M`
scripts/testflight.sh notes.txt --build 42    # a chosen build number
scripts/testflight.sh notes.txt --dry-run     # print the steps; changes nothing
```

`scripts/testflight.sh <notes-file> [--build N] [--skip-upload] [--dry-run]` makes the whole
release, from the checkout it is in (normally main, committed):

1. It loads `.asc.env` from the main checkout (`ASC_ENV` overrides; a worktree finds it through the
   shared repository) and prints none of it.
2. It copies the tree with `sync-macdesk.sh` and runs `ship-macdesk.sh <build>` on the build Mac
   as below. It first checks that App Store Connect has no build with that number.
3. It polls App Store Connect every 30 s until the build is `VALID` (up to 45 minutes), and stops
   on `INVALID` or `FAILED`.
4. It sets the build's "What to Test" text (`whatsNew`, at most 4000 characters) from the notes file.
5. It submits the build to Beta App Review, unless it is already submitted, and polls every 60 s
   until `APPROVED` (up to 2 hours), stopping on `REJECTED`.
6. It adds the build to the testers' group, with up to 5 tries 30 s apart: the group can refuse a
   build for a short time after approval.

- The app and the group are `APP_ID` and `GROUP_ID` at the top of the script;
  `TESTFLIGHT_APP_ID` and `TESTFLIGHT_GROUP_ID` override them.
- `--skip-upload --build N` starts at step 3 with a build already uploaded, for a run that
  stopped after the upload (a review that took over 2 hours, a failed group add).
- `--dry-run` uploads, submits and changes nothing. It checks the notes, the key, the app, the group
  and the build number with read-only App Store Connect calls, and prints the steps.
- The notes come from a file, read once at the start; never edit the script for a release. zsh
  reads a script while it runs it, so the script copies itself to a temporary file and runs that
  copy: an edit, pull or branch switch during the 1–3 hours of a run does not change it.
- `asc.mjs` cuts a response at 4000 characters, so each call asks only for the fields it reads.

By hand, the upload alone is:

```sh
scripts/sync-macdesk.sh
ssh <build host> "sudo launchctl asuser \$(id -u) sudo -u \$USER zsh -lc '~/rexduo-build/scripts/ship-macdesk.sh <build>'"
```

Or upload from GitHub's machines, when the build Macs are busy: the workflow `TestFlight`
(`.github/workflows/testflight.yml`) archives main and uploads it, then step 3 on finishes it.
Push main first and let CI's tests pass for that commit; the workflow runs no tests.

```sh
gh workflow run testflight.yml --ref main -f build=<build>
gh run watch <run id> --exit-status
scripts/testflight.sh notes.txt --skip-upload --build <build>
```

- It signs with the App Store Connect API key (`ASC_AUTH_KEY`, `ASC_AUTH_KEY_ID` and
  `ASC_AUTH_ISSUER` for `ship-macdesk.sh`), held in the secrets of the repository's `testflight`
  environment. GitHub gives that environment's secrets to runs on main only, so pull requests,
  forks and other branches never reach the key. Nothing prints it, and the runner deletes it.
- It is started by hand only, and one runs at a time.

`launchctl asuser` runs the script inside the GUI session; plain ssh can't reach the keychain.
`ship-macdesk.sh` archives, exports with `destination=upload` (set `DEST=export` to only export) and
logs to `~/rexduo-build/build/ship.log` on the build Mac. Builds appear in TestFlight 5–15 minutes later.

The build number is required; without one the script prints its usage and exits 2. It exits 0
only when the export or upload succeeded, and the log then ends with `== done … rc=0`. A failed
step exits 1 and ends the log with `== ARCHIVE_FAILED`, `== SYMBOLS_FAILED` or `== EXPORT_FAILED`
and xcodebuild's status.

It runs `scripts/check-symbols.sh` twice: on the framework before archiving (a failure prints to
the caller) and on the archived app before export (`== SYMBOLS_FAILED` in the log, with the
symbols above it). Nothing is exported or uploaded when the app imports a private system symbol,
which App Store review rejects as ITMS-90338.

What the archive holds (checked 2026-11-16 on a `DEST=export` run):

- libghostty-vt is linked statically: no `Frameworks/` folder, nothing embedded, arm64 only. It
  adds 1.48 MB to the app binary (6.46 MB stripped; the IPA is 13.4 MB).
- Its objects carry DWARF, so `Pteron.app.dSYM` covers it. Bitcode is not involved.
- No private system symbols: Zig's standard library called `__ulock_wait` and `__ulock_wake`,
  and `scripts/ghostty-patches/0001-tinyio-public-darwin-futex.patch` replaces them with the
  public `os_sync_wait_on_address` calls (iOS 17.4). `check-symbols.sh` guards it. No build with
  the patch has been uploaded yet, so Apple's own check has not seen it.
- Third-party licence notices ship in the bundle as `Acknowledgements.txt`.

The app embeds one extension, `PteronWidgets.appex` (the widgets and the controls;
[glance.md](glance.md)), with its own App ID, `dev.abrahamgonzalez.rexduo.widgets`.
Automatic signing with `-allowProvisioningUpdates` registers the App ID and makes its profile at
the first device build or archive, if the signing account may; otherwise register the identifier
in the developer portal first.

Both App IDs carry the App Group `group.dev.abrahamgonzalez.rexduo`, where the app writes the
snapshot the widgets read, and the extension's also carries Data Protection (Complete), which
hides what the widgets mark as private while the phone is locked. The entitlements files ask for
them (`Pteron/Pteron.entitlements`, `PteronWidgets/PteronWidgets.entitlements`). With automatic
signing and `-allowProvisioningUpdates`, Xcode registers the group, turns the capabilities on
for both App IDs and makes new profiles at the next device build or archive, if the signing
account may edit identifiers; a build that stops with "Provisioning profile doesn't include the
application-groups entitlement" (or the data protection one) means it could not, and the group
and the capabilities are then set in the developer portal by hand (Identifiers → App Groups,
then each App ID's App Groups and Data Protection). A simulator build doesn't check any of this.
No device build or archive with the App Group has been made yet.
The build number given on the command line applies to the extension too, which App Store Connect
requires to match the app's.

### The watch app

The app also embeds the watch app, `PteronWatch.app` (in `Pteron.app/Watch`), which embeds its
own extension, `PteronWatchWidgets.appex` ([glance.md](glance.md), The watch). They are
dependencies of the `Pteron` target, so every build, archive and upload of the app builds and
carries them: there is no separate step, scheme or upload, and the build number on the command
line applies to both. The watch app ships inside the iPhone app's IPA and installs from the
iPhone (Watch app → Available Apps, or by itself with Automatic App Install).

- **Two more App IDs:** `dev.abrahamgonzalez.rexduo.watchkitapp` and
  `dev.abrahamgonzalez.rexduo.watchkitapp.widgets`, both with the App Group
  `group.dev.abrahamgonzalez.rexduo` (`PteronWatch/PteronWatch.entitlements`,
  `PteronWatchWidgets/PteronWatchWidgets.entitlements`). The group is the phone's; a watch has
  its own container of it. With automatic signing and `-allowProvisioningUpdates`, Xcode
  registers them at the next device build or archive, if the signing account may edit
  identifiers. If it may not, the build stops at the watch target with "No profiles for
  'dev.abrahamgonzalez.rexduo.watchkitapp' were found"; then, in the developer portal:
  Identifiers → "+" → App IDs → App, for each of the two bundle ids, with App Groups ticked and
  the group chosen.
- **A development install on a watch** needs the watch's UDID registered (Devices → "+",
  platform watchOS; Xcode's Devices window shows the UDID of a watch paired with a connected
  iPhone). `-allowProvisioningDeviceRegistration` registers a connected one. A TestFlight or
  App Store build needs no registered watch.
- **The build Mac** needs the watchOS platform of its Xcode (the SDK) to build the watch
  targets. It needs no watchOS simulator runtime: that is only for running the watch app and
  `PteronWatchTests` on a simulator.
- **App Store Connect** shows the watch app under the same app record; it needs watch
  screenshots before a release to the store, not for TestFlight.
- No device build, archive or upload with the watch app has been made yet, and whether
  `scripts/install-duo.sh` also puts the watch app on a paired watch has not been tried.

`scripts/asc.mjs METHOD PATH [BODY]` makes signed App Store Connect API calls. It needs `ASC_ISS` in the environment (`source .asc.env`;
the file is gitignored) and reads the key from `~/.appstoreconnect/private_keys/` (`ASC_KEY_ID` picks it).

## Pteron Beacon (Mac and Linux)

```sh
Relay/release.sh --no-notarize   # build and sign everything into Relay/dist/release: a local check
Relay/release.sh                 # the same, notarized
Relay/release.sh --publish       # also publish to GitHub Releases (add --skip-build to reuse the build)
```

- `Relay/package.sh` builds: the universal Mac app (Developer ID, hardened runtime, notarized with
  the App Store Connect key) and static Linux binaries for x86_64 and aarch64 (`cargo-zigbuild`).
  No key or secret is compiled in.
- `Relay/release.sh` then signs the Linux binaries and `manifest.json` with the release key
  (`~/.config/rexduo/helper-update.key`, ed25519; public half in `Relay/update-key.pub`) and
  checks every signature against the committed public key before anything goes up.
- What the program is called is in one place, `Relay/src/brand.rs`, and `Relay/setup.sh` has
  it on its one `BEACON=` line (a test holds the two together). `package.sh` and `release.sh`
  ask the built binary (`rex-duo-helper brand`). The Mac icon is `Brand/BeaconIcon.icon`.
- The Mac app goes out in three zips made from the one notarized bundle, one for each folder
  name it has had, and `release.sh` checks that all three hold the same app, that it calls
  itself by the name, and that the manifest names all three (Relay/README.md, Updates):

  | File | Folder in it | Manifest entry | Who takes it |
  |---|---|---|---|
  | `Beacon-macOS.zip` | `Pteron Beacon.app` | `macos-app` | the installer, the phone app, updaters from 0.4.0 |
  | `Rex-DUO-Beacon.zip` | `Rex DUO Beacon.app` | `macos-universal-beacon` | the updater of 0.3.1 |
  | `Rex-DUO-Helper.zip` | `Rex DUO Helper.app` | `macos-universal` | the updater of 0.3.0 |

  The three file names and the three entries stay for good. Shipped copies of the phone app
  check each listed address to the letter and refuse the whole list on a mismatch, so a file
  behind an entry can never be renamed. `macos-app` and `Beacon-macOS.zip` say nothing of
  what the app is called: after another rename they hold the app under its new folder name,
  which is then added to the list of allowed folder names (`Relay/src/update.rs`,
  `Relay/setup.sh`), and older copies reach it through the zip of a name they accept and the
  rename the new version makes when it starts.
- **`MIN_VERSION`.** `release.sh` writes the release's own version as `min_version` unless
  `MIN_VERSION` says otherwise, and a phone says "Beacon needs an update" of every Beacon
  older than that, for the up to 12 hours each takes to update itself. A release that still
  works with the one before it is made with that version: the release that brings the name,
  0.4.0, changes no protocol, so it is `MIN_VERSION=0.3.1 Relay/release.sh` (and the same
  with `--publish --skip-build`).
- The Mac's background job is the LaunchAgent `dev.abrahamgonzalez.rexduo.agent`. A Mac that
  version 0.3.0 or 0.3.1 updates gets the new version in the folder that version knows
  (`Rex DUO Helper.app`, `Rex DUO Beacon.app`), restarted by the old program under its label
  (`….rexduo.helper`, `….rexduo.beacon`). That Beacon then moves the app to its name and the
  job to its label in one sequence with one restart: the bundle is renamed, Launch Services
  is told, the new label's file is written, the earlier jobs are booted out and the new one
  loaded, and the earlier files are deleted once Beacon reports in under the new label
  (docs/helper.md, Mac). In System Settings → Login Items an entry named Pteron Beacon
  appears with its icon, macOS shows "Background Items Added" once, and the earlier entries go
  about 70 seconds later. The bundle identifier, the code signature's identifier, the update
  job's label (`dev.abrahamgonzalez.rexduo.helper.update`), the binary's name, the state
  folder, the log, the release addresses and `version --json`'s output keep what they have, so
  a release needs no other change for this.
- On Linux the binary and the unit keep their names. The unit's `Description` is written by
  `install` alone, so a Beacon that updated itself shows the earlier description in
  `systemctl --user status` until the next install; `rex-duo-helper status` says the name.
- Copies of the phone app from before the name carry an installer that knows the earlier
  names alone (docs/helper.md, "Older copies of the app"): its Remove deletes a renamed
  Beacon's state folder and leaves Beacon running. Once the release with the name is out and
  the app build with the name has passed Beta App Review, the earlier builds are expired in
  App Store Connect (`GET /v1/builds?filter[app]=<id>&filter[expired]=false`, then
  `PATCH /v1/builds/<id>` with `{"data":{"type":"builds","id":"<id>","attributes":{"expired":true}}}`
  for each), with the owner's go-ahead, since it reaches outside testers.
- After a release with a new name, on a Mac that had the version before: Login Items shows the
  new name and icon; `launchctl print gui/$UID/dev.abrahamgonzalez.rexduo.agent` finds the
  job; `status.json`'s `label` is the new one; `~/Library/LaunchAgents` holds no
  `….rexduo.beacon.plist` or `….rexduo.helper.plist`; `/Applications` holds `Pteron Beacon.app`
  alone. On Linux: `rex-duo-helper version` is the new version and `rex-duo-helper status`
  says the new name.
- `--publish` creates the release `helper-v<version>` with the downloads, then updates the release
  `helper-latest`, which holds only `manifest.json`, its signature and `install.sh` (a copy of `Relay/setup.sh`). Installed
  Beacons read the manifest from there and update themselves within 12 hours, so publishing is
  the deploy. Raise `version` in `Relay/Cargo.toml` first; a published version is never replaced.
- Two keys can sign a release: the release key and a recovery key
  (`~/.config/rexduo-recovery/helper-recovery.key`; keep it offline, away from the release key).
  Losing both means no installed Beacon accepts another update. To replace the release key, sign
  a release with either key and `NEXT_KEY=<new public key>`: Beacons that see it trust the new
  key from then on (Relay/README.md, Updates).
- **Turning the port share off everywhere.** `Relay/release.sh --resign --disable port_share
  --publish` signs the published list again with `"disabled": ["port_share"]` and uploads it;
  no file and no version changes, so nothing updates. Every Beacon from 0.7.0 on closes its
  shares and shares nothing from its next update check on (12.5 hours at most for one that
  is running and online), and refuses a new share within 10 minutes of the publish, since
  it looks at the list again before it makes one. `--enable port_share` turns it back on the same way. Run it first
  without `--publish` and read the list it wrote, then run the same command with
  `--publish`: every run starts from the published list again, whatever the run before
  left in `Relay/dist/release`. A release made while it is off keeps it off by
  itself: `release.sh` reads the published list first and carries over what it turns off
  (Relay/README.md, step 8, Turning it off).
- The manifest expires after 180 days (`EXPIRES_DAYS`). `Relay/release.sh --resign --publish`
  signs the current one again without building. An expired manifest stops updates and installs
  from the app, so re-sign before then: Beacon logs a line and a debug build of the app
  shows one in Settings when fewer than 30 days are left.

## Push gateway

```sh
Gateway/scripts/deploy.sh                    # database, migrations, the APNs key as a secret, the Worker
Gateway/scripts/smoke.sh <worker url>        # proves the path to Apple with a token no device has
```

The gateway runs on Cloudflare Workers (Workers Paid plan) with a D1 database. Its address is compiled
into the app (`PushGateway.defaultURL`), so it must not change. `deploy.sh` reads the APNs key from
`~/.appstoreconnect/private_keys/` and sends it only to Cloudflare's secret store. Details and
limits: `Gateway/README.md`.
