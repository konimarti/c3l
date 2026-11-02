#!/usr/bin/env python3
"""Build a static c3c-fetch registry tree (see the c3c fetch protocol) for tests.

  fakereg.py ROOT publish ns/name VERSION [--badsum] [--no-checksum] [--not-latest]
                 [--requires=ns/x:1.0.0,ns/y] [--reqreg=URL] [--deps=a,b] [--c3po=name|url,...]

Writes download/ns/name@VERSION (a zip with manifest.json) and info/ns/name.
--badsum    info record advertises a wrong checksum
--no-checksum  info record has no checksum field
--not-latest   do not move 'latest' to this version
--requires     vendor.c3l.requires entries (id[:min version])
--reqreg       registry URL written on every --requires entry
--deps         c3c "dependencies" names (no source)
--c3po         vendor.c3po.sources entries (name|git url)
"""
import hashlib, json, os, sys, zipfile


def main():
    root, cmd, lib_id, version = sys.argv[1:5]
    flags = set(a for a in sys.argv[5:] if "=" not in a)
    opts = dict(a[2:].split("=", 1) for a in sys.argv[5:] if a.startswith("--") and "=" in a)
    assert cmd == "publish"
    ns, name = lib_id.split("/")
    dl = os.path.join(root, "download", ns)
    inf = os.path.join(root, "info", ns)
    os.makedirs(dl, exist_ok=True)
    os.makedirs(inf, exist_ok=True)

    path = os.path.join(dl, f"{name}@{version}")
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as z:
        man = {"provides": name, "version": version, "targets": {t: {} for t in ("linux-x64", "linux-aarch64", "macos-x64", "macos-aarch64", "windows-x64")}}
        if "deps" in opts:
            man["dependencies"] = opts["deps"].split(",")
        if "requires" in opts:
            reqs = []
            for item in opts["requires"].split(","):
                if item.startswith("vendor:"):   # vendor:<name> has no version
                    rid, rver = item, ""
                else:
                    rid, _, rver = item.partition(":")
                r = {"name": rid.split("/")[-1].split(":")[-1], "source": rid}
                if rver:
                    r["version"] = rver
                if "reqreg" in opts:
                    r["registry"] = opts["reqreg"]
                reqs.append(r)
            man.setdefault("vendor", {}).setdefault("c3l", {})["requires"] = reqs
        if "c3po" in opts:
            srcs = [dict(zip(("name", "source"), i.split("|", 1))) for i in opts["c3po"].split(",")]
            man.setdefault("vendor", {}).setdefault("c3po", {}).update({"c3po-version": 1, "sources": srcs})
        z.writestr("manifest.json", json.dumps(man))
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
