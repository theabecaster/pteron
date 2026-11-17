# Rex DUO Helper: install and update

Rex DUO Helper sends your phone a notification while the Rex DUO app is closed: when an agent
needs you, finishes, or a terminal asks for attention. Install it on each computer that runs a Rex
server. It needs no account and no key, and it keeps itself up to date.

## From the phone

After you add a computer, Rex DUO offers to install the helper on it: tap **Install**. The same
offer is in Settings → Notifications. Rex DUO opens a tab on the computer, which downloads the
helper, checks it and starts it; nothing runs as an administrator. It needs a Mac or Linux
computer you own with a recent Rex. To install by hand instead:

## Mac

1. Download `Rex-DUO-Helper.zip` from the newest "Rex DUO Helper" release at
   <https://github.com/theabecaster/rexduo/releases>.
2. Unzip it and drag **Rex DUO Helper** to Applications.
3. Open it once. It asks to send notifications (for the one "Rex DUO connected" notice per phone),
   then runs in the background and starts again at login.

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
(set when a release is published)
<!-- /install-sha -->

## On the phone

Settings → Notifications → Allow Notifications. The same section shows each computer's helper,
its version, and an **Update** button when a newer one is out.

## Updates

The helper checks for a new release twice a day and installs it by itself. `rex-duo-helper update`
does it now; `rex-duo-helper update --check` only looks. To turn the automatic check off, set
`"auto_update": false` in the helper's `config.json` (Relay/README.md has its location).

Before a new version replaces the running one, the helper checks it:

- the list of releases is signed with the project's release key;
- the download has the size and SHA-256 that list names;
- on a Mac, the app is signed by the project's Apple developer team and notarized by Apple; on
  Linux, the binary carries its own signature from the release key.

If the new version doesn't start, the helper puts the previous one back.

## What it sends, and where

The helper never holds an Apple key or your phone's notification token. Your phone registers with
the Rex DUO push gateway (`Gateway/`), gets a secret and hands that to your helpers through Rex.
A helper sends the notification's text to the gateway with that secret, and the gateway passes it
to Apple. The secret can notify your phone and nothing else. Turning notifications off in the app
deletes it.

## Remove

Mac: `"/Applications/Rex DUO Helper.app/Contents/MacOS/rex-duo-helper" uninstall`, then move the
app to the Trash. Linux: `rex-duo-helper uninstall`, then delete `~/.local/bin/rex-duo-helper`.
