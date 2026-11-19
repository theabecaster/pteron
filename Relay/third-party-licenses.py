#!/usr/bin/env python3
"""The licences of the crates the helper is built from.

    third-party-licenses.py --check                # every crate in Cargo.lock has a licence from the list below
    third-party-licenses.py <output file> <name>   # the same check, then the notices of the crates that
                                                   # are linked into the helper, as one text file whose
                                                   # first line calls the helper by that name
                                                   # (`rex-duo-helper brand` prints it)

The helper is AGPL-3.0-only and its binaries carry these crates, so each release ships their
notices (package.sh puts the file in the Mac app, release.sh uploads it), and a crate whose terms
are not on the list stops the build and `cargo test`.
"""

import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ALLOWED = {
    "MIT", "Apache-2.0", "ISC", "BSD-2-Clause", "BSD-3-Clause", "Unicode-3.0",
    "CDLA-Permissive-2.0", "Zlib", "Unlicense",
}
# What the helper is built for. Crates used only elsewhere (Windows, say) are not in a binary.
TARGETS = [
    "aarch64-apple-darwin", "x86_64-apple-darwin",
    "x86_64-unknown-linux-musl", "aarch64-unknown-linux-musl",
]
NOTICE_FILES = re.compile(r"^(LICEN[SC]E|COPYING|NOTICE|UNLICENSE|COPYRIGHT)", re.I)


def metadata(*more):
    cargo = os.environ.get("CARGO", "cargo")
    out = subprocess.run(
        [cargo, "metadata", "--format-version", "1", "--locked",
         "--manifest-path", os.path.join(HERE, "Cargo.toml"), *more],
        check=True, capture_output=True, text=True,
    ).stdout
    return json.loads(out)


def allowed(expression):
    """True when the terms can be met with licences from the list alone."""
    tokens = re.findall(r"\(|\)|[^\s()]+", (expression or "").replace("/", " OR "))
    pos = 0

    def term():
        nonlocal pos
        if pos >= len(tokens):
            raise ValueError("ends early")
        tok = tokens[pos]
        pos += 1
        if tok == "(":
            value = either()
            if pos >= len(tokens) or tokens[pos] != ")":
                raise ValueError("unclosed bracket")
            pos += 1
            return value
        if tok in (")", "AND", "OR", "WITH"):
            raise ValueError("unexpected " + tok)
        if pos < len(tokens) and tokens[pos] == "WITH":
            pos += 2  # an exception only adds permissions
        return tok in ALLOWED

    def both():
        nonlocal pos
        value = term()
        while pos < len(tokens) and tokens[pos] == "AND":
            pos += 1
            value = term() and value
        return value

    def either():
        nonlocal pos
        value = both()
        while pos < len(tokens) and tokens[pos] == "OR":
            pos += 1
            value = both() or value
        return value

    try:
        value = either()
    except ValueError:
        return False
    return value and pos == len(tokens)


def third_party(meta):
    return [p for p in meta["packages"] if p["source"] is not None]


def check(meta):
    bad = [p for p in third_party(meta) if not allowed(p["license"])]
    for p in bad:
        print("%s %s: licence %r is not on the list" % (p["name"], p["version"], p["license"]), file=sys.stderr)
    return not bad


def linked():
    """Ids of the crates that end up in a helper binary: normal dependencies, any target."""
    ids = set()
    for target in TARGETS:
        resolve = metadata("--filter-platform", target)["resolve"]
        nodes = {n["id"]: n for n in resolve["nodes"]}
        todo = [resolve["root"]]
        while todo:
            node = nodes[todo.pop()]
            for dep in node["deps"]:
                if dep["pkg"] not in ids and any(k["kind"] is None for k in dep["dep_kinds"]):
                    ids.add(dep["pkg"])
                    todo.append(dep["pkg"])
    return ids


def notices(meta, path, name):
    ids = linked()
    crates = sorted((p for p in third_party(meta) if p["id"] in ids), key=lambda p: (p["name"], p["version"]))
    out = [
        "%s is licensed under the GNU Affero General Public License, version 3 only." % name,
        "It is built with the %d open-source crates below. Each keeps its own licence." % len(crates),
        "",
    ]
    for p in crates:
        out += ["=" * 78, "%s %s" % (p["name"], p["version"]), "Licence: %s" % p["license"]]
        if p.get("repository"):
            out.append(p["repository"])
        out.append("=" * 78)
        folder = os.path.dirname(p["manifest_path"])
        names = sorted(n for n in os.listdir(folder) if NOTICE_FILES.match(n) and os.path.isfile(os.path.join(folder, n)))
        if not names:
            sys.exit("%s %s has no licence file in %s" % (p["name"], p["version"], folder))
        for name in names:
            with open(os.path.join(folder, name), encoding="utf-8", errors="replace") as f:
                out += ["", "--- %s ---" % name, "", f.read().rstrip()]
        out.append("")
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(out) + "\n")
    print("%s: %d crates" % (path, len(crates)))


def main(argv):
    if argv[1:] != ["--check"] and (len(argv) != 3 or not argv[2].strip()):
        sys.exit(__doc__)
    meta = metadata()
    if not check(meta):
        sys.exit(1)
    if argv[1] != "--check":
        notices(meta, argv[1], argv[2])


if __name__ == "__main__":
    main(sys.argv)
