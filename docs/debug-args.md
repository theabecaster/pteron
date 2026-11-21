# Debug launch arguments

Pass them after the bundle id: `xcrun simctl launch <id> dev.abrahamgonzalez.rexduo -autoOpen zz-test`.
Each is a UserDefaults key for that run only. All but `-autoOpen` and `-sizing` work only in Debug
builds.

- `-autoOpen <session label>`: open that session's first tab. A label that doesn't exist opens nothing.
- `-sizing mirror`: keep the Mac's pane sizes instead of fitting panes to the phone.
- `-servers 'Name=https://…,Other=http://127.0.0.1:8765'`: use these servers instead of the saved
  ones. A missing `.ts.net` host, a closed port or a 403 shows the real offline screens.
- The first-run guide (architecture.md, First run) shows on a fresh install by itself; none of
  the test launches above shows it. `-onboardingDone NO` brings it back for one run on an install
  with no server that left it (Release too: it is the saved flag's key). `-guideStep
  tour|agents|connect|pairingCode` opens it at the first card, the second card, the checklist,
  or wherever "I Have a Pairing Code" leads (the scanner on a tailnet, else the checklist at its
  Tailscale step); `-guideComputer linux` picks Linux on the checklist; `-guideDemo YES` plays
  it through by itself (Get Started, Continue, Continue, Linux, Back, Skip, Not Now), for a
  recording. With `-simulateNetwork offPrivate` the Tailscale step shows unticked.
- `-simulateOffline <kind>`: every server shows that offline screen and none connects. Kinds:
  `noInternet`, `offPrivateNetwork`, `hostNotFound`, `notAnswering`, `notAllowed`, `insecure`,
  `updateServer`, `updateApp`, `badAddress`, `unknown`, `tunnelDown` (every computer silent
  together). `-simulateRetrying YES` holds Try Again in "Trying…".
- `-simulateNetwork offline|offPrivate|onPrivate`: pretend the phone has no path, is off the
  tailnet, or on it, so real errors classify as they would there. With `offPrivate`,
  `-simulateTailnetAfter <seconds>` has the phone join the tailnet that long after launch, as
  when Tailscale is turned on: the guide's pairing code then opens the scanner by itself, and a
  scanned code's Tailscale card offers Try Again.
- `-wakeTest drop|unreachable`: as the app goes to the background, drop the control connection, as
  iOS does a suspended app's sockets on a device (a simulator keeps them). `drop` reconnects on
  the return, inside the wake's grace: no offline screen. `unreachable` fails every attempt from
  then on, so the offline screen shows when the grace runs out (`ForegroundWake`).
- `-netDelay <ms>`: add a simulated round-trip time to every server's calls and terminal streams
  (`LinkDelay`, RexKit): half before each request leaves and half after its answer; three round
  trips before a new terminal data socket carries its first message (TCP, TLS 1.3 and the
  WebSocket upgrade, which is how the server's data sockets connect), then half per message
  either way. It delays without limiting: a burst stays a burst. Events, file transfers and
  tunnels are not delayed. Also in the benchmark's `BENCH` build.
- No argument: a Debug build logs one `CONTROL_API negotiated=<n> server=<n>` line for each
  control connection it makes, the API revision the server gave it and the newest the server
  speaks, and one `CONTROL_SYNC creators=read|kept` line for each full sync, which says whether
  that sync read `block_creator.list`: `xcrun simctl spawn <id> log show --last 1m --predicate
  'eventMessage CONTAINS "CONTROL_"'`.
- `-simulateDuo <posture>[,<posture>…]`: lay the root out at that window size with its size classes,
  its insets and a fake fold (red dashed line). A list cycles every `-simulateDuoEvery` seconds
  (default 10). The postures, each described once in `DuoSimulation.postures`
  (`State/Posture.swift`), with the window in points and the insets as top, leading, bottom,
  trailing:

  | Posture | Window | Insets | What it is |
  | --- | --- | --- | --- |
  | `unfolded` | 951×669 | 0, 0, 20, 84 | Inner screen, landscape, flat fold at 475.5 |
  | `book` | 951×669 | 0, 0, 20, 84 | The same, partly folded: a 40 pt fold from 455.5 |
  | `unfoldedPortrait` | 669×951 | 44, 0, 20, 0 | Inner screen, portrait, flat fold at 475.5 |
  | `tabletop` | 669×951 | 44, 0, 20, 0 | The same, partly folded: a 40 pt fold from 455.5 |
  | `folded` | 466×678 | 0, 0, 34, 84 | Outer screen, bar on the right |
  | `foldedLandscape` | 678×466 | 0, 0, 34, 84 | Outer screen on its side, bar on the right |
  | `foldedLandscapeBarLeft` | 678×466 | 0, 84, 34, 0 | Outer screen on its side the other way, bar on the left |
  | `halfWindow` | 475×669 | 0, 0, 20, 84 | Right half of the inner screen in Split View |
  | `halfWindowBarLeft` | 475×669 | 0, 84, 20, 0 | Left half of the inner screen in Split View, bar on the left |
  | `iPhone` | 402×874 | 62, 0, 34, 0 | iPhone, portrait |
  | `iPhoneLandscape` | 874×402 | 0, 62, 20, 62 | iPhone, landscape, Dynamic Island on either side |
  | `proMaxLandscape` | 956×440 | 0, 62, 21, 62 | iPhone Pro Max, landscape |

  - **The insets reach the sidebar and the tab.** The root is laid out inside them, so they
    pick the inline sidebar or the drawer (the outer screen on its side is 594 pt inside its
    bar: a drawer), and the sidebar and the tab get them as their safe area: panes, title bar
    and sidebar rows stay inside, backgrounds run under them to the window's edge. With the
    simulated keyboard up the bottom inset is gone, as under a real keyboard.
  - **Where the numbers come from.** Measured in the iOS 27.2 simulators as the window's
    `safeAreaInsets`: the outer screen (`folded`, `foldedLandscape`, `foldedLandscapeBarLeft`)
    on the iPhone Duo, 34 pt at the bottom; `foldedLandscapeBarLeft` with the interface in
    `landscapeRight` (`verticalBarEdge` is then leading; in `landscapeLeft` the same 84 pt are
    trailing). `iPhoneLandscape` on the iPhone 17, which reports the same insets in both
    landscape orientations, so the island's side changes nothing. `halfWindowBarLeft` is
    not measured, since the Duo simulator shows the outer screen only: it is `halfWindow` with
    the bar on the other side, the outer edge, where Apple puts it in Split View
    ([duo-layout.md](duo-layout.md)). The inner screen's insets, `iPhone` and `proMaxLandscape`
    are rough.
  - **Not simulated.** The vertical bar itself: `verticalBarEdge` comes from the real device,
    so the sidebar toggle and the tab's actions stay in the title bar and the inset is empty.
  - **Posture pixel matrix.** A change to layout is compared with its base in every posture
    above, each with the sidebar showing and with `-sidebar closed`, in a `zz-` session with
    `-focus none`. Run base, branch, base again: what differs between the two base runs is
    noise (the sidebar's pulsing status dots, the simulator's clock and home indicator).
    A new posture goes into this table and so into the matrix.
  In a Debug build every `terminal.resize` fit mode sends logs one `FIT_RESIZE <block> <cols>x<rows>`
  line, to count what a fold costs: `xcrun simctl spawn <id> log show --last 1m --predicate
  'eventMessage CONTAINS "FIT_RESIZE"'`. `-simulateDuo unfolded,book -simulateDuoEvery 0.2` flips
  faster than book mode settles and should log none. Each take before a resize logs
  `FIT_OWN <block>` (a claim moment: the pane came on screen, the app came back, tap to fit), a
  pane that finds another client has it logs `FIT_LOST <block> <why> server=<cols>x<rows>`
  (`resize`, `unapplied`, `owner`, `refused`, `guard`), and the one claim a pane makes when it
  finds itself at another grid with nothing claimed logs `FIT_GUARD`.
- `-simulateTent <degrees|off>[,<degrees|off>…]`: the hinge reports these angles instead of the
  real ones, one after the other every `-simulateTentEvery` seconds (default 10); `off` is no
  hinge. `-simulateTent 90` shows the agent board after the one-second hold;
  `-simulateTent off,90,17,10 -simulateTentEvery 3` goes in, stays in at 17° and leaves at 10°
  (`TentDetector`). With `-simulateDuo` the posture supplies the rest: `folded`,
  `foldedLandscape` and the iPhone postures go into tent, the postures with a fold never do, and
  neither does `halfWindow`, which doesn't fill its screen. `-simulateDuo folded,book` leaves
  tent by the fold. Entering and leaving must log no `FIT_RESIZE` line.
  `-boardReturnAfter <seconds>`: the board comes back that long after the last touch, instead
  of 60 s. `-hingeLog YES`: one `HINGE angle= status= division= fills= tent=` line (log category
  `hinge`) for each change of a degree or more, of the status, of the fold or of tent, to see on
  a device what the hinge reports: `xcrun simctl spawn <id> log show --last 1m --predicate
  'eventMessage CONTAINS "HINGE "'`.
- `-boardDemo <scenario>`: the agent board at launch, filled with made-up agents
  (`Features/Board/BoardDemo.swift`). The app uses no server in such a run, whatever is saved or
  passed with `-servers`, so nothing real is opened, and a tile's tap does nothing. Scenarios:
  `none` (no machines), `0` (a machine, no agents), `idle`, `1`, `3`, `6`, `12` (7 tiles and
  "+5 more"), `machines` (two machines and one not connected yet), `offline` (last known tiles,
  dimmed), `stale` (a quiet machine and one that is down with a waiting agent: the headline says
  "Reconnecting…", not "All quiet"), `states` (every state), `long` (long names, messages and places), `churn` (states
  that change every 0.3 s, for the once-a-second reorder). Use it with `-simulateDuo folded` or
  `foldedLandscape`, in Light and Dark Mode.
- Links: `xcrun simctl openurl <id> rexduo://waiting` (or `rexduo://open`, `rexduo://pair`,
  `rexduo://pane?…`) fires a control's or a widget's link.
  A Debug build logs `OPEN_LINK <link> run|queued` for each link, `OPEN_WAITING <step>` when a
  jump ends, `OPEN_PANE <step>` when a pane link ends, and `OPEN_LINK <link> refused` when a control's intent could not open its URL. With `-autoOpen <label>` a link jumps only to agents in that session. `openurl`
  starts a stopped app without launch arguments; [glance.md](glance.md), Testing, has the safe
  way to test a cold launch.
- `-glanceDemo <scenario>`: write a made-up snapshot for the widgets and reload them, once, when
  the app's scene shows (`GlanceDemo` in `Packages/RexGlance`). Scenarios: `quiet`, `working`,
  `error` (one error, nobody waiting), `one`, `several`, `many` (11 waiting: "+N more"),
  `machines`, `stale` (one of three machines down), `offline`, `aging` (ten minutes old), `old`
  (three hours old), `long` (more agents than the snapshot lists), `empty` (connected, no
  agent running), `unpaired`,
  `light-in-dark` (the light theme in both slots), `newer` (a file from a later, incompatible
  app), `none` (no file). Use it with `-autoOpen zz-none`, so the app opens nothing; it logs
  `GLANCE_DEMO <scenario>`. Without it, a test launch (`-servers`, `-boardDemo`, `-autoOpen`,
  `-simulateOffline`) writes no snapshot at all. The scenario also goes to a paired watch
  simulator that has the watch app. The watch app takes the same argument for its own file, and
  `-glanceDetail YES` to open on the first waiting agent (`later` opens it 2 s after launch),
  `-glanceDemoThen <scenario>` to replace the snapshot 4 s after launch, `-glanceDim YES`
  to draw as with the wrist down, and `-glanceScroll`, `-glanceAsk`, `-glanceOutcome` and
  `-glanceConfirm` for the actions ([glance.md](glance.md), The watch).
- `-glanceLive YES` with `-autoOpen <label>`: write the real snapshot in a test launch, with
  only the agents of the session with that label, so no other session's name reaches the file.
  A Debug build logs `GLANCE_WRITE seq=<n> bytes=<n>` for each write. The file is in the
  simulator's App Group container: `xcrun simctl get_app_container <id>
  dev.abrahamgonzalez.rexduo group.dev.abrahamgonzalez.rexduo`, then `glance/snapshot.json`.
- No argument: a Debug build logs `SCENE_VISIBLE servers=<n>` when it starts its servers, at the
  first scene phase that shows the app (docs/architecture.md, Launch).
- `-sidebar closed`: start with the sidebar hidden; `-sidebar open`: start with it shown, a drawer too. `-focus none`: don't give the active pane the
  keyboard. `-settings <page>`: open Settings at that page: `main` (the top level), `servers`,
  `appearance`, `keyboard`, `notifications`, `about`, or a page under one of them, `addServer`,
  `darkTheme`, `lightTheme` or `acknowledgements`, whose Back then leads to its parent.
- `-navigation tabs|sidebar`: use that navigation style for this run ([tab-mode.md](tab-mode.md)).
  It is the setting's own key (`Prefs.navigation`), so it works in Release too and needs no code:
  the argument stands in for the saved choice and leaves it as it was. A change in Settings
  during the run applies at once and is saved; the next launch with the argument starts from the
  argument again.
- `-sidebarMode agents`: start the sidebar in Agents mode (overrides the saved mode for one run). `-sidebarCollapsed '("m:<server id>",
  "s:<server id>:<session id>")'`: fold those groups for this run (`SidebarCollapse` keys).
- `-showAgents YES`: open the Agents sheet at launch (`AgentsSheet`, the Agents list for a layout
  without the sidebar).
- `-showPorts YES`: the first machine's ports button in the sidebar opens its popover as soon as
  it shows, once (`PortsList`).
- `-renderCount YES`: log one `RENDER_COUNT` line every 5 s with how often the sidebar's bodies
  ran since launch (`sessionLists`, `tabRows`, `tabRowLabels`, `statusLeaves`, `portButtons` for the machines' ports buttons and `portRows` for the rows of their lists), how many
  progress values were written (`progressWrites`), how often the tab screen and the pane
  menu's Arrange ran (`windowScreens`, `paneMenuItems`), and how often the tab strip and its
  chips ran (`tabStrips`, `tabChips`), to check that progress reports re-render
  only the status leaf and that an agent's spinning title re-renders neither: `xcrun simctl spawn <id> log show --last 1m --predicate 'eventMessage CONTAINS
  "RENDER_COUNT"'`.
- `-sidebarFoldBench <cycles>`: 8 s after launch, fold and open every machine and session that many
  times, as a tap does, and log one `SIDEBAR_FOLD_BENCH` line (rows, frames, late frames, worst
  frame, and the worst frame of each fold and each open, sorted). `-sidebarFoldBenchScope session`
  folds only the biggest session; `-sidebarFoldBenchAnimate never` switches at once, for
  comparison. The saved fold state is put back.
  Read it with `xcrun simctl spawn <id> log show --last 2m --predicate 'eventMessage CONTAINS
  "SIDEBAR_FOLD_BENCH"'`; on a phone the line also goes to stdout, so `xcrun devicectl device
  process launch --console …` prints it. Numbers mean something only from an optimized build
  (`SWIFT_OPTIMIZATION_LEVEL=-O` on the Debug configuration).
- `-findScript '<step>;<step>…'`: drive find over the active pane once it is live and log each
  step with the keyboard notifications it caused (`FIND_SCRIPT`, also on stdout for
  `devicectl … --console`): `up`, `hw`, `down`, `resign`, `open`, `menu`, `type:<text>`, `esc`,
  `focus`, `done`, `next`, `prev`, `tap`, `gate`, `wait:<s>` (`Features/Terminal/Find/FindScript.swift`).
  `-findScriptEvery <s>` spaces the steps. `-findHandover spacer` tries the fallback hand-over,
  `-findHandover nil` spike S1's rejected variant, `-findCarriesCommands YES` the field carrying
  app commands itself. Use a `zz-` session.
- `-typeTest 'text\n'`: type into the active pane once it is live. With `-scrollBackTest <seconds>`,
  scroll two pages back first and type that much later.
- `-keyboardTest '<step>;<step>…'`: show and hide the software keyboard over the active pane once
  it is live (`Features/Terminal/KeyboardTest.swift`): `up`, `down`, `scroll:<points>`,
  `drag:<points>` (a drag let go there, which ends at the pin within a row of it), `type:<text>`, `jump` (a tap on the jump-to-bottom button), `wait:<s>`. Each step logs the
  grid, the cover, the scroll position (`y=<offset>/<offset at the pin>` in points), the button's state, `jump=` and `unseen=`, and whether
  the terminal is first responder, `first=` (`KEYBOARD_TEST`). A second line per step gives, on
  screen, the keyboard's last reported end frame `kb=x,y,wxh` (`null` before any report), the key
  bar's frame `bar=` (`none` out of a window), the pane's bottom `paneBottom=` (at or above the
  bar's top while the keyboard is up) and the input mode's language `mode=`. The simulator shows the software keyboard only with Connect Hardware
  Keyboard off.
- `-filesTest '<step>;<step>…'`: drive sending files and Open in the active pane once it is live
  (`Features/Files/FilesTest.swift` lists the steps): `keyboard`, `menu`, `reveal`,
  `send:<Mac path>|<Mac path>`, `sendAsIs:…`, `paste:<image path>`, `open:<text>`, `cancel`, `wait:<s>`.
  The files land on the pane's computer and their paths are typed, so use a `zz-` session.
  The file browser: `browse`, `insert`, `browseAt:<path>` open it; then `go:<path>`,
  `enter:<name>`, `up`, `filter:<text>`, `hidden`, `tap:<name>`, `insertPath:<name>`,
  `insertHere`, `share:<name>`, `save:<name>`, `select:<n>`, `refresh`, `done`.
  `run:<action>` runs `pane.go_to_directory`, `pane.insert_path`, `pane.insert_file` or
  `pane.insert_photo` as a bound key does, and `lose:<method>` records that the pane's host
  lacks `list_dir`, `upload_begin` or `download_begin`. The browser lists the folder the
  session's shell is in, and inserts type into that shell: start the `zz-` session in a folder
  made for the test (`rex new zz-test -c <folder>`).
- `-filesListDelay <seconds>`: every listing of the file browser waits that long first, to see
  it while it loads.
- `-shareTest '<step>;<step>…'`: drive sharing in the active pane once it is live
  (`Features/Files/ShareTest.swift` lists the steps): `screen`, `styledScreen`, `all`, `styledAll`
  (each with `:bar:leading` or `:bar:trailing` to point at that edge), `selection`, `cancel`,
  `dismiss`, `wait:<s>`. Each sheet logs `SHARE_ITEM <text|file> <bytes> <path>`.
- `-goTo anything|sessions|commands`: open the palette two seconds after the first tab shows,
  as its key would; `-goToQuery <text>` types that text into it half a second later
  (`Features/GoTo/GoToDebug.swift`); `-goToRun <seconds>` runs the selected row that long after it opened, as Return does (with a
  `zz-` session only: the row acts on the pane); `-goToClose <seconds>` closes it again that long after it
  opened, as Esc does. Use them with `-autoOpen zz-…` for a screenshot or a no-resize check.
- `-panesTest '<step>;<step>…'`: run Arrange's commands on the tab on screen, two seconds apart,
  through the same paths as the menu and the keys (`Features/Tab/PanesTest.swift`): `swap`,
  `moveTo:<n>`, `newTab`, `balance`, `closeOthers` (confirmed), `tab:+1`, `tab:-1`, `dragTab:<gap>`,
  `dragSession:<gap>`, `wait:<s>`, and for floating windows `tapFloat:<n>` (a tap on the first
  pane of the n-th drawn float from the back, from 1), `minimize`, `minimizeAll` and `restore`
  (the first minimized float's row), and for a narrow window's float sheet `sheet:large`,
  `sheet:medium`, `sheet:hide` (back to the tab), `sheet:next`, `sheet:prev` (a swipe on the
  grabber) and `sheet:show<n>` (the n-th float from the front in the floats' menu). After each it logs `PANES_STATE` with the session's tabs,
  their panes, split ratios and floating layers, the tab shown, the pane shown and the sheet's
  float and size (`sheet=<layer>/<size>`); a float tap
  logs `FLOATS_TAP` with what it sent. Only in a `zz-` session you made.
- `-portsTest '<step>;<step>…'`: drive ports in the active pane once it is live
  (`Features/Ports/PortsTest.swift` lists the steps): `list`, `menu:<port>`, `link:<url>`,
  `yes:<url>`, `no:<url>`, `fetch:<path>`, `parallel:<n>`, `done`, `wait:<s>`. It logs
  `PORTS_LIST`, `PORTS_ROUTE`, `PORTS_FETCH`, and the forward logs `PORTS_LISTEN`,
  `PORTS_NEW_BLOCK`, `PORTS_CONN <end>`, `PORTS_CLOSE`, `PORTS_SWEEP`. It makes a tunnel block, so
  use a `zz-` session with a test server started in it. The steps of a ports row, for a port in
  any tab of that session: `process` (one `terminal.process` read, `PORTS_PROCESS`), `watch`
  (each change of the pane's ports and foreground from then on, `PORTS_EVENT`), `owner:<port>`
  and `row:<port>` (what the app holds of the port's process and what the row offers,
  `PORTS_ROW`), `ask:port_owner:<port>` and `ask:port_share:<port>` (the Beacon's own answer to
  an app it doesn't hold, `PORTS_ASK_BEACON`), `browser:<port>`, `stop:<port>`,
  `restart:<port>`, `confirm:<port>` and `cancel:<port>` (`PORTS_BROWSER`, `PORTS_STOP`,
  `PORTS_RESTART`).
- `-portsOwner <hex of a port_owner answer's JSON>` with `-portsTest`: answer `port_owner` with
  that object in the Beacon's place and say the Beacon can hand pages out. A simulator is no
  registered phone, so a real Beacon tells it nothing about a process; this gives a row its
  Stop through a wrapper and its Restart there. Only with facts read from the processes of
  your own `zz-` session.
- `-portsLoop <n>`: no computer needed. Open the browser `n` times on a page the app serves to
  itself on 127.0.0.1, as fast as each page loads, closing it each time (`PortsLoop`). It logs
  `PORTS_LOOP opens=<k> footprint=<MB>` after 5 opens, after 30 and after the last, then
  `PORTS_LOOP done growth=<MB>` (the last less the one after 30), and writes
  `Documents/perf/portsLoop.json`. In some runs the app's memory rises by about 5 MB over the
  first 25 or so opens and is level after, so every open from the 30th on must cost nothing:
  `scripts/bench/ports-loop.sh <sim-id>` runs 100 and fails when they end more than 1 MB over
  30. `-portsLoopHold <seconds>` keeps each page up that long, for a
  screenshot (`-portsLoop 1 -portsLoopHold 10`), and `-portsLoopLandscape YES` turns the iPhone
  on its side first. `-portsLoopBare YES` opens a sheet with only a `WKWebView` in place of the
  browser (the script's `--bare`), and `-portsLoopReadHold <seconds>` waits after each reading,
  with `Documents/perf/portsLoop-at-<k>` written first, for a memory tool to look. The script
  also prints the last reading less the one after 5, which fails nothing. Use it with `-autoOpen zz-none -sizing mirror`, so no pane is touched.
  Also in the benchmark's `BENCH` build.
- `-forceStatus '<text>'`: every pane shows its status chip with this text once it opens and each
  time it is live, to look at the chip over any output. With `-replay <file>` it needs no server.
- `-tapTest col,row[;col,row…]`: tap those cells as a focused finger would, `-tapTestAfter` seconds
  after the pane is live (default 3), and log each result to `Documents/tapTest.txt`.
  `-tapTestType <text>` types after the last tap.
- `-ghosttyDemo <path>`: no server; replay a capture in a bare terminal view (`GhosttyDemoScreen`).
  `-replay <file>`: no server; feed a capture to a real pane (`ReplayScreen`, more arguments
  there). `-perfLog <name>`: measure the pane into `Documents/perf/<name>.json` (`PerfProbe`);
  with it, `-perfIdle <seconds>` and `-perfScroll <seconds>` add an idle phase and a scripted
  fling through the scrollback. `-perfSwitch <n>` switches between the panes of the tab on
  screen n times, forward and back, as a swipe does, `-perfSwitchEvery <seconds>` apart (default
  1.5), and the result's `mounts` holds every pane mount (cold, parked or resumed) with its time
  to the first frame and to the current screen; with `-autoOpen zz-…` only, since fit mode
  claims the panes. `-perfSwitchType <text>` types the text into each pane as it comes back from
  the park and records when the server answered the write; `-perfSwitchWalk YES` goes back for
  the first half of the switches and forward for the second, which in a tab of n / 2 + 1 panes
  ends on the last one with all the others visited. `-findTest <needle>` opens find on the replay's pane before the
  first byte, and `-findSteps <n>` then steps n matches 100 ms apart after the replay (a `find`
  phase). `-perfClean YES` deletes `Documents/perf` and `Documents/bench`
  and quits. `-peelLeadIn <seconds>` and `-drawables 2` are A/B switches for the device
  benchmark. All of these also work in the benchmark's `BENCH` Release build.
- `-echoTest <name>`: key-to-echo on the active pane once it is live (`EchoProbe`, also in the
  `BENCH` build). It types `-echoKeys` distinct letters (default 30) `-echoEvery` seconds apart
  (default 0.4) through the software keyboard's path, after `-echoStart` seconds (default 3),
  then clears the line with Control-U and writes `Documents/perf/<name>.json`: for each key the
  time to the server's answer to its write, to the output that echoes it, and to the first frame
  that shows it, with medians and p95. `-echoWalk YES` first goes back two panes and forward
  two, as `-perfSwitchWalk` does, which leaves two panes warm, and waits `-echoAfterWalk`
  seconds (default 3). It types into a real shell: use `-autoOpen zz-…`. Unlike `-typeTest`,
  which sends its text in one write, every key is a keypress of its own.
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
  with `-servers x -settings notifications`. `-settingsScroll` scrolls that page, and with
  `-settings main` opens it: `-settingsScroll notifications` shows the master switch at the top,
  `-settingsScroll notifications.<n>` puts its n-th computer (from 0) at the top, and
  `-settingsScroll end` shows the end of the page, the last computer at the bottom. A target
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
