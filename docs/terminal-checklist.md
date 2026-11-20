# Terminal regression checklist

What the terminal must do, row by row, and how each row is checked. Run the tests after a change
to the terminal; run the two manual scripts at the end on a device before a release that touched
gestures, input, selection or rendering.

Add a row when the terminal gains a behaviour, with the test that pins it. How the engine is
built: [ghostty-engine.md](ghostty-engine.md). The stream and input rules:
[terminal.md](terminal.md). Selection: [selection.md](selection.md).

How a row is verified:

- a test name: an XCTest or Swift Testing test in `RexDuoTests` (runs in the simulator), or
  in RexKit where it says so.
- **live**: run in the simulator in a throwaway `zz-` session, checked with screenshots and
  `rex capture` of that pane.
- **hand**: needs touches, a hardware keyboard or a device. Touches can't be injected with this
  Xcode, so these rows are only as good as the last run of the manual scripts.

## Table

| # | Item | Verified by | What must hold |
| --- | --- | --- | --- |
| 1 | Feed, snapshot restore | `GhosttyCoreTests`, RexKit `Stream*` tests, live | The pane restores Rex's snapshot: the screen, the scrollback and the prompt are the server's (live: `seq 1 300` and a prompt). A snapshot that can't be restored falls back to `terminal.format` (row 49). |
| 2 | Resize and reflow | `GhosttyCoreTests`, live (fold cycle against `rex capture`) | The terminal reflows locally the way the server does, so a new width needs no redraw from the server. After folded → unfolded → folded the local screen matches `rex capture` line for line. See "Reflow" below for where it can differ. |
| 3 | Fit grid (cell size) | `GhosttyViewTests.testFitGridFollowsTheFontAtEveryFontSize` | At every font size from 7 to 20 pt in 0.5 steps a cell is the font's advance wide and its line height tall, both in whole device pixels. The height is never more than the line height rounded up to a whole point and less than a point under it, so a pane fits up to about 10% more rows than whole-point rows would, never fewer. The Mac's pane is resized to that grid. |
| 4 | System keyboard text | `GhosttyInputViewTests.testTypedTextIsSentAsItsBytesInEveryMode`, `testRawSendsGoOutUnchanged`, live (`-typeTest`) | Typed text goes out as its bytes in normal, DECCKM, DECBKM and bracketed-paste modes; a line feed is Return; DECBKM changes Backspace. Under the Kitty protocol the key is named. |
| 5 | Key bar keys and trackpad | `GhosttyInputViewTests.testCursorKeysInBothCursorModes`, `testRawSendsGoOutUnchanged` | The bar encodes its own bytes; arrows, Home and End follow DECCKM. |
| 6 | Key bar ctrl / alt, one shot and locked, with characters | `GhosttyInputViewTests.testOneShotControlSendsTheControlCharacter`, `testOneShotMetaSendsEscapeThenTheText`, `testOneShotModifiersClearAndNotify` | Includes Ctrl+I, Ctrl+M and Ctrl+[ as Tab, Return and Escape in legacy mode. |
| 7 | Key bar ctrl / alt with Backspace, Return, Tab | `GhosttyViewTests.testOneShotControlWithReturnOrTabSendsThePlainKeyInLegacyMode`, `testOneShotModifiersApplyToBackspaceAndReturn` | Alt+Backspace sends `ESC DEL` (delete a word) and uses up the flag. Ctrl+Backspace sends `0x08`, as Ghostty does. Ctrl+Alt+letter applies both. Ctrl+Return and Ctrl+Tab send the plain key in legacy mode (never `CSI 27;5;13~`, which a shell prints). |
| 7a | Key bar cmd: the next key runs its Rex shortcut and is never typed | `KeyBarCommandTests`, `KeyBarPressTests`; hand | Once and locked; system keyboard characters (shift as the US key needs it) and bar keys; ctrl/alt with cmd make one chord; an unbound chord sends nothing and plays the error haptic. The haptic and a finger on the cap: hand. |
| 7b | Key bar Return: pinned, held for Shift-Return | `KeyBarCommandTests` (the pinned Return tests), `PrefsTests.pinnedKeysLeftTheScrollingKeysInOrder`, `PinnedAttachKeyTests` (attach pinned before Return, off the crease); hand | Once per bar, outside the scroll view; ctrl, alt and cmd as before; held: `CSI 27;2;13~` or `CSI 13;2u`, or `shift+cmd+enter` with cmd; commits a composition instead of sending; nothing under the agent board. The hold's timing and haptic need a finger: hand. |
| 8 | Hardware keyboard | `GhosttyInputKeyTests`, `GhosttyInputViewTests.testHardwareKeysAreEncodedOrLeftToTheTextSystem`, `testHeldKeyRepeatsUntilReleased`; hand | Tests drive `hardwareKeyDown` with `UIKey`'s properties, since a `UIKey` can't be made. Real presses, layouts, dead keys and key repeat need a keyboard. With one-shot ctrl from the key bar a hardware function key takes the modifier. |
| 9 | Keymap bindings (`keyHook`), ⌘ commands | hand | The hook sees each press before the terminal does (`pressesBegan` asks it first). |
| 9a | Hardware keyboard: no system focus halo on a pane | `KeyboardFocusPolicyTests.panesStayOutOfTheSystemFocus`; live (iPad simulator, real key events: Tab and arrows with and without a focused terminal, screenshots) | The terminal view can't become focused and draws no focus effect. iPhone has no focus system at all (`UIFocusSystem.focusSystem(for:)` is nil) unless Full Keyboard Access is on; that ring is the system's and is left alone. |
| 9b | Hardware keyboard: arrows, Tab, Enter, Escape reach the program | `GhosttyInputViewTests.testHardwareKeysAreEncodedOrLeftToTheTextSystem`; live (real key events: arrows and Tab reached `pressesBegan` and the shell) | True whenever the terminal is first responder, which `KeyboardFocusPolicy` keeps it with a hardware keyboard. |
| 9c | Hardware keyboard: a pane switch moves the keyboard | `KeyboardFocusPolicyTests`; live (⌥⌘←, ⌘], ⌘[ in splits and one pane at a time: the next key typed landed in the new pane, checked with `rex capture`) | Also across a fold or unfold (the pool moves the host, UIKit takes the keyboard, the host takes it back), after Settings, and back from the background. |
| 9d | ⌘/ toggles the sidebar in each posture | `ToggleSidebarKeyTests`, `KeyboardLayoutTests`, `SidebarStateTests`, `HardwareKeyPathTests`, `AppShortcutTests`; live (inline on the unfolded size, drawer on the folded size and on an iPhone, and with no first responder at all) | With a terminal focused the key runs through `keyHook`; with none, through the app's menu (`AppShortcutCommands`). |
| 9e | The pool never strands a pane off screen | `TerminalHostPoolTests`; live (three panes on the unfolded size) | The newest container in a window shows the host, not the newest one made. (Before: the active pane was blank and had no keyboard.) |
| 10 | Paste | `GhosttyInputViewTests.testPasteInBothPasteModes`, `testPasteIsBracketedOnlyWhenTheProgramAsked` | Bracketed when the program asked; unsafe control bytes replaced by spaces in both modes. |
| 11 | Empty paste | `GhosttyViewTests.testAnEmptyPasteSendsNothing` | Nothing is sent, as in the Ghostty app: no empty bracket under mode 2004. The host only pastes a non-nil pasteboard string, so this needs an empty string on the pasteboard. |
| 12 | Input methods, dictation, space-bar trackpad | `GhosttyInputTextTests`; hand | Marked text is not drawn in the terminal; the keyboard's candidate bar shows it. |
| 13 | Scrollback: one-finger scroll, deceleration, rubber band, indicator | `GhosttyScrollTests`, `GhosttyScrollViewTests`; hand | 10,000 lines. Scrolls by pixels (sub-row). |
| 14 | Input returns a scrolled-back view to the bottom | `GhosttyIntegrationTests.testEveryKindOfInputJumpsToTheBottomThroughTheScroller`, `testInputAtTheBottomAsksForNoScroll`, live (`-scrollBackTest`) | Typed text, Backspace, key bar keys, `send(txt:)`, paste and hardware keys jump to the bottom through the scroller. |
| 15 | Mouse and focus reports leave the view where it is | `GhosttyIntegrationTests.testMouseAndFocusReportsLeaveAScrolledUpViewWhereItIs` | Clicks and wheel reports are not typing: a scrolled-up view stays. |
| 16 | Page Up / Page Down (hardware, keymap actions) | `GhosttyIntegrationTests.testHardwarePageKeysScrollTheSurface`, `GhosttyInputViewTests.testPageKeysScrollLocallyUnlessTheProgramTookTheCursorKeys` | Local scroll, or the key to the program on an alternate screen or under DECCKM. No key repeat for a local page scroll. |
| 17 | Scroll to previous / next prompt | `GhosttyIntegrationTests.testScrollToPromptMovesTheSurfaceBetweenShellPrompts` | Needs OSC 133 marks. |
| 18 | Pinch font size | `TerminalPinchTests`; hand | The text scales under the fingers; on release the size is stored and the font and the grid change. On a pane resized elsewhere the pinch also fits it here. The terminal keeps its modes and its screen, so nothing is reloaded from the server. |
| 19 | Long press selects a word | `GhosttySelectionTests` (words, paths, URLs, wide characters); hand | Words end at spaces, quotes, brackets, pipes, separators and the box-drawing bar. A word follows a soft wrap onto the next row. |
| 20 | Drag to extend, edge autoscroll | `GhosttySelectionTests.testDraggingToTheTopEdgeScrollsALinePerMoveThroughTheScroller`, `testHitTestingAndRectsAtAFractionalScrollOffsetInHistory`; hand | Hit-testing and rects use the scroller's position (right at any fraction of a row and in history), and the edge scroll goes through the scroll surface, one line per finger move. |
| 20a | The highlight is on the row under the finger | `GhosttySelectionTests.testPointToCellToRectRoundTripAtEveryRowScaleFontSizeAndScrollFraction`, `testAPressLowInARowSelectsThatRowAtAnyScrollFraction`, `testHitTestingWhenTheViewIsBottomAnchoredOrScaled`; hand (step 3) Hit-testing uses the frame's scroll shift. See "Hit-testing" below. |
| 21 | Copy, copy-on-select, shimmer, edit menu | `GhosttySelectionTests` (text and rects), `SelectionUITests.testCopyOnSelectHappensOnLiftAndAfterAnAdjustmentThatChangedSomething`; hand | The host does all four from `selectedText` and `selectionRects`, with the loupe, the selection haptics, handles and Select All in the menu ([selection.md](selection.md)). |
| 22 | Copied text | `GhosttySelectionTests` | What the Ghostty app copies: soft-wrapped rows joined into one line, trailing spaces trimmed. |
| 23 | Selection through output and resize | `GhosttySelectionTests.testTheSelectionSurvivesAReflow`, `testTheSelectionAndItsRectFollowOutput` | The terminal tracks the selection: it stays on its text through output, scrolling and a reflow. |
| 24 | Selection drawn during synchronized output | `GhosttySelectionTests.testASelectionChangeIsDrawnDuringARenderHold` | A selection made while a program holds the screen is drawn at once. |
| 25 | Pointer (mouse / trackpad) drag selects, wheel scrolls | `GhosttySelectionTests.testPointerDrag`, `GhosttyIntegrationTests.testEveryPanOfTheEngineAsksThePanGate`, `testTheEnginesRecognizersAreTheShapeTheHostExpects`; hand | The host's pointer pan on the terminal view asks `panGate`; the wheel-drag pan takes fingers only. |
| 26 | Gesture arbitration: scroll, drag-select, pane swipe, mirror canvas pan, pinch, two-finger tap | `GhosttyIntegrationTests.testEveryPanOfTheEngineAsksThePanGate`, `GhosttyScrollViewTests.testGatesDecideWhetherPansAndTheTapBegin`; hand | Every pan of the terminal view asks `panGate`; its tap asks `tapGate`. The view has no pan that selects. |
| 27 | Double tap (word), triple tap (line) | `SelectionUITests.testDoubleTapSelectsAWordAndTripleTapTheLine`, `testSelectionEndsAdjustAndLine`; hand (Selection 7) | The host counts taps (`TerminalSelectionController.tap`), so the first tap acts at once instead of waiting for a second. Both copy, and show handles and the edit menu. A line follows soft wraps. |
| 28 | Tap near the cursor shows a Paste menu | `SelectionUITests.testATapByTheCursorOffersPaste`, `testRules`; hand (Selection 8) | The trigger (`SelectionRules.tapShowsPaste`): within 3 columns and 1 row of the cursor, terminal focused, no selection cleared by the tap, no mouse tracking, no menu up. Shown with `UIEditMenuInteraction`. |
| 29 | Tap on a link opens it | `GhosttyLinkLookupTests`, `GhosttyTapRoutingTests`, `TerminalTapTests`; live (`-tapTest` on an OSC 8 link and on a web address, Safari opened; a finger tap with the keyboard down and up in a `zz-` session); hand (a real finger) | A tap opens an OSC 8 hyperlink and an `http(s)` address written as text (soft-wrapped ones too), with the keyboard up or down (the keyboard stays as it was) and also in a mouse-tracking program, which then gets no click. See "Taps" below. |
| 30 | Tap on a prompt line moves the cursor (OSC 133 click) | `GhosttyPromptClickTests`, `GhosttyTapRoutingTests`; live (`-tapTest`, then a typed character landed at the tapped cell); hand | The shell must announce `cl=…` or `click_events=…`, the cursor must be at a prompt, primary screen, no mouse tracking, no selection, not within 3 columns and 1 row of the cursor. Arrow keys go through the key encoder (DECCKM). As in Ghostty, every `cl` value moves within one input line. See "Taps" below. |
| 31 | OSC 52 copy to the pasteboard | `GhosttyClipboardTests`; live (`printf '\e]52;c;…'`, then `xcrun simctl pbpaste`) | Every destination is the iOS pasteboard, only valid UTF-8 text, an empty write empties it, silent (no haptic, no shimmer). A query is never answered. One-letter destinations only (`52;pc;…` is dropped). |
| 32 | Theme: foreground, background, cursor, selection, ANSI 16, keyboard appearance, indicator | `GhosttyViewTests.testThemeReachesEveryPart`, `GhosttyScrollViewTests.testThemeStylesTheIndicator`, `GhosttyRenderTests.testExplicitAndPaletteColors`; live (dark theme) | Light themes: by test only. |
| 33 | Colour rendering | live (screenshots) | The theme's hex values are drawn as they are. |
| 34 | Fonts: MesloLGS NF regular, bold, italic, bold italic; fallback | `GhosttyRenderTests.testBoldItalicFaintInvisible`, `testWideCharactersAndGraphemes`, `testEmojiUsesTheColorAtlas`; live (regular, bold) | Italic and bold italic have not been looked at live. |
| 35 | Box drawing, blocks, braille, Powerline | `GhosttyRenderTests.testBoxAndBlockSpritesFillTheCellEdgeToEdge`; live (Powerline prompt) | Drawn as cell-exact sprites, so lines and separators join with no gaps. |
| 36 | Cursor shapes (block, bar, underline) | `GhosttyRenderTests.testCursorFollowsTheTerminal`, `testRendererDrawsBackgroundsGlyphsAndCursor` | |
| 37 | Cursor solid with the keyboard, hollow without | `GhosttyIntegrationTests.testTheCursorIsSolidOnlyWhileTheViewIsFirstResponderInAWindow`; live (solid focused, hollow with `-focus none`) | The cursor follows the first responder. |
| 38 | Cursor blink | `GhosttyIntegrationTests.testTheCursorBlinksOnlyWhenTheTerminalSaysSoAndThePaneIsFocusedAndVisible`, `GhosttyRenderTests.testViewDrawsThenIdlesThenStopsTheThread` | Blinks only when the terminal says so (DECSCUSR, mode 12), focused and on screen. The timer exists only then. Whether a fresh shell's cursor blinks depends on the mode the server's snapshot carries; not checked live. |
| 39 | Mouse clicks and wheel reports, alternate scroll (arrows) | `GhosttyMouseTests`, `GhosttyScrollViewTests.testWheelDragSendsWheelReportsLineByLine`, `testTapSendsPressAndReleaseAtTheCell`, `testAlternateScrollSendsArrowKeysAndRespectsCursorKeyMode`; hand | Routing rules, wheel budget and formats as in `GhosttyMouseReporter`. A long press selects even when the program tracks the mouse (`testALiftedLongPressIsNotAClickForATrackingProgram`). |
| 40 | Mode 1002 drag reports | read of the pan handlers | Touch sends none: a one-finger drag is the wheel, a pointer drag selects. Hover motion is reported under mode 1003. |
| 41 | 120 Hz | `GhosttyRenderTests` (frame cost); hand on a device | The render thread's display link asks for 120 Hz. The simulator can't show it. |
| 42 | Mirror-mode zoom and pan | hand | The terminal view is scaled by the zooming scroll view, so it is soft above 1×. Hit-testing uses the view's own coordinates. Mirror is only behind `-sizing mirror`; not run since the audit. |
| 43 | Fit-mode claim | `FitClaimTests`; live (the pane took the phone's grid and this client as owner; the owner was gone once the app was terminated) | Host code. |
| 44 | "Resized elsewhere · tap to fit here", status chip | hand | Host code. Not run since the audit. |
| 45 | Keyboard show / hide, any new view size | `GhosttyIntegrationTests.testResizingTheViewNeverScrollsTheTerminal`; hand | A view that grew (keyboard gone, unfold) stays at the bottom. (Before: UIKit's offset fix-up for the new size was sent on as a scroll, and the terminal was left scrolled into history.) |
| 45a | The software keyboard covers a fitted pane | `GhosttyScrollTests` (the cover), `KeyboardCoverLayoutTests`; live (`-keyboardTest` over a real `claude` in a `zz-` session: the pane's tty size logged while the keyboard cycled through a streamed reply) | The grid keeps its rows on the main screen; the alternate screen fits above the keyboard. Reading mode (a drag into the scrollback hides the keyboard) needs a finger: hand. |
| 45b | Jump-to-bottom button | `JumpToBottomRuleTests`, `JumpToBottomViewTests`; hand | Shows half a screen (at least 3 rows) into the scrollback, hides within a row of the bottom, during a selection or a pinch, and under a mouse program or the alternate screen. The tap returns to the newest line and leaves the keyboard and the focus alone. The touch itself (no keyboard, no pane swipe from it) needs a finger: hand. Run live in the simulator with `-keyboardTest` (`scroll:`, `jump`; the log gives `jump=`, `unseen=` and `first=`) in a `zz-` session, on the folded Duo, a regular iPhone and the simulated unfolded and landscape postures: the button comes up under a streaming agent reply and its arrow takes the cursor's color; `jump` returns to the bottom and the button goes; with the keyboard up the pane's size (`stty size`) stays through scroll and jump, the button sits above the key bar, and it stays hidden among the rows the keyboard covers; with the keyboard down `jump` leaves the terminal out of first responder; in `less` and `vim` it never shows; in a split only the scrolled pane has one; a recording of it coming and going shows the glass forming and leaving with no flash. |
| 46 | Fold / unfold: the pool moves a live pane | `GhosttyIntegrationTests.testAPaneMovedToAnotherSuperviewDrawsAtOnceAndNothingWhileDetached`, `testSelectionAndCursorSurviveTheMove`; live (`-simulateDuo folded,unfolded,folded` on an iPad simulator) | Draws at once on return, at the new size and scale, without new output. Draws nothing and wakes nothing while detached. |
| 46a | Book mode: a split lands on the crease | `BookSplitTests`, `CreaseSettleTests`; `BookSidebarTests`; live (`-simulateDuo book`, and `unfolded,book` with `-simulateDuoEvery` counting `FIT_RESIZE`); hand on a Duo | Partly folded with a vertical crease, the side-by-side divider nearest the crease sits on it and no pane or handle is in the fold. The inline sidebar collapses on the way in and comes back on the way out, unless the user showed or hid it meanwhile; nothing about it is stored. Rex's ratios don't change. Each pane gets one resize per settled change of posture and none while the fold flickers, and the sidebar doesn't move then either. Everything else is laid out as when flat ([duo-layout.md](duo-layout.md), Book mode). The simulated fold is a guess: step 12 checks a real hinge. |
| 46b | Tent mode: the agent board covers the tab | `TentDetectorTests`, `BoardPresenceTests`, `AgentBoardModelTests`, `BoardOrderThrottleTests`, `BoardLayoutTests`, `PaneCoverTests`; live (`-boardDemo` in every scenario, and `-simulateTent off,90` with `-simulateTentEvery` counting `FIT_RESIZE`); hand on a Duo | The hinge decides only when the board comes and goes. Under it panes draw nothing, take no key and keep their size on the Mac; a pane that was never covered behaves as before. The simulator has no hinge and takes no taps from a script: step 13 checks a real one ([duo-layout.md](duo-layout.md), Tent mode). |
| 47 | Reconnect and resume | RexKit `Stream*` tests | Host and stream code. A fresh connection brings a snapshot; a resume carries none. Not run live. |
| 48 | Background and foreground | `GhosttyIntegrationTests` (visibility), `GhosttyRenderTests.testViewDrawsThenIdlesThenStopsTheThread`; hand | No Metal work and no display-link wake in the background; one frame on return. After more than 30 s the host opens a fresh stream. A fitted pane is given back in the background and stays the Mac's until the app returns (live: `rex block call size` shows `owner: null` 4 s after backgrounding, the phone's client again on return). |
| 49 | Reset and the `terminal.format` fallback | `GhosttySelectionTests.testTheViewNoticesWhenTheTerminalDroppedTheSelection`, `GhosttyCoreTests`, RexKit `StreamSnapshotHandoffTests` | A snapshot that doesn't decode, or is over the 16 MiB cap, falls back: `streamReset` feeds RIS and clear-scrollback, then `streamSnapshot` feeds the screen as text. |
| 50 | Teardown | `GhosttyIntegrationTests.testAClosedPaneLeavesNoTerminalAndNoRenderThreadPane` | No terminal, render-thread pane or thread left. |
| 50a | OSC 9;4 progress: a ring in the tab row and overview card | RexKit `TermProgressTests`, `AlertEventsTests`, `TabBadgeTests`, `BlockBoxTableTests`; live (`printf '\e]9;4;1;40\a'` in a `zz-` pane) | Rex sends it as the `progress_report` block event; the terminal engine never sees it. No ring in the title bar or for a pane with an OSC 7501 record; gone 15 s after the last report ([sidebar.md](sidebar.md), Progress rings). |
| 50b | OSC 9 / 777 desktop notification: a notice toast | `AlertEventsTests`, `NoticeToastTests`, `NoticeFilterTests`, `AlertCopyTests`; live (`printf '\e]9;zz probe\a'` with the pane off screen, then on screen) | The `desktop_notification` block event. Off screen only, never for an agent's pane ([notifications.md](notifications.md)). |
| 50c | Share output: selection, screen, All Output | `ShareTests`, `ShareCompatibilityTests`, RexKit `StreamInputTests` (pending input); live in a `zz-` pane (below, Share) | Share… is last in the edit menu with a selection; Share ▸ in the pane menu holds Plain and Styled, each Screen and All Output. Styled documents run nothing, keep only web and mail links, and use the theme's colors and Menlo. All Output reads in 64–256 KiB chunks, one at a time, waiting for typed input ([terminal.md](terminal.md), Share). |
| 50d | Ports: open a pane's dev server | RexKit `PortsTests`, `TunnelRelayTests`, `CallInOrderTests`; `PortsTests`, `PortForwardTests`; live (`-portsTest` against a macOS and a Linux server; below, Ports) | The pane menu's ports row and tapped loopback links open the page through a dial tunnel; only the opened port is forwarded; debugger ports never open; offline a notice, never Safari. The tunnel block closes on Done, before the background, and on the next sync after a kill; `rex forward ls` is empty after ([terminal.md](terminal.md), Ports). |
| 51 | Backpressure | `TerminalBackpressureTests`, RexKit `StreamBackpressureTests`, `GhosttyCoreTests.testABacklogAboveTheMarkSignalsAndClears` | Above 4 MB of unparsed output the stream stops reading its data socket; below 1 MB it goes on, in order. Input and control calls are not held. Not run live against a real flood. |

## Taps: links, prompt clicks, OSC 52 (rows 29 to 31)

Code: `Ghostty/GhosttyTap.swift` (the order of things a tap does, as a table with a test),
`GhosttyLinks.swift`, `GhosttyPrompts.swift`, `GhosttyClipboard.swift`. The host's tap asks the
terminal view (`tapOpensLink` without the keyboard, `tapOpensLinkOrMovesCursor` with it, at
`TAP HOOK` in `TerminalHost.tap`) in the order `TerminalTapDecision` gives; one hold of the
terminal lock reads everything. A tap that opened a link or moved the cursor is used up: it is
no click for the program and shows no menu.

Order: on an unfocused pane a link opens and the keyboard stays down, anything else only
focuses; a selection is only cleared; a link (OSC 8 or a web address in the text) opens, also in
a mouse-tracking program; a mouse-tracking program gets its click; next to the cursor nothing
moves (the Paste menu, row 28); a tap on the prompt moves the cursor.

With the selection UI (rows 27 and 28):

- **Paste by the cursor wins over a prompt click.** Both use the same zone (within 3 columns and
  1 row of the cursor): inside it the tap offers Paste and moves nothing, outside it the tap moves
  the cursor and shows no menu.
- **A double or triple tap still selects.** A used-up tap is counted as the first tap, and a tap
  that follows one within 0.5 s in the same place is never a link or prompt tap (the shell may not
  have moved its cursor yet, and the keys would go out twice). So a double tap on a word of the
  prompt moves the cursor there and selects the word; on a link it opens the link once.

- **Links.** The hyperlink of a cell is `ghostty_grid_ref_hyperlink_uri`. A plain address is
  looked for in the cell's logical line, built from the rows' wrap flags, in view only. Only
  `http` and `https` are found in text. A link a program wrote opens at once when it is a web or
  mail address; anything else, and a label that names another site, is asked about first
  (`LinkOpenPolicy`). Links are not underlined: Ghostty underlines them only under a hovering
  pointer with a modifier.
- **Prompt click.** libghostty-vt has the grid data (input cells, prompt rows, "cursor at prompt")
  but its C API has neither the click mode the shell announced nor `promptClickMove`. The mode is
  read from the stream with `ghostty_terminal_vt_write_until` at OSC boundaries (upstream's way to
  see a string's bytes); the move is `Screen.promptClickLine` again, with a wide character
  counted once (upstream counts both cells). A snapshot doesn't carry the mode, so after opening a
  pane a click works from the next prompt the shell draws.
- **OSC 52.** `GHOSTTY_TERMINAL_OPT_CLIPBOARD_WRITE`. The callback copies the text and leaves; a
  burst becomes one hop to the main actor and the last write wins. No clipboard-read and no
  write-pty callback exist, so nothing can be sent back. OSC 1337 Copy and OSC 5522 writes arrive
  the same way and are taken too. Only the pane the user works in may write (`setGate`). Live: the
  Rex server's terminal also set the Mac's clipboard from the same sequence.

## Hit-testing

Every touch maps to a cell through one function, `GhosttyGridGeometry`, in device pixels with the
frame's scroll shift: selection points, selection rects and the shimmer all use it. The scroll
surface rests at any pixel offset, so the grid is drawn shifted up by the part of the first row
scrolled past. A second conversion that ignored that shift once highlighted the row above the
finger whenever the view was off the bottom. Don't add another.

## Reflow

The server's terminal and the local one are both Ghostty, the stream carries the server's resize
at its place in the output, and both reflow there. So the host redraws nothing from the server
after a width change. Checked live: after folded → unfolded → folded the local screen and
`rex capture` had the same lines and the same wraps.

Where the two can still differ:

- **History the client doesn't hold.** A wider grid pulls rows back out of scrollback. The client
  keeps 10,000 lines; if the server holds more, rows above that can differ until the next snapshot.
  Only the top of deep history is affected.
- **Different Ghostty versions.** The server's Ghostty and the pin here must stay close (the
  snapshot format requires that anyway).
- **Alternate screen.** Neither side reflows it. The program redraws on SIGWINCH and that output
  comes through the stream, so both end up the same.
- **Programs that redraw on SIGWINCH on the main screen** (a shell prompt): the redraw is output in
  the stream after the resize, applied to the same reflowed screen on both sides.

## Choices on record

Three behaviours were choices, not necessities. They stand; each is one small change to undo.

1. **Row height (row 3).** The line height is a whole number of device pixels, not of points, so
   a pane has up to about 10% more rows and the Mac's pane is resized to that.
2. **Link taps (row 29).** A finger tap opens links, and web addresses in plain text open too.
3. **Row 7.** Ctrl+Return from the key bar sends Return.

## Find (about 3 minutes, on a device)

In a `zz-find` session with `seq 1 3000; echo error` and a few lines with `error` in them:

1. Software keyboard up: ⌘-less, pane menu → Find…. The find bar takes the key bar's place; the
   keyboard doesn't move or flicker. Type `error`: the count shows, Return steps older.
2. Escape: the terminal has the keyboard and the key bar again; the bar floats in the pane. Tap
   its field: it goes back to the accessory slot. Done closes.
3. Keyboard down: ⌘F (or the menu) raises the keyboard once; Done lowers it.
4. Hardware keyboard: ⌘F, ⌘G, ⇧⌘G, ⌘V in the field, ⌘T and ⌘] from the field, Escape. The title
   bar never jumps; fit mode sends no `FIT_RESIZE` (Debug log).
5. `vim` on the alternate screen: the bar is at the top, below the chip; a match under it sends it
   to the bottom on the next step.
6. `yes | head -n 20000` with find open: the count grows, typing stays smooth.

## Share (about 5 minutes)

In a `zz-share` pane:

1. `printf '\e]8;;javascript:alert(1)\e\\click\e]8;;\e\\ <script>alert(2)</script>\n'`, then
   Share ▸ Styled › Screen and open the file in Safari (or Quick Look): nothing runs, `click` is
   plain text, `<script>` shows as text.
2. `ls --color /` and `printf '\e[7m inverse \e[0m\n'`, Styled › All Output: the theme's colors,
   Menlo, not Courier. Inverse cells: note whether they keep the computer's colors (the known
   risk).
3. `seq 1 2000000`, then Plain › All Output: progress with Cancel. Type in another pane of the same
   server meanwhile: each key lands within a chunk (about 100 ms). Open the tab overview during
   the read: it finishes or retries once.
4. The share sheet on the unfolded Duo and on the iPad with `-simulateDuo`: it points at the pane
   menu (title bar) or the window's bar edge, and at the selection for Share….

## Arrange (about 10 minutes)

In a `zz-panes` session you made (`rex new zz-panes`), on a simulator with `-sizing mirror`, then
once with fit:

1. Split twice (`a | b | c`). Arrange ▸ Swap With: the two panes trade places on the Mac too; the
   pane on screen stays. Folded (one pane at a time), only the dots move.
2. Make a second tab. Move to Tab › Tab 2: the pane lands beside Tab 2's focused pane and Tab 2
   opens with it, its scrollback intact. From a tab's last pane: the old tab closes.
3. Move to Tab › New Tab: a new tab right after this one, titled by its pane. Suspend the app
   between the steps once (lock the screen right after the tap): at worst a tab with a fresh shell.
4. Drag a split off even, then Balance Splits. Compare with the Mac's own Balance Splits on the
   same layout. In fit mode each pane sends one `terminal.resize` (`FIT_RESIZE` lines).
5. Close Other Panes…: the dialog counts the panes; with an agent in one it says so.
6. In the sidebar, press a tab row and move: it lifts, the accent line follows, the list scrolls
   at the edges. Drop: the row moves at once and stays. The same for a session row. Press without
   moving: the menu, as before. Swipe: the actions, as before. With VoiceOver: Move Up, Move Down.
7. `-sidebarFoldBench 3` before and after: no slower.

## Floating windows (about 10 minutes)

In a `zz-floats` session you made, with a float from the CLI (`rex api call -s zz-floats
session.new_layer '{"window_id": "<id>", "bounds": [0.3, 0.2, 0.5, 0.6], "layout": {"block":
{"flavor": "com.superlogical.terminal.shell"}}}'`), on a simulator with `-sizing mirror`, then
once with fit:

1. Unfolded (`-simulateDuo unfolded`): the float sits where the Mac has it, with a soft shadow
   and the split stroke; the tiled pane under it is drawn as before. A second float overlaps it.
2. Tap the back float: it comes to the front at once and stays there (`session_view_changed`
   shows it in front on the server). Tap it four more times: nothing more is sent.
3. Arrange ▸ Floating Windows ▸ Minimize: the float goes, the row for it appears; tap the row:
   it is back in front. With only floats left in the tab, Minimize hides on the last one.
4. Folded (`-simulateDuo folded`): one pane at a time, tiled first, then the front float; the
   dots count them. A minimized float isn't a page.
5. Book (`-simulateDuo book`) with one tiled pane and a float across the crease: the float sits
   on one page, the tiled pane spans the fold as before.
6. Fit mode: the float's pane resizes on the Mac to its drawn frame once; minimized, the Mac gets
   its size back within a second.
7. The tent board covers the floats as it covers any pane.
8. Pixel diff every posture, light and dark, of a tab without floats against main: identical.

## Ports (about 10 minutes)

In a `zz-ports` session, with `python3 -m http.server 8765 --bind 127.0.0.1` in a pane:

1. The pane menu's last row above Close reads `localhost:8765` with the program under it. Open it:
   the directory listing loads. `rex forward ls` shows one `Pteron #<tag>` forward. Done: it goes.
2. `printf 'http://localhost:8765/ http://127.0.0.1:9229/ http://localhost:3999/\n'`: the first
   opens at once, the second is refused with a notice, the third asks first.
3. Open the page, go to the Home Screen and back: `rex forward ls` is empty in the background, and
   a reload works after the return.
4. Open the page, kill the app from the switcher, open it again: `rex forward ls` is empty once
   the server has synced.
5. Stop the server, reload: the page fails at once; start it again, reload: it loads.
6. On a device only: no Local Network prompt, and a Vite page with HMR still reloads after
   15 minutes idle.

## Manual script (about 5 minutes)

Rows that still need a hand: 8, 9, 12, 13, 18 to 21 (with 20a), 25, 26, 29, 30, 39, 41, 42, 44, 45, 46a (on a Duo), 48.

Setup: on the Mac, `rex new zz-manual`, then in that pane run `seq 1 400`. In the app open
`zz-manual` (panes fit the phone by default). Close the session when done.

1. **Scroll (13).** Drag down with one finger, flick, let it coast, pull past the top. Expected:
   smooth pixel scrolling, a rubber band at both ends, an indicator at the right.
2. **Type while scrolled (14).** Scrolled up, type `a`. Expected: the view jumps to the prompt.
3. **Long press (19, 20a, 21).** Scroll up a little so a row is cut at the top. Long press a
   number, with the finger low on its row, then on rows near the top, middle and bottom of the pane.
   Expected: each time the number under the finger is highlighted (never the one above), no keyboard
   pops up; on release a shimmer plays exactly over it and Copy / Paste appear. Repeat at the bottom
   of the output after raising and hiding the keyboard, and once in mirror mode (step 9). Tap Copy,
   then long press the prompt and Paste: the number is typed.
4. **Drag select and edge scroll (20).** Long press a number, drag up to the top edge and keep
   moving slightly. Expected: the view scrolls a line per move and the selection grows; nothing
   else scrolls or swipes. Release: the shimmer covers the visible part.
5. **Gestures (26).** Flick horizontally: the pane swipes (with two panes) and the terminal doesn't
   scroll. Two-finger tap: the pane zooms. Pinch: the text scales, and on release the font and
   grid change without the screen being reloaded (18).
6. **Keyboard (45, 45a, 45b, 12).** Tap to raise the keyboard, hide it with the key bar. Expected: the prompt
   stays at the bottom both times, and `stty size` says the same before and after. With the
   keyboard up, drag down: the covered rows, then the scrollback, and the keyboard goes away
   without the text jumping; a tap brings it back. Hold the space bar and slide: the cursor moves along the line.
   Drag half a screen into the scrollback: the jump-to-bottom button comes up in the bottom
   trailing corner, and its arrow takes the cursor's color when a command prints below. Tap it:
   the view returns to the prompt, the keyboard stays down and the pane's focus doesn't change.
7. **Mouse program (39).** Run `vim` (or `less` on a long file). One-finger drag: the file scrolls
   (arrows or wheel), not the scrollback. Two-finger drag: nothing to scroll on the alternate
   screen. In vim with `:set mouse=a`, tap a line: the cursor goes there. Long press a word: it is
   selected, vim's cursor doesn't move. Quit.
8. **Hardware keyboard (8, 9, 25), if at hand.** Type, hold an arrow (it repeats), Ctrl+C, Option+B,
   Page Up / Page Down (scrollback), a ⌘ shortcut from the keymap. With a trackpad: drag selects and
   copies, two-finger scroll scrolls.
9. **Mirror (42, 44).** Mirror has no setting: launch a Debug build with `-sizing mirror`. The pane
   shows the Mac's grid; pinch zooms, drag pans, a long press still selects the right word. Back
   in fit mode (a normal launch), resize the pane on the Mac: the chip "Resized elsewhere · tap to
   fit here" appears; tap it.
10. **Taps (29, 30).** With the keyboard up, run
    `printf '\e]8;;https://example.com\e\\LINK\e]8;;\e\\ https://example.org\n'` and tap `LINK`,
    then the address: each opens in Safari. Hide the keyboard and tap `LINK`: only the keyboard
    comes back. In a shell with Ghostty's shell integration (`OSC 133;A;cl=line`), type
    `echo abcdefghij` and tap the `c`: the cursor goes there; a tap within 3 columns of the cursor
    moves nothing.
11. **Background (48).** Send the app to the background for a few seconds and return: the screen is
    there at once and current. On a device, scrolling should run at 120 Hz (41).
12. **Book mode (46a), on a Duo.** Unfolded in landscape, sidebar showing, a tab with two panes
    side by side (`rex split`). Bend the phone slowly toward a book and back. Expected: once it
    is bent the sidebar slides away and the border between the panes moves onto the fold, with
    both panes clear of it and no text cut; flat again, the sidebar comes back at its width and
    the panes go back. Bend it again and show the sidebar by hand: it stays, flat or bent, and
    quitting and opening the app shows the sidebar as usual. Then check what the simulator can only guess:
    - **Region width.** The gap between the panes is the fold's reserved region plus 6 pt. If
      it looks too wide or too narrow for the hinge, note the region's width (`Division.frame`).
    - **When it turns active.** Note the angle at which the layout changes each way. It should
      not change while the phone is merely not quite flat on a table.
    - **Jitter.** Hold the phone at that angle for 20 s. The layout must not flip back and
      forth, and with a Debug build `FIT_RESIZE` must stay silent while the layout is still
      (docs/debug-args.md). Each real change is one line per pane.
    - **The crease stays put.** Flat and bent, the fold's middle should be the same x; if it
      moves by more than a point, book mode drops and comes back 400 ms later (`CreaseSettle`).
    - Drag a border that is not on the fold: it follows the finger. The border on the fold
      has no handle. `stty size` in a pane says the same before and after raising the keyboard.
13. **Tent mode (46b), on a Duo**, with a Debug build launched with `-hingeLog YES` and at least
    one agent running in a `zz-` session. Fold the phone back and stand it as a tent. Expected:
    after about a second the board replaces the tab on the outer screen, and it goes at once
    when the phone is shut or opened flat. Then check what only a device can show:
    - **What the hinge reports.** Read the `HINGE` lines: the angle on the outer screen in tent
      (if it stays 0 or `none`, tent never triggers and the rule needs another signal), the
      status there, and the angles at which the outer and the inner screen take over.
    - **No false tent.** Half open in the hand like a book, in Split View on the inner screen,
      and folded shut in a pocket grip: no board. Note any posture that shows one.
    - **Nothing resized.** `FIT_RESIZE` logs no line as the board comes and goes, also after
      turning the tent on its other side. `stty size` in the pane is the same before and after.
    - **Touch.** A tile opens its pane and the board goes; it is back after 60 s untouched, and
      not while typing. "+K more" opens the sidebar in Agents mode. Nothing under the board
      takes a tap, and the vertical bar's items are covered or do nothing harmful.
    - **Keyboards.** With the software keyboard up on entry: it goes, and stays down
      afterwards. With a hardware keyboard: no key reaches the pane under the board; afterwards
      the key bar is back and the pane has its size.
    - **Screen.** It stays awake on the board, sleeps as usual in Low Power Mode, and sleeps
      as usual again after leaving tent.
    - **Look.** Both ways up, Light and Dark Mode, Reduce Motion (rings hold still), Reduce
      Transparency (no glow), the largest text size (fewer tiles, none cut), VoiceOver (the
      headline first, then one button per tile).

## Selection (about 5 minutes, on a device)

Touches can't be injected into the simulator, and haptics and the loupe over Metal can only be
judged on hardware. Design and what is already verified: [selection.md](selection.md).

Setup: as above (`zz-manual`, `seq 1 400`, then `echo The quick brown fox jumps over /usr/local/bin/rex`),
font 9 to 11 pt, System Haptics on in iOS Settings (the app follows it). Keyboard down unless a
step says so.

1. **Start of a selection.** Touch and hold a word for half a second. Expected: one firm haptic at
   the instant the word highlights; a loupe above the finger shows the word magnified with its
   highlight (text, not a blank or black lens); the word under the finger is the one highlighted;
   the keyboard stays down.
2. **Drag.** Without lifting, drag right along the row, then down three rows. Expected: the pressed
   word stays whole and the selection grows from it; the loupe follows and shows where the
   selection ends; no tick while moving along a row, one light tick per new row; nothing scrolls or
   swipes. Drag back up past the word: the selection turns around and still holds the whole word.
3. **Lift.** Expected: a two-beat haptic, clearly different from the start, together with the
   shimmer; the loupe goes; two handles appear (start: knob above its row, end: knob below);
   Copy / Paste / Select All appears, above the selection if there is room. Paste somewhere: the
   text is what was highlighted.
4. **Handles.** Drag the end handle's knob down and right, then release; do the same with the start
   handle, up and left. Expected: a light haptic on grab; the selection does not jump when the knob
   is taken; the finger sits beside the row, not on it; the loupe shows the edge being moved; row
   ticks; on release the two-beat haptic and the shimmer again, and the clipboard holds the new
   text. Touch a handle and release without moving: no haptic but the grab, clipboard unchanged.
   Drag one handle past the other: the selection turns around.
5. **Edges.** Drag a handle to within a finger's width of the top edge and hold still. Expected: the
   view scrolls steadily (about 16 lines a second) with a tick per line, the selection grows, and it
   stops when the finger moves away. Same at the bottom after scrolling up. Select on the top row:
   the start knob hangs below the row instead of leaving the pane.
6. **Scroll and output with a selection.** With a selection standing, scroll with one finger away
   from the handles. Expected: scrolling starts as fast as without a selection; the handles move
   with the text and disappear when their end leaves the view. Run `seq 1 50` from the Mac: the
   selection and handles ride up with their text.
7. **Taps.** Double tap a word: selected, copied (two-beat haptic, shimmer), handles and menu. Triple
   tap: the whole line (a wrapped line: all of it). Tap elsewhere: selection, handles and menu go.
   With the keyboard down, the first tap of a double tap raises the keyboard (known; see
   selection.md, open question 2).
8. **Paste by the cursor.** Keyboard up, tap within a few characters of the cursor: Paste appears.
   Tap again: it goes. Tap far from the cursor: no menu.
9. **Select All.** Long press a word, choose Select All. Expected: everything highlights, no copy
   haptic, the menu returns with Copy; the visible end handle pulls the selection back in.
10. **Small targets and reach.** At 9 pt, select a two-letter word and grab each handle (above for
    the start, below for the end). One-handed, repeat steps 1 to 4 near the top of the pane, and on
    the Duo with the pane on each half.
11. **Other modes.** Mirror mode (`-sizing mirror`), zoomed out: handles are full size on the small
    text and stay on the selection while the canvas pans and zooms. In `vim` with `:set mouse=a`:
    long press and handles work and vim's cursor does not move; a double tap selects (its first
    tap is a click).
12. **Haptics off.** System Haptics off in iOS Settings: steps 1 to 4 again with no haptics at all.

If the loupe is blank on the device, relaunch with `-selectionLoupe off` and report it: the fallback
is a loupe drawn from the cell text.
