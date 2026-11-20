# Rex control protocol, as Pteron uses it

The source of truth is `https://<server>/llms.txt` on any Rex server. This file records what the
app relies on; update it when you use a new method or event.

## Connection

- `wss://<server>/api/control`, subprotocol `rex.control.v1`. Only servers with Rex's Tailscale on
  are reachable (`rex server tailscale on`), and the phone must be on the same tailnet and user.
- The client sends `hello` with `api_revision` (`RexControl.apiRevision`, 18), `client`
  (`kind`, `platform`, `name` "Pteron", `version`, `label` = device name) and
  `reconnect_token` when resuming, and no `api_min_revision` (see API revisions). The server
  answers `welcome` with `client.id`, `client.reconnect_token`, `limits.max_message_bytes` and
  the revisions. No welcome in 8 s fails the connect.
- The app pings every 30 s, and on each return to the foreground (no pong in 2.5 s is a drop). On a drop, or a failed first connect, it backs off 1 s → 15 s,
  reconnects with the token, then resyncs, since events may have been missed. A refused upgrade's
  HTTP status (401/403: not allowed; 404/5xx: not Rex), the close code and its reason are kept for
  the offline screen.
- Close code 1008 has two reasons, and only one of them stops the retries. `no common API
  revision: …` means a retry would be refused the same way: `RexControl` stops (`retryStopped`)
  until the user taps Try Again or the app comes back, and the offline screen says which side to
  update, from the end of the reason ("update the server": "Update Rex on <server>"; "update the
  client": "Update Pteron"; neither: the text for any other 1008). `event backlog exceeded` (the
  phone fell 8 MiB of events behind) is an ordinary drop: reconnect and resync.

## API revisions

Every server so far speaks revisions 0 up to its own newest, and translates each connection to the
revision its welcome names. The app says 18 and no minimum, so the server picks the newest
revision both have: an older server connects at its own revision, exactly as it did when the app
said 13, and a newer one translates down to 18. Revisions 14 to 18 change no shape the app sends
or decodes; they add methods and events (14: tunnels; 15: `terminal.ports`, `ports_changed`;
17 to 18: the prompt events and `event_dropped`).

- `RexControl` keeps `negotiatedRevision` (the welcome's `api_revision`; left out means 0),
  `serverRevision` (`api_server_revision`) and `features`, from every welcome, a resumed one
  included: a server can be updated or downgraded between two connections.
- A method newer than 13 is listed with its revision in `RexAPI.minimumRevision`. A call on a
  connection below it fails in the app with `revision_too_low` and is never sent.
- A feature never reads a version string. It asks `ServerCapabilities` (one per server):
  `supports(revision)`; the creator list (`block_creator.list`, whose `api.methods`, `api.events`
  and `flavors` say what each host's blocks can do, per `host_id`); and a probe slot per method
  and host, filled by the feature's own first call. A missing capability hides the feature's
  entry points for that server only.
- "Absent" means `method_not_found`, `revision_too_low`, a missing creator or flavor, or
  `not_found` when the target is known to exist (servers from before `method_not_found` say
  `not_found` for a missing method, and for a missing block too). Any other error leaves the
  answer unknown: the probe is asked once more on that connection, no sooner than 60 s later,
  and again on the next connection.
- The creator list has three states: unknown, known and failed. Unknown and failed both mean no
  answer. A creator that sends no `api.methods` (or no `api.events`) is unknown for methods (or
  events), never "missing".
- The list is about 70 KB (71233 bytes from a revision-18 server with three creators), so it is
  read once per server process (`server_status.instance_id`) and revision, on the first sync that
  meets them, and after that only on `creator_changed` and `hosts_changed`. A resync and a
  reconnect to the same process at the same revision read nothing. A server that names no
  process is read once per connection. Across a reconnect at the same revision the last list
  stays in use. A read that fails never replaces a known list: the list stays, and the next sync
  reads again. A server's error for the first read is `failed`, and is not asked for again.
- Unknown welcome fields, features, creators, flavors, events and error codes are ignored; an
  unknown error code is handled by its `status`.
- `session.create` leaves the new blocks without an owner at every revision (checked at hellos 0,
  13, 16 and 18 against a revision-18 server): a pane is owned once fit mode takes it
  (`session.own_block`), as before.

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
  (`mode: "take"`), `disown_block`, and for Arrange and the sidebar's reorder `swap_blocks`,
  `move_block`, `move_window` and `move` ([terminal.md](terminal.md), Arrange;
  [sidebar.md](sidebar.md), Reorder).
- Other: `block.close`, `hosts.list`, `block_creator.list`, `data.connect`, `client.keymap`,
  `client.action`, `client.key`, `client.reply`.
- Ports: `session.new_block` (dial tunnels), `session.list_blocks` (the sweep),
  `com.superlogical.terminal.ports`. Several `block.close` go through `RexControl.callInOrder`,
  which sends them in one turn, in order.
- Before a server is added (`ServerPreview`, one short connection that attaches to nothing):
  `server.status` (owner, session count), `server.version` (platform), `server.whoami` (account,
  this device's login), `session.list`, `client.list` (is a helper there).
- Terminal block: `size`, `format` (`vt` with the `extra_*` flags for the screen, `text` for tab
  previews, `text` with `trim` and `unwrap` or `html` for Share's All Output), `blob_read`,
  `write`, `resize`, `clear`, `title`, `process`, `program_status`, `upload_begin`,
  `download_begin`, `ports`.

## Ordered calls

The server runs its ordered methods (`move_block`, `move_window`, `swap_blocks`, `block.close`,
`new_window`, from revision 13) one at a time in arrival order on a connection; others, and
responses, can come in any order. `RexControl.callInOrder` hands every request of a sequence to
the socket in one turn of the main actor, which keeps their order on the wire, then waits for all
the answers. Separate calls, `async let` or a task group promise no order. Move to New Tab and
Close Other Panes use it. `session.move` isn't ordered, so the app sends one at a time.

## Share's All Output (`format`, `blob_read`)

- `format` with `max_bytes` answers `content`, and `id` and `total` while more remains; `eof` only
  on newer servers, so the reader checks `id`. A reply without `id` is the whole output.
- `blob_read` with that `id`, `offset` (bytes of content received so far) and `max_bytes` answers
  `data`, `total` and `eof`. `max_bytes` counts the JSON-encoded string, so `data` can be shorter
  than asked. `data` never ends inside a character. An `offset` inside a character returns one
  U+FFFD for each byte from there to the next character (probed on a revision-18 server, macOS),
  so a read that starts at a cut counts each leading U+FFFD as one byte, not three.
- `id` 0 reads the newest result, whatever made it, so the reader always sends its own `id`. A
  concurrent `format` (tab previews, a reconnect's screen read, another phone) can evict it:
  `not_found`, after which the read starts over once.
- Detection: the pane's creator on its host lists `format` and `blob_read` in `api.methods`. An
  unknown or failed creator list counts as present (both exist at revision 13). No probe call.

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
  typed when it arrives; the app always sends a batch, one of a single file included. Reserving an
  index twice is `bad_request` ("already reserved"). Reserving the next index and closing its
  connection with 1000 right after the WELCOME aborts the batch and deletes its finished files,
  which is how the app cancels between files. A batch left unfinished is aborted when its client
  leaves the server. Uploads to one block can run at the same time.
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

- Top level: `session_created`, `session_destroyed`, `session_moved` (`session.list`, read as for
  a dropped one below), `hosts_changed` (hosts, then creators), `keymap_changed`, `client_joined`, `client_left`, `client_prompt_requested`,
  `client_prompt_ended`, `event_dropped`, `session_event`.
- Inside `session_event`: `session_view_changed` (re-read if the revision is newer),
  `session_label_changed`, `block_created`, `block_event`, `creator_changed` (re-read the
  creators), and `window_created`, `window_closed`, `window_label_changed`,
  `active_window_changed`, `block_closed`, `block_owner_changed`, which trigger a debounced
  `session.view`.
- An event of a type the app doesn't know is skipped, at the top level, in a session and in a
  block.
- `block_event` names: `title_changed`, `pwd_changed`, `process_changed`,
  `program_status_changed`, `program_status_removed`, `bell`, `child_exited`,
  `desktop_notification` (a notice toast, [notifications.md](notifications.md)), `progress_report`
  (a progress ring, [sidebar.md](sidebar.md)), `ports_changed` (a pane's ports, for panes on
  screen only; [terminal.md](terminal.md), Ports).

### Progress and notices (terminal block events)

| Event | Payload, as Rex preview.21 sends it |
| --- | --- |
| `progress_report` | `state` set, indeterminate, pause, error or remove; `progress` 0 to 100 (the schema allows 255, the app clamps). `\e]9;4;1` without a value comes as `set` with 0, `\e]9;4;2` as `error` alone. Repeats are sent, also identical ones. No method reads the current value. |
| `desktop_notification` | `title` (empty for OSC 9) and `body` |

Compatibility: neither is in any `llms.txt`; both are listed at runtime in the terminal creator's
`api.events` (`block_creator.list`), seen on rev-13 builds and on preview.20 and .21. The app uses
them only for blocks whose host's terminal creator lists them (`ServerConnection.sendsEvent`); an
unknown or failed creator list counts as absent. Without them the app shows no ring and no notice,
exactly as before. Nothing is probed or sent for either. Unknown `state` values are ignored.

## Dropped events (`event_dropped`, revision 18)

The server sends `event_dropped` in place of an event too large to send, with that event's `seq`,
so no gap shows. `ServerConnection.recover(dropped:)` reads back only what the lost event would
have changed (`DroppedEvent.recovery`); a full sync is the last resort, because it reads every
session and features hang work on it.

| Dropped `event_type` | Read again |
| --- | --- |
| `block_event` (with `block_id`) | that block's status, title and process, once per block for a burst, then the handlers registered for its `block_event_name` (`router.on(blockEvent:)`). The session comes from the event, or from the view that holds the block. Never a full sync. |
| `creator_changed` | `block_creator.list` |
| `session_created`, `session_destroyed`, `session_moved` | `session.list`, once for a burst and one at a time: gone sessions leave, new ones are attached, the order is the server's. An event while it is out asks for one more read; a read an event or a full sync came after is dropped |
| `hosts_changed` | `hosts.list` and `block_creator.list` |
| `keymap_changed` | `client.keymap` |
| `client_joined`, `client_left`, `client_changed` | the push helper's lookup |
| `client_*_requested` (prompt, call, perform) | nothing: the `call_id` to answer went with the event. A prompt then stays open on the other apps, or runs out its `timeout_ms` |
| `client_prompt_ended`, `client_performed`, `client_script_events_dropped`, `tailscale_status_changed` | nothing: the app keeps no state for them |
| any other type with a `session_id` | that session's view (`session.view`), once for a burst |
| any other type without one | a full sync |

A status read back this way doesn't toast, as after any resync. A dropped `desktop_notification`
is lost. A dropped `progress_report` clears that pane's ring until the next report (its handler). A metadata read is older than any live event that arrives while it is out: what such an
event set (status, title or process) is kept, and the read fills in the rest.

## Prompts (`client_prompt_requested`, revision 17)

An action from the configuration file that calls `rex.ui` asks every connected app a question;
the first answer wins. The app shows only the questions of actions it ran itself, in the palette
(below); every other one is declined. `ServerConnection.receivePrompt` answers each it isn't given with
`client.reply {call_id, error: {code: "not_supported"}}` in the turn the event arrives
(`RexControl.post`), which takes only this app out of the prompt: it stays open on the Mac. The
decline is the same at every revision, so a prompt that reaches an older connection isn't left
waiting.

`prompts.onPrompt` is the hook for a feature that shows prompts: it gets a `PromptRequest`
(`call_id`, `action`, the prompt, `timeout_ms`, when it came and on which `connectionSerial`) and
returns true to take it, after which it owes the reply. A prompt whose `kind` isn't `input` or
`pick` is declined without asking the hook. `prompts.onPromptEnded` passes on
`client_prompt_ended`. A `call_id` belongs to its connection: after a reconnect the holder drops
the prompt without replying (`prompts.onConnected`).

The palette (`GoToCenter`) takes a prompt only on a connection at revision 17 or later, when its
`action` names a Lua or block action this phone ran (from a key or the palette) on the same
server and connection, whose `client.action` hasn't answered yet, started within 10 s (or
answered from here since), of kind `input` or `pick`, and the tent board isn't up. It replies
with `client.reply` straight on `RexControl`, never through the pane's input queue, where the
waiting `client.action` holds the one slot: `{"text": …}`, `{"ids": […]}` or
`{"cancelled": true}`. A `bad_request` answer keeps the question open; anything else closes it.
Questions taken while one shows wait their turn and keep their `timeout_ms`.

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

The request asks `server_actions: "configured"` (about 2 KB instead of about 20 KB for `all`),
and the app keeps the reply's `actions` with `kind: "lua"` for the palette's rows
(`KeymapStore.luaActions`). A server that ignores `server_actions` lists everything; only the
`lua` entries count, so the rows are the same. A key runs an action with `origin: "key"`; a row
of the palette with `origin: "palette"` (docs/goto.md, Running). With no tab on screen the
palette's `client.action` leaves out `session_id`. `pane.copy_mode.*` and `client.tab.mute` are
the Mac app's own: their keys stay unbound on the phone and never reach `client.action`.

## Ports and dial tunnels (revisions 14 and 15)

`com.superlogical.terminal.ports` (revision 15; `revision_too_low` below) answers `status` (ok,
partial, unsupported; anything else counts as partial), `ports[]` (`port`, `address` as an IP
literal, `protocol`, `first_seen_at`, `pid` when known), `processes[]` and `truncated`. It doesn't
wake an idle terminal: read it once, then follow the `ports_changed` block event, which carries
the same reply. A `ports_changed` also reaches a revision-13 connection to a newer server, so
the event is never a gate. A truncated reply keeps the entries that came; the app reads no blob.

A dial tunnel is a block of flavor `com.superlogical.tunnel.dial` (listed by
`block_creator.list` for the server's host), made with `session.new_block` and options `host`,
`port` and `client_address`. It starts detached, owned by the client that made it, and is in no
view; `session.list_blocks` lists it (`placement` detached), and so does `rex forward ls`. Its
`block_created`, `block_owner_changed` and `block_closed` reach every attached client. Rex never
removes one, and it survives a server restart without an owner, so its maker closes it
(`block.close`). Each TCP connection is a data connection: `data.connect` with `data_ref_id`
`conn:<uuid>` and subprotocol `rex.data.bytes.v1`, then HELLO and WELCOME, then bytes both ways
(`TunnelRelay` records the rules: at most 64 KiB per message from the client, an empty message
is a half-close, 1001 with no bytes is a refused target, 4000 a closed block, 4006 not the
owner). The same holds on macOS and Linux servers (preview.21, revision 18).
