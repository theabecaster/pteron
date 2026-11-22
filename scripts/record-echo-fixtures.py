#!/usr/bin/env python3
"""Records predicted-echo fixtures from a real shell in a pty.

It plays the phone, the link and the server at once: keys are typed on a client clock, go out
in writes as TerminalStream queues them (one write out at a time, keys typed meanwhile go
together in the next), reach the shell half a round trip later, and the shell's output and the
tty's (echo, canonical) state are stamped with the time they reach the client.
"""
import fcntl, json, os, pty, select, struct, subprocess, sys, termios, time

RTT = 0.150

def winsize(fd, cols, rows):
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))

def tty_state(fd, cache):
    a = termios.tcgetattr(fd)
    echo, canon = bool(a[3] & termios.ECHO), bool(a[3] & termios.ICANON)
    try:
        pg = os.tcgetpgrp(fd)
    except OSError:
        pg = -1
    if pg not in cache:
        try:
            cache[pg] = subprocess.run(["ps", "-o", "comm=", "-p", str(pg)], capture_output=True, text=True).stdout.strip().split("/")[-1]
        except Exception:
            cache[pg] = ""
    return (echo, canon, cache[pg])

def drain(fd, secs):
    end = time.monotonic() + secs
    out = b""
    while True:
        left = end - time.monotonic()
        if left <= 0: return out
        r, _, _ = select.select([fd], [], [], left)
        if r:
            try: out += os.read(fd, 65536)
            except OSError: return out

def kind(b):
    if 0x20 <= b <= 0x7e: return {"key": b}
    if b == 0x7f: return {"back": True}
    return {"boundary": True, "newLine": b in (0x0d, 0x0a, 0x03, 0x04, 0x1a)}

def record(name, script, setup=(), cols=80, rows=24, echo_delay=0.0, source=""):
    pid, fd = pty.fork()
    if pid == 0:
        env = {"TERM": "xterm-256color", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": os.environ.get("REC_HOME", "/tmp"),
               "LANG": "en_US.UTF-8", "PS1": "%~ %# "}
        os.chdir(env["HOME"])
        os.execve("/bin/zsh", ["zsh", "-f", "-i"], env)
    winsize(fd, cols, rows)
    drain(fd, 0.8)
    for line in ("unsetopt zle_bracketed_paste; unset HISTFILE",) + tuple(setup):
        os.write(fd, line.encode() + b"\r")
        drain(fd, 0.4)

    # The client's timeline.
    T = 0.3
    keys, extras, seq = [], [], 0
    # Control-L first: the shell clears and draws its prompt, so the client starts from the
    # same screen as the shell.
    seq += 1; keys.append((0.0, seq, 0x0c))
    for act in script:
        if act[0] == "pause": T += act[1]
        elif act[0] == "type":
            for ch in act[1].encode():
                seq += 1; keys.append((T, seq, ch)); T += act[2]
        elif act[0] == "send":   # several bytes in one input call: a boundary
            seq += 1; keys.append((T, seq, act[1].encode())); T += 0.05
        elif act[0] == "mark": extras.append({"t": round(T, 4), "mark": act[1]})
        elif act[0] == "resize":
            extras.append({"t": round(T, 4), "resize": [act[1], act[2]]})
            extras.append({"server": T + RTT / 2, "winsize": (act[1], act[2])})
    end = T + 2.2 + echo_delay

    steps = []
    for (t, s, b) in keys:
        k = kind(b) if isinstance(b, int) else {"boundary": True, "newLine": any(x in (0x0d, 0x0a, 3, 4, 0x1a) for x in b)}
        steps.append(dict(t=round(t, 4), seq=s, **k))
    # The stream's queue: one write out at a time.
    writes, free, i = [], 0.0, 0
    while i < len(keys):
        leave = max(keys[i][0], free)
        j, data = i, b""
        while j < len(keys) and keys[j][0] <= leave:
            b = keys[j][2]; data += bytes([b]) if isinstance(b, int) else b; j += 1
        writes.append((leave, data, keys[j - 1][1]))
        steps.append({"t": round(leave + RTT, 4), "answered": keys[j - 1][1]})
        free = leave + RTT
        i = j
    actions = sorted([(w[0] + RTT / 2, "write", w[1]) for w in writes] +
                     [(e["server"], "winsize", e["winsize"]) for e in extras if "server" in e], key=lambda a: a[0])
    steps += [e for e in extras if "server" not in e]

    cache, last = {}, None
    t0 = time.monotonic()
    def note_state():
        nonlocal last
        st = tty_state(fd, cache)
        if st != last:
            last = st
            steps.append({"t": round(time.monotonic() - t0 + RTT / 2, 4), "mode": [st[0], st[1]], "fg": st[2]})
    last = tty_state(fd, cache)
    steps.append({"t": 0.0, "mode": [last[0], last[1]], "fg": last[2]})
    a = 0
    while True:
        now = time.monotonic() - t0
        if now >= end: break
        while a < len(actions) and actions[a][0] <= now:
            if actions[a][1] == "write": os.write(fd, actions[a][2])
            else: winsize(fd, *actions[a][2])
            a += 1
            note_state()
        wait = min(0.005, (actions[a][0] - now) if a < len(actions) else 0.005)
        r, _, _ = select.select([fd], [], [], max(0.0, wait))
        if r:
            try: data = os.read(fd, 65536)
            except OSError: break
            if not data: break
            # The first prompt arrives on time: a late echo is of something typed.
            at = time.monotonic() - t0 + RTT / 2
            steps.append({"t": round(at + (echo_delay if at >= 0.5 else 0.0), 4), "out": data.hex()})
        note_state()
    try:
        os.write(fd, b"\x03\x15exit\r")
        drain(fd, 0.3)
        os.close(fd)
        os.waitpid(pid, os.WNOHANG)
    except OSError:
        pass
    order = {"mode": 0, "out": 1, "resize": 2, "answered": 3, "mark": 4, "key": 5, "back": 5, "boundary": 5}
    def rank(s): return next(order[k] for k in order if k in s)
    steps.sort(key=lambda s: (s["t"], rank(s)))
    fixture = {"name": name, "source": source, "cols": cols, "rows": rows, "rtt": RTT, "echoDelay": echo_delay, "steps": steps}
    with open(os.path.join(os.environ.get("REC_OUT", "."), name + ".json"), "w") as f:
        json.dump(fixture, f, separators=(",", ":"))
        f.write("\n")
    print(name, len(steps), "steps", flush=True)

OSC133 = ("PS1=$'%{\\e]133;A\\a%}%~ %# %{\\e]133;B\\a%}'", "preexec() { print -n '\\e]133;C\\a' }", "precmd() { print -n '\\e]133;D\\a' }")
SRC = "recorded: zsh -f -i in a pty on macOS, 150 ms simulated round trip"
SRC133 = SRC + ", prompt marked with OSC 133 A, B, C, D"

typing = [("pause", .4), ("type", "e", .1), ("pause", .7), ("type", "cho hello world", .09), ("pause", .9), ("type", "\r", .1),
          ("pause", .7), ("type", "l", .1), ("pause", .7), ("type", "s -d /", .09), ("pause", .9), ("type", "\r", .1), ("pause", .5)]
typo = [("pause", .4), ("type", "g", .1), ("pause", .7), ("type", "ti\x7f\x7fit sta\x7f\x7f\x7ftatus", .07), ("pause", 1.0),
        ("type", "\x7f\x7f", .5), ("pause", .8), ("type", "\x15", .1)]
read_s = [("pause", .4), ("type", "r", .1), ("pause", .7), ("type", "ead -s x", .09), ("pause", .6), ("type", "\r", .1), ("mark", "secret"),
          ("pause", .5), ("type", "hunter2zz", .09), ("pause", .6), ("type", "\r", .1), ("mark", "done"), ("pause", .4)]
# The stand-in for sudo keeps the tty cooked for a second (an external program in front), then
# asks with echo off. The word is typed ahead: its first letter alone, so that an epoch can
# start and an input_mode reading can come back while echo is still on, then the rest across
# the moment echo goes off.
FAKESUDO = ("fakesudo() { sleep 1.0; print -n 'Password:'; read -s x; print }",)
typeahead = [("pause", .4), ("type", "f", .1), ("pause", .7), ("type", "akesudo", .09), ("pause", .6), ("type", "\r", .01), ("mark", "secret"),
             ("pause", .3), ("type", "s", .1), ("pause", .4), ("type", "wordfish", .09), ("pause", .5), ("type", "sticks", .09),
             ("pause", .8), ("type", "\r", .1), ("mark", "done"), ("pause", .4)]
# The worst case: the shell itself stays in front with the tty cooked for two seconds (a
# builtin wait), then reads with echo off and prints nothing. Nothing on the screen and no key
# of the user's says that echo went off.
QUIET = ("zmodload zsh/zselect", "quiet() { zselect -t 200; read -s x }")
silent = [("pause", .4), ("type", "q", .1), ("pause", .7), ("type", "uiet", .09), ("pause", .6), ("type", "\r", .01), ("mark", "secret"),
          ("pause", .3), ("type", "a", .1), ("pause", .5), ("type", "bcdefghijklmnopqrstuv", .1), ("pause", 2.0), ("type", "\r", .1),
          ("mark", "done"), ("pause", .4)]
vim = [("pause", .4), ("type", "v", .1), ("pause", .7), ("type", "im -u NONE -N", .09), ("pause", .6), ("type", "\r", .1), ("mark", "screen"),
       ("pause", 1.2), ("type", "i", .1), ("pause", .6), ("type", "hello there", .09), ("pause", .7), ("type", "\x1b", .3),
       ("type", ":q!", .15), ("pause", .5), ("type", "\r", .1), ("mark", "back"), ("pause", 1.0),
       ("type", "e", .1), ("pause", .7), ("type", "cho ok", .09), ("pause", .9)]
REDRAW = ("PS1=$'%F{blue}%~%f %*\\n%# '", "TMOUT=1", "TRAPALRM() { zle reset-prompt }")
redraw = [("pause", .4), ("type", "e", .1), ("pause", .7), ("type", "cho one two three four five six", .11), ("pause", 1.2)]
RPROMPT = ("RPROMPT='-╯'",)
rprompt = [("pause", .4), ("type", "e", .1), ("pause", .7), ("type", "cho " + "ab" * 16, .09), ("pause", 1.0)]
wrap = [("pause", .4), ("type", "e", .1), ("pause", .7), ("type", "cho " + "wxyz" * 9, .09), ("pause", 1.0)]
late = [("pause", .4), ("type", "e", .1), ("pause", 1.9), ("type", "cho late", .09), ("pause", 1.6)]
resize = [("pause", .4), ("type", "e", .1), ("pause", .7), ("type", "cho abc", .09), ("resize", 70, 24), ("type", "def", .09), ("pause", .9),
          ("type", "g", .1), ("pause", .7), ("type", "hi", .09), ("pause", .9)]

ALL = {
    "zsh-typing": lambda: record("zsh-typing", typing, source=SRC),
    "zsh-typing-133": lambda: record("zsh-typing-133", typing, setup=OSC133, source=SRC133),
    "typo": lambda: record("typo", typo, source=SRC),
    "read-s": lambda: record("read-s", read_s, source=SRC),
    "read-s-133": lambda: record("read-s-133", read_s, setup=OSC133, source=SRC133),
    "password-typeahead": lambda: record("password-typeahead", typeahead, setup=FAKESUDO, source=SRC + "; a shell function stands in for sudo, with a made-up word"),
    "password-typeahead-133": lambda: record("password-typeahead-133", typeahead, setup=OSC133 + FAKESUDO, source=SRC133 + "; a shell function stands in for sudo, with a made-up word"),
    "silent-read-s": lambda: record("silent-read-s", silent, setup=QUIET, source=SRC + "; a function waits 2 s in a builtin with the tty cooked, then reads with echo off and prints nothing"),
    "vim": lambda: record("vim", vim, source=SRC),
    "prompt-redraw": lambda: record("prompt-redraw", redraw, setup=REDRAW, source=SRC + "; a two-line prompt redrawn every second by zle reset-prompt"),
    "right-prompt": lambda: record("right-prompt", rprompt, setup=RPROMPT, cols=40, source=SRC + "; RPROMPT set"),
    "wrap": lambda: record("wrap", wrap, cols=30, source=SRC),
    "late-echo": lambda: record("late-echo", late, echo_delay=0.9, source=SRC + "; every output after the first prompt 900 ms later than the link alone would bring it"),
    "resize": lambda: record("resize", resize, source=SRC + "; the pty is resized when the client's resize would reach it"),
}

if __name__ == "__main__":
    for n in (sys.argv[1:] or list(ALL)):
        ALL[n]()
    print("DONE", flush=True)
