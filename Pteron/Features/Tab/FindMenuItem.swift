import SwiftUI

/// "Find…" in the pane menu, with the key the pane's server keymap binds to `client.find.open`
/// (⌘F by default), or no key text when nothing runs it. Its own view, so only it reads the
/// keymap: a keymap change redraws this row, not the tab screen. The key is text only; the menu
/// registers no shortcut of its own (the keymap's key already is one).
struct FindMenuItem: View {
    let keymap: KeymapStore
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Find…", systemImage: "magnifyingglass")
            if let key = KeyLabel.for(action: "client.find.open", in: keymap.bindings) {
                Text(key)
            }
        }
    }
}
