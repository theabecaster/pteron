# Ghostty engine: parity with SwiftTerm

Phase 3 audit (2026-11-16) of the Ghostty engine against the SwiftTerm adapter
(`Engine/SwiftTermEngine.swift`, SwiftTerm 1.99.3), member by member of `TerminalEngineView` and
`TerminalKeyTarget`, and for every call `TerminalHost`, `KeyBar` and the hardware keymap make.

Status:

- **same**: the host and the user see the same behaviour.
- **intentional difference**: Ghostty behaves differently on purpose; the note says why.
- **gap**: SwiftTerm does something Ghostty doesn't yet.

How it was verified:

- a test name: an XCTest in `RexConnectTests` (runs in the simulator).
- **live**: run in the simulator in a throwaway `zz-` session, checked with screenshots and
  `rex capture` of that pane.
- **hand**: needs touches, a hardware keyboard or a device. Touches can't be injected with this
  Xcode, so nobody has checked it since the three phase 2 chunks were joined. The script at the end
  covers these rows.

## Table

| # | Item | Status | Verified by | Notes |
| --- | --- | --- | --- | --- |
| 1 | Feed, snapshot restore | same | `GhosttyCoreTests`, RexKit `Stream*` tests, live | Ghostty restores Rex's snapshot; SwiftTerm seeds from `terminal.format`. Same screen in both (live, `seq 1 300` and a prompt). |
| 2 | Resize and reflow | intentional difference | `GhosttyCoreTests`, live (fold cycle against `rex capture`) | Ghostty reflows locally the way the server does (`reflowsLikeServer`), so a new width needs no redraw from the server. After folded → unfolded → folded the local screen matched `rex capture` line for line. See "Reflow" below for where it can differ. |
| 3 | Fit grid (cell size) | intentional difference | `GhosttyParityTests.testFitGridColumnsMatchSwiftTermAndRowsAreNeverFewer` | Columns are equal at every font size from 7 to 20 pt in 0.5 steps. Rows are not: SwiftTerm rounds the line height up to a whole point, Ghostty to a whole device pixel. Ghostty's rows are up to 1 pt shorter, so a pane fits up to about 10% more rows (never fewer), and the Mac's pane is resized to that. Rows were equal in 39 of 135 cases tried. Needs a decision, see the end. |
| 4 | System keyboard text | same | `GhosttyInputViewTests.testTypedTextMatchesSwiftTerm`, `testRawSendsMatchSwiftTerm`, live (`-typeTest`) | Same bytes in normal, DECCKM, DECBKM and bracketed-paste modes. Under the Kitty protocol Ghostty names the key; SwiftTerm does too. |
| 5 | Key bar keys and trackpad | same | `GhosttyInputViewTests.testCursorKeysMatchSwiftTermInBothCursorModes`, `testRawSendsMatchSwiftTerm` | The bar encodes its own bytes; arrows, Home and End follow DECCKM in both. |
| 6 | Key bar ctrl / alt, one shot and locked, with characters | same | `GhosttyInputViewTests.testOneShotControlMatchesSwiftTerm`, `testOneShotMetaMatchesSwiftTerm`, `testOneShotModifiersClearAndNotify` | Includes Ctrl+I, Ctrl+M and Ctrl+[ as Tab, Return and Escape in legacy mode. |
| 7 | Key bar ctrl / alt with Backspace, Return, Tab | intentional difference | `GhosttyParityTests.testOneShotControlWithReturnOrTabSendsThePlainKeyInLegacyMode`, `testOneShotModifierDifferencesThatAreIntended` | Alt+Backspace sends `ESC DEL` (delete a word) and uses up the flag; SwiftTerm sends `DEL` and leaves alt on. Ctrl+Backspace sends `0x08`, as Ghostty does. Ctrl+Alt+letter applies both. Ctrl+Return and Ctrl+Tab send the plain key in legacy mode (fixed here: it was `CSI 27;5;13~`, which a shell prints); SwiftTerm sends nothing. |
| 8 | Hardware keyboard | same | `GhosttyInputKeyTests`, `GhosttyInputViewTests.testHardwareKeysAreEncodedOrLeftToTheTextSystem`, `testHeldKeyRepeatsUntilReleased`; hand | Tests drive `hardwareKeyDown` with `UIKey`'s properties, since a `UIKey` can't be made. Real presses, layouts, dead keys and key repeat need a keyboard. With one-shot ctrl from the key bar a hardware function key takes the modifier (SwiftTerm ignores it). |
| 9 | Keymap bindings (`keyHook`), ⌘ commands | same | hand | The hook sees each press before the engine in both (same code path as SwiftTerm's adapter: `pressesBegan` asks it first). |
| 10 | Paste | same | `GhosttyInputViewTests.testPasteMatchesSwiftTerm`, `testPasteIsBracketedOnlyWhenTheProgramAsked` | Bracketed when the program asked; unsafe control bytes replaced. |
| 11 | Empty paste | intentional difference | `GhosttyParityTests.testAnEmptyPasteSendsNothing` | Ghostty sends nothing, like the Ghostty app. SwiftTerm sends an empty bracket under mode 2004. The host only pastes a non-nil pasteboard string, so this needs an empty string on the pasteboard. |
| 12 | Input methods, dictation, space-bar trackpad | same | `GhosttyInputTextTests`; hand | Neither engine draws marked text in the terminal; the keyboard's candidate bar shows it. |
| 13 | Scrollback: one-finger scroll, deceleration, rubber band, indicator | same | `GhosttyScrollTests`, `GhosttyScrollViewTests`; hand | 10,000 lines in both. Ghostty scrolls by pixels (sub-row), SwiftTerm by rows. |
| 14 | Input returns a scrolled-back view to the bottom | same | `GhosttyIntegrationTests.testEveryKindOfInputJumpsToTheBottomThroughTheScroller`, `testInputAtTheBottomAsksForNoScroll`, live (`-scrollBackTest`, both engines) | Fixed here: typed text, Backspace, key bar keys, `send(txt:)`, paste and hardware keys jump to the bottom through the scroller, as everything SwiftTerm's `send(data:)` carries does. |
| 15 | Mouse and focus reports leave the view where it is | same | `GhosttyIntegrationTests.testMouseAndFocusReportsLeaveAScrolledUpViewWhereItIs` | Fixed here: the scroll chunk jumped to the bottom on clicks and wheel reports; SwiftTerm doesn't. |
| 16 | Page Up / Page Down (hardware, keymap actions) | same | `GhosttyIntegrationTests.testHardwarePageKeysScrollTheSurface`, `GhosttyInputViewTests.testPageKeysScrollLocallyUnlessTheProgramTookTheCursorKeys` | Local scroll, or the key to the program on an alternate screen or under DECCKM. No key repeat for a local page scroll in either. |
| 17 | Scroll to previous / next prompt | same | `GhosttyIntegrationTests.testScrollToPromptMovesTheSurfaceBetweenShellPrompts` | Needs OSC 133 marks in both. |
| 18 | Pinch font size (fit mode) | intentional difference | hand | Same gesture and same font steps. SwiftTerm soft-resets on a font change and the host redraws from the server; Ghostty keeps its modes and screen (`fontChangeResetsModes` is false), so there is no redraw. |
| 19 | Long press selects a word | intentional difference | `GhosttySelectionTests` (words, paths, URLs, wide characters); hand | Same boundary characters. Ghostty's word follows a soft wrap onto the next row; SwiftTerm's stops at the row's end. |
| 20 | Drag to extend, edge autoscroll | same | `GhosttySelectionTests.testDraggingToTheTopEdgeScrollsALinePerMoveThroughTheScroller`, `testHitTestingAndRectsAtAFractionalScrollOffsetInHistory`; hand | Fixed here: hit-testing and rects use the scroller's position (right at any fraction of a row and in history), and the edge scroll goes through the scroll surface. One line per finger move, as the SwiftTerm adapter does. |
| 20a | The highlight is on the row under the finger | same | `GhosttySelectionTests.testPointToCellToRectRoundTripAtEveryRowScaleFontSizeAndScrollFraction`, `testAPressLowInARowSelectsThatRowAtAnyScrollFraction`, `testHitTestingWhenTheViewIsBottomAnchoredOrScaled`; hand (step 3) | Fixed here, reported from a device on build 7a0d37c ("highlights a row above"). See "The row-above bug" below. |
| 21 | Copy, copy-on-select, shimmer, edit menu | same | `GhosttySelectionTests` (text and rects); hand | The host does all four from `selectedText` and `selectionRects`. |
| 22 | Copied text | intentional difference | `GhosttySelectionTests` | Ghostty copies what the Ghostty app copies: soft-wrapped rows joined into one line, trailing spaces trimmed. SwiftTerm copies rows as drawn. |
| 23 | Selection through output and resize | intentional difference | `GhosttySelectionTests.testTheSelectionSurvivesAReflow`, `testTheSelectionAndItsRectFollowOutput` | The terminal tracks the selection: it stays on its text through output, scrolling and a reflow. SwiftTerm's is a fixed buffer range and is lost on a resize. |
| 24 | Selection drawn during synchronized output | same | `GhosttySelectionTests.testASelectionChangeIsDrawnDuringARenderHold` | Fixed here: a selection made while a program holds the screen is drawn at once. |
| 25 | Pointer (mouse / trackpad) drag selects, wheel scrolls | same | `GhosttySelectionTests.testPointerDrag`, `GhosttyIntegrationTests.testEveryPanOfTheEngineAsksThePanGate`, `testTheEnginesRecognizersAreTheShapeTheHostExpects`; hand | Fixed here: the host's pointer pan on the engine view asks `panGate`; the wheel-drag pan takes fingers only. |
| 26 | Gesture arbitration: scroll, drag-select, pane swipe, mirror canvas pan, pinch, two-finger tap | same | `GhosttyIntegrationTests.testEveryPanOfTheEngineAsksThePanGate`, `GhosttyScrollViewTests.testGatesDecideWhetherPansAndTheTapBegin`; hand | Every pan of the engine asks `panGate`; the tap asks `tapGate`. `isBuiltInSelectionPan` is false for all of them: the engine has no pan that selects. |
| 27 | Double tap (word), triple tap (line), SwiftTerm's own menu | gap | read of SwiftTerm's `doubleTap`, `tripleTap` | SwiftTerm selects on a double or triple tap and shows its own menu. Ghostty has only the host's long press. |
| 28 | Tap near the cursor shows a Paste menu | gap | read of SwiftTerm's `singleTap` | SwiftTerm's own context menu. In Ghostty, Paste is on the long-press menu and the key bar. |
| 29 | Tap on an OSC 8 hyperlink opens it | gap | read of SwiftTerm's `singleTap` / `requestOpenLink` | Not wired in Ghostty. |
| 30 | Tap on a prompt line moves the cursor (OSC 133 click) | gap | read of SwiftTerm's `handleSemanticPromptClick` | Not wired in Ghostty. |
| 31 | OSC 52 copy to the pasteboard | gap | read of the adapter's `clipboardCopy` | SwiftTerm sets the iOS pasteboard. Ghostty installs no clipboard callback. |
| 32 | Theme: foreground, background, cursor, selection, ANSI 16, keyboard appearance, indicator | same | `GhosttyParityTests.testThemeReachesEveryPartOnBothEngines`, `GhosttyScrollViewTests.testThemeStylesTheIndicator`, `GhosttyRenderTests.testExplicitAndPaletteColors`; live (dark theme) | Light themes: by test only. |
| 33 | Colour rendering | intentional difference | live (screenshots of both engines, same pane) | Ghostty draws the theme's hex values as they are. SwiftTerm's Metal output of the same prompt is visibly paler (blue and yellow segments). Not investigated on the SwiftTerm side. |
| 34 | Fonts: MesloLGS NF regular, bold, italic, bold italic; fallback | same | `GhosttyRenderTests.testBoldItalicFaintInvisible`, `testWideCharactersAndGraphemes`, `testEmojiUsesTheColorAtlas`; live (regular, bold) | Italic and bold italic were not looked at live in this audit. |
| 35 | Box drawing, blocks, braille, Powerline | intentional difference | `GhosttyRenderTests.testBoxAndBlockSpritesFillTheCellEdgeToEdge`; live (Powerline prompt) | Ghostty draws them as cell-exact sprites, so lines and separators join with no gaps. SwiftTerm uses the font's glyphs. |
| 36 | Cursor shapes (block, bar, underline) | same | `GhosttyRenderTests.testCursorFollowsTheTerminal`, `testRendererDrawsBackgroundsGlyphsAndCursor` | |
| 37 | Cursor solid with the keyboard, hollow without | same | `GhosttyIntegrationTests.testTheCursorIsSolidOnlyWhileTheViewIsFirstResponderInAWindow`; live (solid focused, hollow with `-focus none`) | SwiftTerm's caret follows the first responder too. |
| 38 | Cursor blink | same | `GhosttyIntegrationTests.testTheCursorBlinksOnlyWhenTheTerminalSaysSoAndThePaneIsFocusedAndVisible`, `GhosttyRenderTests.testViewDrawsThenIdlesThenStopsTheThread` | Blinks only when the terminal says so (DECSCUSR, mode 12), focused and on screen. The timer exists only then. Whether a fresh shell's cursor blinks depends on the mode the server's snapshot carries; not compared live. |
| 39 | Mouse clicks and wheel reports, alternate scroll (arrows) | same | `GhosttyMouseTests`, `GhosttyScrollViewTests.testWheelDragSendsWheelReportsLineByLine`, `testTapSendsPressAndReleaseAtTheCell`, `testAlternateScrollSendsArrowKeysAndRespectsCursorKeyMode`; hand | Same routing rules, wheel budget and formats. A long press selects even when the program tracks the mouse, in both (`testALiftedLongPressIsNotAClickForATrackingProgram`). |
| 40 | Mode 1002 drag reports | same | read of SwiftTerm's pan handlers | Neither sends them from touch: a one-finger drag is the wheel, a pointer drag selects. Hover motion is reported under mode 1003 in both. |
| 41 | 120 Hz | same | `GhosttyRenderTests` (frame cost); hand on a device | Both ask for 120 Hz. The simulator can't show it. |
| 42 | Mirror-mode zoom and pan | same | hand | The engine view is scaled by the zooming scroll view in both, so both are soft above 1×. Hit-testing uses the view's own coordinates. Not run in this audit. |
| 43 | Fit-mode claim | same | live (the pane took the phone's grid) | Host code, engine-neutral. |
| 44 | "Resized elsewhere · tap to fit here", status chip | same | hand | Host code, engine-neutral. Not run in this audit. |
| 45 | Keyboard show / hide, any new view size | same | `GhosttyIntegrationTests.testResizingTheViewNeverScrollsTheTerminal`; hand | Fixed here: a view that grew (keyboard gone, unfold) left the terminal scrolled into history, because UIKit's offset fix-up for the new size was sent on as a scroll. |
| 46 | Fold / unfold: the pool moves a live pane | same | `GhosttyIntegrationTests.testAPaneMovedToAnotherSuperviewDrawsAtOnceAndNothingWhileDetached`, `testSelectionAndCursorSurviveTheMove`; live (`-simulateDuo folded,unfolded,folded` on an iPad simulator, both engines) | Draws at once on return, at the new size and scale, without new output. Draws nothing and wakes nothing while detached (fixed here: output used to start the display link for a pane that can't draw). |
| 47 | Reconnect and resume | same | RexKit `Stream*` tests | Host and stream code. Ghostty takes the snapshot of a fresh connection; a resume carries none. Not run live in this audit. |
| 48 | Background and foreground | same | `GhosttyIntegrationTests` (visibility), `GhosttyRenderTests.testViewDrawsThenIdlesThenStopsTheThread`; hand | No Metal work and no display-link wake in the background; one frame on return. The host's 30 s re-read is engine-neutral. |
| 49 | Reset and resync fallback | same | `GhosttySelectionTests.testTheViewNoticesWhenTheTerminalDroppedTheSelection`, `GhosttyCoreTests`, RexKit `Stream*` tests | `streamReset` feeds RIS and clear-scrollback as text to both; a snapshot that doesn't decode falls back to `terminal.format`. |
| 50 | Teardown | same | `GhosttyIntegrationTests.testAClosedPaneLeavesNoTerminalAndNoRenderThreadPane` | No terminal, render-thread pane or thread left. |

Counts: 36 same, 10 intentional differences, 5 gaps (rows 27 to 31).

## The row-above bug (build 7a0d37c)

Reported from an iPhone Duo: a long press highlighted the row above the finger.

Cause: the selection chunk had its own point-to-cell conversion (`GhosttySelectionGeometry`), which
divided the touch's y by the cell height and took the grid to start at the view's top edge. The
renderer draws the grid shifted up by the part of the first row that is scrolled past (the scroll
surface is a `UIScrollView` and rests at any pixel offset, not on row boundaries). The shift was a
placeholder that returned 0 (`selectionScrollShift`), so with a shift of `f` pixels a touch in the
bottom `f` pixels of every row was mapped to the row above, and the terminal highlighted that row.
At the bottom of the output the shift is 0 and the mapping was right, but a second bug put the
view off the bottom without the user scrolling: when the view grew (keyboard hidden, unfold), UIKit
pulled the scroll offset back and that was sent to the terminal as a scroll (row 45). After that,
every press was off by up to a row.

It was not the view's position (the host reads the press in the engine view's coordinates, also
when the view sits at a negative y or is scaled in mirror mode), not the display scale, and not
cell-height rounding: the error did not grow with the row number.

Fix: one mapping, `GhosttyGridGeometry`, in device pixels with the frame's scroll shift, used for
selection points, selection rects and the shimmer. The old conversion is gone.

## Reflow (`reflowsLikeServer`)

The flag stays true. The server's terminal and the local one are both Ghostty, the stream carries
the server's resize at its place in the output, and both reflow there. Checked live: after
folded → unfolded → folded the local screen and `rex capture` had the same lines and the same wraps.

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

The coordinator's lead (a blank Ghostty pane when unfolded on an iPhone 17 simulator) did not
reproduce on an iPad simulator with either engine. The resize bug of row 45 is a possible cause:
it left a taller pane scrolled away from the bottom.

## Locks

`termLock` guards the terminal, `stateLock` the render state, the input mirror and the scroll state
have their own small locks. Order everywhere: `termLock`, then `stateLock`, then the scroll state's
lock; the mirror's lock is taken under `termLock` or alone. No path takes them the other way round.

Fixed:

- Input scrolled the viewport itself on the feed queue (`followOutput`), and an edge drag scrolled it
  under the terminal lock on the main thread. Both now leave a request with the scroll state; only
  the render thread moves the viewport, inside the frame's update.
- `scrollPage` on an alternate screen took the terminal lock on the main thread for one key. It
  uses the input mirror now.
- An unused per-frame callback (`frameSync`) took `termLock` without telling the feed queue; removed.

Accepted, with the bound:

- **Main-thread waits.** Selection calls, mouse reports, the wheel's mode read and the cursor
  position during composition take `termLock` on the main thread. The feed queue lets a waiter in
  between slices, so the wait is one slice of 64 KB of output, plus one row build if the feed queue
  is itself waiting for the renderer at the start of a synchronized update. Typing, pasting and
  scrolling take no terminal lock.
- **Stale input modes.** A key is encoded with the modes of the last parsed slice. Output still in
  the queue (including a snapshot being restored after a reconnect) hasn't changed them yet. The
  window is the feed queue's backlog; SwiftTerm has the same window, longer, while it paces output.
- **Stale scroll routing.** Whether one-finger drags go to the program follows the last drawn
  frame, at most 33 ms behind, and is not updated during a synchronized-output hold (1 s at most).
- **Hit-testing against the last frame.** A touch is mapped with the scroll position of the last
  drawn frame, and the terminal may have scrolled since (one frame of output at most).

## Needs your decision

1. **Row height (row 3).** Keep Ghostty's device-pixel line height (more rows, the Mac's pane is
   resized to more rows than with SwiftTerm), or round up to whole points to give the same grid.
2. **The five gaps (rows 27 to 31).** Which of double / triple tap, the tap-near-cursor Paste menu,
   OSC 8 links, prompt click and OSC 52 copy are wanted before Ghostty is the default.
3. **Row 7.** Ctrl+Return from the key bar sends Return (SwiftTerm sends nothing).

## Manual script (about 5 minutes)

Rows that still need a hand: 8, 9, 12, 13, 18 to 21 (with 20a), 25, 26, 39, 41, 42, 44, 45, 48.

Setup: on the Mac, `rex new zz-manual`, then in that pane run `seq 1 400`. In the app choose
Settings → Terminal → Engine → Ghostty, Pane Size → Fit, and open `zz-manual`. Close the session
when done.

1. **Scroll (13).** Drag down with one finger, flick, let it coast, pull past the top. Expected:
   smooth pixel scrolling, a rubber band at both ends, an indicator at the right.
2. **Type while scrolled (14).** Scrolled up, type `a`. Expected: the view jumps to the prompt.
3. **Long press (19, 20a, 21).** Scroll up a little so a row is cut at the top. Long press a
   number, with the finger low on its row, then on rows near the top, middle and bottom of the pane.
   Expected: each time the number under the finger is highlighted (never the one above), no keyboard
   pops up; on release a shimmer plays exactly over it and Copy / Paste appear. Repeat at the bottom
   of the output after raising and hiding the keyboard, and once in Mirror mode. Tap Copy, then long press the prompt and Paste: the number is typed.
4. **Drag select and edge scroll (20).** Long press a number, drag up to the top edge and keep
   moving slightly. Expected: the view scrolls a line per move and the selection grows; nothing
   else scrolls or swipes. Release: the shimmer covers the visible part.
5. **Gestures (26).** Flick horizontally: the pane swipes (with two panes) and the terminal doesn't
   scroll. Two-finger tap: the pane zooms. Pinch: the text scales, and on release the font and
   grid change without the screen being reloaded (18).
6. **Keyboard (45, 12).** Tap to raise the keyboard, hide it with the key bar. Expected: the prompt
   stays at the bottom both times. Hold the space bar and slide: the cursor moves along the line.
7. **Mouse program (39).** Run `vim` (or `less` on a long file). One-finger drag: the file scrolls
   (arrows or wheel), not the scrollback. Two-finger drag: nothing to scroll on the alternate
   screen. In vim with `:set mouse=a`, tap a line: the cursor goes there. Long press a word: it is
   selected, vim's cursor doesn't move. Quit.
8. **Hardware keyboard (8, 9, 25), if at hand.** Type, hold an arrow (it repeats), Ctrl+C, Option+B,
   Page Up / Page Down (scrollback), a ⌘ shortcut from the keymap. With a trackpad: drag selects and
   copies, two-finger scroll scrolls.
9. **Mirror (42, 44).** Pane Size → Mirror: the pane shows the Mac's grid; pinch zooms, drag pans,
   a long press still selects the right word. Back in Fit, resize the pane on the Mac: the chip
   "Resized elsewhere · tap to fit here" appears; tap it.
10. **Background (48).** Send the app to the background for a few seconds and return: the screen is
    there at once and current. On a device, scrolling should run at 120 Hz (41).
