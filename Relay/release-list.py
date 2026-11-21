#!/usr/bin/env python3
"""What a release list turns off (`disabled`, `signed_at`), written into the list release.sh
is about to sign.

    release-list.py release <list> <published list or -> <disable> <enable>
    release-list.py resign  <list> <published list>      <disable> <enable>

<list> is rewritten in place. <disable> and <enable> are feature names, each followed by a
comma (release.sh's --disable and --enable); either may be empty.

release: <list> is the new release's list. What the published list turns off is carried into
it, so that a release never turns back on what was turned off: only <enable> takes a name out.
`-` says nothing is published yet.

resign: <list> has to be the published list, byte for byte: signing an older copy again
would publish what that copy turns off, not what is turned off now.

Either way the names have to be what a Beacon takes (Relay/src/update.rs, `names`): at most 32,
each 1 to 64 small letters, digits and `_`. A list that turns something off, or did, says when
it was signed, always later than the published one says: a Beacon takes `disabled` only from a
list signed after the one it last took it from.
"""
import datetime
import json
import re
import sys

NAME = re.compile(r"[a-z0-9_]{1,64}")
MOST = 32
STAMP = "%Y-%m-%dT%H:%M:%SZ"


def stop(why):
    sys.exit(f"release: {why}")


def load(path):
    with open(path, "rb") as f:
        data = f.read()
    try:
        listed = json.loads(data)
    except ValueError:
        stop(f"{path} is not JSON")
    if not isinstance(listed, dict):
        stop(f"{path} is not a release list")
    return data, listed


def signed_at(listed):
    try:
        return datetime.datetime.strptime(str(listed.get("signed_at", "")), STAMP)
    except ValueError:
        return None


def flag(text):
    return set(filter(None, text.split(",")))


def main(argv):
    if len(argv) != 6 or argv[1] not in ("release", "resign"):
        stop("usage: release-list.py release|resign <list> <published list or -> <disable> <enable>")
    mode, path, published_path, disable, enable = argv[1:]
    data, listed = load(path)
    published = None
    if published_path != "-":
        published_data, published = load(published_path)
        if mode == "resign" and published_data != data:
            stop(f"{path} is not the list that is published: delete it and run again, and the published one is signed")
    elif mode == "resign":
        stop("there is no published list to sign again")
    # What is turned off now: as the published list has it. (For --resign that is the list itself.)
    before = published if published is not None else {}
    off = before.get("disabled")
    if disable or enable or isinstance(off, list):
        names = set(off) if isinstance(off, list) and all(isinstance(n, str) for n in off) else None
        if names is None and isinstance(off, list):
            stop("the published list's disabled holds something that is not a name")
        names = (names or set()) | flag(disable)
        names -= flag(enable)
        odd = sorted(n for n in names if not NAME.fullmatch(n))
        if odd:
            stop(f"not a feature's name: {', '.join(repr(n) for n in odd)} (small letters, digits and _, 64 at most)")
        if len(names) > MOST:
            stop(f"{len(names)} names are turned off; a Beacon takes {MOST} at most")
        listed["disabled"] = sorted(names)
        signed = datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0, tzinfo=None)
        for earlier in (signed_at(before), signed_at(listed)):
            if earlier is not None:
                signed = max(signed, earlier + datetime.timedelta(seconds=1))
        listed["signed_at"] = signed.strftime(STAMP)
    else:
        listed.pop("disabled", None)
        listed.pop("signed_at", None)
    # One field per line (indent=2): setup.sh reads this file with sed and awk.
    with open(path, "w") as f:
        json.dump(listed, f, indent=2)
        f.write("\n")


if __name__ == "__main__":
    main(sys.argv)
