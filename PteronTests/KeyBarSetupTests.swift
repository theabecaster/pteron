import Foundation
import Testing
@testable import Pteron

/// The key bar's middle capsule as Settings arranges it (`KeyBarSetup`): what it shows first,
/// editing, storing, and carrying the layouts before it over with the same keys.
@MainActor
struct KeyBarSetupTests {
    private func fresh() -> UserDefaults {
        let name = "PteronTests.keybar.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        d.removePersistentDomain(forName: name)
        return d
    }

    /// The capsule's items as bar keys: a shortcut by its id, without "custom:".
    private func keys(_ s: KeyBarSetup) -> [String] {
        s.items.map { item in
            switch item {
            case .key(let id): return id
            case .shortcut(let sc): return sc.isCustom ? String(sc.id.dropFirst("custom:".count)) : sc.id
            case .group(let g): return "group:" + g.id.rawValue
            }
        }
    }

    /// A layout's keys without those that have their own place now, and Shift-Return, which every
    /// setup from before it gets.
    private func scrolling(_ layout: KeyBarLayout) -> [String] {
        layout.keys.filter { !["arrows", "attach", "enter"].contains($0) } + ["shift-enter"]
    }

    // MARK: First setup

    @Test func theFirstSetupIsForAgents() {
        #expect(keys(.standard) == ["esc", "ctrl", "alt", "shift", "tab", "~", "|", "/", "-", "backspace", "paste",
                                    "shift-enter"], "Shift-Return last, right before the pinned Return")
        #expect(KeyBarSetup.editingKeys.prefix(3) == ["backspace", "paste", "shift-enter"])
        #expect(KeyBarSetup.standard.sections == [.primary, .groups, .editing])
        #expect(KeyBarSetup.standard.primary.map(\.id) == KeyBarSetup.primaryKeys)
        #expect(KeyBarSetup.standard.editing.map(\.id) == KeyBarSetup.editingKeys)
        #expect(!KeyBarSetup.primaryKeys.contains("enter") && !KeyBarSetup.editingKeys.contains("enter"), "Return is pinned")
        let characters = ShortcutGroup.standard(.characters)
        #expect(characters.shown && characters.expanded)
        #expect(characters.items.map(\.id) == ["~", "|", "/", "-", "\\", "_", "$", "*", ".", "..", "?", "&", ":", "1", "2", "3"])
        let shortcuts = ShortcutGroup.standard(.shortcuts)
        let allOn = shortcuts.items.allSatisfy(\.on)
        #expect(!shortcuts.shown && allOn)
        for id in ["ctrl-c", "ctrl-r", "ctrl-d", "ctrl-u", "ctrl-w"] {
            #expect(shortcuts.items.contains { $0.id == id }, "\(id)")
        }
        #expect(ShortcutGroup.standard(.functionKeys).items.map(\.label) == (1...12).map { "F\($0)" })
    }

    @Test func aChangedSetupSurvivesARelaunch() {
        let d = fresh()
        let p = Prefs(defaults: d)
        #expect(p.keyBarSetup == .standard)
        var s = p.keyBarSetup
        s.primary[0].shown = false
        s.update(.functionKeys) { $0.shown = true }
        p.keyBarSetup = s
        #expect(Prefs(defaults: d).keyBarSetup == s)
    }

    @Test func itEncodesWithItsVersionAndCustomShortcuts() throws {
        var s = KeyBarSetup.standard
        s.update(.shortcuts) {
            $0.items.append(.custom(label: "⌃⌥C", send: .key(KeyStroke(key: "c", ctrl: true, alt: true))))
            $0.items.append(.custom(label: "ab", send: .text("a\nb")))
        }
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(KeyBarSetup.self, from: data)
        #expect(back == s)
        #expect(back.normalized() == s, "a setup of this version reads back as it is")
        #expect(back.editing.first { $0.id == "shift-enter" }?.shown == true)
        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["version"] as? Int == KeyBarSetup.currentVersion)
        #expect(KeyBarSetup.currentVersion == 2)
        let added = try #require(back.group(.shortcuts)?.items.suffix(2))
        #expect(added.map(\.send) == [.key(KeyStroke(key: "c", ctrl: true, alt: true)), .text("a\nb")])
        let allCustom = added.allSatisfy(\.isCustom)
        #expect(allCustom)
    }

    // MARK: Editing

    @Test func movesShowInTheBar() {
        var s = KeyBarSetup.standard
        s.sections.move(fromOffsets: IndexSet(integer: 2), toOffset: 0)
        #expect(keys(s).prefix(2) == ["backspace", "paste"])
        s.primary.move(fromOffsets: IndexSet(integer: 4), toOffset: 0)
        #expect(keys(s)[3] == "tab")
        s.update(.characters) { $0.items.move(fromOffsets: IndexSet(integer: 3), toOffset: 0) }
        #expect(keys(s).suffix(4) == ["-", "~", "|", "/"])
    }

    @Test func groupsShowAsAButtonOrAsKeys() {
        var s = KeyBarSetup.standard
        s.update(.characters) { $0.expanded = false }
        #expect(keys(s) == ["esc", "ctrl", "alt", "shift", "tab", "group:characters", "backspace", "paste", "shift-enter"])
        s.update(.characters) { g in for i in g.items.indices { g.items[i].on = false } }
        #expect(!keys(s).contains("group:characters"), "a group with nothing on shows nothing")
        s.update(.shortcuts) { $0.shown = true }
        #expect(keys(s).contains("group:shortcuts"))
    }

    @Test func anAddedShortcutShowsAtItsGroupsEnd() {
        var s = KeyBarSetup.standard
        let added = Shortcut.custom(label: "ls", send: .text("ls -la\n"))
        s.update(.characters) { $0.items.append(added) }
        #expect(keys(s) == ["esc", "ctrl", "alt", "shift", "tab", "~", "|", "/", "-", String(added.id.dropFirst(7)),
                            "backspace", "paste", "shift-enter"])
        #expect(added.isCustom && added.on)
    }

    @Test func resetsRestoreWhatTheyCover() {
        var g = ShortcutGroup.standard(.characters)
        g.shown = false
        g.expanded = false
        g.items.append(.custom(label: "x", send: .text("x")))
        g.items.reverse()
        let reset = g.reset()
        #expect(reset.items == ShortcutGroup.standard(.characters).items)
        #expect(!reset.shown && !reset.expanded, "showing and expanding stay as they were")

        var s = KeyBarSetup.standard
        s.sections.reverse()
        s.primary[0].shown = false
        s.update(.characters) { $0.expanded = false; $0.items.append(.custom(label: "x", send: .text("x"))) }
        let layout = s.resetLayout()
        #expect(layout.sections == KeyBarSetup.standard.sections)
        #expect(layout.primary == KeyBarSetup.standard.primary)
        #expect(layout.group(.characters)?.expanded == true)
        #expect(layout.group(.characters)?.items.count == ShortcutGroup.characters.count + 1, "shortcuts stay")

        var hidden = KeyBarSetup.standard
        hidden.editing.removeAll { $0.id == "shift-enter" }
        hidden.editing.append(KeyBarSetup.Key(id: "shift-enter", shown: false))
        #expect(hidden.resetLayout().editing == KeyBarSetup.standard.editing, "Reset Layout shows Shift-Return")
    }

    @Test func normalizingFillsWhatIsMissingAndDropsWhatIsNot() {
        var s = KeyBarSetup.standard
        s.version = 0
        s.sections = [.editing, .editing]
        s.primary = [KeyBarSetup.Key(id: "tab", shown: true), KeyBarSetup.Key(id: "zz", shown: true),
                     KeyBarSetup.Key(id: "tab", shown: false)]
        s.groups = [ShortcutGroup.standard(.shortcuts)]
        let n = s.normalized()
        #expect(n.version == KeyBarSetup.currentVersion)
        #expect(n.sections == [.editing, .primary, .groups])
        #expect(n.primary.map(\.id) == ["tab"] + KeyBarSetup.primaryKeys.filter { $0 != "tab" })
        #expect(n.primary.first?.shown == true)
        #expect(n.primary.dropFirst().allSatisfy { !$0.shown }, "keys it lacked come hidden")
        #expect(n.groups.map(\.id) == [.shortcuts, .characters, .functionKeys])
        #expect(n.groups.dropFirst().allSatisfy { !$0.shown })
        #expect(n.normalized() == n)
    }

    // MARK: Before the setup

    /// The keys each layout showed, after the update, in the new model.
    @Test(arguments: KeyBarLayout.allCases)
    func aPickedLayoutKeepsItsKeys(layout: KeyBarLayout) {
        let d = fresh()
        d.set(layout.rawValue, forKey: "keyBarLayout")
        let s = Prefs(defaults: d).keyBarSetup
        #expect(Set(keys(s)) == Set(scrolling(layout)), "\(layout)")
        #expect(keys(s).count == scrolling(layout).count, "no key twice")
        #expect(s.items.allSatisfy { if case .group = $0 { false } else { true } }, "migrated groups are expanded")
        #expect(d.object(forKey: "keyBarLayout") == nil)
    }

    /// A list the removed editor saved: as the layout it was, or as it is now.
    @Test(arguments: KeyBarLayout.allCases)
    func aSavedListKeepsItsLayoutsKeys(layout: KeyBarLayout) {
        for saved in [layout.storedKeys, layout.keys, layout.keys.filter { $0 != "enter" && $0 != "attach" }] {
            let d = fresh()
            d.set(saved, forKey: "keyBar")
            #expect(Set(keys(Prefs(defaults: d).keyBarSetup)) == Set(scrolling(layout)), "\(saved)")
            #expect(d.object(forKey: "keyBar") == nil)
        }
    }

    @Test func anEditedListKeepsItsOwnKeys() {
        let d = fresh()
        d.set(["esc", "f1", "ctrl-o", "x"], forKey: "keyBar")
        let s = Prefs(defaults: d).keyBarSetup
        #expect(Set(keys(s)) == ["esc", "f1", "ctrl-o", "x", "shift-enter"])
        #expect(s.group(.functionKeys)?.items.first { $0.on }?.id == "f1")
        let o = s.group(.shortcuts)?.items.first { $0.on }
        #expect(o?.label == "^O" && o?.send == .key(KeyStroke(key: "o", ctrl: true)))
        #expect(s.group(.characters)?.items.first { $0.on }?.send == .text("x"))
    }

    @Test func shellKeepsItsCharactersInOrder() {
        let s = KeyBarSetup.migrating(KeyBarLayout.shell.keys)
        #expect(s.group(.characters)?.items.filter(\.on).map(\.id) == ["|", "~", "/", "-"])
        #expect(s.sections == [.primary, .editing, .groups], "sections in the order they first came")
        #expect(KeyBarSetup.migrating(KeyBarLayout.shell.keys) == s, "the same list migrates the same")
    }

    @Test func agentsKeepsItsMenuDigitsAndCommand() {
        let s = KeyBarSetup.migrating(KeyBarLayout.agents.keys)
        #expect(keys(s) == ["esc", "shift-tab", "tab", "ctrl", "cmd", "/", "1", "2", "3", "ctrl-c", "up", "down", "paste",
                            "shift-enter"])
    }

    @Test func anInstallFromBeforeGetsTheAgentsLayoutItHad() {
        for key in ["onboardingDone", "servers"] {
            let d = fresh()
            if key == "servers" { d.set(Data("[]".utf8), forKey: key) } else { d.set(true, forKey: key) }
            #expect(Prefs(defaults: d).keyBarSetup == .migrating(KeyBarLayout.agents.keys), "\(key)")
        }
    }

    @Test func aFreshInstallStartsOnTheFirstSetupAndKeepsIt() {
        let d = fresh()
        #expect(Prefs(defaults: d).keyBarSetup == .standard)
        #expect(d.object(forKey: "keyBarSetup") != nil)
        // Servers added since never make a later launch take it for an install from before.
        d.set(true, forKey: "onboardingDone")
        #expect(Prefs(defaults: d).keyBarSetup == .standard)
    }

    @Test func migrationRunsOnce() {
        let d = fresh()
        d.set("shell", forKey: "keyBarLayout")
        let first = Prefs(defaults: d).keyBarSetup
        d.set("vim", forKey: "keyBarLayout")
        #expect(Prefs(defaults: d).keyBarSetup == first)
        #expect(d.object(forKey: "keyBarLayout") == nil)
    }

    // MARK: Version 2: Shift-Return

    /// A setup as version 1 stored it: without Shift-Return, which version 1 didn't know.
    private func version1(_ s: KeyBarSetup) -> KeyBarSetup {
        var s = s
        s.editing.removeAll { $0.id == "shift-enter" }
        s.version = 1
        return s
    }

    private func store(_ s: KeyBarSetup, in d: UserDefaults) throws {
        d.set(try JSONEncoder().encode(s), forKey: "keyBarSetup")
    }

    private func stored(_ d: UserDefaults) throws -> KeyBarSetup {
        try JSONDecoder().decode(KeyBarSetup.self, from: try #require(d.data(forKey: "keyBarSetup")))
    }

    /// The owner's setup, carried over from the Agents layout, and others: Shift-Return comes
    /// shown, right after Editing's last shown key, and nothing else changes.
    @Test func version2AddsShiftReturnOnceAndLeavesTheRest() throws {
        var edited = KeyBarSetup.migrating(KeyBarLayout.agents.keys)
        edited.editing.move(fromOffsets: IndexSet(integer: 0), toOffset: 3)
        edited.update(.functionKeys) { $0.shown = true; $0.items.append(.custom(label: "ls", send: .text("ls\n"))) }
        edited.primary[0].shown = false
        let cases: [KeyBarSetup] = [
            .migrating(KeyBarLayout.agents.keys), .migrating(KeyBarLayout.shell.keys), .standard, edited,
        ]
        for setup in cases {
            let old = version1(setup)
            let d = fresh()
            try store(old, in: d)
            let s = Prefs(defaults: d).keyBarSetup
            let i = try #require(s.editing.firstIndex { $0.id == "shift-enter" })
            #expect(s.editing[i].shown)
            #expect(s.editing.filter { $0.id == "shift-enter" }.count == 1)
            #expect(i == (old.editing.lastIndex(where: \.shown).map { $0 + 1 } ?? 0), "after Editing's last shown key")
            var rest = s
            rest.editing.remove(at: i)
            rest.version = 1
            #expect(rest == old, "nothing else changes")
            // Saved at once as version 2, so the step never runs again.
            #expect(try stored(d) == s)
            #expect(try stored(d).version == 2)
        }
        // The owner's bar: Shift-Return last, right before the pinned Return.
        let d = fresh()
        try store(version1(.migrating(KeyBarLayout.agents.keys)), in: d)
        #expect(keys(Prefs(defaults: d).keyBarSetup).suffix(2) == ["paste", "shift-enter"])
    }

    @Test func aHiddenShiftReturnStaysHidden() throws {
        let d = fresh()
        try store(version1(.migrating(KeyBarLayout.agents.keys)), in: d)
        let p = Prefs(defaults: d)
        var s = p.keyBarSetup
        let i = try #require(s.editing.firstIndex { $0.id == "shift-enter" })
        s.editing[i].shown = false
        p.keyBarSetup = s
        for _ in 0..<2 {
            #expect(Prefs(defaults: d).keyBarSetup == s, "never added again")
        }
        #expect(!keys(Prefs(defaults: d).keyBarSetup).contains("shift-enter"))
        // Moved, it stays where the user put it, too.
        s.editing.move(fromOffsets: IndexSet(integer: i), toOffset: 0)
        s.editing[0].shown = true
        Prefs(defaults: d).keyBarSetup = s
        #expect(Prefs(defaults: d).keyBarSetup == s)
    }

    @Test func aFreshInstallAndANewerSetupAreLeftAsTheyAre() throws {
        let d = fresh()
        _ = Prefs(defaults: d)
        #expect(try stored(d) == .standard)
        // A setup a later version saved is not rewritten by this one.
        var newer = KeyBarSetup.standard
        newer.version = 3
        let data = try JSONEncoder().encode(newer)
        d.set(data, forKey: "keyBarSetup")
        _ = Prefs(defaults: d)
        #expect(d.data(forKey: "keyBarSetup") == data)
    }

    // MARK: Keys with modifiers

    @Test func keyStrokesSendWhatTheirChordSends() {
        #expect(KeyStroke(key: "c", ctrl: true).bytes == [0x03])
        #expect(KeyStroke(key: "b", alt: true).bytes == [0x1b, 0x62])
        #expect(KeyStroke(key: "tab", shift: true).bytes == Array("\u{1b}[Z".utf8))
        #expect(KeyStroke(key: "left", ctrl: true).bytes == Array("\u{1b}[1;5D".utf8))
        #expect(KeyStroke(key: "f5").bytes == Array("\u{1b}[15~".utf8))
        #expect(KeyStroke(key: "A").bytes == Array("A".utf8))
        #expect(KeyStroke(key: "").bytes == nil)
        #expect(KeyStroke(key: "c", ctrl: true, alt: true).label == "⌃⌥C")
        #expect(KeyStroke(key: "tab", shift: true).label == "⇧Tab")
    }

    @Test func shortcutsThatAreBarKeysGoThroughTheBar() {
        #expect(ShortcutGroup.builtIn(barKey: "~")?.barKey == "~")
        #expect(ShortcutGroup.builtIn(barKey: "ctrl-c")?.barKey == "ctrl-c")
        #expect(ShortcutGroup.builtIn(barKey: "ctrl-c")?.label == "^C")
        #expect(ShortcutGroup.builtIn(barKey: "f1")?.barKey == "f1")
        #expect(Shortcut.custom(label: "⇧⇥", send: .key(KeyStroke(key: "tab", shift: true))).barKey == "shift-tab")
        #expect(ShortcutGroup.builtIn(barKey: "..")?.barKey == nil, "longer text sends its bytes")
        #expect(Shortcut.custom(label: "ab", send: .text("a\nb")).barKey == nil)
        #expect(Shortcut.custom(label: "x", send: .key(KeyStroke(key: "c", ctrl: true, alt: true))).barKey == nil)
    }
}
