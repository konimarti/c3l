<*
 Installing libraries. Adding or updating one library together with everything
 it pulls in is one operation (`Op`): on any failure the project file, the
 lockfile and the library files are restored.

   Op op = install::begin(&project, &opts)!;
   defer catch op.rollback();
   op.add(want, DIRECT)!;
   op.commit();
*>
module c3l::install;

import std::io, std::os, std::collections::list;
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
 `pin` (from the lock) = restore exactly that, keep the role, follow nothing;
 `hash` is then what the installed file must be (the lock's hash column).
*>
struct Want
{
	Kind kind;
	String origin;  // registry base URL, vendor release URL, git URL, directory
	String id;      // ns/name (registry), name (vendor)
	String ref;
	String pin;
	String hash;
}

// For all operations of one command.
struct Options
{
	bool strict;
	String registry;      // the default registry (base URL)
	List{String} hosts;   // trusted hosts besides the built-in ones; grows when the user allows one
}

struct Op
{
	Project* proj;
	Options* opts;
	String dir;     // the library directory
	// journal
	String project_text;
	bool had_lock;
	String lock_text;
	String backup;     // replaced library files are moved here; created when first needed
	List{Touched} touched;
	// resolver (resolve.c3)
	List{String} stack;
	sz count;
}

struct Touched
{
	String name;
	bool had_file;
}

fn Op? begin(Project* p, Options* opts)
{
	Op op = { .proj = p, .opts = opts };
	op.project_text = (String)file::load_temp(p.file) ?? log::fail("cannot read %s", p.file)~!;
	op.had_lock = p.lock.exists();
	if (op.had_lock) op.lock_text = (String)file::load_temp(p.lock.file) ?? log::fail("cannot read %s", p.lock.file)~!;
	op.touched.tinit();
	op.stack.tinit();
	op.dir = p.lib_dir(true)!;
	return op;
}

fn void Op.commit(&self)
{
	if (self.backup.len) sys::remove(self.backup);
	self.backup = "";
	self.touched.clear();
}

<*
 Put back the project file, the lockfile (never written with --frozen) and
 every library file the operation replaced. If a library cannot be put back,
 its previous file stays in the backup directory, and the user is told where.
*>
fn void Op.rollback(&self)
{
	if (catch sys::write_atomic(self.proj.file, self.project_text)) log::error("%s could not be restored", self.proj.file);
	self.proj.changed();
	Lock* l = &self.proj.lock;
	if (!l.frozen)
	{
		if (self.had_lock && @catch(sys::write_atomic(l.file, self.lock_text))) log::error("%s could not be restored", l.file);
		if (!self.had_lock) (void)file::delete(l.file);
	}
	bool frozen = l.frozen;
	*l = lock::load(l.file) ?? *l;
	l.frozen = frozen;

	bool restored = true;
	foreach (t : self.touched)
	{
		String f = self.file_of(t.name);
		sys::remove(f);
		if (t.had_file && !sys::rename(project::lib_file(self.backup, t.name), f))
		{
			log::error("could not restore %s; the previous file is in %s", f, self.backup);
			restored = false;
		}
	}
	if (restored) self.commit();
}

fn String Op.file_of(&self, String name) => project::lib_file(self.dir, name);

// Install one library and, unless it is a restore, what it requires.
fn void? Op.add(&self, Want w, Intent intent)
{
	Manifest m = self.install(w, intent)!;
	if (w.pin.len) return;
	self.check_dependents(m.provides)!;
	self.follow(m.provides, m.requires)!;
}

// Install one library; its manifest, with `provides` set to the name it was installed as.
fn Manifest? Op.install(&self, Want w, Intent intent)
{
	if (w.pin.len) intent = KEEP;  // a restore
	switch (w.kind)
	{
		case REGISTRY: return self.install_registry(w, intent);
		case VENDOR: return self.install_vendor(w, intent);
		case GIT: return self.install_git(w, intent);
		case PATH: return self.install_path(w, intent);
	}
}

fn Manifest? Op.install_registry(&self, Want w, Intent intent)
{
	String name = w.id[(w.id.rindex_of_char('/') ?? -1) + 1..];
	self.check_collision(name, REGISTRY, w.origin, w.id)!;
	Info info = registry::info(w.origin, w.id) ?? log::fail("%s: not found or registry not reachable (%s)", w.id, w.origin)~!;
	String version = w.ref.len ? w.ref : info.latest;
	if (!version.len) return log::fail("registry returned no latest version for %s", w.id)~;
	if (!info.has(version)) return log::fail("no such version '%s' for %s", version, w.id)~;
	if (!w.pin.len && !registry::compatible(w.origin, w.id, version) && self.opts.strict)
	{
		return log::fail("%s@%s is not compatible with this toolchain (--strict)", w.id, version)~;
	}
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
	String got = verify(staged, expected, string::tformat("%s@%s", w.id, version))!;
	warn_provides(staged, name, w.id);
	Manifest m = self.place({ .name = name, .kind = REGISTRY, .origin = w.origin, .id = w.id, .version = version, .pin = got, .hash = got }, staged, intent)!;
	log::info("installed %s %s (%s)", name, version, got);
	return m;
}

fn Manifest? Op.install_vendor(&self, Want w, Intent intent)
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
	if (!http::download(project::lib_file(w.origin, name), staged).ok()) return log::fail("download of vendor:%s failed", name)~;
	if (w.pin.len && (sys::sha256_file(staged) ?? "") != w.pin)
	{
		return log::fail("vendor:%s changed upstream (the collection is one rolling release, it has no versions); 'c3l update %s' takes the new file", name, name)~;
	}
	String got = verify(staged, expected, string::tformat("vendor:%s", name))!;
	warn_provides(staged, name, string::tformat("vendor:%s", name));
	Manifest m = self.place({ .name = name, .kind = VENDOR, .origin = w.origin, .id = name, .version = "latest", .pin = got, .hash = got }, staged, intent)!;
	log::info("installed %s (%s)", name, got);
	return m;
}

<*
 ref: empty (highest release tag, else HEAD), HEAD, a tag, a branch, a full commit,
 or a lock label (branch:NAME, commit:SHA12). pin: commit:<sha>.
 The lock label is the tag, HEAD, branch:NAME or commit:SHA12.
*>
fn Manifest? Op.install_git(&self, Want w, Intent intent)
{
	String url = w.origin;
	Rev rev = resolve_rev(url, w.ref, w.pin)!;
	String tmp = sys::temp_dir()!;
	defer sys::remove(tmp);
	String src = git::checkout(url, rev.commit, rev.kind == TAG || rev.kind == BRANCH ? rev.name : "", tmp)!;
	String name = (manifest::load(src) ?? log::fail("%s has no manifest.json at its root (not a C3 library)", url)~!).provides;
	check_name(name, url)!;
	if (file::exists(string::tformat("%s/.gitmodules", src))) log::warn("%s uses submodules; they are not included in the library", url);
	self.check_collision(name, GIT, url, "-")!;

	String staged = self.staging(name);
	defer (void)file::delete(staged);
	git::archive(src, staged)!;
	String contents = sys::content_hash(staged) ?? log::fail("git archive of %s is not a readable zip", url)~!;
	if (w.hash.starts_with("content:") && contents != w.hash)
	{
		return log::fail("the files of %s at commit %s differ from c3l.lock (expected %s, got %s)", url, rev.commit, w.hash, contents)~;
	}
	String pin = string::tformat("commit:%s", rev.commit);
	Manifest m = self.place({ .name = name, .kind = GIT, .origin = url, .id = "-", .version = rev.label, .pin = pin, .hash = contents }, staged, intent)!;
	log::info("installed %s %s (commit %s)", name, rev.label, rev.commit[:12]);
	return m;
}

// A local directory, linked into the library directory so edits show up in the next build.
fn Manifest? Op.install_path(&self, Want w, Intent intent)
{
	String src = w.origin;
	String name = (manifest::load_file(string::tformat("%s/manifest.json", src)) ?? log::fail("%s has no manifest.json (not a C3 library)", src)~!).provides;
	String abs = (String)src.to_absolute_path(tmem) ?? log::fail("cannot enter %s", src)~!;
	check_name(name, src)!;
	self.check_collision(name, PATH, src, "-")!;
	self.set_aside(name)!;
	String dir = (String)self.dir.to_absolute_path(tmem) ?? log::fail("cannot enter %s", self.dir)~!;
	sys::link(sys::relative(dir, abs), self.file_of(name))!;  // relative: the project can move
	Manifest m = self.place({ .name = name, .kind = PATH, .origin = src, .id = "-", .version = "-", .pin = "-", .hash = "-" }, "", intent)!;
	log::info("linked %s -> %s", name, abs);
	return m;
}

// Library names are global in a project: one name, one source.
fn void? Op.check_collision(&self, String name, Kind kind, String origin, String id)
{
	Entry*? e = self.proj.lock.get(name);
	if (catch e) return;
	bool same_origin = kind == GIT ? git::canonical(e.origin) == git::canonical(origin) : e.origin == origin;
	if (e.kind == kind && same_origin && e.id == id) return;
	return log::fail("'%s' is already installed from %s. Library names are global in a project; run 'c3l remove %s' first.", name, e.source(), name)~;
}

// "provides" of a library's manifest becomes a file name and a lock key.
fn void? check_name(String name, String source) @private
{
	if (!name.len) return log::fail("manifest.json of %s has no 'provides'", source)~;
	if (!lock::valid_name(name)) return log::fail("manifest.json of %s provides '%s', which is not a valid library name", source, name)~;
}

// Where a download is written before it is checked: next to its final place.
fn String Op.staging(&self, String name) => string::tformat("%s/.%s.c3l.part", self.dir, name);

// "sha256:<hex>" of the file, which must be `expected` when that is known.
fn String? verify(String file, String expected, String what) @private
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
fn void? Op.set_aside(&self, String name)
{
	foreach (t : self.touched) if (t.name == name) return;
	String f = self.file_of(name);
	bool had = sys::exists(f);
	if (had)
	{
		if (!self.backup.len) self.backup = sys::temp_dir(self.dir, ".c3l-backup")!;
		String to = project::lib_file(self.backup, name);
		if (!sys::rename(f, to)) return log::fail("cannot move %s to %s", f, to)~;
	}
	self.touched.push({ name, had });
}

<*
 Put `staged` in place (empty: already there), list the library in the project,
 record it in the lock. A library's own manifest lists only its direct
 dependencies, so in a library directory a dependency is not registered.
*>
fn Manifest? Op.place(&self, Entry e, String staged, Intent intent)
{
	String f = self.file_of(e.name);
	if (staged.len)
	{
		self.set_aside(e.name)!;
		if (!sys::rename(staged, f)) return log::fail("cannot write %s", f)~;
	}
	Manifest m = manifest::load(f) ?? (Manifest){};
	if (m.invalid.len) return log::fail("manifest.json of %s requires '%s', which is not a valid library name", e.name, m.invalid)~;
	foreach (note : m.notes) log::warn("%s: %s", e.name, note);
	m.provides = e.name;
	e.role = self.role_of(e.name, intent);
	e.requires = m.require_names();
	if (!(self.proj.libmode && e.role == DEP) && !self.proj.has_dep(e.name)!)
	{
		if (catch err = self.proj.set_dep(e.name, true))
		{
			if (err == project::NOT_UPDATED) return log::fail("could not register %s in %s", e.name, self.proj.file)~;
			return err~;  // already reported
		}
	}
	self.proj.lock.put(e);
	self.proj.lock.save()!;
	return m;
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
	Ref[]? tags = NOT_FOUND~;  // fetched once, when needed
	if (!ref.len && !pin.len)
	{
		tags = git::tags(url);
		ref = git::highest(tags!);
		if (!ref.len) ref = "HEAD";
	}
	Rev r = { .kind = TAG, .name = ref, .label = ref };
	if (ref == "HEAD") r.kind = HEAD;
	if (ref.starts_with("branch:")) r = { .kind = BRANCH, .name = ref["branch:".len..], .label = ref };
	if (ref.starts_with("commit:")) r = { .kind = COMMIT, .commit = ref["commit:".len..], .label = short_commit(ref["commit:".len..]) };
	if (pin.len)
	{
		r.commit = pin.strip_prefix("commit:");
		if (!git::is_commit(r.commit)) return log::fail("the lock pins %s to '%s', which is not a commit id", url, pin)~;
		return r;
	}
	switch (r.kind)
	{
		case HEAD:
			r.commit = git::head(url)!;
			if (!r.commit.len) return log::fail("cannot resolve HEAD of %s%s", url, git::because())~;
		case BRANCH:
			r.commit = git::branch_commit(url, r.name)!;
			if (!r.commit.len) return log::fail("branch '%s' not found in %s%s", r.name, url, git::because())~;
		case COMMIT:
			break;
		case TAG: // a plain name: a tag, else a branch, else a full commit
			if (catch tags) tags = git::tags(url);
			r.commit = git::commit_of(tags!, ref);
			if (r.commit.len) return r;
			r = { .kind = BRANCH, .name = ref, .commit = git::branch_commit(url, ref)!, .label = string::tformat("branch:%s", ref) };
			if (r.commit.len) return r;
			if (is_short_commit(ref)) return log::fail("'%s' is not a tag or branch in %s; give a commit as its full 40-character hash", ref, url)~;
			if (!git::is_commit(ref)) return log::fail("'%s' is not a tag, branch or full commit hash in %s%s", ref, url, git::because())~;
			r = { .kind = COMMIT, .commit = ref, .label = short_commit(ref) };
	}
	if (r.kind == COMMIT && !git::is_commit(r.commit)) return log::fail("a commit must be given as the full 40-character hash")~;
	return r;
}

fn bool is_short_commit(String s) @private
{
	if (s.len < 7 || s.len >= 40) return false;
	foreach (c : s) if (!c.is_xdigit()) return false;
	return true;
}

fn String short_commit(String commit) @private => string::tformat("commit:%s", commit[:commit.len < 12 ? commit.len : 12]);
