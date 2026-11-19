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
- `-wakeTest drop|unreachable`: as the app goes to the background, drop the control connection, as
  iOS does a suspended app's sockets on a device (a simulator keeps them). `drop` reconnects on
  the return, inside the wake's grace: no offline screen. `unreachable` fails every attempt from
  then on, so the offline screen shows when the grace runs out (`ForegroundWake`).
- `-simulateDuo <posture>[,<posture>…]`: lay the root out at that window size with its size classes,
  rough insets and a fake fold (red dashed line). Postures: `unfolded`, `book`, `unfoldedPortrait`,
  `tabletop`, `folded`, `foldedLandscape`, `halfWindow`, `iPhone`, `iPhoneLandscape`,
  `proMaxLandscape` (sizes in `DuoSimulation`, `State/Posture.swift`). A list cycles every
  `-simulateDuoEvery` seconds (default 10).
  In a Debug build every `terminal.resize` fit mode sends logs one `FIT_RESIZE <block> <cols>x<rows>`
  line, to count what a fold costs: `xcrun simctl spawn <id> log show --last 1m --predicate
  'eventMessage CONTAINS "FIT_RESIZE"'`. `-simulateDuo unfolded,book -simulateDuoEvery 0.2` flips
  faster than book mode settles and should log none.
- `-sidebar closed`: start with the sidebar hidden. `-focus none`: don't give the active pane the
  keyboard. `-settings main|addServer|darkTheme|lightTheme`: open Settings at that page.
- `-sidebarMode agents`: start the sidebar in Agents mode (overrides the saved mode for one run). `-sidebarCollapsed '("m:<server id>",
  "s:<server id>:<session id>")'`: fold those groups for this run (`SidebarCollapse` keys).
- `-sidebarFoldBench <cycles>`: 8 s after launch, fold and open every machine and session that many
  times, as a tap does, and log one `SIDEBAR_FOLD_BENCH` line (rows, frames, late frames, worst
  frame, and the worst frame of each fold and each open, sorted). `-sidebarFoldBenchScope session`
  folds only the biggest session; `-sidebarFoldBenchAnimate never` switches at once, for
  comparison. The saved fold state is put back.
  Read it with `xcrun simctl spawn <id> log show --last 2m --predicate 'eventMessage CONTAINS
  "SIDEBAR_FOLD_BENCH"'`; on a phone the line also goes to stdout, so `xcrun devicectl device
  process launch --console …` prints it. Numbers mean something only from an optimized build
  (`SWIFT_OPTIMIZATION_LEVEL=-O` on the Debug configuration).
- `-typeTest 'text\n'`: type into the active pane once it is live. With `-scrollBackTest <seconds>`,
  scroll two pages back first and type that much later.
- `-keyboardTest '<step>;<step>…'`: show and hide the software keyboard over the active pane once
  it is live (`Features/Terminal/KeyboardTest.swift`): `up`, `down`, `scroll:<points>`,
  `type:<text>`, `jump` (a tap on the jump-to-bottom button), `wait:<s>`. Each step logs the
  grid, the cover, the scroll position, the button's state, `jump=` and `unseen=`, and whether
  the terminal is first responder, `first=` (`KEYBOARD_TEST`). The simulator shows the software keyboard only with Connect Hardware
  Keyboard off.
- `-filesTest '<step>;<step>…'`: drive sending files and Open in the active pane once it is live
  (`Features/Files/FilesTest.swift` lists the steps): `keyboard`, `menu`, `reveal`,
  `send:<Mac path>|<Mac path>`, `sendOriginal:…`, `paste:<image path>`, `open:<text>`, `cancel`, `wait:<s>`.
  The files land on the pane's computer and their paths are typed, so use a `zz-` session.
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
- `-simulateHelperSetup <state>`: show the helper install sheet in that state, with no server and
  nothing running. States: `offer`, `preparing`, `download`, `verify`, `install`, `connecting`,
  `allow`, `password`, `password-wrong`, `password-computer`, `lost`, `connected`,
  `connected-allow`, `denied`, `manual`, `changed`, `error-release`, `error-timeout` and
  `error-<exit code>` (10 to 21, or any other number for "stopped"). `-simulateHelperSetupOS linux`
  makes the computer a Linux one; `-simulateHelperSetupKind repair` titles the sheet "Repairing".
  Use it with `-servers x`, which leaves the server list empty, so the app connects to nothing.
- `-simulateNotifications <name>`: show Settings → Notifications in that state, with no server
  and nothing registered; the controls do nothing. One name per row of the two tables in
  docs/notifications.md. The master switch: `master-off`, `master-not-asked`, `master-on`,
  `master-quiet`, `master-denied`, `master-no-address` (with two healthy computers where the
  switch lists them). A computer, listed first with a healthy one under it: `healthy`,
  `update-available` (the Beacon before the newest; the simulated release list says 0.3.1), `off`, `offline`, `turns-off` (turned off while it could not be
  reached), `not-installed`, `needs-manual`, `setting-up`,
  `waiting`, `setup-failed`, `too-old`, `not-running`, `connecting` (on, and its Beacon has not said its version yet), `reconnecting`, `reconnect-failed`,
  `changed`, `click-allow`, `limit` (the notification service asked for an hour's wait), `too-many` (it holds as many computers for this phone as it takes), `removing`, `remove-failed`, `updating`,
  and the results of a test, `test-sent` and `test-failed`. `all` lists one
  computer per state under made-up names (Studio, Laptop, Mini, …). `long-names` gives the
  longest lines a long computer name, to check how they wrap. `confirm-remove`,
  `confirm-trust`, `details` and `how` open the screen with that confirm or sheet up over the
  first computer; a row's menu has no name, because iOS opens a menu only for a touch. Use it
  with `-servers x -settings main`, and `-settingsScroll notifications` to bring the section
  into view: `-settingsScroll notifications.<n>` puts its n-th computer (from 0) at the top,
  and `-settingsScroll end` shows the end of the page, where a short section sits. A target
  that is already partly in view stays where it is.
- `-pushToken <hex>`: use this APNs token and skip the permission check (push registration in a
  simulator).
- `-pushGateway <url>`: register with another push gateway (https, or http on this machine).
- `-notificationsScript <steps>`: act on the first computer's row in Settings → Notifications as
  taps would, for runs against a real server: steps separated by commas, from `ready`, `off`,
  `on`, `flips:<n>`, `masterflips:<n>`, `test`, `remove`, `install`, `fix:<seconds>` (the row's one button), `sleep:<seconds>`. Each
  step writes the row to the log, category `notifications-script`
  (`State/NotificationsScript.swift`).
- `-helperReleaseMirror http://127.0.0.1:<port>`: read the helper's release list from a copy of
  the release folders served on this machine (the list is still checked against the built-in
  keys). `-autoHelperSetup install|repair`: start that on the first server to connect. With
  `-pushToken`, the install doesn't ask iOS for the notification permission.
- `-launchPeel fold`, `-launchSlow <factor>`, `-launchHold <seconds>`: the launch transition
  (`LaunchTransition.swift`).
