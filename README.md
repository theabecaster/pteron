# Pteron

Pteron is a native iPhone and iPad app for Rex, [Superlogical](https://superlogical.com)'s terminal
multiplexer. It lets you see and drive the sessions, tabs and panes running on your computers,
and tells you when an agent needs you. It is built for the iPhone Duo's folded and unfolded
screens and works on any iPhone or iPad with iOS 18 or later.

Pteron is an independent app. It is not affiliated with or endorsed by Superlogical. Rex is a
separate product: install it on each computer you want to reach from your phone.

## Get it

Join the public beta on TestFlight: https://testflight.apple.com/join/zf8heFAX

Open the link on your iPhone. It installs TestFlight first if you don't have it.

## Set up

Pteron connects to your computer privately, through Tailscale, a free private network for your
own devices. On first launch a short guide walks through these steps; **Setup Guide** (on the
empty screen, and in Settings → About) and **How to Set Up a Computer** (in Settings → Computers
→ Add Computer) open its checklist again.

1. **Rex on your computer.** Pteron shows your Rex sessions. Rex is a terminal app for Mac and
   Linux; **Get Rex** opens its [installation page](https://www.superlogical.com/rex/docs/installation).
2. **Connect this iPhone with Tailscale.** Install Tailscale (**Get Tailscale** opens it in the
   App Store), sign in, then turn it on. Rex only lets in devices signed in to the same account
   as the computer. The guide ticks this step once the iPhone has a Tailscale address. If you
   tap **I Have a Pairing Code** before this iPhone is on Tailscale, the guide opens at this step
   and opens the camera by itself once Tailscale is on.
3. **Turn on Tailscale in Rex.** Rex joins Tailscale by itself; the computer's Tailscale app
   isn't needed.
   - Mac: in Rex, Settings → Server → Tailscale → **Serve over Tailscale**.
   - Linux: run `rex server tailscale on`. If it asks you to sign in, run
     `rex server tailscale login` and open the link on any device. Tailscale stays on until Rex
     restarts; start the server with `--tailscale` to keep it on.

   Sign in with the same account as on the iPhone.
4. **Show the pairing code, then tap Scan Code.** On your computer, in Rex: Settings → Server →
   Remote Address → **Pair**. Or run `rex server tailscale pair`. No Pair option? Update Rex.
   Pteron checks the computer, shows its name, account and sessions, and **Add & Open** takes
   you to its active tab (**Add**, for a computer with no sessions yet; Pteron then offers
   **New Session**). You can also type the computer's address (such as
   `studio-rex.your-tailnet.ts.net`) with **Enter Address**, or in Settings → Computers → Add
   Computer under **Or Enter Its Address**; a typed address is checked the same way.

Repeat step 4 for each computer. A computer that Rex already knows about shows up under
**Not Added** in the sidebar, with an **Add** button.

## Using Pteron

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
runs in it, on the computer too. Pteron asks first when an agent is running there, and always
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

The key bar above the keyboard holds the keys a phone keyboard lacks. Settings → Keyboard offers
three layouts: **Agents** (Escape, Shift-Tab, Tab, `/` for slash commands, arrows, Ctrl-C, and 1,
2, 3 for an agent's choices), **Shell** and **Vim**. Each has ctrl and cmd; Shell also has alt and
Shift-Tab.

- **Return** stays at the end of the bar in every layout, next to the hide key; the other keys
  scroll. Hold it for Shift-Return: a new line in an agent's message without sending it.

- Tap **ctrl** or **alt** to apply it to the next key; double-tap to lock it on.
- **cmd** is the Mac's ⌘: tap it, then a key, to run that Rex shortcut (cmd then `t` opens a tab,
  cmd then `d` splits, cmd then `1` goes to the first tab). Double-tap to lock it. The key is never
  typed; a key with no shortcut does nothing.
- Hold an arrow to repeat it.
- Drag the ✥ key like a trackpad to move through menus and history.
- The paperclip beside Return, or Attach in the pane menu, sends a photo or a file to the pane's
  computer and types its path into the pane, as dropping a file on a terminal does on a Mac. Its
  menu says where it goes. With an image copied, the edit menu offers Paste Image beside Paste.
  You can also drop files on a pane from another app, and select a path the terminal shows to
  Open that file on the phone.
- The last key hides the keyboard.

### Hardware keyboards

With a keyboard attached, Pteron uses Rex's own shortcuts, including any you changed in your Rex
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
| ⌘P, ⇧⌘P | Go to Anything, the command palette |
| ⌘+, ⌘-, ⌘0 | Text size |
| ⌘, | Settings |

Option works as Alt (Meta) in the terminal unless your keyboard layout needs it to type a
character.

A tab's floating windows show as they do in the Rex app; on a narrow screen one at a time, as a
sheet over the tab, and the pane menu's Floating Windows section lists them. On an iPhone Duo
standing folded as a tent, the outer screen shows the agent board: who is waiting for you, at a
glance.

### Text size and theme

Settings → Appearance sets the text size (7 to 20 pt) and picks one theme for Light Mode and one
for Dark Mode from Rex's themes. The app follows the system's appearance. Pinching a pane also
changes the text size.

### iPhone Duo postures

Pteron follows the size of its window, so it works the same in every posture:

- **Folded:** the sidebar slides over the tab as a drawer, and one pane shows at a time.
- **Unfolded:** the sidebar sits beside the tab, and splits are laid out as on your computer.
- **Split View or a half window:** the layout follows the window's width, so a narrow window
  behaves like the folded screen.

Folding or unfolding keeps your place: the same tab, the same pane and its keyboard.

## Notifications

Pteron can tell you when an agent needs your input, when it finishes, or when a terminal asks
for attention. While the app is open, these show as a short banner at the top for panes you
aren't looking at. While it is closed, they arrive as iPhone notifications.

To get notifications while the app is closed, each computer needs Pteron Beacon, a small
program that runs on Mac and Linux computers and keeps itself up to date. After you add a
computer, Pteron offers to install Beacon on it; tap **Install**.

Everything else is in Settings → Notifications:

- **Turn notifications on or off.** The **Notifications** switch is for the whole app. The
  first time you turn it on, iOS asks for permission. If notifications are turned off for
  Pteron in iOS Settings, the switch shows off and says so; tap **Open Settings** to turn them on.
- **Choose computers.** With the switch on, each computer has its own switch. Turning a
  computer on installs Beacon on that computer if it has none ("Turn on to install Beacon");
  turning it off stops notifications from that computer only, and leaves Beacon installed. A computer that
  can't be reached when you turn it off shows "Turns off when … is back" and stops then.
- **See how a computer is doing.** A computer that works shows its Beacon version under its
  name ("Beacon 0.6.1"). Otherwise that line says what is wrong, with one button to fix it when
  one can: **Update**, **Repair**, **Try Again**, **Continue** or **Trust…**.
- **Send a test.** Touch and hold a computer, or tap **…**, and choose **Send Test
  Notification**. The computer sends one notification to this iPhone.
- **Remove Beacon.** In the same menu, choose **Remove Beacon…**. It stops notifications
  from that computer to every iPhone that used Beacon, and removes Beacon from the
  computer. **Reinstall Beacon** and **Show Details** are there too.

## Privacy and security

- **Your sessions stay between your phone and your computers.** Pteron connects straight to
  each Rex server over your Tailscale network. There is no Pteron account and no analytics.
- **Notifications go through a small relay.** Pteron Beacon sends each notification to the
  Pteron push service, which only passes it on to Apple for delivery. Beacon never holds your
  phone's notification token or an Apple key.
- **What the relay stores:** your phone's notification token and which of Apple's delivery
  services it uses, and for each computer a fingerprint of the secret its Beacon uses, with the computer's
  name and when it was added, plus daily counts for its limits. It keeps fingerprints of keys,
  never the keys themselves, and it never stores or logs what a notification says. Turning
  notifications off stops each computer from sending and keeps your phone's entry for when you
  turn them on again; removing Beacon deletes that computer's entry, and entries unused for
  180 days are deleted.
- **Beacons are checked.** The app checks each Beacon's identity before it trusts it, and warns
  you if a computer's Beacon changes. Beacon updates are signed and checked before they install.

## Troubleshooting

**The app says it can't reach a computer, or it is "Out of range".**
Check that Tailscale is connected on the iPhone and that the computer is on the same Tailscale account.
Pteron reconnects by itself as soon as it can.

**"Isn't answering".**
The computer may be asleep, or Rex isn't running there. Wake it and open Rex.

**"Didn't let this iPhone in".**
The iPhone is signed in to Tailscale with a different account than the computer. Sign in with
the same account.

**"Can't verify" or "That address won't work".**
Use the computer's full Tailscale address (`https://…ts.net`) in Settings → Computers, or pair
again with `rex server tailscale pair`.

**Notifications don't arrive.**
Open Settings → Notifications and look at the line under the computer's name. "Beacon isn't
running": tap **Repair**. "Beacon needs an update": tap **Update**. If iOS has turned
notifications off for Pteron, the section says so and offers **Open Settings**. The computer
has to be on and Rex has to be running for Beacon to see your agents.

**"Beacon has changed".**
Beacon on that computer was replaced. Tap **Trust…** if you reinstalled or removed it
yourself; otherwise choose **Reinstall Beacon** from the computer's menu.

## Building from source

See [docs/development.md](docs/development.md) for building, testing and how the code is laid
out, and [CONTRIBUTING.md](CONTRIBUTING.md) before you send a change.

## Licence

Pteron is free software under the [GNU Affero General Public License, version 3](LICENSE)
(AGPL-3.0-only). You may use, study, change and share it. Anything built from it, including a
hosted service, must be released under the same licence with its full source. The names and
artwork are not licensed for other products. Third-party code and its licences are listed in
[NOTICE](NOTICE) and in the app under Settings → About → Acknowledgements.
