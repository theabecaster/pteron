# Pteron Beacon: install and update

Pteron Beacon sends your phone a notification while the Pteron app is closed: when an agent
needs you, finishes, or a terminal asks for attention. Install it on each computer that runs a Rex
server. It needs no account and no key, and it keeps itself up to date.

Works with Rex by Superlogical. Not affiliated.

## From the phone

After you add a computer, Pteron offers to install Beacon on it: tap **Install**. The same
offer is in Settings → Notifications. Pteron opens a tab on the computer, which downloads the
Beacon, checks it and starts it; nothing runs as an administrator. It needs a Mac or Linux
computer you own with a recent Rex. To install by hand instead:

## Mac

1. Download `Beacon-macOS.zip` (`Rex-DUO-Beacon.zip` in a release before 0.4.0) from the
   newest "Pteron Beacon" release at
   <https://github.com/theabecaster/pteron/releases>.
2. Unzip it and drag **Pteron Beacon** to Applications.
3. Open it once. It asks to send notifications (for the one "Pteron connected" notice per phone),
   then runs in the background and starts again at login.

Pteron Beacon had two names before: Rex DUO Helper (version 0.3.0) and Rex DUO Beacon (version
0.3.1). A Mac that has `Rex DUO Helper.app` or `Rex DUO Beacon.app` keeps everything it allowed
and every registered phone: the next update or install leaves one app, `Pteron Beacon.app`, in
the same Applications folder. Nobody has to do anything for it. The command-line program is
still `rex-duo-helper`, and the state folder and the log keep the names they have
(`Rex DUO Helper`), as do the bundle identifier and the address releases come from.

An installed Beacon gets the new version from its own updater, which looks for the folder name
it knows, so the new version first sits in a folder of the earlier name. About 30 seconds after
it starts there, it renames that folder to `Pteron Beacon.app` and moves its background job,
in one step with one restart.

macOS keeps the app's path in its Launch Services record too, and the move takes it along:
Launch Services is told to forget the earlier path and to record `Pteron Beacon.app`
(`lsregister -u`, then `-f`). After that the LaunchAgent is written for the new path and loaded.
If `lsregister` is missing or fails, the move goes on without it.

The background job is the LaunchAgent `dev.abrahamgonzalez.rexduo.agent`
(`~/Library/LaunchAgents/dev.abrahamgonzalez.rexduo.agent.plist`). Its label was
`dev.abrahamgonzalez.rexduo.helper` in version 0.3.0 and `dev.abrahamgonzalez.rexduo.beacon` in
version 0.3.1. macOS names and draws a job in System Settings → General → Login Items after the
app it found when the job's file first appeared, for as long as that file exists, so the label
moves when the app's name does. The order: the file of the new label is written for the
program where it is now, the earlier jobs are booted out and the new one loaded, Beacon
reports in `status.json` that it runs under the new label, and only then are the earlier files
deleted, every one that is there. A file exists at every moment. If Beacon does not report in
within 20 s, the new job is booted out, its file removed, the earlier job loaded again from its
file, and one line goes to the log; the next start tries again. An install, a repair, opening
the app and the app's move to its name all make this move, and so does a Beacon that finds
itself running under an earlier label, about 30 s after it started. With the new file and an
earlier one both there at a start (a move that was cut short), the Beacon under the new label
boots the earlier jobs out and deletes their files, and one under an earlier label gives way
to it. `rex-duo-helper status` names the label in use.

In Login Items the person sees a new entry named **Pteron Beacon**, with its icon, once the new
file is written, and macOS shows its "Background Items Added" notice once. Nothing has to be
allowed again. The entry of the earlier label, and the one of the app's earlier path, stay
beside it until about 70 seconds after the earlier file is deleted (measured on macOS 26 for
the move of version 0.3.1); then macOS drops them, and one entry is left. Someone who switched
Beacon off in Login Items keeps it off: nothing runs there, so nothing moves, until they
install or open it again.

### Older copies of the app

The Pteron app carries the installer, so a copy of the app from before the name carries an
installer that knows the two earlier names alone. Against a release that has the name, it
behaves as follows (`Relay/test-install.sh` runs that installer and holds these outcomes):

- **A new install** works and pushes reach the phone. Beacon takes its name as it starts, and
  the installer goes on with the path it put the app at: the Mac is not asked whether Beacon
  may show its own notice, and the installer's last sentence names a path that is gone.
- **An install over a Beacon that has its name** downloads the app once more; the copy it
  places gives way to the one that is there. The outcome is the same.
- **Remove** does not find the app or its background job. It deletes the state folder, so the
  phones registered on that computer are forgotten, while Beacon stays installed and running
  under `dev.abrahamgonzalez.rexduo.agent`. The app says Beacon was removed. Removing it from
  a current copy of the app, or by hand with the current script, finishes the job.

Those copies of the app are withdrawn (their TestFlight builds expired) once a release with
the name is out; until then, update the app before removing Beacon from it.

## Linux

```sh
curl -fsSL https://github.com/theabecaster/pteron/releases/download/helper-latest/install.sh | sh
```

The script downloads the newest release for x86_64 or aarch64, checks its signature, puts
`rex-duo-helper` in `~/.local/bin` and sets up a systemd user service. It needs `curl` and
`openssl` 3 and runs nothing as root. To read it first, download it and run `sh install.sh`.

The script prints the fingerprint of the key it checks the download with. It must be one of:

```
7b705fff0a944df37850e01668fc078f23c24aae7ab75075892ac84613cbd792   release key
f8de1b767a622ab0bd2671e32f34d63961edd993af28a6ad7fcb9179a76299f3   recovery key
```

(SHA-256 of the key's 32 bytes; the keys are in `Relay/update-key.pub`.)

To check the script before you run it, download it and compare its SHA-256 with this value for
the current release:

<!-- install-sha -->
```
29176463ef0c0d5d1fd26a5238b4204cdf7827a392bd9dd4b10966464a11f696  install.sh
```
<!-- /install-sha -->

## On the phone

Settings → Notifications: one switch for notifications and one per computer. A computer's row
says when its Beacon needs something, with one button for it, and its menu has **Send Test
Notification**, **Show Details** (Beacon's version and the computer's system), **Reinstall
Beacon** and **Remove Beacon…**. Reinstall and Remove run the installer, so they are only on a
Mac or Linux computer's menu.

## Updates

Beacon checks for a new release twice a day and installs it by itself. `rex-duo-helper update`
does it now; `rex-duo-helper update --check` only looks. To turn the automatic check off, set
`"auto_update": false` in Beacon's `config.json` (Relay/README.md has its location).

Before a new version replaces the running one, Beacon checks it:

- the list of releases is signed with the project's release key;
- the download has the size and SHA-256 that list names;
- on a Mac, the app is signed by the project's Apple developer team and notarized by Apple; on
  Linux, the binary carries its own signature from the release key.

If the new version doesn't start, Beacon puts the previous one back.

Beacon holds the pushes its person would see at a computer anyway, at this computer's desk or at
a desk elsewhere through the push gateway, until they leave or for 10 minutes at most
(Relay/README.md, Desk presence). It has no switch; the release list's `desk` and `signed_at`
fields belonged to one that never shipped, and every reader ignores them.

## Opening a dev server in the phone's browser

From 0.7.0. Pteron shows a dev server's page inside the app. For "Open in Browser", which
opens the page in Safari or any other browser on the phone, the computer's Beacon shares the
server's port with that phone for as long as it is used. This works only on a computer that
runs the regular Tailscale app, signed in to the same tailnet as the phone; on any other
computer the app does not offer it: Beacon's status answer says whether a share could
work (`share_possible`), which it finds out by asking the Tailscale app at most once a
minute.

What a share exposes, and to whom:

- One port of the computer, as a web page, at the computer's Tailscale name or address
  (`http://desk.example.ts.net:3000`). Beacon listens on the Tailscale address only: nothing
  is opened on your Wi-Fi or to the internet.
- Only the phone that asked can connect, by its own Tailscale address. Only a phone that is
  registered with this Beacon can ask, and Tailscale has to say that the phone is a device
  of the same Tailscale user as the computer. A connection from any other device is closed
  unread.
- Only web traffic passes (HTTP and WebSockets), and only to that one port. The dev server
  sees the request as a local one, so servers that only answer as `localhost` work.
- Only a port that one of your own programs listens on is shared, from 1024 up (or 80).
  The usual ports of debuggers, databases and the like are refused.
- At most eight shares exist at once, with at most 64 connections between them.

When it closes, by itself:

- 30 minutes after the phone's last connection to it closed;
- 10 minutes after the dev server stopped. Until then the address shows a small page that
  says nothing is running there, and it loads the real page again as soon as the server is
  back;
- when the phone turns notifications from this computer off or is removed with
  `rex-duo-helper forget`, and when Beacon stops or restarts.

Beacon also answers the app's question of which processes are behind a port (their ids,
names, process groups, the arguments they were started with and their folders, for your own
processes only), so that Stop and Restart in the app's Ports list work for a server started
through `npm run dev` and the like. It only reports: Beacon never stops, signals or starts a
process itself. Arguments go to your phone in that one answer and nowhere else: not to the
log, a file or the push gateway. Environment variables are never read out. The details of both are in `Relay/README.md`, steps 8 and 9.

## What it sends, and where

Beacon never holds an Apple key or your phone's notification token. Your phone registers with
the Pteron push gateway (`Gateway/`), gets a secret and hands that to your Beacons through Rex.
A Beacon sends the notification's text to the gateway with that secret, and the gateway passes it
to Apple. The secret can notify your phone and nothing else. Turning notifications off in the app
deletes it.

## Removing Beacon

From the phone: Settings → Notifications, the computer's menu, **Remove Beacon**. Pteron opens a
tab on the computer that stops Beacon and deletes it. By hand, on a Mac or on Linux, the
same script does it when it gets the two arguments `3 -`:

```sh
curl -fsSL https://github.com/theabecaster/pteron/releases/download/helper-latest/install.sh | sh -s -- 3 -
```

It downloads nothing and runs nothing as an administrator. It stops Beacon's background
service, removes its entry from launchd or systemd, and deletes what is listed below. On a Mac
the app stops its own service, and it is run only after its code signature was checked. On
Linux nothing that is installed is run: `systemctl --user disable --now rex-duo-helper` stops
the service.

- Mac: `Pteron Beacon.app` in `/Applications` and `~/Applications` (and a copy an update set
  aside, and the same under the earlier names `Rex DUO Beacon.app` and `Rex DUO Helper.app`),
  `~/Library/Application Support/Rex DUO Helper` and Beacon's log in
  `~/Library/Logs` (both keep the name the program first had);
- Linux: `~/.local/bin/rex-duo-helper` (and a copy an update set aside) and
  `~/.local/state/rex-duo-helper`.

The state folder holds the phones registered on that computer, so they are forgotten; installing
Beacon again starts fresh. Lingering on Linux stays as it is. On a Mac an app folder is deleted
only after it passes the code signature check; one that does not pass stays where it is. If
something can't be stopped or deleted, or stays, the script names it and ends with code 15.

Without the script: on a Mac run
`"/Applications/Pteron Beacon.app/Contents/MacOS/rex-duo-helper" uninstall`, then move the app
to the Trash; on Linux run `rex-duo-helper uninstall`, which also deletes
`~/.local/bin/rex-duo-helper`. Both leave the state folder.
