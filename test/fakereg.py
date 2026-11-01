#!/usr/bin/env python3
"""Build a static c3c-fetch registry tree (see the c3c fetch protocol) for tests.

  fakereg.py ROOT publish ns/name VERSION [--badsum] [--no-checksum] [--not-latest]

Writes download/ns/name@VERSION (a zip with manifest.json) and info/ns/name.
--badsum    info record advertises a wrong checksum
--no-checksum  info record has no checksum field
--not-latest   do not move 'latest' to this version
"""
import hashlib, json, os, sys, zipfile


def main():
    root, cmd, lib_id, version = sys.argv[1:5]
    flags = set(sys.argv[5:])
    assert cmd == "publish"
    ns, name = lib_id.split("/")
    dl = os.path.join(root, "download", ns)
    inf = os.path.join(root, "info", ns)
    os.makedirs(dl, exist_ok=True)
    os.makedirs(inf, exist_ok=True)

    path = os.path.join(dl, f"{name}@{version}")
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("manifest.json", json.dumps({"provides": name, "version": version, "targets": {}}))
        z.writestr("src/lib.c3", f"module {name};\nfn int answer() => 42;\n")
    data = open(path, "rb").read()
    sha = hashlib.sha256(data).hexdigest()

    ipath = os.path.join(inf, name)
    rec = json.load(open(ipath)) if os.path.exists(ipath) else {
        "library": lib_id, "description": f"test lib {name}", "tags": [], "latest": version,
        "updated": "2026-01-01T00:00:00Z", "versions": {}}
    entry = {"version": version, "description": f"test lib {name}", "size": len(data),
             "published": "2026-01-01T00:00:00Z"}
    if "--no-checksum" not in flags:
        entry["checksum"] = "sha256:" + ("0" * 64 if "--badsum" in flags else sha)
    # newest first
    rec["versions"] = {version: entry, **{k: v for k, v in rec["versions"].items() if k != version}}
    if "--not-latest" not in flags:
        rec["latest"] = version
    json.dump(rec, open(ipath, "w"))
    print(sha)


main()
