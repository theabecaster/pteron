# Rex DUO Beacon: install and update

Rex DUO Beacon sends your phone a notification while the Rex DUO app is closed: when an agent
needs you, finishes, or a terminal asks for attention. Install it on each computer that runs a Rex
server. It needs no account and no key, and it keeps itself up to date.

## From the phone

After you add a computer, Rex DUO offers to install Beacon on it: tap **Install**. The same
offer is in Settings → Notifications. Rex DUO opens a tab on the computer, which downloads the
Beacon, checks it and starts it; nothing runs as an administrator. It needs a Mac or Linux
computer you own with a recent Rex. To install by hand instead:

## Mac

1. Download `Rex-DUO-Beacon.zip` from the newest "Rex DUO Beacon" release at
   <https://github.com/theabecaster/rexduo/releases>.
2. Unzip it and drag **Rex DUO Beacon** to Applications.
3. Open it once. It asks to send notifications (for the one "Rex DUO connected" notice per phone),
   then runs in the background and starts again at login.

Rex DUO Beacon was called Rex DUO Helper before. A Mac that has `Rex DUO Helper.app` keeps
everything it allowed and every registered phone: the next update or install leaves one app,
`Rex DUO Beacon.app`, in the same Applications folder. The command-line program is still
`rex-duo-helper`, and the state folder and the log keep their names.

macOS keeps the app's path in its Launch Services record too, and the move takes it along:
Launch Services is told to forget `Rex DUO Helper.app` and to record `Rex DUO Beacon.app`
(`lsregister -u`, then `-f`). After that the LaunchAgent is written for the new path and loaded.
If `lsregister` is missing or fails, the move goes on without it.

The background job is the LaunchAgent `dev.abrahamgonzalez.rexduo.beacon`
(`~/Library/LaunchAgents/dev.abrahamgonzalez.rexduo.beacon.plist`). Its label was
`dev.abrahamgonzalez.rexduo.helper` before, and macOS names a job in System Settings → General →
Login Items after the app it found when the job's file first appeared, for as long as that
file exists. So the label moves once, in this order: the file of the new label is written for
the program where it is now, the earlier job is booted out and the new one loaded, Beacon
reports in `status.json` that it runs under the new label, and only then is the earlier file
deleted. One of the two files exists at every moment. If Beacon does not report in within 20 s,
the new job is booted out, its file removed, the earlier job loaded again from its file, and
one line goes to the log; the next start tries again. An install, a repair, opening the app
and the app's move to its name all make this move, and so does a Beacon that finds itself
running under the earlier label, about 30 s after it started. With both files there at a start
(a move that was cut short), the Beacon under the new label boots the earlier job out and
deletes its file, and one under the earlier label gives way to it. `rex-duo-helper status`
names the label in use.

In Login Items the person sees a new entry named **Rex DUO Beacon** once the new file is
written. The entry of the earlier label, and the one of the app's earlier path, stay beside it
until about 70 seconds after the earlier file is deleted (measured on macOS 26); then macOS
drops them, and one entry is left.

## Linux

```sh
curl -fsSL https://github.com/theabecaster/rexduo/releases/download/helper-latest/install.sh | sh
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
ca42ec66c41db41acaf911ced36128a85971dfe951798e39dbd906be7ffebd13  install.sh
```
<!-- /install-sha -->

## On the phone

Settings → Notifications: one switch for notifications and one per computer. A computer's row
says when its Beacon needs something, with one button for it, and its menu has **Send Test
Notification**, **Show Details** (Beacon's version and the computer's system), **Reinstall
Beacon** and **Remove Beacon…**.

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

## What it sends, and where

Beacon never holds an Apple key or your phone's notification token. Your phone registers with
the Rex DUO push gateway (`Gateway/`), gets a secret and hands that to your Beacons through Rex.
A Beacon sends the notification's text to the gateway with that secret, and the gateway passes it
to Apple. The secret can notify your phone and nothing else. Turning notifications off in the app
deletes it.

## Removing Beacon

From the phone: Settings → Notifications, the computer's menu, **Remove Beacon**. Rex DUO opens a
tab on the computer that stops Beacon and deletes it. By hand, on a Mac or on Linux, the
same script does it when it gets the two arguments `3 -`:

```sh
curl -fsSL https://github.com/theabecaster/rexduo/releases/download/helper-latest/install.sh | sh -s -- 3 -
```

It downloads nothing and runs nothing as an administrator. It stops Beacon's background
service, removes its entry from launchd or systemd, and deletes what is listed below. On a Mac
the app stops its own service, and it is run only after its code signature was checked. On
Linux nothing that is installed is run: `systemctl --user disable --now rex-duo-helper` stops
the service.

- Mac: `Rex DUO Beacon.app` in `/Applications` and `~/Applications` (and a copy an update set
  aside, and the same under the earlier name `Rex DUO Helper.app`),
  `~/Library/Application Support/Rex DUO Helper` and Beacon's log in
  `~/Library/Logs`;
- Linux: `~/.local/bin/rex-duo-helper` (and a copy an update set aside) and
  `~/.local/state/rex-duo-helper`.

The state folder holds the phones registered on that computer, so they are forgotten; installing
Beacon again starts fresh. Lingering on Linux stays as it is. On a Mac an app folder is deleted
only after it passes the code signature check; one that does not pass stays where it is. If
something can't be stopped or deleted, or stays, the script names it and ends with code 15.

Without the script: on a Mac run
`"/Applications/Rex DUO Beacon.app/Contents/MacOS/rex-duo-helper" uninstall`, then move the app
to the Trash; on Linux run `rex-duo-helper uninstall`, which also deletes
`~/.local/bin/rex-duo-helper`. Both leave the state folder.
