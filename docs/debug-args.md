# Debug launch arguments

Pass them after the bundle id: `xcrun simctl launch <id> dev.abrahamgonzalez.rexduo -autoOpen zz-test`.
Each is a UserDefaults key for that run only. All but `-autoOpen` and `-sizing` work only in Debug
builds.

- `-autoOpen <session label>`: open that session's first tab. A label that doesn't exist opens nothing.
- `-sizing mirror`: keep the Mac's pane sizes instead of fitting panes to the phone.
- `-servers 'Name=https://…,Other=http://127.0.0.1:8765'`: use these servers instead of the saved
  ones. A missing `.ts.net` host, a closed port or a 403 shows the real offline screens.
- `-simulateOffline <kind>`: every server shows that offline screen and none connects. Kinds:
  `noInternet`, `offPrivateNetwork`, `hostNotFound`, `notAnswering`, `notAllowed`, `insecure`,
  `badAddress`, `unknown`. `-simulateRetrying YES` holds Try Again in "Trying…".
- `-simulateNetwork offline|offPrivate|onPrivate`: pretend the phone has no path, is off the
  tailnet, or on it, so real errors classify as they would there.
- `-simulateDuo <posture>[,<posture>…]`: lay the root out at that window size with its size classes,
  rough insets and a fake fold (red dashed line). Postures: `unfolded`, `book`, `unfoldedPortrait`,
  `tabletop`, `folded`, `foldedLandscape`, `halfWindow`, `iPhone`, `iPhoneLandscape`,
  `proMaxLandscape` (sizes in `DuoSimulation`, `State/Posture.swift`). A list cycles every
  `-simulateDuoEvery` seconds (default 10).
- `-sidebar closed`: start with the sidebar hidden. `-focus none`: don't give the active pane the
  keyboard. `-settings main|addServer|darkTheme|lightTheme`: open Settings at that page.
- `-sidebarMode agents`: start the sidebar in Agents mode (overrides the saved mode for one run). `-sidebarCollapsed '("m:<server id>",
  "s:<server id>:<session id>")'`: fold those groups for this run (`SidebarCollapse` keys).
- `-sidebarFoldBench <cycles>`: 8 s after launch, fold and open every machine and session that many
  times, as a tap does, and log one `SIDEBAR_FOLD_BENCH` line (rows, frames, late frames, worst
  frame). `-sidebarFoldBenchScope session` folds only the biggest session;
  `-sidebarFoldBenchAnimate never` switches at once, for comparison. The saved fold state is put
  back.
  Read it with `xcrun simctl spawn <id> log show --last 2m --predicate 'eventMessage CONTAINS
  "SIDEBAR_FOLD_BENCH"'`. Numbers mean something only from an optimized build
  (`SWIFT_OPTIMIZATION_LEVEL=-O` on the Debug configuration).
- `-typeTest 'text\n'`: type into the active pane once it is live. With `-scrollBackTest <seconds>`,
  scroll two pages back first and type that much later.
- `-tapTest col,row[;col,row…]`: tap those cells as a focused finger would, `-tapTestAfter` seconds
  after the pane is live (default 3), and log each result to `Documents/tapTest.txt`.
  `-tapTestType <text>` types after the last tap.
- `-ghosttyDemo <path>`: no server; replay a capture in a bare terminal view (`GhosttyDemoScreen`).
  `-replay <file>`: no server; feed a capture to a real pane (`ReplayScreen`, more arguments
  there). `-perfLog <name>`: measure the pane into `Documents/perf/<name>.json` (`PerfProbe`);
  with it, `-perfIdle <seconds>` and `-perfScroll <seconds>` add an idle phase and a scripted
  fling through the scrollback. `-perfClean YES` deletes `Documents/perf` and `Documents/bench`
  and quits. `-peelLeadIn <seconds>` and `-drawables 2` are A/B switches for the device
  benchmark. All of these also work in the benchmark's `BENCH` Release build.
- `-selectionDemo <steps>`, `-selectionLoupe off`: docs/selection.md.
- `-simulateScan <payload>`: open "Pair via QR Code" at launch and read this payload as if the
  camera had (the simulator has no camera). `open` only opens the scanner. With `-settings
  addServer` it scans from that page, and `-simulateOffline <kind>` makes the check fail that way.
  `-simulateCamera denied|restricted|unavailable` shows the scanner in that camera state.
  `-simulateIdentity 'os=linux,account=sam,owner=sam@x.com,viewer=me@x.com,sessions=api|web,count=5,helper=no'`
  gives a scanned code that identity card with no network. `-pairHost <https address>` opens the
  flow at that address, as a tap on a known computer does.
- `-pushToken <hex>`: use this APNs token and skip the permission check (push registration in a
  simulator).
- `-launchPeel fold`, `-launchSlow <factor>`, `-launchHold <seconds>`: the launch transition
  (`LaunchTransition.swift`).
