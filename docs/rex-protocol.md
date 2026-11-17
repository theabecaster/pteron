# Rex control protocol, as Rex DUO uses it

The source of truth is `https://<server>/llms.txt` on any Rex server. This file records what the
app relies on; update it when you use a new method or event.

## Connection

- `wss://<server>/api/control`, subprotocol `rex.control.v1`. Only servers with Rex's Tailscale on
  are reachable (`rex server tailscale enable`), and the phone must be on the same tailnet and user.
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
  previews), `blob_read`, `write`, `resize`, `clear`, `title`, `process`, `program_status`.

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
