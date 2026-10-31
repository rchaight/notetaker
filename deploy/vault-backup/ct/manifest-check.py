#!/usr/bin/env python3
"""manifest-check.py: verify a replica inbox against its manifest.json.

Install path: /usr/local/lib/vault-backup/manifest-check.py (spec 4.4)
Usage:        python3 -I manifest-check.py <inbox dir>

Prints exactly one line on stdout:
  ok count=<N> generated_at=<ISO> bytes=<sum> digest=<hex>   exit 0
  reason=<token>                                   exit 4
Paths never appear on stdout; diagnostics (which may name notes) go to stderr,
which the wrapper sends to the log file only. Standard library only, never
follows symlinks (os.lstat), reads files in binary.

Tokens: disabled_marker manifest_missing manifest_invalid manifest_disabled
count_mismatch entry_missing entry_size entry_sha256 stray_file not_regular
bad_path digest_mismatch
"""
import hashlib
import json
import os
import stat
import sys


def refuse(token, detail=""):
    if detail:
        sys.stderr.write("manifest-check: %s: %s\n" % (token, detail))
    print("reason=%s" % token)
    sys.exit(4)


def main():
    if len(sys.argv) != 2:
        sys.stderr.write("usage: manifest-check.py <inbox dir>\n")
        sys.exit(2)
    inbox = sys.argv[1]

    # 1. The kill-switch marker wins over everything, even a valid manifest.
    if os.path.lexists(os.path.join(inbox, "DISABLED")):
        refuse("disabled_marker")

    mpath = os.path.join(inbox, "manifest.json")
    try:
        st = os.lstat(mpath)
    except OSError:
        refuse("manifest_missing")
    if not stat.S_ISREG(st.st_mode):
        refuse("manifest_invalid", "manifest.json is not a regular file")
    try:
        with open(mpath, "rb") as fh:
            m = json.loads(fh.read().decode("utf-8"))
    except (OSError, ValueError) as exc:
        refuse("manifest_invalid", str(exc))
    if not isinstance(m, dict) or m.get("schemaVersion") != 1:
        refuse("manifest_invalid", "schemaVersion")
    if m.get("disabled") is True:
        refuse("manifest_disabled")
    files = m.get("files")
    generated_at = m.get("generatedAt")
    digest = m.get("filesDigest")
    if not isinstance(files, list) or not isinstance(generated_at, str) or not isinstance(digest, str):
        refuse("manifest_invalid", "missing keys")
    if m.get("noteCount") != len(files):
        refuse("count_mismatch", "%r vs %d" % (m.get("noteCount"), len(files)))

    vault = os.path.join(inbox, "vault")
    try:
        vst = os.lstat(vault)
    except OSError:
        refuse("entry_missing", "vault")
    if not stat.S_ISDIR(vst.st_mode):
        refuse("not_regular", "vault is not a real directory")
    seen = set()
    total = 0
    h = hashlib.sha256()
    for e in files:
        if not isinstance(e, dict):
            refuse("manifest_invalid", "entry")
        p, sha, nbytes = e.get("path"), e.get("sha256"), e.get("bytes")
        if not isinstance(p, str) or not isinstance(sha, str) or not isinstance(nbytes, int) or isinstance(nbytes, bool):
            refuse("manifest_invalid", "entry fields")
        if not p or p.startswith("/") or "\0" in p:
            refuse("bad_path", p)
        if p in seen:
            refuse("bad_path", p)
        parts = p.split("/")
        if any(c in ("", "..") for c in parts):
            refuse("bad_path", p)
        cur = vault
        for c in parts:
            cur = os.path.join(cur, c)
            try:
                cst = os.lstat(cur)
            except OSError:
                refuse("entry_missing", p)
            if stat.S_ISLNK(cst.st_mode):
                refuse("bad_path", p)
        if not stat.S_ISREG(cst.st_mode):
            refuse("not_regular", p)
        if cst.st_size != nbytes:
            refuse("entry_size", p)
        with open(cur, "rb") as fh:
            data = fh.read()
        if len(data) != nbytes:
            refuse("entry_size", p)
        if hashlib.sha256(data).hexdigest() != sha.lower():
            refuse("entry_sha256", p)
        seen.add(p)
        total += nbytes
        h.update(("%d:%s\n%s\n" % (len(p.encode("utf-8")), p, sha)).encode("utf-8"))

    # Strays and non-regular files: walk without following links.
    def walk_error(exc):
        refuse("not_regular", str(exc))

    for root, dirs, names in os.walk(vault, onerror=walk_error, followlinks=False):
        rel_root = os.path.relpath(root, vault)
        for n in list(dirs) + names:
            full = os.path.join(root, n)
            mode = os.lstat(full).st_mode
            if not (stat.S_ISREG(mode) or stat.S_ISDIR(mode)):
                refuse("not_regular", full)
        for n in names:
            rel = n if rel_root == "." else rel_root + "/" + n
            if n.endswith(".md") and rel not in seen:
                refuse("stray_file", rel)

    if h.hexdigest() != digest.lower():
        refuse("digest_mismatch")

    print("ok count=%d generated_at=%s bytes=%d digest=%s" % (len(files), generated_at, total, digest.lower()))


if __name__ == "__main__":
    try:
        main()
    except OSError as exc:
        sys.stderr.write("manifest-check: %s\n" % exc)
        print("reason=not_regular")
        sys.exit(4)
