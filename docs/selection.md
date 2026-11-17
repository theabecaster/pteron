# Text selection in the terminal: research, design, status

The problem, from a device: "highlighting seems to highlight a row above. It's hard to use right now
as I don't know where it is starting. Also give me haptic feedback as I'm holding, to know when it
starts highlighting."

Two causes. The row-above bug was a hit-testing error and is fixed (see
[terminal-checklist.md](terminal-checklist.md), "The row-above bug"). The second is physical: at 9 to 11 pt
a row is about 11 to 14 pt high and a fingertip covers 2 to 4 rows, so even with correct hit-testing
the user cannot see what is under the finger. This document is about the second.

Code: `RexConnect/Features/Terminal/Selection/`. Tests: `RexConnectTests/SelectionUITests.swift`.
Manual checklist: [terminal-checklist.md](terminal-checklist.md), "Selection".

## What it does now

- **Long press** (0.45 s): selects the word under the finger, plays a firm haptic at that moment,
  and shows the system loupe above the finger with the text and the highlight magnified.
- **Drag** without lifting: extends by cells. The pressed word stays whole: the drag is anchored on
  the word's far end. The loupe follows the moving edge. A light tick plays for each new row. Near
  the top or bottom edge the view scrolls, a line every 60 ms, for as long as the finger stays there.
- **Lift**: the selection is copied (copy-on-select), a two-beat "success" haptic plays in step
  with the shimmer, two handles appear, and the edit menu (Copy, Paste, Select All) opens above the
  selection.
- **Handles**: drag either one to adjust. The loupe shows the edge being moved, rows tick, edges
  autoscroll. On release the adjusted selection is copied again (haptic and shimmer again) and the
  menu returns. Dragging one handle past the other turns the selection around.
- **Double tap** selects a word, **triple tap** the line; both copy and show handles and menu.
- **Tap elsewhere** clears. A tap within 3 columns and 1 row of the cursor (terminal focused, no
  selection, no mouse-tracking program) shows Paste.
- No selection: nothing is drawn and no touch is intercepted.

## Research

### Apple's selection UI for a custom-drawn view

| API | What it gives | What it needs | Verdict here |
| --- | --- | --- | --- |
| `UITextLoupeSession` (iOS 17) | The system magnifier. `begin(at:fromSelectionWidgetView:in:)`, `move(to:withCaretRect:trackingCaret:)`, `invalidate()`. | Any view. "UITextSelectionDisplayInteraction or UITextInput isn't required" (WWDC23 session 10058). | Used. |
| `UITextSelectionDisplayInteraction` (iOS 17) | System cursor, highlight and handle views, display only: "just provides the selection UI without the gestures". | A `UITextInput` whose `selectedTextRange` and `selectionRects(for:)` describe the selection. | Not used: see design A/C. |
| `UITextInteraction` (iOS 13) | Gestures, loupe, handles, edit menu together. | A complete and correct `UITextInput`: positions, ranges, `closestPosition(to:)`, `selectionRects(for:)`, `caretRect(for:)`, tokenizer. | Rejected: see design A. |
| `UIEditMenuInteraction` (iOS 16) | The edit menu, placed around `targetRectFor`, arrow by `preferredArrowDirection`. | A delegate. | Already used; now prefers to sit above the selection. |
| `UIFeedbackGenerator` family | Haptics. `prepare()` keeps the Taptic Engine ready "for a short period of time (typically seconds)"; preparing and firing at once "does not improve latency"; prepare again after each trigger. | | Used: see "Haptics". |
| `UICanvasFeedbackGenerator` (iOS 17.5) | `alignmentOccurred(at:)`, `pathCompleted(at:)`. | | Not used: Apple aims it at drawing canvases and Pencil; a row crossing is a "value changing" (`UISelectionFeedbackGenerator`). |

Sources: [UITextLoupeSession](https://developer.apple.com/documentation/uikit/uitextloupesession),
[WWDC23 "What's new with text and text interactions"](https://developer.apple.com/videos/play/wwdc2023/10058/),
[Adopting system selection UI in custom text views](https://developer.apple.com/documentation/uikit/adopting-system-selection-ui-in-custom-text-views),
[UITextSelectionDisplayInteraction](https://developer.apple.com/documentation/uikit/uitextselectiondisplayinteraction),
[UITextSelectionHandleView](https://developer.apple.com/documentation/uikit/uitextselectionhandleview),
[UITextInteraction](https://developer.apple.com/documentation/uikit/uitextinteraction),
[UIEditMenuInteraction](https://developer.apple.com/documentation/uikit/uieditmenuinteraction),
[prepare()](https://developer.apple.com/documentation/uikit/uifeedbackgenerator/prepare()),
[UICanvasFeedbackGenerator](https://developer.apple.com/documentation/uikit/uicanvasfeedbackgenerator),
[HIG: Playing haptics](https://developer.apple.com/design/human-interface-guidelines/playing-haptics),
[HIG: Edit menus](https://developer.apple.com/design/human-interface-guidelines/edit-menus).

**Does the system loupe show Metal content?** Apple documents nothing about how the loupe captures,
and no public report was found either way for `CAMetalLayer`, `framebufferOnly` or drawables
presented from another thread. So it was tested here: on the iOS 27.2 simulator (iPhone 17) the
loupe magnifies our grid, its colours, the selection highlight and the handles, live, with the layer
exactly as the app configures it (`framebufferOnly = true`, presented from the render thread). The
loupe magnifies what the compositor shows, not what the app can read back, which is why
`framebufferOnly` does not matter. Prior art agrees: Compose Multiplatform, which draws through
Metal, ships its iOS 17 magnifier on `UITextLoupeSession`
([PR 1000](https://github.com/JetBrains/compose-multiplatform-core/pull/1000)).
**Not verified: a real device.** If the loupe is blank there, `-selectionLoupe off` (UserDefaults
`selectionLoupe`) turns it off, and the fallback would be a loupe we draw ourselves from the cell
text (not built).

**Could `UITextInteraction` on our `UITextInput` give everything for free?** No, not at a sane
cost. Our conformance (`GhosttyInputText.swift`) is a one-line shadow document of what was typed
since the last Return, there for input methods, dictation and the space-bar trackpad:
`selectionRects(for:)` returns `[]`, `closestPosition(to:)` returns the caret, `caretRect` is the
bottom-left cell. `UITextInteraction` "heavily relies" on those being right
([Nutrient](https://www.nutrient.io/blog/adopting-uitextinteraction/)). To back it with the grid:

- `UITextPosition` / `UITextRange` would have to name grid cells over the whole scrollback, and the
  same protocol would still have to serve the keyboard's one-line document. Two documents behind
  one `UITextInput` is the conflict: the keyboard would read and replace terminal text, and
  marked text, dictation and the space-bar trackpad would move the system's selection.
- The system would draw its own caret and call `setSelectedTextRange` on taps; `.nonEditable`
  avoiding the keyboard could not be confirmed.
- Its recognizers (a long press with the system's timing, taps, a range-adjust pan that
  `gesturesForFailureRequirements` does not list) compete with our scroll surface, pane swipe,
  pinch, and mouse reporting. Reported: no autoscroll, no zoom handling, fixed blue tint
  ([Steve Shepard, iOS 13](https://steveshepard.com/blog/adventures-with-uitextinteraction/)).
- `selectionRects(for:)` on Select All of a long scrollback would be thousands of rects, asked for
  on the main thread, each needing the terminal lock.

**What iOS does itself** (iPhone User Guide, HIG): touch and hold magnifies; double tap selects a
word, triple tap a paragraph; handles adjust after the lift; the edit menu appears above or below
the selection; user guides describe a haptic when a long-press selection begins. The HIG asks to "let people
select and copy noneditable text" and to use each haptic for its documented meaning without
overusing them.

### Other terminals

| App | How it selects | Loupe | Handles | Haptics | Notes |
| --- | --- | --- | --- | --- | --- |
| Blink Shell (hterm in WKWebView) | WebKit's own selection, character granularity ([TermView.m:181](https://github.com/blinksh/blink/blob/HEAD/Blink/Terminal/TermView.m#L181)) | WebKit's | WebKit's | none of its own | While a selection exists it disables pinch and tap and drops scroll touches ([WKWebView.swift:131](https://github.com/blinksh/blink/blob/HEAD/Blink/WebKit/WKWebView.swift#L131-L142)). A keyboard selection mode (`h/j/k/l`, `w/b`, `o` swaps ends, `y` copies). Complaints: imprecise and slow ([#126](https://github.com/blinksh/blink/issues/126)), long selections truncated ([#2278](https://github.com/blinksh/blink/issues/2278)), steals drags from mouse programs ([#2309](https://github.com/blinksh/blink/issues/2309)). |
| Termius | "Press and hold the word, then release"; handles at both ends ([docs](https://docs.termius.com/terminal/mobile-terminal)) | not confirmed | yes | not confirmed | Lift-to-select exists because its long-press-drag sends arrow keys. |
| Secure ShellFish | Double tap starts, triple tap a line ([help](https://secureshellfish.app/help/cursor-and-selection)) | not confirmed | not confirmed | not confirmed | Under mouse programs: Option passes clicks, Shift keeps them local. |
| Prompt 3 | not documented | | | | Release notes mention only a "Send Mouse Events" toggle. |
| iSH, a-Shell | hterm in WKWebView: WebKit's selection | WebKit's | WebKit's | | |
| libghostty-spm | Long press (0.7 s) opens the menu; double tap word, triple tap row; with a selection, one finger drags handles and two fingers scroll ([guide](https://lakr233.github.io/libghostty-spm/guide/text-selection.html)) | | yes | | |
| Termux (Android) | Long press: haptic, word selected, two handle popups that flip at screen edges, floating Copy / Paste toolbar ([source](https://github.com/termux/termux-app/blob/HEAD/terminal-view/src/main/java/com/termux/view/textselection/TextSelectionCursorController.java)) | none | yes | on long press | The closest full design to ours. |

Read from source where a file is linked; from the vendor's docs otherwise. App Store and forum
sentiment could not be gathered; the complaints above are GitHub issues.

What this says: no open-source native terminal on iOS has a loupe or selection haptics, and the
ones that feel native get it from WebKit. The recurring complaints are imprecision at small sizes,
handles too small to grab, and selection fighting scroll or mouse reporting.

### Terminal-specific concerns and how each is handled

- **A program that tracks the mouse** (vim, tmux): long press and handles are ours and never reach
  the program. A single tap is still its click, so the first tap of a double tap clicks. The
  engine's own tap clears a selection instead of clicking.
- **Output while selecting**: the selection is the terminal's tracked selection, so it stays on its
  text. Handles follow on the next display frame (the controller's display link compares
  `selectionGeometryStamp`, the scroll position of the last drawn frame). A reset drops the
  selection; the handles go within 0.1 s.
- **Scrollback**: handles scroll with the text; an end scrolled out of view has no handle. Edge
  autoscroll reaches the rest.
- **Soft wraps and wide characters**: word and line selection are libghostty-vt's (they follow soft
  wraps); `selectionExtent` already treats a wide character as one cell, and the handle ends come
  from it.
- **Rectangular selection**: nothing creates one from touch. `selectionEnds` handles one (top-left,
  bottom-right) if a future gesture does.
- **Tiny fonts**: the loupe, plus handles whose knob sits off the text (above the row for the start,
  below for the end) with a 24 pt hit radius (48 pt across, Apple's minimum is 44) regardless of
  font or mirror zoom. Taking a handle keeps the offset between finger and cell, so the selection
  does not jump and the finger stays beside the row it is editing.
- **One hand, both hands, the fold**: every target is where the selection is; nothing is anchored
  to a screen edge or corner. The overlay is per pane, so a half-screen pane works alone.
- **Not delaying scroll**: no recognizer was added to the scroll path and none waits for another to
  fail. The only new recognizer is on the handle overlay, which takes touches only within 24 pt of
  a visible handle. Without a selection the overlay passes everything.
- **Copy-on-select and the shimmer**: kept. See "Decisions".

## Designs compared

**A. Adopt `UITextInteraction` on our `UITextInput`.** Gives the full system look and behaviour.
Costs: a second, grid-backed document behind the protocol the keyboard uses; system recognizers
inside our gesture arbitration; no control of timing, autoscroll, tint or mouse-mode behaviour;
`selectionRects` cost on large selections; copy-on-select and the shimmer would have to hook
selection changes the system makes. High risk of regressions in typing, dictation and scrolling,
which work. Rejected.

**B. Keep our gestures; add `UITextLoupeSession`, our own handles, haptics.** Gives the loupe
(system look, zero rendering cost for us), handles sized for small fonts, haptics, word and line
taps. The selection stays the terminal's; nothing touches `UITextInput`. Costs: handles are ours to
draw and hit-test (about 150 lines); the loupe over Metal is confirmed in the simulator only.
Performance: a drag event costs two calls into the terminal view and no allocation; nothing runs
without a selection.
Chosen.

**C. Hybrid: ours for gestures, `UITextSelectionDisplayInteraction` for the handle views.** The
system would draw handles (and could draw the highlight) from `selectedTextRange` and
`selectionRects(for:)`. It still needs the grid-backed `UITextInput` of design A for those two, so
it inherits the two-documents conflict, and the handle views are display only: dragging them is our
gesture either way (a recognizer on the system's handle view did not fire for one developer,
[forum 751752](https://developer.apple.com/forums/thread/751752)). It buys the system's handle
shape and nothing else. Rejected; worth another look only if the keyboard document is ever split
off into its own object.

## Design of B

```
TerminalHost (recognizers, arbitration, clipboard, shimmer, edit menu)
   │  touchDown · pressBegan/Moved/Ended/Cancelled · tap · selectAll · selectionCleared
   ▼
TerminalSelectionController ── SelectionSession (pure state machine → effects)
   │        │        │
   │        │        └─ SelectionFeedback  (SystemSelectionFeedback: generators)
   │        └────────── SelectionLoupe     (SystemSelectionLoupe: UITextLoupeSession)
   │                    SelectionHandlesView + SelectionHandleLayout (pure geometry)
   ▼
GhosttyTerminalView (points, cells and rects all from GhosttyGridGeometry)
```

- `SelectionSession` holds the phase (`idle`, `pressing`, `selected`, `adjusting`) and turns events
  into an option set of effects. It decides every "when": which haptic, when to copy, when the
  loupe, handles and menu show. It has no UIKit in it.
- `TerminalSelectionController` performs effects and owns the one display link, which runs only
  while a selection is up and the pane is in a window.
- Point to cell and cell to rect come only from the terminal view (`gridCell(at:)`,
  `selectionEnds`, `selectionRects`), which is `GhosttyGridGeometry`. The Selection folder does
  no grid math.

### Haptics

| Event | When | Generator |
| --- | --- | --- |
| `start` | The long press highlights a word; or, after a press on blank space, the first cell the drag covers | `UIImpactFeedbackGenerator(style: .medium)` |
| `grab` | A handle is taken; a long press lands on blank space (nothing highlighted yet) | `UIImpactFeedbackGenerator(style: .light)` |
| `tick` | The moving end enters another row, during a drag, a handle drag or an edge autoscroll. At most one per 60 ms | `UISelectionFeedbackGenerator.selectionChanged()` |
| `copy` | The selection went to the clipboard, in the same call as the shimmer: on lift, after a handle adjustment that changed something, after a double or triple tap | `UINotificationFeedbackGenerator.notificationOccurred(.success)` |

- The start is one firm beat; the copy is the system's two-beat success pattern. They cannot be
  confused, and "success: a task or action has completed" is the documented meaning.
- `prepare()` runs at touch down (every finger touch on the pane, so the start of a long press
  0.45 s later has no lag), again when the press is recognized, after every tick, and when a
  handle is grabbed. So the copy generator is always prepared within the last few seconds of a
  drag. Preparing is skipped entirely when the Haptics setting is off.
- All behind `Prefs.haptics`, like the `Haptic` helper.
- No per-word tick: at 10 pt a horizontal drag crosses a word every few points, and with row ticks
  on top it reads as a buzz. Rows are what the user cannot see under the finger.

### Decisions

- **When copy-on-select fires**: on lift of the long press, and again on release of a handle if the
  drag moved its end to another cell. A handle that was only touched copies nothing. Double and
  triple taps copy at once. Select All never copies by itself (it can be the whole scrollback);
  Copy in the menu does.
- **Word-anchored drag**: the view's drag runs from the pressed cell to the finger, which cut the
  pressed word in two. The controller now waits until the finger leaves the word, then anchors the
  drag on the word's far end with `beginSelectionAdjust`.
- **Edge autoscroll**: the engine scrolls one line when asked with a point within half a cell of
  its edge, once per call. The controller widens that to 18 pt and repeats every 60 ms while the
  finger rests there, by asking with a point just past the edge and then putting the selection end
  back under the finger.
- **Double and triple tap without delaying the single tap**: taps are counted in the host's tap
  handler (0.35 s, 28 pt), not with recognizers that wait for each other. The first tap therefore
  acts at once, as before: it focuses the pane and raises the keyboard if it was down.
- **Edit menu**: Copy, Paste, Select All, above the selection when there is room (the end handle
  hangs below it). Hidden while a finger is on the selection.
- **Pointer (mouse, trackpad) drags**: unchanged. No loupe, handles or new haptics.

### Performance

- No selection: no display link, no layers shown, `point(inside:)` of the overlay returns false
  after one comparison.
- A drag event: `extendSelection`, then `selectionEnds` (for the loupe and handles). That
  is three short `termLock` sections on the main thread, each bounded by one parser slice (the
  bound in terminal-checklist.md, "Locks"). Effects are an `OptionSet`; rects and cells are values;
  layers are reused with implicit animations off. Nothing is allocated per event.
- A frame with a standing selection: one read of the scroll state's own lock. The ends are read
  again (terminal lock) only when that position changed, or every 0.1 s to notice a dropped
  selection. `selectionExtent` converts three references to screen coordinates, which walks the
  page list; that was "once per gesture" and is now once per scrolled frame while a selection
  stands. Not measured on a device with a full scrollback; if it shows, cache the ends as
  scrollback rows and shift them by the scroll delta.
- The loupe is drawn by the system from the composited screen: no extra render pass, no readback.

## What the selection UI asks of the terminal view

In `Ghostty/GhosttyTerminalView+SelectionUI.swift`; the two value types (`TerminalGridCell`,
`TerminalSelectionEnds`) are in `Selection/SelectionSeam.swift`.

| Member | For |
| --- | --- |
| `selectionEnds: TerminalSelectionEnds?` | Rects of the first and last selected cell; an end out of view is nil |
| `selectionGeometryStamp: Int` | Cheap "did the grid move" check, per frame |
| `beginSelectionAdjust(movingStart:) -> Bool` | Handle drags and the word-anchored drag |
| `selectLine(at:) -> Bool` | Triple tap |
| `gridCell(at:) -> TerminalGridCell?` | Row ticks, word bounds, the cursor menu (rows count from the top of the scrollback) |
| `cursorGridCell: TerminalGridCell?` | The cursor menu |
| `sendsTapsToProgram: Bool` | No cursor menu under mouse tracking |

In the core: `GhosttyCore.beginSelectionAdjust(movingStart:anchor:)`, `selectLine(col:row:)`, and
two flags on `GhosttySelectionExtent` (`startClipped`, `endClipped`).

## Hooks in TerminalHost

Each is marked `SELECTION UI` in `TerminalHost.swift`. The recognizers and their gates are as they
were; no arbitration changed.

- `setupSelectionUI()`, called at the end of `setupGestures()`: builds the controller and gives it
  the shimmer, the edit menu and the `selecting` flag.
- `gestureRecognizer(_:shouldReceive:)`: `selectionUI.touchDown()` for finger touches.
- `tapped()`: `selectionUI.tap(at:focused:)` first. **The line above it is the hook for link and
  prompt taps** (comment `TAP HOOK (links, prompts)`): a tap that hit an OSC 8 link or an OSC 133
  prompt should return there, before selection sees the tap.
- `longPressed(_:)`: forwards the four phases.
- `clearSelection()`: `term.clearSelectedRange()` plus `selectionUI.selectionCleared()`; replaces
  the direct calls.
- Edit menu: Select All item; `willPresentMenuFor` / `willDismissMenuFor` keep `menuVisible`;
  `presentEditMenu(at:)` presents or moves the menu.
- `perform(.selectAll)` and `applyTheme` (handle colour: the theme's cursor colour).

## Debug launch arguments

- `-selectionDemo <steps>`: plays a gesture by program on the first pane that comes on screen
  (`Selection/SelectionDemo.swift`), for screenshots. Steps are `;`-separated: `press:c,r`,
  `move:c,r`, `lift`, `grab:start|end`, `drag:c,r`, `drop`, `tap:c,r`, `double:c,r`, `triple:c,r`,
  `all`. `-selectionDemoDelay` and `-selectionDemoStep` set the timing. Example:
  `-replay /tmp/x.txt -replayFontSize 10 -focus none -selectionDemo "press:30,20;move:44,24;lift;grab:end;drag:50,28"`.
- `-selectionLoupe off`: no loupe.

## Verified, and not

Verified by tests (23 in `SelectionUITests`): the state machine through press, drag, lift, handle
adjustment and clear; every haptic trigger point with a recording sink, including the prepare
before the start, the rate limit, the copy confirmation and the copy after an adjustment; handle
geometry, flipping and hit targets; word and line taps; the word-anchored drag; copy-on-select
timing; the cursor menu rule; the members above on a real terminal view.

Verified by screenshot in the simulator (replay screen, 10 pt, iPhone 17, iOS 27.2): the loupe over
the Metal grid during a press, a drag and a handle drag, showing text, highlight and handle; both
handles on the selection's edges; the knob flipping under the top row; handles at full size on a
zoomed-out mirror grid; the menu with Copy, Paste, Select All.

Needs a person with a device (the checklist in terminal-checklist.md):

- The loupe over Metal on real hardware, and whether its magnification is enough at 9 pt.
- How every haptic feels, and that the start arrives with no lag.
- Real touches: grabbing a handle at 9 to 11 pt, one-handed reach, edge autoscroll speed, that
  scrolling is not delayed with or without a selection, a triple tap landing on fresh handles.
- The edit menu's placement next to the handles, and the keyboard staying down during long press
  and handle drags.
- Mouse-tracking programs: the first tap of a double tap is a click; whether the engine's own tap
  clears a tap-made selection there.

## Open questions

1. The copy haptic is the two-beat success pattern on every lift and every handle adjustment. If
   that is too much, a single `.rigid` impact is the alternative.
2. A double tap raises the keyboard when it was down (its first tap is a normal tap). Delaying the
   single tap by 0.35 s would avoid that and make every tap feel slower.
3. The tap-near-cursor Paste menu can show when the tap was only meant to focus the prompt; drop
   it if it annoys.
4. Per-word ticks were left out as noisy. Easy to add in `SelectionSession` if wanted.
