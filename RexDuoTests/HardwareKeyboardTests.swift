import Testing
import SwiftUI
import UIKit
import RexKit
@testable import RexDuo

// Hardware keyboard: which binding a press runs on any layout, who holds the keyboard, and what
// Toggle Sidebar does in each arrangement. Presses are `KeyInput.Press` values, since a `UIKey`
// can't be made; the one test that needs a real `UIKey` builds it through the Objective-C runtime.

private typealias Press = KeyInput.Press

private let cmd: UIKeyModifierFlags = .command
private let shiftCmd: UIKeyModifierFlags = [.command, .shift]

// HID usages.
private let keyA = 4, key7 = 36, keyMinus = 45, keySemicolon = 51, keySlash = 56

@MainActor
private func store(_ extra: [(String, String, JSONObject?)] = [], dropping: Set<String> = []) -> KeymapStore {
    let s = KeymapStore(control: RexControl(address: "", client: ClientInfo(name: "test", version: "0", label: "test")))
    guard !extra.isEmpty || !dropping.isEmpty else { return s }
    // As `client.keymap` answers: the config file's bindings on top, then the defaults the app sent.
    var list: [JSONObject] = extra.map { k, a, args in
        var o: JSONObject = ["keys": [k], "action": a, "source": "config"]
        if let args { o["args"] = args }
        return o
    }
    for (k, a, args) in KeyDefaults.layer.reversed() where !dropping.contains(k) {
        var o: JSONObject = ["keys": [k], "action": a, "source": "default"]
        if let args { o["args"] = args }
        list.append(o)
    }
    s.apply(KeymapStore.bindings(in: ["bindings": list]))
    return s
}

@MainActor
private func command(_ s: KeymapStore, _ p: Press) -> RexCommand? {
    guard case .command(let c)? = s.resolve(tiers: KeyInput.chordTiers(p))?.1 else { return nil }
    return c
}

@MainActor
struct ToggleSidebarKeyTests {
    private let usSlash = Press(usage: keySlash, flags: cmd, characters: "/", charactersIgnoringModifiers: "/")

    @Test func theDefaultKeymapTogglesTheSidebarOnCmdSlash() {
        #expect(command(store(), usSlash) == .toggleSidebar)
    }

    @Test func aServerKeymapLayeredOnTheDefaultsKeepsIt() {
        // The owner's config binds other keys (`rex keymap`): the default on cmd+/ stays.
        let s = store([("cmd+k", "session.switch", nil), ("shift+enter", "pane.send_key", ["key": "ctrl+j"])])
        #expect(command(s, usSlash) == .toggleSidebar)
    }

    @Test func aServerBindingOnCmdSlashWinsOverTheDefault() {
        #expect(command(store([("cmd+/", "client.tab.new", nil)]), usSlash) == .newTab)
    }

    @Test func aBindingTheAppCannotPerformFallsThroughToTheDefault() {
        #expect(command(store([("cmd+/", "client.find", nil)]), usSlash) == .toggleSidebar)
    }

    @Test func aKeymapWithoutTheBindingLeavesTheKeyToTheTerminal() {
        #expect(store(dropping: ["cmd+/"]).resolve(tiers: KeyInput.chordTiers(usSlash)) == nil)
    }

    @Test func everyDefaultKeyRunsSomethingAfterTheServerLayersItsOwn() {
        let s = store([("cmd+k", "session.switch", nil)])
        for (spelling, _, _) in KeyDefaults.layer {
            guard let chord = KeyChord(spelling: spelling) else {
                Issue.record("\(spelling) doesn't parse")
                continue
            }
            #expect(s.resolve([chord]) != nil, "\(spelling)")
        }
    }
}

/// Layouts where the character a binding names isn't where a US keyboard has it.
@MainActor
struct KeyboardLayoutTests {
    @Test func usLayout() {
        let s = store()
        #expect(command(s, Press(usage: keySlash, flags: cmd, characters: "/", charactersIgnoringModifiers: "/")) == .toggleSidebar)
        #expect(command(s, Press(usage: keyMinus, flags: cmd, characters: "-", charactersIgnoringModifiers: "-")) == .fontSmaller)
        // Shift + a digit types a symbol no default names: the physical binding still runs.
        #expect(command(s, Press(usage: 30, flags: cmd, characters: "1", charactersIgnoringModifiers: "1")) == .goToTab(1))
    }

    @Test(arguments: ["Spanish ISO", "German"])
    func slashIsShiftSevenOnSpanishAndGermanKeyboards(layout: String) {
        // The press arrives as shift+cmd+7; what it types is "/".
        let p = Press(usage: key7, flags: shiftCmd, characters: "/", charactersIgnoringModifiers: "7")
        #expect(KeyInput.chordTiers(p).map { $0.map(\.spelling) } == [["shift+cmd+7", "shift+cmd+[Digit7]"], ["cmd+/"]], "\(layout)")
        #expect(command(store(), p) == .toggleSidebar, "\(layout)")
    }

    @Test func theKeyAtTheUSSlashPositionRunsWhatItTypes() {
        // Spanish and German: that key types "-". The character wins, as on the Mac.
        let p = Press(usage: keySlash, flags: cmd, characters: "-", charactersIgnoringModifiers: "-")
        #expect(command(store(), p) == .fontSmaller)
    }

    @Test func aBindingThatNamesThePressBeatsTheCharacterItTypes() {
        // shift+cmd+7 is bound: on a Spanish keyboard it must not become cmd+/.
        let s = store([("shift+cmd+7", "client.tab.new", nil)])
        let p = Press(usage: key7, flags: shiftCmd, characters: "/", charactersIgnoringModifiers: "7")
        #expect(command(s, p) == .newTab)
        // And a binding on the physical key beats both later tiers.
        let physical = store([("shift+cmd+[Digit7]", "client.tab.close", nil)])
        #expect(command(physical, p) == .closeTab)
    }

    @Test func aKeyThatTypesNothingABindingCanNameFallsBackToItsPosition() {
        // Spanish: the key at US ";" types "ñ".
        let s = store([("cmd+;", "client.tab.new", nil)])
        let p = Press(usage: keySemicolon, flags: cmd, characters: "ñ", charactersIgnoringModifiers: "ñ")
        #expect(KeyInput.chordTiers(p).map { $0.map(\.spelling) } == [["cmd+ñ", "cmd+[Semicolon]"], ["cmd+;"]])
        #expect(command(s, p) == .newTab)
        // A binding on what it types still comes first.
        #expect(command(store([("cmd+ñ", "client.tab.close", nil), ("cmd+;", "client.tab.new", nil)]), p) == .closeTab)
    }

    @Test func aKeyThatTypesAnASCIICharacterNeverFallsBackToItsPosition() {
        // AZERTY: the key at US "a" types "q". cmd+Q must not run cmd+A's binding.
        let s = store([("cmd+a", "client.tab.new", nil)])
        let p = Press(usage: keyA, flags: cmd, characters: "q", charactersIgnoringModifiers: "q")
        #expect(KeyInput.chordTiers(p).count == 1)
        #expect(s.resolve(tiers: KeyInput.chordTiers(p)) == nil)
    }

    @Test func shiftedLettersAndNamedKeysGetNoExtraTier() {
        #expect(KeyInput.chordTiers(Press(usage: 7, flags: shiftCmd, characters: "D", charactersIgnoringModifiers: "d")).count == 1)
        #expect(KeyInput.chordTiers(Press(usage: 40, flags: shiftCmd, characters: "\r", charactersIgnoringModifiers: "\r")).count == 1)
        // US shift+cmd+/ types "?": tried as cmd+? only after shift+cmd+/ itself.
        let q = KeyInput.chordTiers(Press(usage: keySlash, flags: shiftCmd, characters: "?", charactersIgnoringModifiers: "/"))
        #expect(q.map { $0.map(\.spelling) } == [["shift+cmd+/", "shift+cmd+[Slash]"], ["cmd+?"]])
    }
}

@MainActor
struct KeyboardFocusPolicyTests {
    private typealias S = KeyboardFocusPolicy.Situation

    @Test func withAHardwareKeyboardTheActivePaneTakesAFreeKeyboard() {
        #expect(KeyboardFocusPolicy.takesKeyboard(S(hardwareKeyboard: true)))
        // Something that types nothing (a SwiftUI hosting view) doesn't keep it from the pane.
        #expect(KeyboardFocusPolicy.takesKeyboard(S(hardwareKeyboard: true, holder: .other)))
    }

    @Test func withoutOneThePaneStaysDownUnlessItHadTheKeyboard() {
        #expect(!KeyboardFocusPolicy.takesKeyboard(S()))
        // A fold or unfold moved the pane while it had the keyboard.
        #expect(KeyboardFocusPolicy.takesKeyboard(S(hadKeyboard: true)))
    }

    @Test func theKeyboardFollowsTheActivePane() {
        // Another pane's terminal has it: the newly active pane takes it, hardware keyboard or not.
        #expect(KeyboardFocusPolicy.takesKeyboard(S(holder: .terminal)))
        #expect(KeyboardFocusPolicy.takesKeyboard(S(hardwareKeyboard: true, holder: .terminal)))
        #expect(!KeyboardFocusPolicy.takesKeyboard(S(paneActive: false, hardwareKeyboard: true, holder: .terminal)))
    }

    @Test(arguments: [
        S(paneActive: false, hardwareKeyboard: true),
        S(inWindow: false, hardwareKeyboard: true),
        S(appActive: false, hardwareKeyboard: true),
        S(holdsKeyboard: true, hardwareKeyboard: true),
        // A text field is being edited (Settings, a rename field).
        S(hardwareKeyboard: true, holder: .textInput),
        S(hadKeyboard: true, holder: .textInput),
        // A sheet or an alert is up.
        S(hardwareKeyboard: true, sheetUp: true),
        S(hardwareKeyboard: true, sheetUp: true, holder: .terminal),
        // The user put the software keyboard away with the key bar's hide key, and there is no
        // hardware keyboard: a fold or a freed keyboard doesn't bring it back.
        S(hadKeyboard: true, userHidKeyboard: true),
        S(userHidKeyboard: true),
        S(hadKeyboard: true, userHidKeyboard: true, holder: .other),
        // A text field keeps the keyboard from a pane that hid its own, too.
        S(hardwareKeyboard: true, userHidKeyboard: true, holder: .textInput),
        S(hardwareKeyboard: true, userHidKeyboard: true, sheetUp: true),
    ])
    func neverOtherwise(s: KeyboardFocusPolicy.Situation) {
        #expect(!KeyboardFocusPolicy.takesKeyboard(s))
    }

    @Test func aHiddenKeyboardNeverLeavesTheKeysWithAnotherPane() {
        // The reviewed defect: pane B hid its keyboard, pane A has it, B becomes active. B
        // refused the keyboard, so a hardware keyboard went on typing into A.
        let hiddenThere = S(hardwareKeyboard: true, userHidKeyboard: true, holder: .terminal)
        #expect(KeyboardFocusPolicy.takesKeyboard(hiddenThere))
        #expect(KeyboardFocusPolicy.takesQuietly(hiddenThere))
        // Without a hardware keyboard the keyboard still leaves the pane that isn't active.
        #expect(KeyboardFocusPolicy.takesKeyboard(S(userHidKeyboard: true, holder: .terminal)))
        // A free keyboard: hardware keys go to the active pane, hidden or not.
        #expect(KeyboardFocusPolicy.takesKeyboard(S(hardwareKeyboard: true, userHidKeyboard: true)))
        #expect(KeyboardFocusPolicy.takesKeyboard(S(hardwareKeyboard: true, userHidKeyboard: true, holder: .other)))
        // Quietly only where the user hid it.
        #expect(!KeyboardFocusPolicy.takesQuietly(S(hardwareKeyboard: true, holder: .terminal)))
        #expect(!KeyboardFocusPolicy.takesQuietly(S(hardwareKeyboard: true)))
    }

    @Test func aPaneThatIsNotActiveMustGiveTheKeyboardUp() {
        #expect(KeyboardFocusPolicy.mustResign(paneActive: false, holdsKeyboard: true))
        #expect(!KeyboardFocusPolicy.mustResign(paneActive: true, holdsKeyboard: true))
        #expect(!KeyboardFocusPolicy.mustResign(paneActive: false, holdsKeyboard: false))
        #expect(!KeyboardFocusPolicy.mustResign(paneActive: true, holdsKeyboard: false))
    }

    @Test func aSheetOnItsWayOutNoLongerCovers() {
        #expect(!KeyboardFocusPolicy.sheetUp(in: nil))
        #expect(!KeyboardFocusPolicy.sheetUp(in: UIWindow(frame: .zero)))
    }

    @Test func classifiesTheFirstResponder() {
        let term = GhosttyTerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 240), fontSize: 12, cols: 40, rows: 10)
        let other = GhosttyTerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 240), fontSize: 12, cols: 40, rows: 10)
        #expect(KeyboardFocusPolicy.holder(nil, own: term) == .nobody)
        #expect(KeyboardFocusPolicy.holder(term, own: term) == .nobody)
        #expect(KeyboardFocusPolicy.holder(other, own: term) == .terminal)
        #expect(KeyboardFocusPolicy.holder(UITextField(), own: term) == .textInput)
        #expect(KeyboardFocusPolicy.holder(UITextView(), own: term) == .textInput)
        #expect(KeyboardFocusPolicy.holder(UIViewController(), own: term) == .other)
        #expect(KeyboardFocusPolicy.holder(UIView(), own: term) == .other)
    }

    @Test func appShortcutsStayOutOfTextFieldsAndSheets() {
        #expect(KeyboardFocusPolicy.runsAppShortcut(holder: .nobody, sheetUp: false))
        #expect(KeyboardFocusPolicy.runsAppShortcut(holder: .other, sheetUp: false))
        #expect(KeyboardFocusPolicy.runsAppShortcut(holder: .terminal, sheetUp: false))
        #expect(!KeyboardFocusPolicy.runsAppShortcut(holder: .textInput, sheetUp: false))
        #expect(!KeyboardFocusPolicy.runsAppShortcut(holder: .nobody, sheetUp: true))
    }

    @Test func aPaneThatKeepsBeingMovedStopsTakingTheKeyboardBack() {
        var limiter = KeyboardFocusPolicy.RetakeLimiter()
        let allowed = (0..<5).map { limiter.allows(at: 10 + Double($0) * 0.1) }
        #expect(allowed == [true, true, true, false, false])
        // Later, a fold moves it again: allowed.
        let later = limiter.allows(at: 20)
        #expect(later)
    }

    @Test func panesStayOutOfTheSystemFocus() {
        // No focus halo on a pane: the focus system has nothing to land on in the terminal view.
        let ghostty = GhosttyTerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 240), fontSize: 12, cols: 40, rows: 10)
        #expect(!ghostty.canBecomeFocused)
        #expect(ghostty.canBecomeFirstResponder)
        // And where the focus system does reach it (Full Keyboard Access), it draws no halo of its own.
        let control = RexControl(address: "", client: ClientInfo(name: "test", version: "0", label: "test"))
        let host = TerminalHost(stream: TerminalStream(control: control, sessionID: "s", blockID: "b"), sizing: .mirror,
                                fontSize: 12, theme: ThemeStore.fallback)
        #expect(host.term.focusEffect == nil)
        #expect(!host.canBecomeFocused)
    }
}

/// The app's menu shortcuts: what runs a command when no terminal has the keyboard.
@MainActor
struct AppShortcutTests {
    @Test func theDefaultsGiveToggleSidebarOnCmdSlash() throws {
        let list = AppShortcuts.list(KeyDefaults.resolved)
        let s = try #require(list.first { $0.id == "cmd+/" })
        #expect(s.command == .toggleSidebar)
        #expect(s.key.character == "/")
        #expect(s.modifiers == .command)
        #expect(s.title == "Show/Hide Sidebar")
    }

    @Test func onlyAppCommandsAndOneShortcutPerKey() {
        let list = AppShortcuts.list(KeyDefaults.resolved)
        // Keys a pane handles (send a key, jump to a prompt) need a pane.
        for id in ["cmd+backspace", "cmd+left", "alt+left", "cmd+up", "cmd+enter"] {
            #expect(!list.contains { $0.id == id }, "\(id)")
        }
        for id in ["cmd+,", "cmd+t", "cmd+w", "cmd+k", "cmd+]", "cmd+.", "ctrl+tab", "shift+cmd+enter", "cmd+[Digit1]", "cmd+="] {
            #expect(list.contains { $0.id == id }, "\(id)")
        }
        let keys = list.map { "\($0.key.character)|\($0.modifiers.rawValue)" }
        #expect(Set(keys).count == keys.count)
    }

    @Test func followsTheServerKeymap() {
        let s = store([("cmd+/", "pane.send_key", ["key": "ctrl+u"]), ("cmd+j", "client.sidebar.toggle", nil)])
        let list = AppShortcuts.list(s.bindings)
        // cmd+/ now types into the pane: no menu shortcut may take it.
        #expect(!list.contains { $0.id == "cmd+/" })
        #expect(list.first { $0.id == "cmd+j" }?.command == .toggleSidebar)
    }
}

struct SidebarStateTests {
    private let inline = Arrangement.decide(size: CGSize(width: 951, height: 669), division: nil)
    private let drawer = Arrangement.decide(size: CGSize(width: 466, height: 678), division: nil)

    @Test func toggleSidebarShowsAndHidesItInEveryArrangement() {
        for arrangement in [inline, drawer] {
            var s = SidebarState()
            let shown: SidebarState.Presentation = arrangement.inline ? .inline : .drawer
            #expect(s.presentation(arrangement) == shown)
            let hid = s.perform(.toggleSidebar)
            #expect(hid)
            #expect(s.presentation(arrangement) == .hidden)
            let showed = s.perform(.toggleSidebar)
            #expect(showed)
            #expect(s.presentation(arrangement) == shown)
        }
    }

    @Test func theSameStateCarriesAcrossAFold() {
        var s = SidebarState()
        _ = s.perform(.toggleSidebar)
        #expect(s.presentation(inline) == .hidden)
        #expect(s.presentation(drawer) == .hidden)
        _ = s.perform(.toggleSidebar)
        #expect(s.presentation(inline) == .inline)
        #expect(s.presentation(drawer) == .drawer)
    }

    @Test func otherCommandsLeaveItAlone() {
        var s = SidebarState()
        for c in [RexCommand.newTab, .nextPane, .settings, .jumpToWaiting, .toggleZoom] {
            let ran = s.perform(c)
            #expect(!ran)
            #expect(s.open)
        }
    }

    @Test func showingATabClosesADrawerAndKeepsAnInlineSidebar() {
        var s = SidebarState()
        s.tabShown(inline: true)
        #expect(s.open)
        s.tabShown(inline: false)
        #expect(!s.open)
        s.reveal()
        #expect(s.open)
    }

    @Test func toggleSidebarIsAnAppCommandNotATabCommand() {
        // RootView runs it, so it works with no tab on screen.
        #expect(!RexCommand.toggleSidebar.isWindowCommand)
    }
}

/// The host pool: which container shows a pane's host.
@MainActor
struct TerminalHostPoolTests {
    @Test func theNewestContainerInAWindowShowsTheHost() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        let onScreen = UIView(), newerOffScreen = UIView(), older = UIView()
        window.addSubview(older)
        window.addSubview(onScreen)
        // SwiftUI built a newer container it never showed: it must not take the host.
        #expect(TerminalHostPool.target([older, onScreen, newerOffScreen]) === onScreen)
        // With none on screen (a pane being built), the newest.
        #expect(TerminalHostPool.target([UIView(), newerOffScreen]) === newerOffScreen)
        #expect(TerminalHostPool.target([UIView]()) == nil)
    }
}

/// The whole path of a press: the engine view's `pressesBegan`, the host's `keyHook`, the keymap,
/// the command.
@MainActor
struct HardwareKeyPathTests {
    /// A press with a key, which UIKit only makes itself.
    private final class FakePress: UIPress {
        let fakeKey: UIKey
        init(_ key: UIKey) {
            fakeKey = key
            super.init()
        }
        override var key: UIKey? { fakeKey }
    }

    /// A `UIKey` through the Objective-C runtime: it has no public initializer.
    private func makeKey(usage: Int, flags: UIKeyModifierFlags, characters: String) throws -> UIKey {
        let made = (UIKey.self as AnyObject).perform(NSSelectorFromString("new"))?.takeRetainedValue()
        let key = try #require(made as? UIKey)
        key.setValue(usage, forKey: "keyCode")
        key.setValue(flags.rawValue, forKey: "modifierFlags")
        // Its text lives in string ivars with private names: set them all.
        var count: UInt32 = 0
        if let ivars = class_copyIvarList(UIKey.self, &count) {
            defer { free(ivars) }
            for ivar in UnsafeBufferPointer(start: ivars, count: Int(count)) {
                guard let type = ivar_getTypeEncoding(ivar), String(cString: type).contains("NSString") else { continue }
                object_setIvar(key, ivar, characters as NSString)
            }
        }
        try #require(key.keyCode.rawValue == usage && key.modifierFlags == flags && key.charactersIgnoringModifiers == characters)
        return key
    }

    private func makeHost() -> (TerminalHost, KeymapStore) {
        let control = RexControl(address: "", client: ClientInfo(name: "test", version: "0", label: "test"))
        let stream = TerminalStream(control: control, sessionID: "s", blockID: "b")
        let host = TerminalHost(stream: stream, sizing: .mirror, fontSize: 12, theme: ThemeStore.fallback)
        let keymap = KeymapStore(control: control)
        host.keymap = keymap
        return (host, keymap)
    }

    @Test func cmdSlashOnTheEngineViewRunsToggleSidebar() throws {
        let (host, _) = makeHost()
        var commands: [RexCommand] = []
        host.onCommand = { commands.append($0) }
        let key = try makeKey(usage: keySlash, flags: cmd, characters: "/")
        host.term.pressesBegan([FakePress(key)], with: nil)
        #expect(commands == [.toggleSidebar])
    }

    @Test func theGhosttyEngineAsksTheHookBeforeItRoutesACommandChord() throws {
        let view = GhosttyTerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 240), fontSize: 12, cols: 40, rows: 10)
        var seen: [(Int, UIKeyModifierFlags)] = []
        view.keyHook = { key in
            seen.append((key.keyCode.rawValue, key.modifierFlags))
            return true
        }
        view.pressesBegan([FakePress(try makeKey(usage: keySlash, flags: cmd, characters: "/"))], with: nil)
        #expect(seen.count == 1)
        #expect(seen.first?.0 == keySlash)
        #expect(seen.first?.1 == cmd)
        // Left alone, the engine gives a Command chord to the app and the system: it never types it.
        #expect(GhosttyInputKeymap.route(usage: keySlash, flags: cmd, characters: "/", charactersIgnoringModifiers: "/") == .system)
    }

    @Test func aBoundKeyRepeatsThroughTheSharedRepeaterAndStopsWhenThePaneIsLeft() throws {
        // ⌥⌘← is Focus Pane Left in the default keymap, and repeats while held.
        let (host, _) = makeHost()
        let clock = ManualKeyRepeatClock()
        host.keyRepeat = KeyRepeater(clock: clock, notifications: NotificationCenter(), keyIsDown: { _ in true })
        var ran = 0
        host.onCommand = { _ in ran += 1 }
        let key = try makeKey(usage: 80, flags: [.alternate, .command], characters: UIKeyCommand.inputLeftArrow)
        host.term.pressesBegan([FakePress(key)], with: nil)
        #expect(host.keyRepeat.isRepeating)
        // Not the active pane, not on screen, no keyboard: the first repeat finds that out.
        clock.advance(5)
        #expect(!host.keyRepeat.isRepeating)

        // A release ends it, through the responder chain.
        host.term.pressesBegan([FakePress(key)], with: nil)
        #expect(host.keyRepeat.isRepeating)
        host.pressesEnded([FakePress(key)], with: nil)
        #expect(!host.keyRepeat.isRepeating)

        // So does the pane no longer being the active one.
        host.isActive = true
        host.term.pressesBegan([FakePress(key)], with: nil)
        #expect(host.keyRepeat.isRepeating)
        host.isActive = false
        #expect(!host.keyRepeat.isRepeating)
        #expect(ran == 3, "each press ran the command once; no repeat got through")
    }

    @Test func theKeyCommandListCarriesToggleSidebar() throws {
        let (host, _) = makeHost()
        let commands = try #require(host.keyCommands)
        let slash = try #require(commands.first { $0.input == "/" && $0.modifierFlags == .command })
        #expect(slash.title == "Show/Hide Sidebar")
        #expect(slash.wantsPriorityOverSystemBehavior)
    }

    @Test func theKeyboardFocusHookReportsTakingAndLosingTheKeyboard() {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        let view = GhosttyTerminalView(frame: CGRect(x: 0, y: 0, width: 320, height: 240), fontSize: 12)
        var events: [Bool] = []
        view.keyboardFocusHook = { events.append($0) }
        window.addSubview(view)
        window.makeKeyAndVisible()
        guard view.becomeFirstResponder() else { return }  // no key window in this test host
        _ = view.resignFirstResponder()
        #expect(events == [true, false])
        window.isHidden = true
    }
}
