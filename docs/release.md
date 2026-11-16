# Release

Device builds and TestFlight uploads run on macdesk, because signing needs its unlocked GUI
keychain. Run these only when asked: they install on a real phone or upload to App Store Connect.

- Bundle id `dev.abrahamgonzalez.rexduo` (kept from before the rename), team `R2PVQ496X7`,
  automatic signing. Display name "Rex Connect", product `RexConnect.app`.
- The build number is passed as `CURRENT_PROJECT_VERSION`; it must be higher than the last upload.
- The project is generated, so every flow runs `xcodegen generate` locally and copies the result.

## Install on the iPhone Duo

`scripts/install-duo.sh [build]` generates the project, rsyncs the tree to
`macdesk:~/rexconnect-build/`, builds Release for the Duo paired there and installs it with
`devicectl`. The build log is `macdesk:~/rexconnect-build/build.log`.

## TestFlight

```sh
xcodegen generate
rsync -a --delete --exclude .claude --exclude build --exclude .build --exclude .git --exclude .asc.env \
  ./ macdesk:rexconnect-build/
ssh macdesk "sudo launchctl asuser \$(id -u) sudo -u \$USER zsh -lc '~/rexconnect-build/scripts/ship-macdesk.sh <build>'"
```

`launchctl asuser` runs the script inside the GUI session; plain ssh can't reach the keychain.
`ship-macdesk.sh` archives, exports with `destination=upload` (set `DEST=export` to only export) and
logs to `macdesk:~/rexconnect-build/build/ship.log`. Builds appear in TestFlight 5–15 minutes later.

`scripts/asc.mjs METHOD PATH [BODY]` makes signed App Store Connect API calls. It needs `ASC_ISS` in the environment (`source .asc.env`;
the file is gitignored) and reads the key `~/.appstoreconnect/private_keys/AuthKey_2M674J7J7N.p8`.

## Rex Connect Helper (Mac and Linux)

```sh
Relay/package.sh --no-notarize   # Mac app signed with Developer ID, plus Linux binaries: a quick local check
Relay/package.sh                 # also notarize, staple and verify
```

Output in `Relay/dist`: `Rex Connect Helper.zip` (universal Rust binary in a bundle with an icon
made from the iOS app icon, hardened runtime, no entitlements, notarized with the App Store Connect
key) and static `rex-connect-helper-linux-x86_64` / `-aarch64` (cross-compiled with
`cargo zigbuild`; set `ZIG` if zig isn't on PATH). `build.rs` embeds the APNs key
`AuthKey_5G2D4URHAC.p8` in every binary: share them only with trusted people, never commit them,
and revoke the key if a copy leaks. Details are in `Relay/README.md`.
