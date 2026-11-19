# Glance surfaces

What the app offers outside its own window. For now: two controls and the links they open the
app with. Widgets and a watch app come later and add their parts here.

## Controls

The extension `RexDuoWidgets` (bundle id `dev.abrahamgonzalez.rexduo.widgets`) declares two
controls for Control Center, the Lock Screen's bottom slots and the Action button
(`RexDuoWidgets/Controls.swift`):

| Control | Kind | Opens |
|---|---|---|
| Open Rex DUO | `dev.abrahamgonzalez.rexduo.control.open` | `rexduo://open` |
| Jump to Waiting | `dev.abrahamgonzalez.rexduo.control.waiting` | `rexduo://waiting` |

- Each is a `ControlWidgetButton` whose action is `OpenLinkIntent`
  (`RexDuoWidgets/OpenLinkIntent.swift`), an intent of our own with `openAppWhenRun`. The file
  is compiled into the extension and into the app: the system finds the intent in the
  extension and runs it in the app, which it brings forward first.
- In the app the intent does one thing: it opens the link's URL
  (`RexDuo/App/OpenLinkIntent+App.swift`). So a control takes the same single path into the app
  as any other link, `onOpenURL`, and nothing is injected into the intent.
- The intent is marked not discoverable, to stay out of Shortcuts and Spotlight.
- The extension links `GlanceModel` (for `DeepLink`) and nothing else of ours: no RexKit, no
  engine.
- Every word and symbol the controls show is in `ControlText`, at the top of `Controls.swift`.
- On a locked phone the system asks for the unlock before it opens the app.
- **Why not `OpenURLIntent` alone.** Checked on the iOS 27.2 simulator, by tapping the control
  in Control Center:

  | Action of the button | Result |
  |---|---|
  | `OpenURLIntent(rexduo://…)` itself | fails: `CHSErrorDomain 1107`, "Encountered action intent without linkAction" |
  | an intent in the extension only, returning `.result(opensIntent: OpenURLIntent(…))` | "succeeds"; the app never opens |
  | the same with `openAppWhenRun` | fails |
  | an intent in both targets with `openAppWhenRun`, returning `opensIntent: OpenURLIntent(…)` | the app opens; the URL never reaches `onOpenURL` |
  | an intent in both targets with `openAppWhenRun` that opens the URL itself (what ships) | the app opens and takes the link, from a cold launch too |

## Links

`DeepLink` (`Packages/RexGlance`, `GlanceModel`) is the one list of links, and the one parser.
The app registers the `rexduo` scheme (`CFBundleURLTypes`) and takes links in `onOpenURL`
(`RexDuoApp` → `AppModel.openLink`).

| URL | Effect |
|---|---|
| `rexduo://open` | The app comes forward. Nothing else changes: the tab, an open sheet and the agent board stay. |
| `rexduo://waiting` | `AppModel.openWaiting()`: opens the agent that has waited longest. |
| any other `rexduo:` URL | As `open`. |
| a URL of another scheme | Ignored. |

- Only an exact host with no path, user, password or port names a link. A query and a fragment
  are ignored; no link takes parameters.
- Any app or web page can fire a link, so a link only navigates. It never types, never resizes
  by itself, and never acts on a pane the app hasn't loaded.
- A link that arrives before the first screen is up waits in `AppModel` until
  `AppDelegate.attach` releases it, as a tapped push waits.

### Jump to Waiting

After a cold launch no server has said yet which agents wait, so the link can't decide at once
as the waiting pill does. `OpenWaiting` (`State/OpenWaiting.swift`) holds the rules as a pure
step, and `AppModel.openWaiting` feeds it every 0.1 s:

- **It waits** until every server either knows its agents' states or shows a connection
  problem, for at most 10 s. "Knows" is `ServerConnection.agentsCurrent`: a full read of the
  states has ended since the latest connect, resync or trip to the background, and
  `agentKeys` was brought up to date with it. `synced` is not
  enough, because it turns true when the tabs are in and the states are not.
- **Once one server knows of a waiting agent**, the others get 2 s more, then the jump goes
  without them.
- **It gives up only on the person's own move**: the tab on screen is neither the one that was
  there when the link arrived nor one `autoSelect()` put there since (`AppModel.autoSelected`).
  The launch landing on the last tab by itself doesn't cancel the jump; a tapped tab or a
  tapped push does.
- **Which agent.** The one waiting longest, by the time the phone first saw it waiting; ties go
  by server order, then by block order. Agents first seen after the link arrived all tie,
  because after a cold launch those times only say which server synced first. The pill, the
  keyboard shortcut and the magic tap keep their own order (`Waiting.all`), so just after a
  cold launch they can pick a different agent than the control does.
- **With nobody waiting, no servers, or the 10 s run out**, nothing happens: no notice and no
  haptic. The app is just open. (The pill's and the shortcut's "No agent is waiting for you."
  is unchanged.)
- A second `waiting` link replaces a wait that is still running.

### Effects on the computer

A `waiting` link that finds an agent has exactly the effects of a tapped push for that agent,
and no others:

- `session.focus_block` for the agent's pane and `session.focus_window` for its tab.
- When the pane shows, fit mode claims and resizes it, as for any tab the person opens.
- It sets `AppModel.openRequest`, so Settings, the pairing sheet, a Beacon install's cover and
  the agent board are put away, as a push tap puts them away. An install keeps running;
  Settings → Notifications shows its row again.

`open`, an unknown link and a `waiting` link that finds nobody send nothing to any server.

## Testing

- `xcrun simctl openurl <sim> rexduo://waiting` fires a link. A Debug build logs one
  `OPEN_LINK <link> run|queued` line for each link it takes and one `OPEN_WAITING <step>` line
  when a jump ends. `OPEN_LINK <link> refused` means a control's intent ran in the app and the
  system would not open its URL. Read them with `xcrun simctl spawn <sim> log show --last 1m --predicate 'eventMessage
  CONTAINS "OPEN_"'`.
- In a test launch (`-autoOpen <label>`) a link jumps only to agents in the session with that
  label, so a test can't open, focus or resize a pane in a real session.
- `simctl openurl` starts an app that isn't running **without** launch arguments, and a plain
  launch opens the last real tab. To test a cold launch from a link, first save the arguments
  in the simulator's own defaults, which the app reads like launch arguments:
  `xcrun simctl spawn <sim> defaults write dev.abrahamgonzalez.rexduo autoOpen zz-test` (and
  `servers`, `sizing` and the like the same way). Delete them, or the simulator, afterwards.
- The controls show in the simulator's Control Center (swipe down from the top right, "+",
  "Add a Control") and work there. The Lock Screen slots, the Action button and a locked phone
  need a device: try each control with the app not running, in the background, and with the
  phone locked.
