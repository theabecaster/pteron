"""Runs a command in a pseudo-terminal the way a Rex tab does, for Relay/test-install.sh, and
plays Rex DUO's part: when the command reports that it waits for the setup code, types it.

    python3 -I pty-run.py <output file> <code file or -> <command> [arguments…]

Everything the command writes to the terminal goes to the output file. When an OSC 7501 record
with the title `code` appears, the contents of the code file are typed into the terminal,
followed by Return, once. With `-` nothing is typed. A `|` in the file is not typed: the part
after it follows 1.2 seconds later. The code is read from a file so that it is in no command
line here either.

Ends with the command's exit code (128 + the signal's number when a signal ended it). A hangup
or a termination signal sent to this program hangs up the command's process group and closes
the terminal, as closing the tab does, and then waits for the command.
"""

import base64
import os
import pty
import re
import select
import signal
import sys
import time

out_path, code_path, command = sys.argv[1], sys.argv[2], sys.argv[3:]
code = b""
if code_path != "-":
    with open(code_path, "rb") as f:
        code = f.read()

closing = False
pid = 0


def close_terminal(*_):
    global closing
    closing = True
    if pid:
        try:
            os.killpg(pid, signal.SIGHUP)
        except OSError:
            pass


signal.signal(signal.SIGHUP, close_terminal)
signal.signal(signal.SIGTERM, close_terminal)

pid, fd = pty.fork()
if pid == 0:
    os.execvp(command[0], command)

seen = b""
typed = False
with open(out_path, "wb", buffering=0) as out:
    while not closing:
        try:
            ready, _, _ = select.select([fd], [], [], 0.2)
        except InterruptedError:
            continue
        if not ready:
            continue
        try:
            data = os.read(fd, 65536)
        except OSError:
            break
        if not data:
            break
        out.write(data)
        if typed or code_path == "-":
            continue
        seen += data
        for title in re.findall(rb"\x1b\]7501;[^\x1b\x07]*:title=([A-Za-z0-9+/=]*)[^\x1b\x07]*\x1b\\", seen):
            if base64.b64decode(title) == b"code":
                first, _, rest = code.partition(b"|")
                if rest:
                    os.write(fd, first)
                    time.sleep(1.2)
                    first = rest
                os.write(fd, first + b"\r")
                typed = True
                break
os.close(fd)
_, status = os.waitpid(pid, 0)
sys.exit(128 + os.WTERMSIG(status) if os.WIFSIGNALED(status) else os.WEXITSTATUS(status))
