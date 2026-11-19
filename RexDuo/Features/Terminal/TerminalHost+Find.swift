import UIKit

/// Find in one pane (docs/terminal.md, Find): the two bars over one model, who holds the keyboard,
/// and the fit hold. Made on first use; a pane that never searched has none.
@MainActor
final class PaneFind {
    let model = FindModel()
    let accessory = FindAccessoryBar()
    let overlay = FindOverlayBar()
    /// The overlay field's accessory in the fallback (`FindSpacer`).
    let spacer = FindSpacer()
    /// A drag on the overlay that starts nothing, so iOS 26's content swipe-back waits for it.
    let overlayPan = UIPanGestureRecognizer()
    var open = false
    /// Where the overlay floats (top only on the alternate screen).
    var edge = FindBarPlacement.Edge.bottom
    /// Who held the keyboard before the field took it: Done gives it back.
    var record = KeyboardRecord.none
    /// The grid fit mode keeps while the field holds the keyboard on a rising keyboard (path E).
    var hold: (cols: Int, rows: Int)?
    /// The pane's width when the hold was taken: another width ends it.
    var holdWidth: CGFloat = 0
    /// The field stopped editing while `FitHoldDeferral` was set: release when it clears.
    var releasePending = false
    /// The field held the keyboard when a cover came: it gets it back when the cover goes.
    var fieldHadKeyboard: FindFieldPlace?
    /// "Find…" from the pane menu: the field takes the keyboard once the menu is gone.
    var pendingFocus = false
    var pendingFocusRecord = KeyboardRecord.none
    /// When the overlay field last lost the keyboard (a fold resigns it before the move).
    var fieldLostKeyboardAt: CFTimeInterval = -1
    /// The overlay field had the keyboard when the pane's view moved.
    var movedWithField = false
    /// The overlay field may take the keyboard now (paths C and D); a tap on it otherwise hands
    /// the keyboard to the accessory field.
    var overlayFocusAllowed = false
    /// The current match lies under the keyboard on the alternate screen while the hold is on:
    /// the grid is lifted until the next step or the release.
    var liftsForMatch = false
    /// The next result follows a step or a needle change (the bar may change edge, the grid may lift).
    var userActed = false
    var debounce: DispatchWorkItem?
    var lastAnnounce: CFTimeInterval = 0
    /// The accessory field's find chords and the keymap generation they were made for.
    var commands: (generation: Int, list: [UIKeyCommand])?
}

/// Which keys the pane keeps while its find field edits. Pure.
enum FindKeys {
    /// Keys that edit text are the field's whatever they are bound to: arrows, Delete and forward
    /// Delete with any modifier, and ⌘Z, ⇧⌘Z, ⌘X, ⌘C, ⌘V, ⌘A.
    static func editsText(_ c: KeyChord) -> Bool {
        if ["left", "right", "up", "down", "backspace", "delete", "home", "end"].contains(c.key) { return true }
        if c.mods == .cmd, ["z", "x", "c", "v", "a"].contains(c.key) { return true }
        if c.mods == [.shift, .cmd], c.key == "z" { return true }
        return false
    }

    /// An allowlist: app commands and the find keys stay; everything a pane does with its
    /// terminal (send a key, copy, paste, scroll, a server action, a forwarded key) goes, and so
    /// does any action added later unless it is added here on purpose.
    static func keepsWhileEditing(action: AppAction, chord: KeyChord) -> Bool {
        guard !editsText(chord) else { return false }
        if case .command = action { return true }
        return false
    }
}

/// Which of the pane's two find fields.
enum FindFieldPlace: Equatable {
    case accessory, overlay
}

extension TerminalHost: FindBarOwner {
    /// The hand-over in use (`FindHandover`).
    static var findUsesSpacer: Bool { FindHandover.current == .spacer }

    // MARK: State

    /// The pane's find field that holds the keyboard, if one does.
    var findFieldHoldingKeyboard: FindFieldPlace? {
        guard let f = finder else { return nil }
        if f.accessory.content.field.isFirstResponder { return .accessory }
        if f.overlay.content.field.isFirstResponder { return .overlay }
        return nil
    }

    var findOpen: Bool { finder?.open ?? false }

    /// The pane's own find fields: the focus policy counts them as the pane's.
    var ownFindFields: [UIView] {
        guard let f = finder else { return [] }
        return [f.accessory.content.field, f.overlay.content.field]
    }

    private func makeFinder() -> PaneFind {
        if let f = finder { return f }
        let f = PaneFind()
        for bar in [f.accessory.content, f.overlay.content] {
            bar.owner = self
            bar.apply(theme: theme)
            f.model.attach(bar)
        }
        f.accessory.barEdge = keyBar.barEdge
        f.accessory.crease = keyBar.crease
        f.overlay.isHidden = true
        f.overlayPan.cancelsTouchesInView = false
        f.overlayPan.addTarget(self, action: #selector(overlayPanned))
        f.overlay.addGestureRecognizer(f.overlayPan)
        // Under the selection's loupe and handles and the status chip.
        insertFindOverlay(f.overlay)
        finder = f
        term.findHook = { [weak self] r in self?.findResultArrived(r) }
        yieldContentSwipeBack()
        f.accessory.content.field.findCommands = { [weak self] in self?.accessoryFindCommands() ?? [] }
        f.accessory.content.field.findAction = { [weak self] chord in self?.keymap?.resolve([chord])?.1 }
        return f
    }

    @objc private func overlayPanned() {}

    /// The accessory field's find chords, made again when the keymap changes.
    private func accessoryFindCommands() -> [UIKeyCommand] {
        guard let f = finder else { return [] }
        let generation = keymap?.generation ?? -1
        if let c = f.commands, c.generation == generation { return c.list }
        let list = findKeyCommands()
        f.commands = (generation, list)
        return list
    }

    /// The keymap's chords for the find actions, for a field in the keyboard's window.
    private func findKeyCommands() -> [UIKeyCommand] {
        let bindings = keymap?.bindings ?? KeyDefaults.resolved
        var decided = Set<KeyChord>()
        var out: [UIKeyCommand] = []
        for b in bindings where b.chord.mods.contains(.cmd) && !decided.contains(b.chord) {
            guard let action = AppAction.resolve(b.action, b.args) else { continue }
            decided.insert(b.chord)
            // The find keys; with the menu-route fallback on, every app command too.
            let carried: Bool
            if case .command(.find) = action {
                carried = true
            } else if case .command = action {
                carried = FindHandover.fieldCarriesCommands && !FindKeys.editsText(b.chord)
            } else {
                carried = false
            }
            guard carried, let input = KeyInput.commandInput(b.chord) else { continue }
            let cmd = UIKeyCommand(title: KeyActions.title(b), action: #selector(FindField.findChordFired(_:)), input: input,
                                   modifierFlags: KeyInput.flags(b.chord.mods), propertyList: b.chord.spelling)
            cmd.wantsPriorityOverSystemBehavior = true
            out.append(cmd)
        }
        return out
    }

    // MARK: Entry points

    /// A find key (⌘F, ⌘G, ⇧⌘G), from this pane's keys, the app menu or another client.
    func performFind(_ step: FindStep) {
        guard !covered else { return }
        switch step {
        case .open:
            if let place = findFieldHoldingKeyboard {
                // ⌘F while the field edits selects its text, from any route.
                selectAll(field(place))
            } else {
                openFind(text: nil, focus: true)
            }
        case .next, .previous:
            // With find closed, as before: nothing.
            guard findOpen else { return }
            stepFind(step == .next ? 1 : -1)
        }
    }

    /// "Find…" from the pane menu: the field takes the keyboard once the menu has gone
    /// (`coverChanged(covered: false)`), instead of the terminal's usual reclaim.
    func findFromMenu() {
        onFocus?()
        if tintAdjustmentMode == .dimmed || resignedUnderCover {
            let f = makeFinder()
            f.pendingFocus = true
            f.pendingFocusRecord = resignedUnderCover ? (keyboardQuiet ? .quiet : .shown) : .none
            resignedUnderCover = false
            openFind(text: nil, focus: false)
        } else {
            openFind(text: nil, focus: true)
        }
    }

    /// Opens find with `text` (nil: the last needle used in any pane), selected.
    func openFind(text: String?, focus: Bool) {
        let f = makeFinder()
        if !f.open {
            f.open = true
            f.edge = alternateScreen ? .top : .bottom
            term.openFind()
        }
        let t = text ?? FindModel.lastText
        f.model.setText(t, from: nil)
        FindModel.lastText = t
        search(t, at: 0)
        if focus { focusFindField() }
        if let place = findFieldHoldingKeyboard { selectAll(field(place)) }
        layoutFind()
    }

    /// Closes find. `giveBack`: the keyboard goes back to whoever had it before the field took it.
    func closeFind(giveBack: Bool = true) {
        guard let f = finder, f.open else { return }
        let holding = findFieldHoldingKeyboard
        f.open = false
        f.debounce?.cancel()
        f.debounce = nil
        f.pendingFocus = false
        // A hand-over still waiting for the bar to show must not run after the close.
        f.accessory.cancelWhenShown()
        if term.inputAccessoryView === f.accessory {
            term.inputAccessoryView = keyboardQuiet ? nil : keyBar
            if term.isFirstResponder { term.reloadInputViews() }
        }
        f.fieldHadKeyboard = nil
        term.closeFind()
        f.model.setResult(FindResult())
        releaseFitHold(deferrable: false)
        if holding != nil {
            if giveBack {
                retakeKeyboard(f.record)
            }
            resignFindField()
        }
        f.overlay.isHidden = true
        layoutFind()
    }

    private func field(_ place: FindFieldPlace) -> FindField {
        place == .accessory ? finder!.accessory.content.field : finder!.overlay.content.field
    }

    private func selectAll(_ field: FindField) {
        field.selectedTextRange = field.textRange(from: field.beginningOfDocument, to: field.endOfDocument)
    }

    // MARK: Who holds the keyboard

    /// Gives the keyboard to the find field, the way that changes nothing about the keyboard:
    /// - shown (software keyboard or the key bar, paths A and B): the accessory field, handed
    ///   over inside the displayed accessory slot;
    /// - quiet (paths C and D): the overlay field, with the same empty input views;
    /// - down, without a hardware keyboard (path E): the keyboard rises as a tap's does, with the
    ///   fit hold taken first so no layout during the rise asks for a smaller grid.
    func focusFindField() {
        guard let f = finder, f.open, findFieldHoldingKeyboard == nil, !covered else { return }
        f.record = KeyboardRecord.capture(self)
        let responder = UIResponder.rexCurrentFirstResponder()
        let quiet: Bool
        let shown: Bool
        if let t = responder as? GhosttyTerminalView {
            quiet = t.inputView != nil
            shown = !quiet
        } else if let other = responder as? FindField {
            quiet = other.inputView != nil
            shown = !quiet
        } else {
            quiet = hardwareKeyboard()
            shown = false
        }
        if !quiet, Self.findUsesSpacer {
            // The fallback: the overlay field, with the system keyboard and an empty accessory of
            // the key bar's height, so the keyboard keeps its frame.
            if !shown { takeFitHold() }
            let field = f.overlay.content.field
            field.inputView = nil
            field.inputAccessoryView = f.spacer
            f.overlayFocusAllowed = true
            let took = field.becomeFirstResponder()
            f.overlayFocusAllowed = false
            if !took { releaseFitHold(deferrable: false) }
        } else if quiet {
            // Paths C and D: the overlay field with the terminal's quiet input views.
            let field = f.overlay.content.field
            field.inputView = quietInputView
            field.inputAccessoryView = nil
            f.overlayFocusAllowed = true
            _ = field.becomeFirstResponder()
            f.overlayFocusAllowed = false
        } else {
            // Paths A, B and E. The hold first, in this turn, so no layout during a rising
            // keyboard asks for a smaller grid. Then the terminal shows the find bar in its
            // accessory slot (the same height as the key bar), and once the bar is in the
            // keyboard's window its field takes the keyboard from the terminal, which holds it
            // until then: no moment without a first responder.
            if !shown { takeFitHold() }
            setKeyboardQuiet(false)
            term.inputAccessoryView = f.accessory
            if term.isFirstResponder {
                term.reloadInputViews()
            } else {
                _ = term.becomeFirstResponder()
            }
            f.accessory.whenShown { [weak self] in self?.accessoryFieldTakesKeyboard() }
        }
        layoutFind()
    }

    /// Step 2 of the hand-over: the accessory field takes the keyboard inside the displayed slot,
    /// with the terminal's input view, and the key bar is the terminal's accessory again at once
    /// (no reload): whatever gives the terminal the keyboard next shows it.
    private func accessoryFieldTakesKeyboard() {
        guard let f = finder, f.open, term.isFirstResponder, term.inputAccessoryView === f.accessory else {
            if let f = finder, term.inputAccessoryView === f.accessory {
                term.inputAccessoryView = keyBar
                if term.isFirstResponder { term.reloadInputViews() }
            }
            // The field never took the keyboard: no hold may outlive the hand-over.
            releaseFitHold(deferrable: false)
            return
        }
        let field = f.accessory.content.field
        field.inputView = term.inputView
        field.inputAccessoryView = FindHandover.fieldAccessoryNil ? nil : f.accessory
        let took = field.becomeFirstResponder()
        term.inputAccessoryView = keyBar
        if !took || !field.isFirstResponder {
            field.inputAccessoryView = nil
            term.reloadInputViews()
            releaseFitHold(deferrable: false)
        }
        layoutFind()
    }

    /// The field gives the keyboard up to nobody (Done after path E, a pane switch).
    func resignFindField() {
        guard let f = finder else { return }
        for field in [f.accessory.content.field, f.overlay.content.field] where field.isFirstResponder {
            _ = field.resignFirstResponder()
        }
    }

    /// The terminal takes the keyboard from the field: Escape with text. Quiet if the field had
    /// the quiet input views (paths C and D).
    private func returnToTerminal(from field: FindField) {
        setKeyboardQuiet(field.inputView != nil)
        _ = term.becomeFirstResponder()
    }

    /// The terminal lost the keyboard while the field's hand-over waited for the bar to show (a
    /// cover, a pane switch, the app going away): the hand-over is off, and so is the hold.
    func findHandOverAbandoned() {
        guard let f = finder, f.accessory.handOverPending, findFieldHoldingKeyboard == nil else { return }
        f.accessory.cancelWhenShown()
        if term.inputAccessoryView === f.accessory { term.inputAccessoryView = keyboardQuiet ? nil : keyBar }
        releaseFitHold(deferrable: false)
    }

    /// The pane is no longer active: a field of its own that still holds the keyboard gives it up.
    func resignFindFieldIfInactive() {
        guard !isActive, findFieldHoldingKeyboard != nil else { return }
        resignFindField()
    }

    /// A cover (sheet, alert, menu, the agent board) came while the field held the keyboard.
    func findFieldCovered() -> Bool {
        guard let f = finder, let place = findFieldHoldingKeyboard else { return false }
        f.fieldHadKeyboard = place
        resignFindField()
        return true
    }

    /// The cover went: the field that had the keyboard gets it back, or the menu's "Find…" focuses
    /// it. True when find took the keyboard (the terminal's reclaim is skipped).
    func findRetakesAfterCover() -> Bool {
        guard let f = finder, f.open else { return false }
        if f.pendingFocus {
            f.pendingFocus = false
            let record = f.pendingFocusRecord
            DispatchQueue.main.async { [weak self] in
                guard let self, let f = self.finder, f.open else { return }
                self.focusAfterCover(record)
            }
            return true
        }
        if let place = f.fieldHadKeyboard {
            f.fieldHadKeyboard = nil
            let record: KeyboardRecord = place == .overlay ? .quiet : .shown
            DispatchQueue.main.async { [weak self] in
                guard let self, let f = self.finder, f.open else { return }
                self.focusAfterCover(record)
            }
            return true
        }
        return false
    }

    /// The terminal's keyboard comes back as it was before the cover, and the field takes it in
    /// the same turn: the frames are today's dismissal.
    private func focusAfterCover(_ record: KeyboardRecord) {
        guard let f = finder, !covered, window != nil, findFieldHoldingKeyboard == nil else { return }
        switch record {
        case .quiet:
            setKeyboardQuiet(true)
            _ = term.becomeFirstResponder()
        case .shown:
            setKeyboardQuiet(false)
            _ = term.becomeFirstResponder()
        case .none, .ownFindField:
            break
        }
        focusFindField()
        f.record = record
    }

    /// After a move (fold, unfold), an overlay field that had the keyboard takes it back.
    func findRetakesAfterMove() -> Bool {
        guard let f = finder, f.open, f.movedWithField else { return false }
        f.movedWithField = false
        let field = f.overlay.content.field
        field.inputView = quietInputView
        field.inputAccessoryView = nil
        f.overlayFocusAllowed = true
        _ = field.becomeFirstResponder()
        f.overlayFocusAllowed = false
        return true
    }

    /// Before the pane's view moves: an overlay field resigned in this turn counts as holding.
    func noteFindFieldBeforeMove(now: CFTimeInterval) -> Bool {
        guard let f = finder else { return false }
        let held = f.overlay.content.field.isFirstResponder || now - f.fieldLostKeyboardAt < 0.05
        f.movedWithField = held
        return held
    }

    // MARK: The fit hold

    /// Fit mode keeps the newest grid it asked for while the keyboard rises for the field.
    private func takeFitHold() {
        guard let f = finder, fitted, f.hold == nil, let wanted = claimWanted else { return }
        f.hold = wanted
        f.holdWidth = bounds.width
    }

    /// The grid fit mode keeps now, if a hold is on.
    var findHold: (cols: Int, rows: Int)? { finder?.hold }

    /// A new width ends the hold: the grid that fits is another one. Called from layout.
    func releaseFitHoldIfWidthChanged() {
        guard let f = finder, f.hold != nil, abs(f.holdWidth - bounds.width) > 0.5 else { return }
        releaseFitHold(deferrable: false)
    }

    /// Ends the hold at once and lays out for the size that fits now. `deferrable`: the field
    /// stopped editing (a palette may be taking over, `FitHoldDeferral`).
    func releaseFitHold(deferrable: Bool) {
        guard let f = finder, f.hold != nil else { return }
        if deferrable, FitHoldDeferral.isSet(in: window) {
            f.releasePending = true
            return
        }
        f.hold = nil
        f.releasePending = false
        f.liftsForMatch = false
        relayoutAfterHold()
    }

    @objc func fitHoldDeferralCleared(_ n: Notification) {
        guard let f = finder, f.releasePending, (n.object as? UIWindow) === window else { return }
        f.releasePending = false
        // The palette gave the keyboard back to the field: the hold stays.
        if findFieldHoldingKeyboard != nil { return }
        releaseFitHold(deferrable: false)
    }

    // MARK: Searching

    private func search(_ text: String, at delay: TimeInterval) {
        guard let f = finder else { return }
        f.debounce?.cancel()
        let needle = FindQuery.sanitize(text)
        let work = DispatchWorkItem { [weak self] in
            guard let self, let f = self.finder, f.open else { return }
            f.userActed = true
            self.term.setFindNeedle(needle)
        }
        f.debounce = work
        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        } else {
            work.perform()
        }
    }

    private func stepFind(_ by: Int) {
        guard let f = finder, f.open else { return }
        // A short needle still waiting for its delay is searched now.
        if let pending = f.debounce, !pending.isCancelled {
            pending.perform()
            pending.cancel()
        }
        f.userActed = true
        term.stepFind(by)
    }

    private func findResultArrived(_ r: FindResult) {
        guard let f = finder, f.open else { return }
        f.model.setResult(r)
        guard f.userActed, r.open else { return }
        f.userActed = false
        // The bar changes edge only on the alternate screen, and only for the user.
        let cell = term.cellSize.height
        var rows: ClosedRange<CGFloat>?
        if let s = r.selected, cell > 0 {
            let snap = term.scrollSnapshot
            let viewTop = snap.active ? snap.maxRow : min(snap.offset, snap.maxRow)
            rows = CGFloat(s.startRow - viewTop) * cell...CGFloat(s.endRow - viewTop + 1) * cell
        }
        let edge = FindBarPlacement.edge(alternateScreen: alternateScreen, current: f.edge,
                                         barHeight: FindOverlayBar.height(compact: f.overlay.compact),
                                         paneHeight: bounds.height, safeTop: safeAreaInsets.top, matchRows: rows, flip: true)
        if edge != f.edge {
            f.edge = edge
            layoutFind()
        }
        // On the alternate screen under the hold, a match under the keyboard lifts the grid.
        if f.hold != nil, alternateScreen {
            let lifts = rows.map { $0.upperBound > bounds.height } ?? false
            if lifts != f.liftsForMatch {
                f.liftsForMatch = lifts
                positionTermForFind()
            }
        }
        announce(r)
    }

    private func announce(_ r: FindResult) {
        guard UIAccessibility.isVoiceOverRunning, let f = finder, let text = FindQuery.spokenCount(r) else { return }
        let now = CACurrentMediaTime()
        guard now - f.lastAnnounce >= 1 else { return }
        f.lastAnnounce = now
        UIAccessibility.post(notification: .announcement, argument: text)
    }

    // MARK: Layout

    /// Places the overlay, the find inset and the jump button. Called from `layoutSubviews` too.
    func layoutFind() {
        guard let f = finder else { return }
        let shows = f.open && !covered && findFieldHoldingKeyboard != .accessory
        if f.overlay.isHidden == shows { f.overlay.isHidden = !shows }
        guard shows else {
            term.setFindInset(0)
            placeJumpButton()
            return
        }
        f.overlay.compact = traitCollection.verticalSizeClass == .compact
        let h = FindOverlayBar.height(compact: f.overlay.compact)
        let creaseSpan = findCreaseSpan()
        let frame = FindBarPlacement.frame(bounds: bounds, safeTop: safeAreaInsets.top, safeBottom: safeAreaInsets.bottom,
                                           edge: alternateScreen ? f.edge : .bottom, barHeight: h,
                                           chipShown: !statusChipHidden, crease: creaseSpan)
        if f.overlay.frame != frame { f.overlay.frame = frame }
        let gridBottom = fitted ? nil : term.frame.maxY * zoomScale - zoomOffsetY
        let inset = FindBarPlacement.findInset(bar: frame, edge: alternateScreen ? f.edge : .bottom, paneHeight: bounds.height,
                                               alternateScreen: alternateScreen, zoom: fitted ? 1 : zoomScale,
                                               gridBottom: gridBottom)
        term.setFindInset(inset)
        placeJumpButton()
    }

    /// The overlay's frame while it shows at the bottom, for the jump button.
    var findBottomBarFrame: CGRect? {
        guard let f = finder, f.open, !f.overlay.isHidden, !alternateScreen || f.edge == .bottom else { return nil }
        return f.overlay.frame
    }

    /// A vertical crease across the pane, in the pane's coordinates.
    private func findCreaseSpan() -> ClosedRange<CGFloat>? {
        guard let crease = keyBar.crease, let w = window, let screen = w.windowScene?.screen else { return nil }
        let r = convert(w.convert(crease, to: screen.coordinateSpace), from: screen.coordinateSpace)
        guard r.maxX > bounds.minX, r.minX < bounds.maxX else { return nil }
        return r.minX...r.maxX
    }

    func applyFindTheme(_ t: TermTheme) {
        guard let f = finder else { return }
        f.accessory.content.apply(theme: t)
        f.overlay.content.apply(theme: t)
    }

    func setFindSurroundings(barEdge: NSDirectionalRectEdge?, crease: CGRect?) {
        guard let f = finder else { return }
        f.accessory.barEdge = barEdge
        f.accessory.crease = crease
    }

    /// The overlay field had the keyboard quietly as a cover comes: the terminal takes it back,
    /// quiet as before, and the field's text stays.
    func yieldOverlayFieldToTerminal() {
        setKeyboardQuiet(true)
        _ = term.becomeFirstResponder()
    }

    // MARK: FindBarOwner

    func findBarTouched(_ bar: FindBarContent) {
        // The pane becomes the active one first, so ⌘G then acts on it.
        onFocus?()
    }

    func findBarShouldEdit(_ bar: FindBarContent) -> Bool {
        guard let f = finder, f.open else { return false }
        if bar === f.accessory.content { return true }
        if f.overlayFocusAllowed { return true }
        // A tap on the overlay's field: focus the pane, then hand the keyboard to the field the
        // way the keyboard's state allows (the accessory field on paths A, B and E).
        onFocus?()
        focusFindField()
        return false
    }

    func findBarBeganEditing(_ bar: FindBarContent) {
        guard let f = finder else { return }
        if bar === f.accessory.content {
            // The key bar is the terminal's accessory again, unless it is quiet.
            term.inputAccessoryView = keyboardQuiet ? nil : keyBar
        }
        layoutFind()
    }

    func findBarEndedEditing(_ bar: FindBarContent) {
        guard let f = finder else { return }
        // The accessory field's accessory is its own bar: let go of it, or the two keep each other.
        if bar === f.accessory.content { bar.field.inputAccessoryView = nil }
        if bar === f.overlay.content { f.fieldLostKeyboardAt = CACurrentMediaTime() }
        // Whatever took the field's keyboard (the terminal, Escape, Done, another pane, a cover,
        // the board, a fold): the hold ends now, with no wait on a keyboard notification.
        if findFieldHoldingKeyboard == nil { releaseFitHold(deferrable: true) }
        layoutFind()
        // The terminal took the keyboard back with the same input views. UIKit lays the window
        // out 2 pt off after that hand-back (iOS 27.2 simulator: the tab moves up 2 pt until the
        // next keyboard change); one more reload of the same views, a turn later, puts it right.
        // It posts one more, identical, end frame.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.term.isFirstResponder, !self.keyboardQuiet else { return }
            self.term.reloadInputViews()
        }
    }

    func findBar(_ bar: FindBarContent, changed text: String, committed: Bool) {
        guard let f = finder else { return }
        f.model.setText(text, from: bar)
        // Marked text (an input method composing) isn't searched.
        guard committed else { return }
        FindModel.lastText = text
        search(text, at: FindQuery.delay(for: text))
    }

    func findBarReturn(_ bar: FindBarContent) { stepFind(1) }

    func findBar(_ bar: FindBarContent, step: Int) { stepFind(step) }

    func findBarDone(_ bar: FindBarContent) { closeFind() }

    func findFieldShiftReturn(_ field: FindField) { stepFind(-1) }

    func findFieldEscape(_ field: FindField) {
        guard finder != nil else { return }
        if (field.text ?? "").isEmpty {
            closeFind()
        } else {
            returnToTerminal(from: field)
        }
    }

    func findField(_ field: FindField, perform action: AppAction) {
        switch action {
        case .command(.find(let step)): performFind(step)
        // The menu-route fallback (`FindHandover.fieldCarriesCommands`): app commands from the
        // field run in the field's pane.
        case .command(let c): onCommand?(c)
        default: break
        }
    }
}
