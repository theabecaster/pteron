"""Reads what setup.sh printed and lists its OSC 7501 program-status records, for
Relay/test-install.sh.

    python3 -I osc.py <captured output>

One line per record: state, title, progress or `-`, kind or `-`. It fails when a record is not
the agreed shape: `ESC ] 7501 ; key=value:key=value… ESC \\`, id and app `rexduo-setup`, title
and msg in base64, msg a plain sentence.
"""

import base64
import re
import sys

data = open(sys.argv[1], "rb").read()
records = re.findall(rb"\x1b\]7501;([^\x1b\x07]*)\x1b\\", data)
if data.count(b"\x1b]7501;") != len(records):
    sys.exit("a record does not end with ESC \\")
for raw in records:
    fields = dict(part.split("=", 1) for part in raw.decode("ascii").split(":"))
    if fields.get("id") != "rexduo-setup" or fields.get("app") != "rexduo-setup":
        sys.exit(f"wrong id or app: {fields}")
    if set(fields) - {"id", "app", "state", "progress", "kind", "title", "msg"}:
        sys.exit(f"unknown field: {fields}")
    title = base64.b64decode(fields["title"], validate=True).decode()
    msg = base64.b64decode(fields["msg"], validate=True).decode()
    if not msg.strip() or "\n" in msg or "\x1b" in msg:
        sys.exit(f"msg is not one plain sentence: {msg!r}")
    progress = fields.get("progress", "-")
    if progress != "-" and not 0 <= int(progress) <= 100:
        sys.exit(f"progress out of range: {progress}")
    print(fields["state"], title, progress, fields.get("kind", "-"))
