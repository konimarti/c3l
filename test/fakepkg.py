#!/usr/bin/env python3
"""Minimal c3pkg.eu look-alike for tests: publish (PUT), versions, index, info, download.

  fakepkg.py PORT [--token TOKEN] [--ratelimit]

State is in memory. Rules mirror the real API docs: bearer token, multipart `file`,
`c3_version` required, `description` required for a new package, manifest.json at the
zip root whose `provides` and `version` must match the URL, versions immutable.
"""
import hashlib, io, json, re, sys, zipfile
from email import message_from_bytes
from http.server import BaseHTTPRequestHandler, HTTPServer

TOKEN = "c3p_test"
RATELIMIT = False
PKGS = {}  # name -> {"description": str, "versions": {ver: {...}}}
SEMVER = re.compile(r"^\d+\.\d+\.\d+(-[0-9A-Za-z][0-9A-Za-z.-]*)?$")


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def send(self, code, body=b"", ctype="application/json", extra=None):
        if isinstance(body, (dict, list)):
            body = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(body)

    def err(self, code, msg):
        self.send(code, {"error": msg})

    def do_GET(self):
        p = self.path.split("?")[0]
        m = re.match(r"^/api/v1/packages/?$", p)
        if m:
            return self.send(200, {"packages": list(PKGS)})
        m = re.match(r"^/api/v1/packages/([^/]+)/versions$", p)
        if m:
            pk = PKGS.get(m[1])
            if not pk:
                return self.err(404, "not found")
            return self.send(200, {"versions": [dict(version=v, **{k: e[k] for k in ("c3_version", "targets", "sha256_file", "yanked")}) for v, e in pk["versions"].items()]})
        m = re.match(r"^/index/([^/]+)/(.+)\.json$", p)
        if m and m[1] in PKGS and m[2] in PKGS[m[1]]["versions"]:
            e = PKGS[m[1]]["versions"][m[2]]
            return self.send(200, {"name": m[1], "version": m[2], **{k: e[k] for k in ("c3_version", "targets", "sha256_file", "yanked")}})
        m = re.match(r"^/info/([^/]+)/([^/]+)$", p)
        if m and m[2] in PKGS:
            vs = PKGS[m[2]]["versions"]
            return self.send(200, {"library": f"{m[1]}/{m[2]}", "description": "test", "tags": [], "latest": list(vs)[0],
                                   "updated": "2026-01-01T00:00:00Z",
                                   "versions": {v: {"version": v, "checksum": "sha256:" + e["sha256_file"], "size": len(e["data"]),
                                                    "published": "2026-01-01T00:00:00Z"} for v, e in vs.items()}})
        m = re.match(r"^/download/([^/]+)/([^@]+)@(.+)$", p)
        if m and m[2] in PKGS and m[3] in PKGS[m[2]]["versions"]:
            return self.send(200, PKGS[m[2]]["versions"][m[3]]["data"], "application/zip")
        self.err(404, "not found")

    def do_PUT(self):
        n = int(self.headers.get("Content-Length", 0))
        raw = self.rfile.read(n)
        if RATELIMIT:
            return self.send(429, {"error": "slow down"}, extra={"Retry-After": "7"})
        if self.headers.get("Authorization") != f"Bearer {TOKEN}":
            return self.err(401, "invalid token")
        m = re.match(r"^/api/v1/packages/([^/]+)/versions/([^/]+)$", self.path)
        if not m:
            return self.err(404, "not found")
        name, ver = m[1], m[2]
        msg = message_from_bytes(b"Content-Type: " + self.headers["Content-Type"].encode() + b"\r\n\r\n" + raw)
        form = {}
        for part in msg.get_payload():
            form[part.get_param("name", header="content-disposition")] = part.get_payload(decode=True)
        if not SEMVER.match(ver):
            return self.send(422, {"error": "invalid version", "errors": {"version": "must be semver"}})
        if "file" not in form or "c3_version" not in form:
            return self.send(422, {"error": "missing field", "errors": {"file": "required"}})
        try:
            z = zipfile.ZipFile(io.BytesIO(form["file"]))
            man = json.loads(re.sub(r",(\s*[}\]])", r"\1", re.sub(r"(?m)^\s*//.*$", "", z.read("manifest.json").decode())))
        except Exception as e:
            return self.send(422, {"error": "not a valid .c3l: " + str(e)})
        if man.get("provides") != name:
            return self.send(422, {"error": f"manifest provides {man.get('provides')!r}, URL says {name!r}"})
        if man.get("version") != ver:
            return self.send(422, {"error": f"manifest version {man.get('version')!r}, URL says {ver!r}"})
        pk = PKGS.get(name)
        if pk is None:
            if not form.get("description"):
                return self.send(422, {"error": "description required", "errors": {"description": "required on first publish"}})
            pk = PKGS[name] = {"versions": {}}
        if ver in pk["versions"]:
            return self.err(409, f"{name} {ver} already exists")
        data = form["file"]
        pk["versions"] = {ver: {"data": data, "c3_version": form["c3_version"].decode(), "targets": ["linux-x64", "macos-aarch64"],
                                "sha256_file": hashlib.sha256(data).hexdigest(), "yanked": False,
                                "license": (form.get("license") or b"").decode()}, **pk["versions"]}
        self.send(201, {"name": name, "version": ver, "created": True, "url": f"/packages/{name}"})


def main():
    global TOKEN, RATELIMIT
    port = int(sys.argv[1])
    a = sys.argv[2:]
    if "--token" in a:
        TOKEN = a[a.index("--token") + 1]
    RATELIMIT = "--ratelimit" in a
    HTTPServer(("127.0.0.1", port), H).serve_forever()


main()
