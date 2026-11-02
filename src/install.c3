<*
 Installing libraries. Adding or updating one library together with everything
 it pulls in is one operation (`Op`): on any failure the project file, the
 lockfile and the library files are restored.

   Op op = install::begin(&project, opts)!;
   defer catch op.rollback();
   op.add(want)!;
   op.commit();
*>
module c3l::install;

import std::io, std::os, std::collections::list, libc;
import c3l::log, c3l::sys, c3l::lock, c3l::project, c3l::manifest;
import c3l::http, c3l::registry, c3l::vendor, c3l::git;

// What a library is to the project once installed.
enum Intent
{
	DIRECT, // asked for by the project
	DEP,    // pulled in by another library (stays direct if it already is)
	KEEP,   // update or restore: the role it has (direct if new)
}

<*
 A library to install. `ref`: version, tag, branch, HEAD, commit; empty = the newest.
 `pin` (from the lock) = restore exactly that, keep the role, follow nothing.
*>
struct Want
{
	Kind kind;
	String origin;  // registry base URL, vendor release URL, git URL, directory
	String id;      // ns/name (registry), name (vendor)
	String ref;
	String pin;
}

struct Options
{
	bool strict;
	String registry;  // the default registry (base URL)
	String[] hosts;   // trusted hosts besides the built-in ones
}

struct Installed
{
	Entry entry;
	Manifest manifest;
}

struct Op
{
	Project* proj;
	Options opts;
	String dir;     // the library directory
	Intent intent;
	// journal
	String project_text;
	String lock_text;  // empty: there was no lockfile
	String backup;     // replaced library files are moved here
	List{Touched} touched;
	// resolver (resolve.c3)
	List{String} stack;
	List{String} hosts;
	sz count;
}

struct Touched
{
	String name;
	bool had_file;
}

fn Op? begin(Project* p, Options opts)
{
	Op op = { .proj = p, .opts = opts, .intent = DIRECT };
	op.project_text = (String)file::load_temp(p.file) ?? log::fail("cannot read %s", p.file)~!;
	op.lock_text = p.lock.exists() ? (String)file::load_temp(p.lock.file) ?? "" : "";
	op.touched.tinit();
	op.stack.tinit();
	op.hosts.tinit();
	op.hosts.push_all(opts.hosts);
	op.dir = p.lib_dir(true)!;
	op.backup = string::tformat("%s/.c3l-backup", op.dir);
	return op;
}

fn void Op.commit(&self)
{
	sys::remove(self.backup);
	self.touched.clear();
}

fn void Op.rollback(&self)
{
	(void)file::save(self.proj.file, self.project_text);
	if (self.lock_text.len)
	{
		(void)file::save(self.proj.lock.file, self.lock_text);
	}
	else
	{
		(void)file::delete(self.proj.lock.file);
	}
	foreach (t : self.touched)
	{
		String f = self.file_of(t.name);
		sys::remove(f);
		if (t.had_file) libc::rename(string::tformat("%s/%s.c3l", self.backup, t.name).zstr_tcopy(), f.zstr_tcopy());
	}
	self.commit();
	bool frozen = self.proj.lock.frozen;
	self.proj.lock = lock::load(self.proj.lock.file) ?? self.proj.lock;
	self.proj.lock.frozen = frozen;
}

fn String Op.file_of(&self, String name) => string::tformat("%s/%s.c3l", self.dir, name);

// Install one library and, unless it is a restore, what it requires.
fn void? Op.add(&self, Want w)
{
	Installed i = self.install(w)!;
	if (!w.pin.len) self.follow(i.entry.name, i.manifest.requires)!;
}

fn Installed? Op.install(&self, Want w)
{
	switch (w.kind)
	{
		case REGISTRY: return self.install_registry(w);
		case VENDOR: return self.install_vendor(w);
		case GIT: return self.install_git(w);
		case PATH: return self.install_path(w);
	}
}

fn Installed? Op.install_registry(&self, Want w)
{
	String name = w.id[(w.id.rindex_of_char('/') ?? -1) + 1..];
	self.check_collision(name, REGISTRY, w.origin, w.id)!;
	Info info = registry::info(w.origin, w.id) ?? log::fail("%s: not found or registry not reachable (%s)", w.id, w.origin)~!;
	String version = w.ref.len ? w.ref : info.latest;
	if (!version.len) return log::fail("registry returned no latest version for %s", w.id)~;
	if (!info.has(version)) return log::fail("no such version '%s' for %s", version, w.id)~;
	String sum = info.checksum(version);
	if (w.pin.len && sum.len && w.pin != sum)
	{
		log::warn("registry checksum for %s@%s differs from c3l.lock (immutable versions must never change)", w.id, version);
	}
	String expected = w.pin.len ? w.pin : sum;
	if (!expected.len) log::warn("registry gave no checksum for %s@%s; recording the downloaded file (trust on first use)", w.id, version);

	String staged = self.staging(name);
	defer (void)file::delete(staged);
	log::info("fetching %s@%s from %s", w.id, version, w.origin);
	if (!registry::download(w.origin, w.id, version, staged)) return log::fail("download of %s@%s from %s failed", w.id, version, w.origin)~;
	String got = self.verify(staged, expected, string::tformat("%s@%s", w.id, version))!;
	warn_provides(staged, name, w.id);
	Installed i = self.place({ .name = name, .kind = REGISTRY, .origin = w.origin, .id = w.id, .version = version, .pin = got, .hash = got }, staged, w.pin.len > 0)!;
	log::info("installed %s %s (%s)", name, version, got);
	return i;
}

fn Installed? Op.install_vendor(&self, Want w)
{
	String name = w.id;
	if (!lock::valid_name(name)) return log::fail("'%s' is not a vendor library name", name)~;
	self.check_collision(name, VENDOR, w.origin, name)!;
	String expected = w.pin;
	if (!expected.len)
	{
		Asset? a = vendor::find(name);
		if (catch e = a)
		{
			if (e == vendor::NOT_LISTED) return log::fail("no vendor library '%s' (list them with: c3l add vendor)", name)~;
			return log::fail("cannot read the vendor library list (%s)", vendor::api())~;
		}
		expected = a.digest;
	}
	if (!expected.len) log::warn("no checksum is listed for vendor:%s; recording the downloaded file (trust on first use)", name);

	String staged = self.staging(name);
	defer (void)file::delete(staged);
	log::info("fetching vendor:%s from %s", name, w.origin);
	if (!http::download(string::tformat("%s/%s.c3l", w.origin, name), staged).ok()) return log::fail("download of vendor:%s failed", name)~;
	String got = self.verify(staged, expected, string::tformat("vendor:%s", name))!;
	warn_provides(staged, name, string::tformat("vendor:%s", name));
	Installed i = self.place({ .name = name, .kind = VENDOR, .origin = w.origin, .id = name, .version = "latest", .pin = got, .hash = got }, staged, w.pin.len > 0)!;
	log::info("installed %s (%s)", name, got);
	return i;
}

<*
 ref: empty (highest semver tag, else HEAD), HEAD, a tag, a branch, a full commit,
 or a lock label (branch:NAME, commit:SHA12). pin: commit:<sha>.
 The lock label is the tag, HEAD, branch:NAME or commit:SHA12.
*>
fn Installed? Op.install_git(&self, Want w)
{
	String url = w.origin;
	Rev rev = resolve_rev(url, w.ref, w.pin)!;
	String src = sys::temp_dir()!;
	defer sys::remove(src);
	git::checkout(url, rev.commit, rev.kind == TAG || rev.kind == BRANCH ? rev.name : "", src)!;
	Manifest m = manifest::load(src) ?? log::fail("%s has no manifest.json at its root (not a C3 library)", url)~!;
	String name = m.provides;
	if (!name.len) return log::fail("manifest.json of %s has no 'provides'", url)~;
	if (file::exists(string::tformat("%s/.gitmodules", src))) log::warn("%s uses submodules; they are not included in the library", url);
	self.check_collision(name, GIT, url, "-")!;

	String staged = self.staging(name);
	defer (void)file::delete(staged);
	git::archive(src, staged)!;
	String pin = string::tformat("commit:%s", rev.commit);
	Installed i = self.place({ .name = name, .kind = GIT, .origin = url, .id = "-", .version = rev.label, .pin = pin, .hash = pin }, staged, w.pin.len > 0)!;
	log::info("installed %s %s (commit %s)", name, rev.label, rev.commit[:12]);
	return i;
}

// A local directory, linked into the library directory so edits show up in the next build.
fn Installed? Op.install_path(&self, Want w)
{
	String src = w.origin;
	Manifest m = manifest::load_file(string::tformat("%s/manifest.json", src)) ?? log::fail("%s has no manifest.json (not a C3 library)", src)~!;
	String abs = (String)src.to_absolute_path(tmem) ?? log::fail("cannot enter %s", src)~!;
	String name = m.provides;
	if (!name.len) return log::fail("manifest.json of %s has no 'provides'", src)~;
	self.check_collision(name, PATH, src, "-")!;
	self.set_aside(name);
	sys::link(abs, self.file_of(name))!;
	Installed i = self.place({ .name = name, .kind = PATH, .origin = src, .id = "-", .version = "-", .pin = "-", .hash = "-" }, "", w.pin.len > 0)!;
	log::info("linked %s -> %s", name, abs);
	return i;
}

// Library names are global in a project: one name, one source.
fn void? Op.check_collision(&self, String name, Kind kind, String origin, String id)
{
	Entry*? e = self.proj.lock.get(name);
	if (catch e) return;
	if (e.kind == kind && e.origin == origin && e.id == id) return;
	String from = e.id == "-" ? e.origin : string::tformat("%s %s", e.origin, e.id);
	return log::fail("'%s' is already installed from %s:%s. Library names are global in a project; run 'c3l remove %s' first.", name, e.kind.name, from, name)~;
}

// Where a download is written before it is checked: next to its final place.
fn String Op.staging(&self, String name) => string::tformat("%s/.%s.c3l.part", self.dir, name);

// "sha256:<hex>" of the file, which must be `expected` when that is known.
fn String? Op.verify(&self, String file, String expected, String what)
{
	String got = sys::sha256_file(file) ?? log::fail("cannot read %s", file)~!;
	if (expected.len && got != expected) return log::fail("checksum mismatch for %s: expected %s, got %s", what, expected, got)~;
	return got;
}

fn void warn_provides(String file, String name, String what) @private
{
	String provides = (manifest::load(file) ?? (Manifest){}).provides;
	if (provides.len && provides != name) log::warn("manifest of %s provides '%s', c3c will register it as '%s'", what, provides, name);
}

// Move the current file of `name` out of the way (once per operation).
fn void Op.set_aside(&self, String name)
{
	foreach (t : self.touched) if (t.name == name) return;
	String f = self.file_of(name);
	bool had = sys::exists(f);
	if (had)
	{
		(void)path::mkdir(self.backup);
		libc::rename(f.zstr_tcopy(), string::tformat("%s/%s.c3l", self.backup, name).zstr_tcopy());
	}
	self.touched.push({ name, had });
}

<*
 Put `staged` in place (empty: already there), list the library in the project,
 record it in the lock. A library's own manifest lists only its direct
 dependencies, so in a library directory a dependency is not registered.
*>
fn Installed? Op.place(&self, Entry e, String staged, bool restore)
{
	String f = self.file_of(e.name);
	if (staged.len)
	{
		self.set_aside(e.name);
		if (libc::rename(staged.zstr_tcopy(), f.zstr_tcopy())) return log::fail("cannot write %s", f)~;
	}
	Manifest m = manifest::load(f) ?? (Manifest){};
	e.role = self.role_of(e.name, restore ? KEEP : self.intent);
	e.requires = m.require_names();
	if (!(self.proj.libmode && e.role == DEP) && !self.proj.has_dep(e.name)!)
	{
		if (catch self.proj.set_dep(e.name, true)) return log::fail("could not register %s in %s", e.name, self.proj.file)~;
	}
	self.proj.lock.put(e);
	self.proj.lock.save()!;
	return { e, m };
}

// A direct library stays direct; a new one is what was asked for.
fn Role Op.role_of(&self, String name, Intent intent)
{
	if (intent == DIRECT) return DIRECT;
	if (try old = self.proj.lock.get(name)) return old.role;
	return intent == DEP ? DEP : DIRECT;
}

enum RevKind
{
	TAG,
	BRANCH,
	HEAD,
	COMMIT,
}

struct Rev
{
	RevKind kind;
	String name;    // tag or branch name
	String commit;
	String label;   // what the lock records as version
}

fn Rev? resolve_rev(String url, String ref, String pin) @private
{
	if (!ref.len && !pin.len)
	{
		ref = git::highest_tag(url)!;
		if (!ref.len) ref = "HEAD";
	}
	Rev r = { .kind = TAG, .name = ref, .label = ref };
	if (ref == "HEAD") r.kind = HEAD;
	if (ref.starts_with("branch:")) r = { .kind = BRANCH, .name = ref["branch:".len..], .label = ref };
	if (ref.starts_with("commit:")) r = { .kind = COMMIT, .commit = ref["commit:".len..], .label = short_commit(ref["commit:".len..]) };
	if (pin.len)
	{
		r.commit = pin.strip_prefix("commit:");
		return r;
	}
	switch (r.kind)
	{
		case HEAD:
			r.commit = git::head(url)!;
			if (!r.commit.len) return log::fail("cannot resolve HEAD of %s (not a reachable git repository?)", url)~;
		case BRANCH:
			r.commit = git::branch_commit(url, r.name)!;
			if (!r.commit.len) return log::fail("branch '%s' not found in %s", r.name, url)~;
		case COMMIT:
			break;
		case TAG: // a plain name: a tag, else a branch, else a full commit
			r.commit = git::tag_commit(url, ref)!;
			if (r.commit.len) return r;
			r = { .kind = BRANCH, .name = ref, .commit = git::branch_commit(url, ref)!, .label = string::tformat("branch:%s", ref) };
			if (r.commit.len) return r;
			if (!git::is_commit(ref)) return log::fail("'%s' is not a tag, branch or full commit hash in %s", ref, url)~;
			r = { .kind = COMMIT, .commit = ref, .label = short_commit(ref) };
	}
	if (r.kind == COMMIT && !git::is_commit(r.commit)) return log::fail("a commit must be given as the full 40-character hash")~;
	return r;
}

fn String short_commit(String commit) @private => string::tformat("commit:%s", commit[:commit.len < 12 ? commit.len : 12]);
