# Rex DUO

Rex DUO is a native iPhone app for [Rex](https://rex.superlogical.com), Super Logical's terminal
multiplexer. It lets you see and drive the sessions, tabs and panes running on your computers,
and tells you when an agent needs you. It is built for the iPhone Duo's folded and unfolded
screens and works on any iPhone with iOS 18 or later.

Rex is a separate product. Install it on each computer you want to reach from your phone.

## Get it

<!-- TESTFLIGHT_LINK -->
Public TestFlight link coming soon.

## Set up

1. **Turn on Rex's Tailscale serving on your computer.** Rex DUO reaches Rex over Tailscale, a
   private network that links your devices. In a terminal on the computer, run
   `rex server tailscale on` and sign in to Tailscale if Rex asks (`rex server status` shows the
   sign-in link). This lasts until the Rex server restarts; to keep it on, start the server with
   `--tailscale`.
2. **Put your iPhone on the same tailnet.** Install Tailscale on the iPhone and sign in with the
   same account as the computer. Rex only lets in devices signed in to that account.
3. **Add the computer in Rex DUO.** On a fresh install the sidebar offers **Pair via QR Code**,
   and Settings → Servers → Add Server has it too. On the computer, run
   `rex server tailscale pair` and point the camera at the code it shows. Rex DUO checks the
   computer, shows its name, account and sessions, and **Add & Open** takes you to its active
   tab. You can also type the computer's address (such as `studio-rex.your-tailnet.ts.net`)
   under **Or Enter Its Address**.

Repeat step 3 for each computer. A computer that Rex already knows about shows up under
**Not added** in the sidebar, with an **Add** button.

## Using Rex DUO

### The sidebar

The sidebar lists your computers, their sessions, and each session's tabs, like the sidebar in
Rex on the Mac. Each tab shows its agent, its pane count, and whether the agent is working,
waiting for you or done.

- Tap a computer or a session to fold or open it. A folded group still shows how many tabs it
  holds and how many agents are waiting or working.
- Use the **+** beside a session to add a tab, and swipe or long-press a row for more (rename,
  close, new session).
- Switch the top of the sidebar to **Agents** to see every agent on every computer, with the
  ones waiting for you first. Tap one to jump to it, or swipe it to interrupt it or press Enter.
- Show or hide the sidebar with its button, by swiping in from the left edge, or with ⌘/ on a
  keyboard. Drag its edge to make it wider or narrower.

### Tabs and panes

A tab fills the rest of the screen. When there is room, its panes are laid out as they are on
your computer, and you can drag the borders between them. When there isn't, one pane shows at a
time, with dots in the title bar for the others.

The pane you are looking at is resized to fit the phone. Rex gives it back its own size when you
leave it or put the app in the background. If something else resizes it, tap the notice to fit
it to the phone again.

The **Pane Actions** button splits the pane right or down, opens a new tab, shows all tabs,
zooms, clears, renames, and closes the pane or tab. Closing a pane, tab or session stops what
runs in it, on the computer too. Rex DUO asks first when an agent is running there, and always
before it closes a session.

### Gestures

| Gesture | What it does |
| --- | --- |
| Tap a pane | Focus it and bring up the keyboard |
| Tap a link | Open it |
| Tap on the shell prompt | Move the cursor there (shells with Ghostty's shell integration) |
| Drag up or down | Scroll back through the output (or scroll inside full-screen programs) |
| Swipe sideways on a pane | Next or previous pane |
| Swipe sideways on the title | Next or previous tab |
| Tap the title | List the session's tabs |
| Two-finger tap | Zoom the pane to fill the tab, or unzoom it |
| Pinch | Change the text size |

### Selecting text

Touch and hold a word to select it. A magnifier shows what is under your finger; keep dragging to
select more. When you lift your finger, the selection is copied to the clipboard straight away,
and handles appear so you can adjust it (adjusting copies again). Double-tap selects a word and
triple-tap a line. A menu offers Copy, Paste and Select All, and Open when the selection is a
path. Tap near the cursor for a Paste button.

### The key bar

The key bar above the keyboard holds the keys a phone keyboard lacks. Settings → Key Bar offers
three layouts: **Agents** (Escape, Shift-Tab, arrows, Enter, Ctrl-C, and 1, 2, 3 for an agent's
choices), **Shell** and **Vim**.

- Tap **ctrl** or **alt** to apply it to the next key; double-tap to lock it on.
- Hold an arrow to repeat it.
- Drag the ✥ key like a trackpad to move through menus and history.
- The paperclip sends a photo or a file to the pane's computer and types its path into the pane,
  as dropping a file on a terminal does on a Mac. Its menu says where it goes. You can also drop
  files on a pane from another app, and select a path the terminal shows to Open that file on the
  phone.
- The last key hides the keyboard.

### Hardware keyboards

With a keyboard attached, Rex DUO uses Rex's own shortcuts, including any you changed in your Rex
config. A few defaults:

| Keys | Action |
| --- | --- |
| ⌘/ | Show or hide the sidebar |
| ⌘. | Switch the sidebar to Agents and back |
| ⌥⌘. | Jump to the agent that has waited longest |
| ⌘T, ⌥⌘W | New tab, close tab |
| ⌘1 to ⌘9, ⇧⌘] and ⇧⌘[ | Go to a tab, next and previous tab |
| ⇧⌘\ | Show all tabs |
| ⌘D, ⇧⌘D | Split right, split down |
| ⌥⌘ and an arrow, ⌘] and ⌘[ | Move between panes |
| ⇧⌘Return | Zoom the pane |
| ⌘K | Change session |
| ⌘+, ⌘-, ⌘0 | Text size |
| ⌘, | Settings |

Option works as Alt (Meta) in the terminal unless your keyboard layout needs it to type a
character.

### Text size and theme

Settings → Appearance sets the text size (7 to 20 pt) and picks one theme for Light Mode and one
for Dark Mode from Rex's themes. The app follows the system's appearance. Pinching a pane also
changes the text size.

### iPhone Duo postures

Rex DUO follows the size of its window, so it works the same in every posture:

- **Folded:** the sidebar slides over the tab as a drawer, and one pane shows at a time.
- **Unfolded:** the sidebar sits beside the tab, and splits are laid out as on your computer.
- **Split View or a half window:** the layout follows the window's width, so a narrow window
  behaves like the folded screen.

Folding or unfolding keeps your place: the same tab, the same pane and its keyboard.

## Notifications

Rex DUO can tell you when an agent needs your input, when it finishes, or when a terminal asks
for attention. While the app is open, these show as a short banner at the top for panes you
aren't looking at. While it is closed, they arrive as iPhone notifications.

To get them while the app is closed, turn on notifications, and the app sets up a small helper,
Rex DUO Helper, on each computer for you. After you add a computer, Rex DUO offers to install
the helper there; tap **Install**. Settings → Notifications shows each computer's helper and
offers to install, repair, reinstall or update it. The helper runs on Mac and Linux computers
and keeps itself up to date.

## Privacy and security

- **Your sessions stay between your phone and your computers.** Rex DUO connects straight to
  each Rex server over your Tailscale network. There is no Rex DUO account and no analytics.
- **Notifications go through a small relay.** Rex DUO Helper sends each notification to the Rex
  DUO push service, which only passes it on to Apple for delivery. The helper never holds your
  phone's notification token or an Apple key.
- **What the relay stores:** your phone's notification token and which of Apple's delivery
  services it uses, and for each computer a fingerprint of the secret its helper uses, with the computer's
  name and when it was added, plus daily counts for its limits. It keeps fingerprints of keys,
  never the keys themselves, and it never stores or logs what a notification says. Turning
  notifications off deletes your phone's entry, and entries unused for 180 days are deleted.
- **Helpers are checked.** The app checks each helper's identity before it trusts it, and warns
  you if a computer's helper changes. Helper updates are signed and checked before they install.

## Troubleshooting

**The app says it can't reach a computer, or it is "Out of range".**
Check that Tailscale is connected on the iPhone and that the computer is on the same tailnet.
Rex DUO reconnects by itself as soon as it can.

**"Isn't answering".**
The computer may be asleep, or Rex isn't running there. Wake it and open Rex.

**"Didn't let this iPhone in".**
The iPhone is signed in to Tailscale with a different account than the computer. Sign in with
the same account.

**"Can't verify" or "That address won't work".**
Use the computer's full Tailscale address (`https://…ts.net`) in Settings → Servers, or pair
again with `rex server tailscale pair`.

**Notifications don't arrive.**
Open Settings → Notifications. If a computer says Rex DUO Helper isn't running, tap **Install**
or **Repair**. If iOS has turned notifications off for Rex DUO, the section says so and offers
**Open Settings**. The computer has to be on and Rex has to be running for the helper to see
your agents.

**"Rex DUO Helper on … changed".**
The helper on that computer was replaced. Tap **Trust** only if you reinstalled it yourself;
otherwise tap **Reinstall**.

## Building from source

See [docs/development.md](docs/development.md) for building, testing and how the code is laid
out, and [CONTRIBUTING.md](CONTRIBUTING.md) before you send a change.

## Licence

Rex DUO is free software under the [GNU Affero General Public License, version 3](LICENSE)
(AGPL-3.0-only). You may use, study, change and share it. Anything built from it, including a
hosted service, must be released under the same licence with its full source. The names and
artwork are not licensed for other products. Third-party code and its licences are listed in
[NOTICE](NOTICE) and in the app under Settings → About → Acknowledgements.
