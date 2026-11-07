#!/usr/bin/env python3
"""c3pkg.eu look-alike for tests: publish (PUT), read API, c3c fetch protocol. Pure stdlib.

mirrors c3pkg 8d6fdc001f4ef31c7fa64b4aac5dcd3534900dd7 (2026-11-06)

  fakepkg.py PORT [--token TOKEN] [--ratelimit] [--owner NAME]

State is in memory. One user: the holder of TOKEN (default c3p_test), whose login is NAME
(default "acme"); every package published through the fake belongs to that user, and the
`c3c fetch` endpoints (/info, /download) require the namespace to equal the owner, as the
real server does. --ratelimit answers every (authenticated) publish with 429.

Endpoints, as in the real server (internal/web/{web,api,fetch,packages,ratelimit}.go,
internal/pkg/{inspect,names,semver}.go):

  GET  /api/v1/packages[?q=&tag=&page=&per_page=&sort=]   {"packages","total","page","per_page"}
  GET  /api/v1/packages/{name}                             package with its versions
  GET  /api/v1/packages/{name}/versions                    {"versions": [...]} newest first
  GET  /api/v1/packages/{name}/{ver}/download
  PUT  /api/v1/packages/{name}/versions/{ver}              publish (Bearer token, multipart)
  PUT/DELETE /api/v1/packages/{name}/versions/{ver}/yank   yank / unyank (owner)
  GET  /index/{name}/list | /{ver}.json | /{ver}.c3l
  GET  /search?q=&tag=   GET /info/{ns}/{name}   GET /download/{ns}/{name}@{ver|latest}

Anything else is the Go mux's plain-text "404 page not found" (so /index.json is a 404).

Mock only (the real server has no such thing; its yank needs the owner's token):

  PUT|POST /_test/yank/{name}/{ver}     yank a version, no auth
  DELETE   /_test/yank/{name}/{ver}     unyank it

Not mirrored: upload size limits, the web UI, stars, user pages, reports, the per-IP
read limits (only the publish limit exists, as the always-on --ratelimit), README rendering.
"""
import hashlib, io, json, re, sys, time, zipfile
from email import message_from_bytes
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlsplit

TOKEN = "c3p_test"
OWNER = "acme"
RATELIMIT = False
PKGS = {}  # name -> {description, tags, license, docs_url, git_url, readme, owner, created, updated, downloads, versions: {ver: {...}}}
CLOCK = [0]

NAME_RE = re.compile(r"[a-z][a-z0-9_]{1,63}")
TAG_RE = re.compile(r"[a-z0-9][a-z0-9-]{0,23}")
C3VER_RE = re.compile(r"[0-9]{1,4}\.[0-9]{1,4}(\.[0-9]{1,4})?")
TARGET_RE = re.compile(r"[a-z0-9][a-z0-9_-]{0,31}")
LIBRARY_RE = re.compile(r"[a-z][a-z0-9_]{0,126}")
SEMVER_RE = re.compile(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?")
RESERVED = {"std", "core", "c3", "c3c", "c3pkg", "test", "tests", "admin", "api", "index", "www", "static", "new"}
MAX_README = 512 << 10
SEARCH_LIMIT = 20
PAGE_SIZE = 20
SOURCE_EXTS = (".c3", ".c3i", ".c3t")


def goq(s):
    """Go's %q, near enough."""
    return json.dumps(s, ensure_ascii=False)


def now():
    # strictly increasing, so "updated" order is publish order even within one second
    CLOCK[0] = max(CLOCK[0] + 1, int(time.time()))
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(CLOCK[0]))


# ---- semver (internal/pkg/semver.go) ----

def parse_semver(s):
    """-> (major, minor, patch, pre-list) or raises ValueError with the server's wording."""
    m = SEMVER_RE.fullmatch(s)
    if m is None or len(s) > 64:
        raise ValueError(f"{goq(s)} is not a valid version; use MAJOR.MINOR.PATCH, optionally with -prerelease")
    nums = []
    for g in m.groups()[:3]:
        if int(g) >= 1 << 32:
            raise ValueError(f"version number {goq(g)} is too large")
        nums.append(int(g))
    pre = m[4].split(".") if m[4] else []
    for i in pre:
        if i.isascii() and i.isdigit() and ((len(i) > 1 and i[0] == "0") or len(i) > 9):
            raise ValueError(f"invalid prerelease identifier {goq(i)}")
    return (*nums, pre)


def cmp_semver(a, b):
    for x, y in zip(a[:3], b[:3]):
        if x != y:
            return -1 if x < y else 1
    pa, pb = a[3], b[3]
    if not pa and not pb:
        return 0
    if not pa:
        return 1
    if not pb:
        return -1
    for x, y in zip(pa, pb):
        if x == y:
            continue
        xn, yn = x.isascii() and x.isdigit(), y.isascii() and y.isdigit()
        if xn and yn:
            return -1 if int(x) < int(y) else 1
        if xn:
            return -1
        if yn:
            return 1
        return -1 if x < y else 1
    return (len(pa) > len(pb)) - (len(pa) < len(pb))


class _Key:
    def __init__(self, v):
        self.v = parse_semver(v)

    def __lt__(self, o):
        return cmp_semver(self.v, o.v) < 0


def sorted_versions(pk):
    """Version records, newest first (store.sortVersions)."""
    return sorted(pk["versions"].values(), key=lambda e: _Key(e["version"]), reverse=True)


def latest_version(vs):
    """Highest non-yanked stable, else highest non-yanked prerelease, else None (store.LatestVersion)."""
    pre = None
    for e in vs:
        if e["yanked"]:
            continue
        if parse_semver(e["version"])[3]:
            pre = pre or e
            continue
        return e
    return pre


# ---- names, tags, urls (internal/pkg/names.go) ----

def validate_name(name):
    if not NAME_RE.fullmatch(name):
        return "Package names are 2–64 characters: lowercase letters, digits and '_', starting with a letter."
    if name in RESERVED:
        return "That name is reserved."
    return ""


def validate_dependency(name):
    if LIBRARY_RE.fullmatch(name):
        return ""
    return f'manifest.json "dependencies" has {goq(name)}. Use the plain library name, like "vk".'


def normalize_tags(raw):
    tags = []
    for t in [x for x in re.split(r"[, \n]", raw.lower()) if x]:
        if not TAG_RE.fullmatch(t):
            return None, "Tags use lowercase letters, digits and '-' (up to 24 characters): " + t
        if t not in tags:
            tags.append(t)
    if len(tags) > 5:
        return None, "Use at most 5 tags."
    return tags, ""


def validate_url(s):
    if s == "":
        return ""
    try:
        u = urlsplit(s)
        ok = u.scheme in ("http", "https") and u.hostname and "@" not in u.netloc and len(s) <= 300
    except ValueError:
        ok = False
    return "" if ok else "Enter a full http(s) URL (up to 300 characters)."


def validate_readme(b):
    if len(b) > MAX_README:
        return "The README is larger than 512 KB."
    try:
        b.decode("utf-8")
    except UnicodeDecodeError:
        return "The README must be UTF-8 text."
    if b"\0" in b:
        return "The README must be UTF-8 text."
    return ""


# ---- manifest and archive (internal/pkg/inspect.go) ----

class Invalid(Exception):
    pass


def standard_json(src):
    """Strip // and /* */ comments and trailing commas, as pkg.standardJSON does."""
    out = []
    last_comma = -1
    last = ""
    i, n = 0, len(src)
    while i < n:
        c = src[i]
        if c == '"':
            end = i + 1
            while end < n and src[end] != '"':
                if src[end] == "\\":
                    end += 1
                end += 1
            end = min(end + 1, n)
            out.append(src[i:end])
            i = end - 1
            last_comma, last = -1, c
        elif c == "/" and i + 1 < n and src[i + 1] == "/":
            while i < n and src[i] != "\n":
                i += 1
            i -= 1
        elif c == "/" and i + 1 < n and src[i + 1] == "*":
            closing = src.find("*/", i + 2)
            if closing < 0:
                return "".join(out)
            i = closing + 1
        elif c in " \t\r\n":
            out.append(c)
        elif c in "}]" and last_comma >= 0:
            del out[last_comma]
            out.append(c)
            last_comma, last = -1, c
        else:
            last_comma = -1
            if c == "," and last not in ("[", "{", ","):
                last_comma = len(out)
            out.append(c)
            last = c
        i += 1
    return "".join(out)


def check_entry_path(name):
    t = name.rstrip("/") if name.endswith("/") else name
    if t == "":
        return "empty name"
    if len(name) > 300:
        return "name too long"
    if name.startswith("/"):
        return "absolute path"
    if "\\" in name:
        return "backslash in path"
    if len(t) >= 2 and t[1] == ":":
        return "drive letter"
    if any(ord(r) < 0x20 or ord(r) == 0x7F for r in name):
        return "control character in name"
    if any(seg in ("", ".", "..") for seg in t.split("/")):
        return "path traversal"
    return ""


def glob_re(glob):
    b, i = ["^"], 0
    while i < len(glob):
        c = glob[i]
        if glob.startswith("**/", i):
            b.append("(?:.*/)?")
            i += 3
            continue
        if glob.startswith("**", i):
            b.append(".*")
            i += 2
            continue
        b.append("[^/]*" if c == "*" else "[^/]" if c == "?" else re.escape(c))
        i += 1
    b.append("$")
    return re.compile("".join(b), re.S)


def is_list_of_str(v):
    return isinstance(v, list) and all(isinstance(x, str) for x in v)


def dependency_list(man):
    out = []

    def add(raw):
        if raw is None:
            return
        if not is_list_of_str(raw):
            raise Invalid('manifest.json "dependencies" must be a list of library names.')
        for n in raw:
            if n not in out:
                out.append(n)

    add(man.get("dependencies"))
    targets = man.get("targets") or {}
    for t in sorted(targets):
        if isinstance(targets[t], dict):
            add(targets[t].get("dependencies"))
    return out


def inspect(data):
    """-> info dict, or raises Invalid(msg)."""
    try:
        z = zipfile.ZipFile(io.BytesIO(data))
        infos = z.infolist()
    except Exception:
        raise Invalid("This is not a valid .c3l (zip) archive.")
    files, seen, manifest, readme = [], set(), None, None
    for f in infos:
        msg = check_entry_path(f.filename)
        if msg:
            raise Invalid(f"Unsafe entry {goq(f.filename)} in the archive: {msg}.")
        if (f.external_attr >> 16) & 0o170000 == 0o120000:
            raise Invalid(f"Symbolic links are not allowed ({goq(f.filename)}).")
        clean = f.filename.rstrip("/") if f.filename.endswith("/") else f.filename
        if clean in seen:
            raise Invalid(f"Duplicate entry {goq(clean)} in the archive.")
        seen.add(clean)
        if f.is_dir():
            continue
        try:
            body = z.read(f)
        except Exception:
            raise Invalid(f"The archive entry {goq(clean)} is corrupt.")
        if clean == "manifest.json":
            if len(body) > 1 << 20:
                raise Invalid("manifest.json is too large.")
            manifest = body
        if readme is None and clean.lower() == "readme.md" and len(body) <= MAX_README and validate_readme(body) == "":
            readme = body
        files.append((clean, hashlib.sha256(body).hexdigest()))
    if manifest is None:
        raise Invalid("manifest.json is missing from the root of the archive.")
    try:
        man = json.loads(standard_json(manifest.decode("utf-8")))
        ok = isinstance(man, dict)
        ok = ok and all(man.get(k) is None or isinstance(man[k], str) for k in ("provides",))
        ok = ok and (man.get("sources") is None or is_list_of_str(man["sources"]))
        ok = ok and (man.get("targets") is None or isinstance(man["targets"], dict))
        if not ok:
            raise ValueError
    except (ValueError, UnicodeDecodeError, RecursionError):
        raise Invalid("manifest.json is not valid JSON.")
    provides = man.get("provides") or ""
    msg = validate_name(provides)
    if msg:
        raise Invalid(f'manifest.json "provides" is {goq(provides)}. {msg}')
    version = man.get("version")
    if version is None:
        version = ""
    elif not isinstance(version, str):
        raise Invalid('manifest.json "version" must be a string.')
    sources = man.get("sources") or ["**"]
    matchers = []
    for s in sources:
        if s.startswith("/") or ".." in s or "\\" in s:
            raise Invalid(f'manifest.json "sources" has an unsafe pattern {goq(s)}.')
        matchers.append(glob_re(s))
    if not any(r.match(p) and p.endswith(SOURCE_EXTS) for p, _ in files for r in matchers):
        raise Invalid('None of the manifest.json "sources" match a .c3 file in the archive.')
    targets = []
    for t in man.get("targets") or {}:
        if not TARGET_RE.fullmatch(t):
            raise Invalid(f"manifest.json has an invalid target name {goq(t)}.")
        targets.append(t)
    targets.sort()
    requires = dependency_list(man)
    for n in requires:
        msg = validate_dependency(n)
        if msg:
            raise Invalid(msg)
    tree = hashlib.sha256()
    for p, s in sorted(files):
        tree.update(f"{s}  {p}\n".encode())
    return {"name": provides, "version": version, "targets": targets, "requires": requires, "readme": readme,
            "sha256_file": hashlib.sha256(data).hexdigest(), "sha256_tree": tree.hexdigest()}


# ---- the HTTP side ----

def parse_multipart(ctype, raw):
    """-> (fields {name: str}, file part (filename, bytes) or None, readme file bytes or None)."""
    fields, files = {}, {}
    if not ctype or not ctype.lower().startswith("multipart/form-data"):
        return fields, files
    try:
        msg = message_from_bytes(b"Content-Type: " + ctype.encode() + b"\r\n\r\n" + raw)
        parts = msg.get_payload() if msg.is_multipart() else []
    except Exception:
        return fields, files
    for part in parts:
        name = part.get_param("name", header="content-disposition")
        body = part.get_payload(decode=True) or b""
        fn = part.get_filename()
        if fn is not None:
            files[name] = (fn, body)
        else:
            fields[name] = body.decode("utf-8", "replace")
    return fields, files


def publish(name, ver, fields, files):
    """The body of doPublish. -> (status, json body)."""
    new = name not in PKGS
    errs = {}
    info = data = None
    # readUpload
    if "file" not in files:
        errs["file"] = "Choose a .c3l file to upload."
    elif not files["file"][0].lower().endswith(".c3l"):
        errs["file"] = "The file must have the .c3l extension."
    else:
        data = files["file"][1]
        try:
            info = inspect(data)
            if info["name"] != name:
                errs["file"] = f'manifest.json "provides" is {goq(info["name"])}, but this package is named {goq(name)}.'
                info = None
        except Invalid as e:
            errs["file"] = str(e)
    # checkVersionFields
    version = ver
    c3 = fields.get("c3_version", "").strip()
    try:
        parse_semver(ver)
    except ValueError as e:
        errs["version"] = str(e)
    if info is not None and "version" not in errs:
        if info["version"] == "":
            errs["file"] = 'manifest.json has no "version". Add one, for example "version": "1.0.0", and build the library again.'
        else:
            try:
                parse_semver(info["version"])
                if ver != info["version"]:
                    errs["version"] = f'manifest.json "version" is {goq(info["version"])}, but you are publishing {goq(ver)}. Change one so they match.'
            except ValueError as e:
                errs["file"] = 'manifest.json "version": ' + str(e)
            version = info["version"]
    if not C3VER_RE.fullmatch(c3):
        errs["c3_version"] = "Enter a C3 version such as 0.7.5."
    meta, readme = {}, None
    if new:
        meta = {k: fields.get(k, "").strip() for k in ("description", "license", "docs_url", "git_url")}
        if not 1 <= len(meta["description"]) <= 280:
            errs["description"] = "Describe the package in up to 280 characters."
        if len(meta["license"]) > 40:
            errs["license"] = "Keep the license under 40 characters, for example MIT."
        for k in ("docs_url", "git_url"):
            if validate_url(meta[k]):
                errs[k] = validate_url(meta[k])
        meta["tags"], problem = normalize_tags(fields.get("tags", ""))
        if problem:
            errs["tags"] = problem
        if "readme" in files or "readme" in fields:
            b = files["readme"][1] if "readme" in files else fields["readme"].encode()
            b = b.replace(b"\r\n", b"\n")
            if validate_readme(b):
                errs["readme"] = validate_readme(b)
            elif b:
                readme = b.decode()
        if readme is None and info is not None and info["readme"] is not None:
            readme = info["readme"].decode()
    if errs:
        return 422, errs
    if not new and version in PKGS[name]["versions"]:
        return 409, {"version": f"Version {version} is already published. Versions are immutable; choose a new version number."}
    stamp = now()
    if new:
        PKGS[name] = {"description": meta["description"], "tags": meta["tags"], "license": meta["license"], "docs_url": meta["docs_url"],
                      "git_url": meta["git_url"], "readme": readme or "", "owner": OWNER, "created": stamp, "downloads": 0, "versions": {}}
    pk = PKGS[name]
    pk["updated"] = stamp
    pk["versions"][version] = {"version": version, "c3_version": c3, "targets": info["targets"], "requires": info["requires"],
                               "size": len(data), "sha256_file": info["sha256_file"], "sha256_tree": info["sha256_tree"],
                               "yanked": False, "published": stamp, "data": data}
    return 201, {"name": name, "version": version, "created": new}


def api_version(name, e):
    return {"version": e["version"], "c3_version": e["c3_version"], "targets": e["targets"], "size": e["size"],
            "sha256_file": e["sha256_file"], "sha256_tree": e["sha256_tree"], "yanked": e["yanked"], "published": e["published"],
            "download_url": f"/api/v1/packages/{name}/{e['version']}/download"}


def words(s):
    return [w for w in re.split(r"[^0-9A-Za-z]+", s.lower()) if w]


def listing(q, tag, installable, order_by="updated"):
    """-> filtered, ordered [(name, pk)] as store.ListPackages."""
    q, tag = q.strip()[:100], tag.lower()
    qw = words(q)[:8]
    out = []
    for name, pk in PKGS.items():
        vs = sorted_versions(pk)
        if installable and not any(not e["yanked"] for e in vs):
            continue
        if tag and tag not in pk["tags"]:
            continue
        if q:
            toks = words(name + " " + pk["description"] + " " + " ".join(pk["tags"]))
            if not qw or not all(any(t.startswith(w) for t in toks) for w in qw):
                continue
        out.append((name, pk))
    out.sort(key=lambda x: list(PKGS).index(x[0]), reverse=True)  # newest package first on ties
    out.sort(key=lambda x: x[1]["updated"], reverse=True)
    if order_by == "downloads":
        out.sort(key=lambda x: x[1]["downloads"], reverse=True)
    if q:
        out.sort(key=lambda x: x[0] != q.strip().lower())
    return out


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def send(self, code, body=b"", ctype="application/json; charset=utf-8", extra=None):
        if not isinstance(body, bytes):
            body = (json.dumps(body, separators=(",", ":"), ensure_ascii=False) + "\n").encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def err(self, code, msg, fields=None, extra=None):
        """apiError: {"error": msg or the first field's message, "errors": {...}}."""
        body = {"error": msg}
        if fields:
            body["errors"] = fields
            if not msg:
                body["error"] = fields[sorted(fields)[0]]
        self.send(code, body, extra=extra)

    def not_found(self):
        self.send(404, b"404 page not found\n", "text/plain; charset=utf-8")

    def pkg(self, name):
        pk = PKGS.get(name)
        if pk is None:
            self.err(404, "package not found")
        return pk

    def send_version(self, name, pk, e, immutable=True):
        if not self.headers.get("Range"):
            pk["downloads"] += 1
        self.send(200, e["data"], "application/octet-stream", {
            "Content-Disposition": f'attachment; filename="{name}-{e["version"]}.c3l"', "ETag": f'"{e["sha256_file"]}"',
            "Cache-Control": "public, max-age=31536000, immutable" if immutable else "no-cache"})

    def authed(self):
        if self.headers.get("Authorization") == f"Bearer {TOKEN}":
            return True
        self.err(401, "authentication required: send 'Authorization: Bearer <token>'", extra={"WWW-Authenticate": 'Bearer realm="c3pkg"'})
        return False

    # ---- GET ----

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        u = urlsplit(self.path)
        p, q = u.path, {k: v[0] for k, v in parse_qs(u.query).items()}
        if p == "/api/v1/packages":
            return self.api_list(q)
        m = re.fullmatch(r"/api/v1/packages/([^/]+)", p)
        if m:
            return self.api_get(m[1])
        m = re.fullmatch(r"/api/v1/packages/([^/]+)/versions", p)
        if m:
            pk = self.pkg(m[1])
            return pk and self.send(200, {"versions": [api_version(m[1], e) for e in sorted_versions(pk)]})
        m = re.fullmatch(r"/api/v1/packages/([^/]+)/([^/]+)/download", p)
        if m:
            return self.download_version(m[1], m[2])
        m = re.fullmatch(r"/index/([^/]+)/([^/]+)", p)
        if m:
            return self.index(m[1], m[2])
        if p == "/search":
            return self.search(q)
        m = re.fullmatch(r"/info/([^/]+)/([^/]+)", p)
        if m:
            return self.info(m[1], m[2])
        m = re.fullmatch(r"/download/([^/]+)/([^/]+)", p)
        if m:
            return self.fetch_download(m[1], m[2])
        self.not_found()

    def api_list(self, q):
        try:
            per = int(q.get("per_page", ""))
        except ValueError:
            per = 0
        if per < 1 or per > 100:
            per = PAGE_SIZE
        try:
            page = int(q.get("page", ""))
        except ValueError:
            page = 1
        if page < 1 or page > 10000:
            page = 1
        found = listing(q.get("q", ""), q.get("tag", ""), False, "downloads" if q.get("sort") == "downloads" else "updated")
        out = []
        for name, pk in found[(page - 1) * per:page * per]:
            l = latest_version(sorted_versions(pk))
            d = {"name": name, "description": pk["description"], "tags": pk["tags"], "owner": pk["owner"]}
            if l:
                d["latest_version"] = l["version"]
                if l["c3_version"]:
                    d["c3_version"] = l["c3_version"]
            d.update(downloads=pk["downloads"], stars=0, updated=pk["updated"])
            out.append(d)
        self.send(200, {"packages": out, "total": len(found), "page": page, "per_page": per})

    def api_get(self, name):
        pk = self.pkg(name)
        if not pk:
            return
        vs = sorted_versions(pk)
        l = latest_version(vs)
        d = {"name": name, "description": pk["description"], "tags": pk["tags"], "owner": pk["owner"]}
        if l:
            d["latest_version"] = l["version"]
            if l["c3_version"]:
                d["c3_version"] = l["c3_version"]
        d.update(downloads=pk["downloads"], stars=0, updated=pk["updated"])
        for k in ("license", "docs_url", "git_url"):
            if pk[k]:
                d[k] = pk[k]
        d["created"] = pk["created"]
        if pk["readme"]:
            d["readme"] = pk["readme"]
        d["versions"] = [api_version(name, e) for e in vs]
        self.send(200, d)

    def download_version(self, name, ver):
        pk = self.pkg(name)
        if not pk:
            return
        e = pk["versions"].get(ver)
        if not e:
            return self.err(404, "version not found")
        self.send_version(name, pk, e)

    def index(self, name, file):
        if file == "list":
            pk = self.pkg(name)
            return pk and self.send(200, "".join(e["version"] + "\n" for e in sorted_versions(pk) if not e["yanked"]).encode(),
                                    "text/plain; charset=utf-8")
        if file.endswith(".json"):
            pk = self.pkg(name)
            if not pk:
                return
            e = pk["versions"].get(file[:-5])
            if not e:
                return self.err(404, "version not found")
            return self.send(200, {"name": name, "version": e["version"], "c3_version": e["c3_version"], "targets": e["targets"],
                                   "requires": e["requires"], "size": e["size"], "sha256_file": e["sha256_file"],
                                   "sha256_tree": e["sha256_tree"], "yanked": e["yanked"],
                                   "download": f"/index/{name}/{e['version']}.c3l"})
        if file.endswith(".c3l"):
            return self.download_version(name, file[:-4])
        self.err(404, "not found")

    def search(self, q):
        if "text/html" in self.headers.get("Accept", ""):
            return self.send(302, b"", "text/plain; charset=utf-8", {"Location": "/" + ("?" + urlsplit(self.path).query if "?" in self.path else "")})
        found = listing(q.get("q", ""), q.get("tag", "").strip(), True)
        entries = []
        for name, pk in found[:SEARCH_LIMIT]:
            vs = sorted_versions(pk)
            l = latest_version(vs)
            entries.append({"library": f"{pk['owner']}/{name}", "description": pk["description"], "tags": pk["tags"],
                            "latest": l["version"], "updated": l["published"], "versions": [e["version"] for e in vs if not e["yanked"]]})
        self.send(200, {"libraries": entries, "total": len(found)}, extra={"Cache-Control": "no-store", "Vary": "Accept"})

    def fetch_pkg(self, ns, name):
        pk = PKGS.get(name)
        if pk is None or pk["owner"].lower() != ns.lower():
            self.err(404, "package not found")
            return None
        return pk

    def info(self, ns, name):
        pk = self.fetch_pkg(ns, name)
        if not pk:
            return
        vs = sorted_versions(pk)
        l = latest_version(vs)
        if not l:
            return self.err(404, "package has no available version")
        versions = {}
        for e in vs:
            v = {"version": e["version"]}
            if pk["description"]:
                v["description"] = pk["description"]
            v["maintainer"] = pk["owner"]
            if pk["git_url"]:
                v["repository"] = pk["git_url"]
            if pk["license"]:
                v["license"] = pk["license"]
            if e["targets"]:
                v["targets"] = e["targets"]
            v.update(checksum="sha256:" + e["sha256_file"], size=e["size"], published=e["published"])
            if e["yanked"]:
                v["yanked"] = True
            versions[e["version"]] = v
        body = (json.dumps({"library": f"{pk['owner']}/{name}", "description": pk["description"], "tags": pk["tags"],
                            "latest": l["version"], "updated": l["published"], "versions": versions},
                           separators=(",", ":"), ensure_ascii=False) + "\n").encode()
        etag = '"' + hashlib.sha256(body[:-1]).hexdigest()[:32] + '"'
        extra = {"ETag": etag, "Cache-Control": "public, max-age=60"}
        if any(t.strip() in (etag, "*") for t in self.headers.get("If-None-Match", "").split(",")):
            return self.send(304, b"", extra=extra)
        self.send(200, body, extra=extra)

    def fetch_download(self, ns, file):
        name, at, ver = file.partition("@")
        pk = self.fetch_pkg(ns, name)
        if not pk:
            return
        alias = not at or ver == "latest"
        e = latest_version(sorted_versions(pk)) if alias else pk["versions"].get(ver)
        if not e:
            return self.err(404, "version not found")
        self.send_version(name, pk, e, immutable=not alias)

    # ---- PUT, POST, DELETE ----

    def body(self):
        return self.rfile.read(int(self.headers.get("Content-Length", 0)))

    def do_POST(self):
        self.do_PUT()

    def do_DELETE(self):
        self.do_PUT()

    def do_PUT(self):
        raw = self.body()
        p = urlsplit(self.path).path
        m = re.fullmatch(r"/_test/yank/([^/]+)/([^/]+)", p)
        if m:
            return self.yank(m[1], m[2], self.command != "DELETE")
        m = re.fullmatch(r"/api/v1/packages/([^/]+)/versions/([^/]+)/yank", p)
        if m and self.command in ("PUT", "DELETE"):
            if self.authed():
                self.yank(m[1], m[2], self.command == "PUT")
            return
        m = re.fullmatch(r"/api/v1/packages/([^/]+)/versions/([^/]+)", p)
        if not m or self.command != "PUT":
            return self.not_found()
        if not self.authed():  # authentication comes before the rate limit
            return
        if RATELIMIT:
            return self.send(429, {"error": "too many requests; retry in 7s"}, extra={"Retry-After": "7"})
        name, ver = m[1], m[2]
        msg = validate_name(name)
        if msg:
            return self.err(422, msg)
        fields, files = parse_multipart(self.headers.get("Content-Type"), raw)
        code, res = publish(name, ver, fields, files)
        if code == 201:
            return self.send(201, {**res, "url": f"http://{self.headers.get('Host')}/packages/{name}"})
        self.err(code, "", res)

    def yank(self, name, ver, yanked):
        pk = PKGS.get(name)
        if pk is None:
            return self.err(404, "package not found")
        if ver not in pk["versions"]:
            return self.err(404, "version not found")
        pk["versions"][ver]["yanked"] = yanked
        self.send(204)


def main():
    global TOKEN, OWNER, RATELIMIT
    port = int(sys.argv[1])
    a = sys.argv[2:]
    if "--token" in a:
        TOKEN = a[a.index("--token") + 1]
    if "--owner" in a:
        OWNER = a[a.index("--owner") + 1]
    RATELIMIT = "--ratelimit" in a
    ThreadingHTTPServer(("127.0.0.1", port), H).serve_forever()


main()
