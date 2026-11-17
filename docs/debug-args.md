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
- `-typeTest 'text\n'`: type into the active pane once it is live. With `-scrollBackTest <seconds>`,
  scroll two pages back first and type that much later.
- `-tapTest col,row[;col,row…]`: tap those cells as a focused finger would, `-tapTestAfter` seconds
  after the pane is live (default 3), and log each result to `Documents/tapTest.txt`.
  `-tapTestType <text>` types after the last tap.
- `-ghosttyDemo <path>`: no server; replay a capture in a bare terminal view (`GhosttyDemoScreen`).
  `-replay <file>`: no server; feed a capture to a real pane (`ReplayScreen`, more arguments
  there). `-perfLog <name>`: measure the pane into `Documents/perf/<name>.json` (`PerfProbe`).
- `-selectionDemo <steps>`, `-selectionLoupe off`: docs/selection.md.
- `-simulateScan <payload>`: open "Pair via QR Code" at launch and read this payload as if the
  camera had (the simulator has no camera). `open` only opens the scanner. With `-settings
  addServer` it scans from that page, and `-simulateOffline <kind>` makes the check fail that way.
  `-simulateCamera denied` shows the scanner with camera access refused.
- `-pushToken <hex>`: use this APNs token and skip the permission check (push registration in a
  simulator).
- `-launchPeel fold`, `-launchSlow <factor>`, `-launchHold <seconds>`: the launch transition
  (`LaunchTransition.swift`).
