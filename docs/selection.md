# Text selection in the terminal

At 9 to 11 pt a row is 11 to 14 pt high and a fingertip covers 2 to 4 rows, so the user can't see
what is under the finger. The selection UI answers that with the system loupe, handles placed off
the text, and haptics at each step.

Code: `RexDuo/Features/Terminal/Selection/`. Tests: `RexDuoTests/SelectionUITests.swift`.
Manual device script: [terminal-checklist.md](terminal-checklist.md), "Selection".

## What it does

- **Long press** (0.45 s): selects the word under the finger, plays a firm haptic at that moment,
  and shows the system loupe above the finger with the text and the highlight magnified.
- **Drag** without lifting: extends by cells. The pressed word stays whole: the drag is anchored on
  the word's far end. The loupe follows the moving edge. A light tick plays for each new row. Near
  the top or bottom edge the view scrolls a line every 60 ms while the finger stays there.
- **Lift**: the selection is copied (copy-on-select), a two-beat "success" haptic plays with the
  shimmer, two handles appear, and the edit menu (Copy, Paste, Select All) opens above the
  selection.
- **Handles**: drag either one to adjust. The loupe shows the edge being moved, rows tick, edges
  autoscroll. On release the adjusted selection is copied again and the menu returns. Dragging one
  handle past the other turns the selection around.
- **Double tap** selects a word, **triple tap** the line; both copy and show handles and menu.
- **Tap elsewhere** clears. A tap within 3 columns and 1 row of the cursor (terminal focused, no
  selection, no mouse-tracking program) shows Paste.
- Pointer (mouse, trackpad) drags select directly, with no loupe, handles or haptics.
- **Share…** is the edit menu's last item, after Select All, whenever there is a selection: the
  selection as plain text through the share sheet, formatted off the main thread, then cleared
  once the sheet is up ([terminal.md](terminal.md), Share).
- Without a selection nothing is drawn and no touch is intercepted.

## Why our own handles and not UITextInteraction

`UITextInteraction` and `UITextSelectionDisplayInteraction` need a `UITextInput` whose positions,
ranges and `selectionRects(for:)` describe the grid. The terminal view's `UITextInput`
(`GhosttyInputText.swift`) is a one-line shadow of what was typed, which input methods, dictation
and the space-bar trackpad need. One protocol can't serve both documents without the keyboard
reading and replacing terminal text. The system's recognizers would also compete with scrolling,
the pane swipe, pinch and mouse reporting, and `selectionRects` for Select All on a long
scrollback would be thousands of rects under the terminal lock. So the app keeps its own gestures
and uses only the system loupe (`UITextLoupeSession`), which needs no `UITextInput`.

The loupe magnifies what the compositor shows, so it works over the Metal layer with
`framebufferOnly = true` and frames presented from the render thread. Verified in the simulator,
not yet on a device. If it is blank on hardware, `-selectionLoupe off` turns it off; the fallback
would be a loupe drawn from the cell text (not built).

## Design

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
- `TerminalSelectionController` performs effects and owns one display link, which runs only while
  a selection is up and the pane is in a window.
- Point to cell and cell to rect come only from the terminal view (`gridCell(at:)`,
  `selectionEnds`, `selectionRects`), which uses `GhosttyGridGeometry`. Keep it the one mapping:
  a second point-to-cell conversion once ignored the scroll shift and highlighted the row above
  the finger.
- The selection is the terminal's tracked selection, so it stays on its text through output,
  scrolling and reflow. Handles follow on the next frame (`selectionGeometryStamp`); an end
  scrolled out of view has no handle.
- Handles: the knob sits off the text (above the row for the start, below for the end) with a
  24 pt hit radius at any font size or mirror zoom. Taking a handle keeps the offset between finger
  and cell, so the selection doesn't jump.
- In a program that tracks the mouse, long press and handles stay ours; a single tap is still the
  program's click, so the first tap of a double tap clicks.

### Haptics

| Event | When | Generator |
| --- | --- | --- |
| `start` | The long press highlights a word; or, after a press on blank space, the first cell the drag covers | `UIImpactFeedbackGenerator(style: .medium)` |
| `grab` | A handle is taken; a long press lands on blank space | `UIImpactFeedbackGenerator(style: .light)` |
| `tick` | The moving end enters another row (drag, handle drag, edge autoscroll). At most one per 60 ms | `UISelectionFeedbackGenerator` |
| `copy` | The selection went to the clipboard, with the shimmer | `UINotificationFeedbackGenerator` `.success` |

- The start is one firm beat and the copy is the two-beat success pattern, so they can't be confused.
- `prepare()` runs at every touch down, when the press is recognized, after every tick and on a
  grab, because a prepared generator stays ready only a few seconds.
- iOS's System Haptics setting mutes them; the app has no setting of its own.
- No per-word tick: at 10 pt a horizontal drag crosses a word every few points, and with row ticks
  it reads as a buzz.

### Decisions

- **Copy-on-select** fires on lift of the long press, and on release of a handle that moved its end
  to another cell. Double and triple taps copy at once. Select All never copies by itself (it can be
  the whole scrollback); Copy in the menu does.
- **Edge autoscroll**: the engine scrolls one line when asked with a point within half a cell of
  its edge. The controller widens that to 18 pt and repeats every 60 ms while the finger rests.
- **Taps are counted in the host's tap handler** (0.35 s, 28 pt), not by recognizers that wait for
  each other, so a single tap acts at once.
- **Edit menu**: Copy, Paste, Select All, above the selection when there is room. Hidden while a
  finger is on the selection.

### Performance

- No selection: no display link, no layers shown, and the overlay's `point(inside:)` returns false
  after one comparison. No recognizer was added to the scroll path.
- A drag event: three short `termLock` sections on the main thread, each bounded by one parser
  slice. Nothing is allocated per event.
- A standing selection: one read of the scroll state's lock per frame; the ends are re-read only
  when the scroll position changed, or every 0.1 s to notice a dropped selection.

## What the selection UI asks of the terminal view

In `Ghostty/GhosttyTerminalView+SelectionUI.swift`; the value types (`TerminalGridCell`,
`TerminalSelectionEnds`) are in `Selection/SelectionSeam.swift`.

| Member | For |
| --- | --- |
| `selectionEnds: TerminalSelectionEnds?` | Rects of the first and last selected cell; an end out of view is nil |
| `selectionGeometryStamp: Int` | Cheap "did the grid move" check, per frame |
| `beginSelectionAdjust(movingStart:) -> Bool` | Handle drags and the word-anchored drag |
| `selectLine(at:) -> Bool` | Triple tap |
| `gridCell(at:) -> TerminalGridCell?` | Row ticks, word bounds, the cursor menu |
| `cursorGridCell: TerminalGridCell?` | The cursor menu |
| `sendsTapsToProgram: Bool` | No cursor menu under mouse tracking |

Each hook in `TerminalHost.swift` is marked `SELECTION UI`. In `tapped()` the engine's link and
prompt taps (`TAP HOOK`) run first; a tap they used never reaches the selection UI.

## Debug launch arguments

- `-selectionDemo <steps>`: play a gesture on the first pane that comes on screen, for screenshots
  (`Selection/SelectionDemo.swift` lists the steps). `-selectionDemoDelay` and
  `-selectionDemoStep` set the timing. Example:
  `-replay /tmp/x.txt -replayFontSize 10 -focus none -selectionDemo "press:30,20;move:44,24;lift;grab:end;drag:50,28"`.
- `-selectionLoupe off`: no loupe.

## Open questions

1. The copy haptic plays on every lift and handle adjustment. If that is too much, a single
   `.rigid` impact is the alternative.
2. A double tap raises the keyboard when it was down (its first tap is a normal tap). Delaying the
   single tap by 0.35 s would avoid that and make every tap feel slower.
3. The Paste menu by the cursor can show when the tap was only meant to focus the prompt.
