# Rex control protocol, as Rex DUO uses it

The source of truth is `https://<server>/llms.txt` on any Rex server. This file records what the
app relies on; update it when you use a new method or event.

## Connection

- `wss://<server>/api/control`, subprotocol `rex.control.v1`. Only servers with Rex's Tailscale on
  are reachable (`rex server tailscale on`), and the phone must be on the same tailnet and user.
- The client sends `hello` with `api_revision` (`RexControl.apiRevision`, 13), `client`
  (`kind`, `platform`, `name` "Rex DUO", `version`, `label` = device name) and
  `reconnect_token` when resuming. The server answers `welcome` with `client.id`,
  `client.reconnect_token` and `limits.max_message_bytes`. No welcome in 8 s fails the connect.
- The app pings every 30 s. On a drop, or a failed first connect, it backs off 1 s → 15 s,
  reconnects with the token, then resyncs, since events may have been missed. A refused upgrade's
  HTTP status (401/403: not allowed; 404/5xx: not Rex) and close code 1008 are kept for the offline
  screen.

## Messages

- Request `{type: "request", id, method, payload}` → `{type: "response", id, payload}` or
  `{…, error: {code, message, status}}` (thrown as `RexError`).
- Event `{type: "event", seq, payload: {type, payload}}`. `seq` counts from 1 per connection with
  no gaps; a gap triggers a resync.
- Block methods take `{session_id, block_id, args}`; terminal ones are
  `com.superlogical.terminal.<name>`. The server doesn't order concurrent block calls.

## Methods used

- Sessions: `session.bootstrap` (`event_scope: "all"`), `attach`, `view`, `list`, `create`,
  `destroy`, `set_label`, `new_window`, `close_window`, `set_window_label`, `focus_window`,
  `new_split`, `focus_block`, `zoom_block`, `resize_pane` (ratio 0.05–0.95), `own_block`
  (`mode: "take"`), `disown_block`.
- Other: `block.close`, `hosts.list`, `data.connect`, `client.keymap`, `client.action`,
  `client.key`.
- Before a server is added (`ServerPreview`, one short connection that attaches to nothing):
  `server.status` (owner, session count), `server.version` (platform), `server.whoami` (account,
  this device's login), `session.list`, `client.list` (is a helper there).
- Terminal block: `size`, `format` (`vt` with the `extra_*` flags for the screen, `text` for tab
  previews), `blob_read`, `write`, `resize`, `clear`, `title`, `process`, `program_status`,
  `upload_begin`, `download_begin`.

## Files (`rex.data.bytes.v1`)

`upload_begin` and `download_begin` give a ticket for a data connection (`GET /api/data`) with
subprotocol `rex.data.bytes.v1`, with the same HELLO, WELCOME and REJECT as a terminal stream.
`/llms.txt` doesn't describe an upload's bytes. This is what probes of Rex servers showed (revision
13 on Linux, 16 on macOS), checked with SHA-256; `BytesStream` in RexKit records it.

- **Upload.** After the WELCOME the client sends the file as binary messages of at most 64 KiB (a
  1 MiB message drops the connection), then one empty binary message: the file is complete. The
  server moves it into place and closes with 1000. Until then the bytes sit in `<name>.partial`.
- **Wrong size.** Ending short of `size`, or sending past it, closes with 4006 `data stream broke
  a rule` and aborts the batch.
- **Cancel.** Any other end before the empty message, a close with 1000 included, aborts the
  upload and its whole batch at once: the batch's files are deleted, nothing is typed, and a later
  `upload_begin` with that batch ID fails with `conflict`. A RESUME is refused (REJECT 0x03), so a
  lost upload starts again with a new `upload_begin`.
- **Batch.** A batch's files may arrive in any order; once all `count` have, the server types their
  paths in `index` order, separated by spaces, with a trailing space. A file without a batch is
  typed when it arrives. Uploads to one block can run at the same time.
- **Limits and names.** `size` up to 104857600 bytes (100 MiB), else `too_large`; a negative size
  and a `ref` without a lower-case UUID are `bad_request`; `.` and `..` are not file names. The
  server drops directories and control characters from the name (an empty one becomes `upload`)
  and cuts it to 247 bytes keeping the extension. Paths are typed escaped for a shell with
  backslashes: `it\'s\ \"q\".txt`, `\$HOME\;\`x\`\&.txt`. A leading `-` is harmless inside an
  absolute path.
- **Landing folder.** `<state>/rex/uploads/<pid>-<instance>/<block uuid>/<ref uuid>/<name>`, files
  0600 in 0700 folders: `~/.local/state/rex/uploads` on Linux, `~/Library/Application
  Support/rex/uploads` on macOS. Closing the block deletes its folder.
- **Download.** After the WELCOME the server sends the file in binary messages (32 KiB in
  practice) and closes with 1000; closing with 1000 cancels. Refusals: `not_found`, and
  `bad_request` for a folder ("is a directory"), a device ("not a regular file") or a file the
  server can't open ("permission denied"). `version` is left out while the file changed in the
  last second; with `if_none_match` set to a current version the answer is `not_modified`.
- **Support.** A server without the methods answers `method_not_found`. The app asks with a `ref`
  the server must refuse: a server that has them answers `bad_request` and reserves nothing.

## Events handled

- Top level: `session_created`, `session_destroyed`, `session_moved`, `hosts_changed`,
  `keymap_changed`, `session_event`.
- Inside `session_event`: `session_view_changed` (re-read if the revision is newer),
  `session_label_changed`, `block_created`, `block_event`, and `window_created`,
  `window_closed`, `window_label_changed`, `active_window_changed`, `block_closed`,
  `block_owner_changed`, which trigger a debounced `session.view`.
- `block_event` names: `title_changed`, `pwd_changed`, `process_changed`,
  `program_status_changed`, `program_status_removed`, `bell`, `child_exited`,
  `desktop_notification`.

## Program status (OSC 7501)

Agents report records with `state` idle | working | done | blocked | error, plus `app`
(or `effective_app`), `msg`, `title`, `progress`, and for blocked a `kind` (permission, question,
auth). A block shows its most urgent record: blocked > error > working > done > idle.

## Keymap

`client.keymap` returns Rex's defaults under the user's `init.lua`. The app sends the actions it
can perform (`KeyActions`) and its default layer (`KeyDefaults`), keeps single-key bindings, and
re-reads on `keymap_changed`. Bindings to actions the app lacks fall through to the next binding
or the terminal; config-file and block actions run on the server with `client.action`; keys bound
to Lua functions go to `client.key`.
