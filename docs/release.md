# Release

Device builds and TestFlight uploads run on a build Mac over ssh, because signing needs its unlocked
GUI keychain. Run these only when asked: they install on a real phone or upload to App Store Connect.

The scripts default to the maintainer's setup. Point them at yours with `REXDUO_BUILD_HOST` (the
build Mac's ssh host), `REXDUO_DEVICE` (the phone's UDID), and `ASC_KEY_ID` and `ASC_KEY` (the App
Store Connect key). The scripts' file names still say `macdesk`; any build Mac works.

- Bundle id `dev.abrahamgonzalez.rexduo` (fixed: App Store Connect and the APNs topic depend on
  it), team `R2PVQ496X7`, automatic signing. Display name "Rex DUO" (`CFBundleDisplayName`),
  product `RexDuo.app`.
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

## TestFlight

```sh
scripts/sync-macdesk.sh
ssh <build host> "sudo launchctl asuser \$(id -u) sudo -u \$USER zsh -lc '~/rexduo-build/scripts/ship-macdesk.sh <build>'"
```

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
- Its objects carry DWARF, so `RexDuo.app.dSYM` covers it. Bitcode is not involved.
- No private system symbols: Zig's standard library called `__ulock_wait` and `__ulock_wake`,
  and `scripts/ghostty-patches/0001-tinyio-public-darwin-futex.patch` replaces them with the
  public `os_sync_wait_on_address` calls (iOS 17.4). `check-symbols.sh` guards it. No build with
  the patch has been uploaded yet, so Apple's own check has not seen it.
- Third-party licence notices ship in the bundle as `Acknowledgements.txt`.

The app embeds one extension, `RexDuoWidgets.appex` (the controls; [glance.md](glance.md)), with
its own App ID, `dev.abrahamgonzalez.rexduo.widgets`. It needs no capability and no App Group.
Automatic signing with `-allowProvisioningUpdates` registers the App ID and makes its profile at
the first device build or archive, if the signing account may; otherwise register the identifier
in the developer portal first. No device build or archive with the extension has been made yet.
The build number given on the command line applies to the extension too, which App Store Connect
requires to match the app's.

`scripts/asc.mjs METHOD PATH [BODY]` makes signed App Store Connect API calls. It needs `ASC_ISS` in the environment (`source .asc.env`;
the file is gitignored) and reads the key from `~/.appstoreconnect/private_keys/` (`ASC_KEY_ID` picks it).

## Rex DUO Beacon (Mac and Linux)

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
- The Mac app goes out in two zips made from the one notarized bundle: `Rex-DUO-Beacon.zip`
  holds it as `Rex DUO Beacon.app` (the manifest's `macos-universal-beacon` entry) and
  `Rex-DUO-Helper.zip` as `Rex DUO Helper.app`, the app's earlier name (the `macos-universal`
  entry, which the updater of version 0.3.0 reads). `release.sh` checks that both hold the same
  app and that the manifest names both (Relay/README.md, Updates).
- The Mac's background job is the LaunchAgent `dev.abrahamgonzalez.rexduo.beacon`. A Mac that
  version 0.3.0 updates gets the new version in `Rex DUO Helper.app`, restarted under the
  earlier label, `dev.abrahamgonzalez.rexduo.helper`. That Beacon then moves the app to its name
  and the job to its label in one sequence with one restart: the bundle is renamed, Launch
  Services is told, the new label's file is written, the earlier job is booted out and the new
  one loaded, and the earlier file is deleted once Beacon reports in under the new label
  (docs/helper.md, Mac). In System Settings → Login Items an entry named Rex DUO Beacon
  appears, and the earlier entries go about 70 seconds later. The bundle identifier, the code
  signature's identifier, the update job's label (`dev.abrahamgonzalez.rexduo.helper.update`),
  the state folder and the log keep their names, so a release needs no other change for this.
- `--publish` creates the release `helper-v<version>` with the downloads, then updates the release
  `helper-latest`, which holds only `manifest.json`, its signature and `install.sh` (a copy of `Relay/setup.sh`). Installed
  Beacons read the manifest from there and update themselves within 12 hours, so publishing is
  the deploy. Raise `version` in `Relay/Cargo.toml` first; a published version is never replaced.
- Two keys can sign a release: the release key and a recovery key
  (`~/.config/rexduo-recovery/helper-recovery.key`; keep it offline, away from the release key).
  Losing both means no installed Beacon accepts another update. To replace the release key, sign
  a release with either key and `NEXT_KEY=<new public key>`: Beacons that see it trust the new
  key from then on (Relay/README.md, Updates).
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
