<*
 Publishing a library: everything that can be checked before the upload, the
 deterministic package, and the upload to a registry with an API (c3pkg).
*>
module c3l::publish;

import std::io, std::os, std::sort, std::collections::list, std::collections::object, std::encoding::json;
import c3l::log, c3l::sys, c3l::lock, c3l::semver, c3l::manifest, c3l::jsonedit, c3l::http, c3l::registry, c3l::git, c3l::install;

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
	int errors;
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
	Manifest? m = manifest::load_file(string::tformat("%s/manifest.json", dir));
	if (catch e = m)
	{
		if (e == manifest::NO_MANIFEST)
		{
			p.error("no manifest.json in %s; publish a library directory (create one with 'c3c init-lib <name>')", dir);
		}
		else
		{
			p.error("manifest.json in %s cannot be read as JSON (comments and trailing commas are fine)", dir);
		}
		return p;
	}
	p.name = m.provides;
	if (!p.name.len)
	{
		p.error("manifest.json has no \"provides\" (the package name)");
		return p;
	}
	if (!lock::valid_name(p.name)) p.error("invalid package name '%s' (letters, digits, '.', '_', '-')", p.name);
	if (!p.resolve_version(s.version, m.version))
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
	bool sources;
	foreach (f : files) if (f.ends_with(".c3") || f.ends_with(".c3i")) sources = true;
	if (!sources) log::warn("%s contains no .c3/.c3i sources", dir);
	if (!file::exists(string::tformat("%s/README.md", dir))) log::warn("no README.md in %s (the registry shows it as the package page)", dir);

	p.check_dependencies(m);
	p.check_clean(s.allow_dirty);
	if (!s.no_build) p.check_build();
	if (!s.offline) p.check_registry(s);
	if (!p.errors) log::info("%s %s (from %s, C3 %s) passes all checks", p.name, p.version, p.version_from, p.c3_version);
	return p;
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
		log::warn("'%s' is in the manifest's dependencies but nothing says where to get it; run 'c3l add' for it in this library so consumers can install it automatically", r.name);
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
	bool dirty = git::lines(self.dir, { "status", "--porcelain", "--untracked-files=no", "--", "." }).len > 0
		|| packed(git::lines(self.dir, { "ls-files", "-o", "--exclude-standard" })).len > 0;
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

// Compile the staged package as a library, with the library's own dependencies.
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
		if (try libs = path::ls(tmem, (Path)lib))
		{
			foreach (f : libs) if (((String)f).ends_with(".c3l")) argv.push_all({ "--lib", ((String)f).strip_suffix(".c3l") });
		}
	}
	argv.push_all({ "compile-only", "--lib", self.name, "--no-obj" });
	Output? o = sys::run(argv.array_view(), MERGE);
	if (try o && o.code == 0)
	{
		log::info("library compiles with c3c %s", sys::c3_version());
		return;
	}
	self.error("the library does not compile:");
	String[] lines = (o.out ?? "").trim().tsplit("\n");
	foreach (line : lines[lines.len > 15 ? lines.len - 15 : 0..]) io::eprintn(line);
}

// Not published yet, not older than what is; a new package needs a description.
fn void Package.check_registry(&self, Settings s)
{
	String base = registry::base(s.registry);
	bool guessed;
	if ((registry::detect(base, s.registry_type, &guessed) ?? Api.STATIC) != C3PKG) return;
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
		char[] data = file::load_temp(string::tformat("%s/%s", self.dir, f)) ?? log::fail("staging %s/%s failed", self.dir, f)~!;
		file::save(dst, data) ?? log::fail("staging %s/%s failed", self.dir, f)~!;
	}
	String mfile = string::tformat("%s/manifest.json", to);
	String text = (String)file::load_temp(mfile) ?? log::fail("manifest.json is not part of the package (is it ignored by git?)")~!;
	text = jsonedit::set_string(text, "version", self.version);
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
 The files that belong in the package, sorted: tracked and untracked-not-ignored
 in a git repository, else everything; never installed libraries or build output.
 c3l.lock is part of it.
*>
fn String[] Package.files(&self)
{
	String[] all;
	if (git::is_repo(self.dir))
	{
		all = git::lines(self.dir, { "-c", "core.quotepath=off", "ls-files", "-co", "--exclude-standard" });
	}
	else
	{
		List{String} found;
		found.tinit();
		if (try list = path::ls(tmem, (Path)self.dir, no_dirs: true, recursive: true))
		{
			foreach (f : list) found.push((String)f);
		}
		all = found.array_view();
	}
	List{String} out;
	out.tinit();
	foreach (f : packed(all))
	{
		if (file::is_file(string::tformat("%s/%s", self.dir, f)) && !out.contains(f)) out.push(f);
	}
	sort::quicksort(&out, fn int(String a, String b) => a.compare_to(b));
	return out.array_view();
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
