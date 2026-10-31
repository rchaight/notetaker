#!/usr/bin/env python3
"""make-fixture.py: build a replica-inbox fixture for the vault-backup tests.

Usage: python3 -I make-fixture.py <inbox dir> [--notes N] [--generated-at ISO]
         [--disabled] [--kill-image] [--corrupt digest|size|sha|stray|missing|count|dup|vaultlink]

Writes <inbox>/vault/** (N notes, nested folders, UTF-8 names) and
<inbox>/manifest.json using the digest formula of spec section 2: sha256 over
"<utf8 byte length of path>:<path>\\n<sha256>\\n" per file in `files` order.
--disabled   : DISABLED marker + manifest with disabled=true, noteCount=0
--kill-image : DISABLED marker only (the nr-kill image, no manifest)
Stdlib only. The target directory is emptied first.
"""
import argparse
import datetime
import hashlib
import json
import os
import shutil


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("inbox")
    ap.add_argument("--notes", type=int, default=120)
    ap.add_argument("--generated-at", default=None)
    ap.add_argument("--disabled", action="store_true")
    ap.add_argument("--kill-image", action="store_true")
    ap.add_argument("--corrupt", choices=["digest", "size", "sha", "stray", "missing", "count", "dup", "vaultlink"])
    a = ap.parse_args()

    gen = a.generated_at or datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    if os.path.isdir(a.inbox):
        shutil.rmtree(a.inbox)
    os.makedirs(a.inbox)

    if a.kill_image:
        open(os.path.join(a.inbox, "DISABLED"), "w").close()
        return

    files = []
    os.makedirs(os.path.join(a.inbox, "vault"), exist_ok=True)
    if not a.disabled:
        folders = ["", "Projects/Alpha", "Projects/Beta/Deep", "Meetings", "Journal/2026", "Ideas éè"]
        for i in range(a.notes):
            folder = folders[i % len(folders)]
            name = "note-%04d üñî.md" % i
            rel = (folder + "/" + name) if folder else name
            full = os.path.join(a.inbox, "vault", rel)
            os.makedirs(os.path.dirname(full), exist_ok=True)
            body = ("# Note %d\n\nBody of note %d with some text.\n- [ ] task %d >friday\n" % (i, i, i)).encode("utf-8")
            with open(full, "wb") as fh:
                fh.write(body)
            files.append({"path": rel, "sha256": hashlib.sha256(body).hexdigest(), "bytes": len(body)})
    files.sort(key=lambda f: f["path"].encode("utf-8"))

    h = hashlib.sha256()
    for f in files:
        h.update(("%d:%s\n%s\n" % (len(f["path"].encode("utf-8")), f["path"], f["sha256"])).encode("utf-8"))
    digest = h.hexdigest()
    count = len(files)

    if a.corrupt == "digest":
        digest = ("0" if digest[0] != "0" else "1") + digest[1:]
    elif a.corrupt == "size":
        files[0]["bytes"] += 1
    elif a.corrupt == "sha":
        s = files[0]["sha256"]
        files[0]["sha256"] = ("0" if s[0] != "0" else "1") + s[1:]
    elif a.corrupt == "stray":
        with open(os.path.join(a.inbox, "vault", "stray-note.md"), "w") as fh:
            fh.write("not in manifest\n")
    elif a.corrupt == "missing":
        os.remove(os.path.join(a.inbox, "vault", files[-1]["path"]))
    elif a.corrupt == "count":
        count += 1
    elif a.corrupt == "dup":
        files.append(dict(files[0]))
        count += 1
    elif a.corrupt == "vaultlink":
        real = os.path.join(a.inbox, "vault-real")
        os.rename(os.path.join(a.inbox, "vault"), real)
        os.symlink("vault-real", os.path.join(a.inbox, "vault"))

    manifest = {
        "schemaVersion": 1,
        "disabled": bool(a.disabled),
        "noteCount": 0 if a.disabled else count,
        "files": files,
        "filesDigest": digest,
        "generatedAt": gen,
        "calendarIncluded": False,
        "appVersion": "fixture",
        "excludedLocked": 0,
        "excludedHidden": 0,
        "excludedFolders": 0,
        "excludedOther": 0,
    }
    with open(os.path.join(a.inbox, "manifest.json"), "w", encoding="utf-8") as fh:
        json.dump(manifest, fh, sort_keys=True, ensure_ascii=False)
    if a.disabled:
        open(os.path.join(a.inbox, "DISABLED"), "w").close()
    with open(os.path.join(a.inbox, "calendar-remote.json"), "w") as fh:
        fh.write("{}\n")


if __name__ == "__main__":
    main()
