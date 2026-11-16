# Release

Device builds and TestFlight uploads run on macdesk, because signing needs its unlocked GUI
keychain. Run these only when asked: they install on a real phone or upload to App Store Connect.

- Bundle id `dev.abrahamgonzalez.rexduo` (kept from before the rename), team `R2PVQ496X7`,
  automatic signing. Display name "Rex Connect", product `RexConnect.app`.
- The build number is passed as `CURRENT_PROJECT_VERSION`; it must be higher than the last upload.
- The project is generated and macdesk has no XcodeGen, so every flow generates it locally and
  copies the result.

## Copying the tree to macdesk

`scripts/sync-macdesk.sh [-n] [remote-dir]` does the copy for both flows below. It checks the
Ghostty framework (`scripts/check-ghostty.sh`), runs `xcodegen generate` and rsyncs the tree to
`macdesk:~/rexconnect-build/` (or `remote-dir`). `-n` is a dry run.

- The copy uses `rsync --delete`, so the script refuses any `remote-dir` that is not a single
  folder name starting with `rexconnect-build` under macdesk's home.
- Keys never go across: `.asc.env` and other `.env` files, `Relay/dist` and `Relay/.stage` (both
  hold the APNs key), and any `*.p8`, `*.p12`, `*.pem`, `*.key`, `*.cer`, `*.mobileprovision` or
  `*.provisionprofile`.

- libghostty-vt is built on this Mac by `scripts/build-ghostty.sh` and copied; macdesk never
  builds it. The binary that ships is then the one the tests and benchmarks ran against, and
  macdesk needs no Zig, no Ghostty checkout and no network access to them. Building on macdesk
  would not make the binary reproducible either: `build-ghostty.sh` runs there (92 s cold), but
  two builds of the same pin differ byte for byte. `Vendor/GhosttyVt.stamp` travels with the
  framework and records the Ghostty commit, Zig version and patches it came from.
- From `Vendor/` only `GhosttyVt.xcframework` and `GhosttyVt.stamp` are sent, 51 MB once per
  rebuild; unchanged files are skipped. The copy works when `Vendor` is a symlink (agent worktrees).
- All three slices are sent although device builds link only `ios-arm64` (13 MB). Dropping the
  others would need a rewritten `Info.plist` in a second copy of the framework, to save 38 MB once
  per re-pin.
- `ship-macdesk.sh` and the app target's pre-build phase run the same check on macdesk, so a copy
  with a missing or stale framework fails with one line instead of a link error. The check also
  fails if `project.yml`'s iOS deployment target is below 17.4, which the framework needs.

## Install on the iPhone Duo

`scripts/install-duo.sh [build]` runs `sync-macdesk.sh`, builds Release for the Duo paired with
macdesk and installs it with `devicectl`. The build log is `macdesk:~/rexconnect-build/build.log`.

## TestFlight

```sh
scripts/sync-macdesk.sh
ssh macdesk "sudo launchctl asuser \$(id -u) sudo -u \$USER zsh -lc '~/rexconnect-build/scripts/ship-macdesk.sh <build>'"
```

`launchctl asuser` runs the script inside the GUI session; plain ssh can't reach the keychain.
`ship-macdesk.sh` archives, exports with `destination=upload` (set `DEST=export` to only export) and
logs to `macdesk:~/rexconnect-build/build/ship.log`. Builds appear in TestFlight 5–15 minutes later.

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
- Its objects carry DWARF, so `RexConnect.app.dSYM` covers it. Bitcode is not involved.
- No private system symbols: Zig's standard library called `__ulock_wait` and `__ulock_wake`,
  and `scripts/ghostty-patches/0001-tinyio-public-darwin-futex.patch` replaces them with the
  public `os_sync_wait_on_address` calls (iOS 17.4). `check-symbols.sh` guards it. No build with
  the patch has been uploaded yet, so Apple's own check has not seen it.
- Third-party licence notices ship in the bundle as `Acknowledgements.txt`.

`scripts/asc.mjs METHOD PATH [BODY]` makes signed App Store Connect API calls. It needs `ASC_ISS` in the environment (`source .asc.env`;
the file is gitignored) and reads the key `~/.appstoreconnect/private_keys/AuthKey_2M674J7J7N.p8`.

## Rex Connect Helper (Mac)

```sh
Relay/package.sh --no-notarize   # build universal, sign with Developer ID: a quick local check
Relay/package.sh                 # also notarize, staple and verify; writes Relay/dist/Rex Connect Helper.zip
```

The script builds `RexConnectHelper` for arm64 and x86_64, wraps it in a bundle with an icon made
from the iOS app icon, embeds the APNs key `AuthKey_5G2D4URHAC.p8`, signs with hardened runtime and
no entitlements, and notarizes with the App Store Connect key. The zip contains the APNs key: share
it only with trusted people, never commit it, and revoke the key if a copy leaks. Details are in
`Relay/README.md`.
