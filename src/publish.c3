<*
 Publishing a library: everything that can be checked before the upload, the
 deterministic package, and the upload to a registry with an API (c3pkg).
*>
module c3l::publish;

import std::io, std::os, std::sort, std::collections::list, std::collections::object, std::encoding::json;
import c3l::log, c3l::sys, c3l::lock, c3l::semver, c3l::manifest, c3l::jsonedit, c3l::http, c3l::registry, c3l::git, c3l::install, c3l::select;

const String MIN_SOURCE_LIB = "0.8.6";  // the c3c that builds source libraries

// From the command line.
struct Settings
{
	String registry;
	String registry_type;
	String version;
	String c3_version;
	String token_file;
	bool allow_dirty;
	bool no_build;
	bool offline;
	bool list;
	String target;
	String description;
	String license;
	String tags;
	String docs_url;
	String git_url;
}

struct Package
{
	String dir;
	String name;
	String version;
	String version_from;
	String c3_version;
	String[] dependency_entries;  // the manifest's "dependencies", as written
	int errors;
	Selection chosen;   // what files() chose, once
	bool selected;
	String work;        // temporary directory of a source-lib build, removed by cleanup()
	String root;        // where the files are read from: the dir, or what c3c built
	String[] platforms; // the manifest's "targets"
	String target;      // the source-lib target the package is built from, empty for a manifest.json library
}

fn void Package.error(&self, String format, args...) @format(1)
{
	log::error("%s", string::tformat(format, ...args));
	self.errors++;
}

<*
 Every check that can run before the upload. Problems are counted in
 `errors`, each one printed; warnings do not count.
*>
fn Package check(String dir, Settings s)
{
	Package p = { .dir = dir };
	if (!file::is_dir(dir))
	{
		p.error("%s is not a directory", dir);
		return p;
	}
	Manifest? m = p.load_manifest(s);
	if (catch m) return p;  // load_manifest said why
	p.name = m.provides;
	if (!p.name.len)
	{
		p.error("manifest.json has no \"provides\" (the package name)");
		return p;
	}
	if (!lock::valid_name(p.name)) p.error("invalid package name '%s' (letters, digits, '.', '_', '-')", p.name);
	if (!p.resolve_version(s.version, p.target.len ? "" : m.version))
	{
		p.error("no version: tag the commit (git tag v1.2.3), pass --version 1.2.3, or set \"version\" in manifest.json (or project.json)");
		return p;
	}
	if (!semver::strict(p.version))
	{
		p.error("'%s' (from %s) is not a valid semantic version; the registry wants MAJOR.MINOR.PATCH or MAJOR.MINOR.PATCH-prerelease, e.g. 1.2.3 or 1.2.3-rc.1", p.version, p.version_from);
		return p;
	}
	p.c3_version = s.c3_version.len ? s.c3_version : sys::c3_version();
	if (!p.c3_version.len) p.error("cannot determine the C3 version; pass --c3-version");

	String[] files = p.files();
	if (s.list) p.print_list();
	bool sources;
	foreach (f : files) if (f.ends_with(".c3") || f.ends_with(".c3i")) sources = true;
	if (!sources) log::warn("%s contains no .c3/.c3i sources", dir);
	p.warn_tests();
	if (!file::exists(string::tformat("%s/README.md", dir))) log::warn("no README.md in %s (the registry shows it as the package page)", dir);

	p.dependency_entries = m.entries;
	if (p.target.len)
	{
		List{String} plain;
		plain.tinit();
		foreach (d : m.entries) plain.push(manifest::bare_name(d));
		p.dependency_entries = plain.array_view();
	}
	p.platforms = m.targets;
	p.check_dependencies(m);
	p.check_clean(s.allow_dirty);
	if (!s.no_build) p.check_build();
	if (!s.offline) p.check_registry(s);
	if (!p.errors) log::info("%s %s (from %s, C3 %s) passes all checks", p.name, p.version, p.version_from, p.c3_version);
	return p;
}

faultdef NO_SOURCE_LIB;

<*
 manifest.json of the library in `dir`; a project without one but with a
 "source-lib" target gets it from what `c3c build <target>` writes.
*>
fn Manifest? Package.load_manifest(&self, Settings s)
{
	Manifest? m = manifest::load_file(string::tformat("%s/manifest.json", self.dir));
	if (try m) return m;
	if (@catch(m) != manifest::NO_MANIFEST)
	{
		self.error("manifest.json in %s cannot be read as JSON (comments and trailing commas are fine)", self.dir);
		return manifest::BAD_MANIFEST~;
	}
	String[] targets = source_lib_targets(self.dir);
	if (!targets.len)
	{
		self.error("no manifest.json in %s; publish a library directory (create one with 'c3c init-lib <name>') or a project with a \"source-lib\" target", self.dir);
		return manifest::NO_MANIFEST~;
	}
	return self.build_source_lib(targets, s.target);
}

<*
 The targets of type "source-lib" in the project.json(5) of `dir`, sorted.
*>
fn String[] source_lib_targets(String dir) @private
{
	List{String} out;
	out.tinit();
	String file = string::tformat("%s/project.json", dir);
	if (!file::exists(file)) file = string::tformat("%s/project.json5", dir);
	char[]? data = file::load_temp(file);
	if (catch data) return {};
	Object* root = json::tparse((String)data) ?? null;
	Object* targets = root && root.is_map() ? root.get("targets") ?? null : null;
	if (!targets || !targets.is_map()) return {};
	targets.@each_entry(; String key, Object* t)
	{
		if (t.is_map() && (t.get_string("type") ?? "") == "source-lib") out.push(key);
	};
	sort::quicksort(&out, fn int(String a, String b) => a.compare_to(b));  // the map has no order to rely on
	return out.array_view();
}

<*
 Build the source-lib target with c3c into a temporary directory (the
 project's own build and output directories stay as they are); the package is
 what c3c wrote, plus c3l.lock.
*>
fn Manifest? Package.build_source_lib(&self, String[] targets, String want)
{
	String target = want;
	switch
	{
		case want.len && !has_name(targets, want):
			self.error("project.json has no source-lib target '%s' (it has: %s)", want, names(targets));
			return NO_SOURCE_LIB~;
		case !want.len && targets.len > 1:
			self.error("project.json has several source-lib targets (%s); pick one with --target <name>", names(targets));
			return NO_SOURCE_LIB~;
		case !want.len:
			target = targets[0];
	}
	String v = sys::c3_version();
	if (!v.len || semver::compare(v, MIN_SOURCE_LIB) < 0)
	{
		self.error("packing a project's source-lib target needs c3c %s or newer (this is %s)", MIN_SOURCE_LIB, v.len ? v : "unknown");
		return NO_SOURCE_LIB~;
	}
	String? work = sys::temp_dir();
	if (catch work)
	{
		self.errors++;
		return NO_SOURCE_LIB~;
	}
	self.work = work;
	String out = string::tformat("%s/o", work);
	Output? o = sys::run({ sys::c3c(), "--path", self.dir, "build", target, "--build-dir", string::tformat("%s/b", work), "--output-dir", out, "--no-compress" }, MERGE);
	if (catch o) 
	{
		self.error("cannot run c3c");
		return NO_SOURCE_LIB~;
	}
	if (o.code != 0)
	{
		self.error("c3c build %s failed:", target);
		String[] lines = o.out.trim().tsplit("\n");
		foreach (line : lines[lines.len > 15 ? lines.len - 15 : 0..]) io::eprintn(line);
		return NO_SOURCE_LIB~;
	}
	String built;
	if (try list = path::ls(tmem, (Path)out))
	{
		foreach (f : list)
		{
			String name = ((String)f);
			if (name.ends_with(".c3l") && file::is_dir(string::tformat("%s/%s", out, name))) built = string::tformat("%s/%s", out, name);
		}
	}
	if (!built.len)
	{
		self.error("c3c build %s wrote no library", target);
		return NO_SOURCE_LIB~;
	}
	self.root = built;
	self.target = target;
	Lock l = lock::load(string::tformat("%s/c3l.lock", self.dir)) ?? (Lock){};  // check_dependencies reports a broken one
	if (l.entries.len() > 0)
	{
		char[]? data = file::load_temp(string::tformat("%s/c3l.lock", self.dir));
		if (try data) (void)file::save(string::tformat("%s/c3l.lock", built), data);
	}
	return manifest::load_file(string::tformat("%s/manifest.json", built)) ?? NO_SOURCE_LIB~;
}

fn bool has_name(String[] list, String name) @private
{
	foreach (n : list) if (n == name) return true;
	return false;
}

fn String names(String[] list) @private
{
	DString d = dstring::temp();
	foreach (i, n : list)
	{
		if (i) d.append(", ");
		d.append(n);
	}
	return d.str_view();
}

// Remove what a source-lib build left in the temporary directory.
fn void Package.cleanup(&self)
{
	if (self.work.len) sys::remove(self.work);
	self.work = "";
}

<*
 The version, in this order: --version, a semver tag on HEAD, "version" in
 manifest.json, "version" in project.json. A source that says something else
 only gets a warning.
*>
fn bool Package.resolve_version(&self, String option, String in_manifest)
{
	String pfile = string::tformat("%s/project.json", self.dir);
	if (!file::exists(pfile)) pfile = string::tformat("%s/project.json5", self.dir);
	String in_project = (manifest::load_file(pfile) ?? (Manifest){}).version;
	String tag, tagged;
	if (git::is_repo(self.dir))
	{
		foreach (t : git::lines(self.dir, { "tag", "--points-at", "HEAD" }))
		{
			String v = t.strip_prefix("v");
			if (!semver::strict(v) || (tagged.len && semver::compare(v, tagged) <= 0)) continue;
			tagged = v;
			tag = t;
		}
	}
	switch
	{
		case option.len > 0:
			self.version = option.strip_prefix("v");
			self.version_from = "--version";
			if (tagged.len && tagged != self.version) log::warn("tag %s on HEAD says %s, but --version says %s; using %s", tag, tagged, self.version, self.version);
		case tagged.len > 0:
			self.version = tagged;
			self.version_from = string::tformat("git tag %s", tag);
		case in_manifest.len > 0:
			self.version = in_manifest;
			self.version_from = "manifest.json";
		case in_project.len > 0:
			self.version = in_project;
			self.version_from = pfile[self.dir.len + 1..];
		default:
			return false;
	}
	if (in_manifest.len && in_manifest != self.version)
	{
		log::warn("manifest.json says version %s, publishing %s (from %s); the archive's manifest gets %s", in_manifest, self.version, self.version_from, self.version);
	}
	if (in_project.len && in_project != self.version)
	{
		log::warn("%s says version %s, publishing %s (from %s)", pfile[self.dir.len + 1..], in_project, self.version, self.version_from);
	}
	return true;
}

// Consumers get the dependencies from the c3l.lock in the package; a local directory cannot travel.
fn void Package.check_dependencies(&self, Manifest m)
{
	Lock? l = lock::load(string::tformat("%s/c3l.lock", self.dir));
	if (catch l)
	{
		self.errors++;  // load said why
		return;
	}
	foreach (r : m.requires)
	{
		if (r.name == self.name)
		{
			log::warn("%s lists itself as a dependency", self.name);
			continue;
		}
		if (r.source.len) continue;
		if (try e = l.get(r.name) && e.role == Role.DIRECT && e.kind != Kind.PATH) continue;
		String f = string::tformat("lib/%s.c3l", r.name);
		if (!l.has(r.name) && sys::exists(string::tformat("%s/%s", self.dir, f)))
		{
			// the package leaves lib/ out, and c3c finds a library only next to the others, never inside one
			self.error("the manifest depends on '%s', but %s is not in c3l.lock, so consumers cannot get it: lock it with 'c3l add <source>' (publish it to a registry or a git repository first), or put its sources in this library (e.g. vendor/%s/, listed in \"sources\")", r.name, f, r.name);
			continue;
		}
		log::warn("'%s' is in the manifest's dependencies but nothing says where to get it; run 'c3l add' for it in this library so consumers can install it automatically", r.name);
	}
	foreach (&sm : git::submodules(string::tformat("%s/lib", self.dir)))
	{
		Entry*? e = l.get(sm.name);
		if (catch e)
		{
			log::warn("%s is a git submodule that c3l.lock does not list; consumers do not get submodules ('c3l migrate' locks it)", sm.path);
			continue;
		}
		Status st = install::submodule_status(e, sm);
		if (st != OK) self.error("%s", install::explain(st, e, sm));
	}
	foreach (e : l.entries)
	{
		if (e.role != DIRECT || e.kind != PATH) continue;
		self.error("dependency '%s' is a local directory, which consumers cannot fetch; add it from a registry or a git URL before publishing", e.name);
	}
}

fn void Package.check_clean(&self, bool allow_dirty)
{
	if (!git::is_repo(self.dir)) return;
	bool dirty = git::lines(self.dir, { "status", "--porcelain", "--untracked-files=no", "--", "." }).len > 0;
	if (!dirty)
	{
		// a new file the package would hold
		String[] untracked = packed(git::lines(self.dir, { "-c", "core.quotepath=off", "ls-files", "-o", "--exclude-standard" }));
		foreach (p : self.choose().picked)
		{
			if (has_name(untracked, p.path)) dirty = true;
		}
	}
	if (!dirty) return;
	if (allow_dirty)
	{
		log::warn("working tree is not clean; the package will not match the commit");
		return;
	}
	bool lock = git::lines(self.dir, { "status", "--porcelain", "--", "c3l.lock" }).len > 0;
	self.error("working tree is not clean (commit or stash, or pass --allow-dirty), so the package would not match a commit%s",
		lock ? "; c3l.lock is part of the package, commit it" : "");
}

<*
 Compile the staged package as a library, with what consumers get besides it:
 the libraries in its c3l.lock. Anything else in lib/ does not travel, so the
 library must not need it.
*>
fn void Package.check_build(&self)
{
	String? tmp = sys::temp_dir();
	if (catch tmp)
	{
		self.errors++;  // temp_dir said why
		return;
	}
	defer sys::remove(tmp);
	if (catch self.stage(tmp))
	{
		self.errors++;  // stage said why
		return;
	}
	List{String} argv;
	argv.tinit();
	String empty = string::tformat("%s/cwd", tmp);
	(void)path::mkdir(empty);
	argv.push_all({ sys::c3c(), "--path", empty, "--libdir", string::tformat("%s/stage", tmp) });
	String lib = string::tformat("%s/lib", self.dir);
	if (file::is_dir(lib))
	{
		argv.push_all({ "--libdir", (String)lib.to_absolute_path(tmem) ?? lib });
		Lock l = lock::load(string::tformat("%s/c3l.lock", self.dir)) ?? (Lock){};  // check_dependencies reported a broken one
		foreach (e : l.entries)
		{
			if (sys::exists(string::tformat("%s/%s.c3l", lib, e.name))) argv.push_all({ "--lib", e.name });
		}
	}
	argv.push_all({ "compile-only", "--lib", self.name, "--no-obj" });
	Output? o = sys::run(argv.array_view(), MERGE);
	bool built;
	if (try o) built = o.code == 0;
	if (!built)
	{
		self.error("the library does not compile:");
		String[] lines = (o.out ?? "").trim().tsplit("\n");
		foreach (line : lines[lines.len > 15 ? lines.len - 15 : 0..]) io::eprintn(line);
		return;
	}
	log::info("library compiles with c3c %s", sys::c3_version());

	// the other platforms of the manifest, compiled without objects
	String host = sys::host_target();
	String[] sorted = self.platforms;
	sort::quicksort(sorted, fn int(String a, String b) => a.compare_to(b));
	foreach (t : sorted)
	{
		if (t == host) continue;
		if (t.starts_with("android-"))
		{
			// c3c asks to download the NDK (and waits for the answer) before it checks anything
			log::info("%s skipped: c3c needs the Android NDK for it, which 'check' does not download", t);
			continue;
		}
		argv.push_all({ "--target", t });
		Output? po = sys::run(argv.array_view(), MERGE);
		argv.pop()!!;
		argv.pop()!!;
		bool ok;
		if (try po) ok = po.code == 0;
		if (ok)
		{
			log::info("library compiles for %s", t);
			continue;
		}
		String said = (po.out ?? "");
		if (said.contains("cannot be used with arch/os"))
		{
			// a library this one depends on does not support the platform: not a fault of this package
			log::warn("%s not checked: a library it depends on does not support it", t);
			continue;
		}
		if (!self.compiles_trivial(tmp, t))
		{
			log::info("%s skipped: c3c cannot check any library for it here (no SDK?)", t);
			continue;
		}
		self.error("the library does not compile for %s:", t);
		String[] lines = (po.out ?? "").trim().tsplit("\n");
		foreach (line : lines[lines.len > 15 ? lines.len - 15 : 0..]) io::eprintn(line);
	}
}

// Can c3c check an empty library for `target` here? When not, a failure for it says nothing about the package.
fn bool Package.compiles_trivial(&self, String tmp, String target)
{
	String dir = string::tformat("%s/trivial", tmp);
	String lib = string::tformat("%s/triv.c3l", dir);
	(void)path::mkdir(lib, true);
	if (catch file::save(string::tformat("%s/manifest.json", lib), `{ "provides": "triv", "sources": [ "t.c3" ] }`)) return false;
	if (catch file::save(string::tformat("%s/t.c3", lib), "module triv;\n")) return false;
	String empty = string::tformat("%s/cwd", tmp);
	Output? o = sys::run({ sys::c3c(), "--path", empty, "--libdir", dir, "compile-only", "--lib", "triv", "--no-obj", "--target", target }, MERGE);
	if (try o) return o.code == 0;
	return false;
}

<*
 Test code in the package is compiled by consumers: warn about a file named
 *_test.c3 and about one with an @test function.
*>
fn void Package.warn_tests(&self)
{
	List{String} found;
	found.tinit();
	String base = self.root.len ? self.root : self.dir;
	foreach (f : self.files())
	{
		if (!f.ends_with(".c3") && !f.ends_with(".c3t")) continue;
		bool test = f.ends_with("_test.c3");
		if (!test)
		{
			String text = (String)file::load_temp(string::tformat("%s/%s", base, f)) ?? "";
			test = text.contains("@test");
		}
		if (test) found.push(f);
	}
	if (!found.len()) return;
	log::warn("the package contains test code that consumers compile too: %s%s", found[0], found.len() > 1 ? string::tformat(" and %d more", found.len() - 1) : "");
}

<*
 What `--list` prints: each packed file with the rule that took it, then the
 files left out (tracked, or not ignored by git).
*>
fn void Package.print_list(&self)
{
	Selection* c = self.choose();
	io::printfn("packed (%d):", c.picked.len);
	foreach (p : c.picked) io::printfn("  %s\t%s", p.path, p.rule);
	io::printfn("left out (%d):", c.left_out.len);
	foreach (f : c.left_out) io::printfn("  %s", f);
}

// Not published yet, not older than what is; a new package needs a description.
// c3pkg's rule for an entry of "dependencies": [a-z][a-z0-9_]{0,126}
fn bool c3pkg_dependency(String d)
{
	if (!d.len || d.len > 127 || !(d[0] >= 'a' && d[0] <= 'z')) return false;
	foreach (c : d) if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '_')) return false;
	return true;
}

fn void Package.check_registry(&self, Settings s)
{
	String base = registry::base(s.registry);
	bool guessed;
	if ((registry::detect(base, s.registry_type, &guessed) ?? Api.STATIC) != C3PKG) return;
	foreach (d : self.dependency_entries)
	{
		if (c3pkg_dependency(d)) continue;
		self.error("manifest.json \"dependencies\" has \"%s\"; %s only takes a plain library name there, like \"vk\" (c3l.lock in the package says where consumers get it)", d, base);
	}
	String[]? published = registry::versions(base, self.name);
	if (catch e = published)
	{
		if (e != registry::NO_PACKAGE)
		{
			log::warn("could not query %s for existing versions", base);
			return;
		}
		if (!s.description.len) self.error("%s is new on this registry: --description is required for the first publish", self.name);
		return;
	}
	foreach (v : published)
	{
		if (v == self.version)
		{
			self.error("%s %s is already published; versions are immutable, bump the version", self.name, self.version);
			return;
		}
	}
	foreach (v : published)
	{
		if (semver::compare(self.version, v) >= 0) continue;
		log::warn("%s is older than the published %s", self.version, v);
		return;
	}
}

<*
 Copy the package into `<tmp>/stage/<name>.c3l` with the version being
 published in its manifest. Its c3l.lock comes along: that is how consumers
 learn what the library requires.
*>
fn String? Package.stage(&self, String tmp)
{
	String to = string::tformat("%s/stage/%s.c3l", tmp, self.name);
	String[] files = self.files();
	if (!files.len) return log::fail("no files to pack in %s", self.dir)~;
	foreach (f : files)
	{
		String dst = string::tformat("%s/%s", to, f);
		(void)path::mkdir(dst[:dst.rindex_of_char('/')!!], true);
		String from = string::tformat("%s/%s", self.root.len ? self.root : self.dir, f);
		char[] data = file::load_temp(from) ?? log::fail("staging %s failed", from)~!;
		file::save(dst, data) ?? log::fail("staging %s failed", from)~!;
	}
	String mfile = string::tformat("%s/manifest.json", to);
	String text = (String)file::load_temp(mfile) ?? log::fail("manifest.json is not part of the package (is it ignored by git?)")~!;
	text = jsonedit::set_string(text, "version", self.version);
	if (self.target.len)
	{
		// c3c copies the project's dependencies, which may be full paths; a package names libraries only (c3l.lock says where from)
		foreach (item : jsonedit::array_items(text, "dependencies"))
		{
			String bare = manifest::bare_name(item);
			if (bare != item) text = jsonedit::put_array(text, "dependencies", bare, bare, true);
		}
	}
	file::save(mfile, text) ?? log::fail("cannot write %s", mfile)~!;
	return to;
}

// Stage and zip the package into `out`; its "sha256:<hex>".
fn String? Package.pack(&self, String out)
{
	String tmp = sys::temp_dir()!;
	defer sys::remove(tmp);
	String staged = self.stage(tmp)!;
	write_zip(staged, self.files(), out)!;
	return sys::sha256_file(out);
}

<*
 The files that belong in the package, sorted: what the manifest names and
 c3c reads (see select.c3), from the files git tracks or does not ignore (all
 files without git). Chosen once; what is wrong with the choice is reported
 and counted then.
*>
fn String[] Package.files(&self)
{
	List{String} out;
	out.tinit();
	foreach (p : self.choose().picked) out.push(p.path);
	return out.array_view();
}

fn Selection* Package.choose(&self)
{
	if (self.selected) return &self.chosen;
	self.selected = true;
	String[] all, ignored;
	if (git::is_repo(self.dir))
	{
		all = git::lines(self.dir, { "-c", "core.quotepath=off", "ls-files", "-co", "--exclude-standard" });
		ignored = git::lines(self.dir, { "-c", "core.quotepath=off", "ls-files", "-o", "-i", "--exclude-standard" });
	}
	else
	{
		all = walk(self.dir);
	}
	List{String} cand;
	cand.tinit();
	foreach (f : packed(all))
	{
		if (file::is_file(string::tformat("%s/%s", self.dir, f)) && !cand.contains(f)) cand.push(f);
	}
	if (self.root.len)
	{
		// c3c chose the files of a source-lib target; what is left of the project is left out
		List{Pick} picked;
		picked.tinit();
		foreach (f : walk(self.root))
		{
			picked.push({ f, f == "manifest.json" ? "manifest" : f == "c3l.lock" ? "lock" : string::tformat("source-lib target %s", self.target) });
		}
		sort::quicksort(&picked, fn int(Pick a, Pick b) => a.path.compare_to(b.path));
		List{String} left;
		left.tinit();
		foreach (f : cand) if (!picked.contains_pick(f)) left.push(f);
		self.chosen = { picked.array_view(), left.array_view(), {}, {} };
		return &self.chosen;
	}
	Lock l = lock::load(string::tformat("%s/c3l.lock", self.dir)) ?? (Lock){};  // check_dependencies reports a broken one
	String text = (String)file::load_temp(string::tformat("%s/manifest.json", self.dir)) ?? "";
	self.chosen = select::choose(text, cand.array_view(), packed(ignored), sys::platforms(), l.entries.len() > 0);
	foreach (e : self.chosen.errors) self.error("%s", e);
	foreach (w : self.chosen.warnings) log::warn("%s", w);
	return &self.chosen;
}

fn bool List{Pick}.contains_pick(&self, String path)
{
	foreach (p : *self) if (p.path == path) return true;
	return false;
}

// Every file below `dir`, relative to it, with '/'.
fn String[] walk(String dir) @private
{
	List{String} found;
	found.tinit();
	if (try list = path::ls(tmem, (Path)dir, no_dirs: true, recursive: true))
	{
		foreach (f : list)
		{
			$if env::WIN32:
				found.push(((String)f).treplace("\\", "/"));  // package paths use '/'
			$else
				found.push((String)f);
			$endif
		}
	}
	return found.array_view();
}

// Without what is never packed.
fn String[] packed(String[] files) @private
{
	List{String} out;
	out.tinit();
	foreach (f : files)
	{
		String in_lib = f.starts_with("lib/") ? f["lib/".len..] : "";
		bool top_c3l = f.ends_with(".c3l") && !f.contains("/");
		bool lib_c3l = in_lib[:in_lib.index_of_char('/') ?? in_lib.len].ends_with(".c3l");  // lib/x.c3l, lib/x.c3l/...
		if (top_c3l || lib_c3l || f.starts_with("obj/") || f.starts_with("build/") || f.starts_with(".git/")) continue;
		out.push(f);
	}
	return out.array_view();
}

<*
 Upload the package `file` to a c3pkg registry, then compare the checksum the
 registry reports with the uploaded file's.
*>
fn void? Package.upload(&self, Settings s, String file, String sha)
{
	String base = registry::base(s.registry);
	String host = install::host_of(base);
	if (!base.starts_with("https://") && host != "localhost" && host != "127.0.0.1")
	{
		return log::fail("refusing to send the API token to %s: not https", base)~;
	}
	List{Part} form;
	form.tinit();
	form.push({ .name = "file", .file = file });
	form.push({ .name = "c3_version", .value = self.c3_version });
	String[2][] fields = {
		{ "description", s.description }, { "license", s.license }, { "tags", s.tags },
		{ "docs_url", s.docs_url }, { "git_url", s.git_url },
	};
	foreach (f : fields) if (f[1].len) form.push({ .name = f[0], .value = f[1] });
	Response r = http::request({
		.method = "PUT",
		.url = string::tformat("%s/api/v1/packages/%s/versions/%s", base, self.name, self.version),
		.headers = { string::tformat("Authorization: Bearer %s", token(s.token_file)!) },
		.form = form.array_view(),
		.timeout = 600,
		.no_redirects = true,  // the token goes to this URL only
	});
	if (r.error.len) return log::fail("upload failed: cannot reach %s", base)~;
	if (r.status != 201)
	{
		Object* o = json::tparse(r.body) ?? null;
		String msg = o && o.is_map() ? o.get_string("error") ?? "" : "";
		if (!msg.len) msg = r.body[:r.body.len < 300 ? r.body.len : 300];
		switch (r.status)
		{
			case 401:
			case 403: return log::fail("registry rejected the token (HTTP %d): %s", r.status, msg.len ? msg : "not authorized")~;
			case 429: return log::fail("rate limited by the registry; retry in %s seconds", r.retry_after.len ? r.retry_after : "a few")~;
			default: return log::fail("registry refused %s@%s (HTTP %d): %s", self.name, self.version, r.status, msg)~;
		}
	}
	Object* idx = registry::index(base, self.name, self.version) ?? null;
	String got = idx ? (idx.get_string("sha256_file") ?? "").strip_prefix("sha256:") : "";
	String want = sha.strip_prefix("sha256:");
	if (!got.len)
	{
		log::warn("published, but the registry does not report a checksum yet; verify with 'c3l info'");
		return;
	}
	if (got != want) return log::fail("published, but the registry's checksum (%s) differs from the uploaded file (%s)", got, want)~;
	log::info("published %s %s (registry checksum matches sha256:%s)", self.name, self.version, want);
}

// --token-file > $C3L_TOKEN > $C3PKG_TOKEN, whitespace removed. Never an argument.
fn String? token(String file) @private
{
	String t = env::tget_var("C3L_TOKEN") ?? env::tget_var("C3PKG_TOKEN") ?? "";
	if (file.len)
	{
		String text = (String)file::load_temp(file) ?? log::fail("cannot read token file %s", file)~!;
		t = text.tsplit("\n")[0];
	}
	DString out = dstring::temp();
	foreach (c : t) if (!c.is_space()) out.append_char(c);
	if (!out.len()) return log::fail("no API token. Create one in the registry settings and pass it with --token-file FILE, $C3L_TOKEN or $C3PKG_TOKEN")~;
	return out.str_view();
}
