<*
 The project c3l works on, in the current directory. A directory with
 project.json(5) is a project: its dependencies and library directory are read
 through `c3c project view`, never guessed. A directory with only manifest.json
 is a library: its dependencies are the manifest's "dependencies", installed in ./lib.
*>
module c3l::project;

import std::io, std::os, std::collections::list, c3l::log, c3l::sys, c3l::manifest, c3l::lock, c3l::jsonedit, c3l::git, c3l::registry;

struct Project
{
	String file;
	bool libmode;
	Lock lock;
	String[] dep_names;  // deps(), read once, again after the file changed
	bool deps_read;
	String[] search_paths;  // dependency-search-paths, read once, again after the file changed
	bool paths_read;
	Submodule[] subs;    // submodules(), read once
	bool subs_read;
}

// The project in the current directory and its lockfile ($C3L_LOCK, default c3l.lock).
fn Project? find()
{
	Lock lock = lock::load(env::tget_var("C3L_LOCK") ?? "c3l.lock")!;
	foreach (f : (String[]){ "project.json", "project.json5" })
	{
		if (file::exists(f)) return { .file = f, .lock = lock };
	}
	if (file::exists("manifest.json")) return { .file = "manifest.json", .libmode = true, .lock = lock };
	String cwd = (String)(path::tcwd() ?? (Path)".");
	return log::fail("no project.json found in %s. Run c3l from the project root (create one with 'c3c init' or 'c3l init <name>').", cwd)~;
}

<*
 Where libraries are installed: the first dependency-search-paths entry ("lib"
 is added when there is none and `create` is set); ./lib for a library.
*>
fn String? Project.lib_dir(&self, bool create = false)
{
	if (self.libmode)
	{
		if (create) (void)path::mkdir("lib");
		return "lib";
	}
	String[] paths = self.paths()!;
	if (!paths.len && create)
	{
		self.edit("dependency-search-paths", "lib", true)!;
		log::info("added \"lib\" to dependency-search-paths in %s", self.file);
		paths = self.paths()!;
	}
	if (!paths.len) return log::fail("no entry in dependency-search-paths in %s (c3l add creates it)", self.file)~;
	if (create) (void)path::mkdir(paths[0], true);
	return paths[0];
}

// The names in the project's (or library manifest's) "dependencies".
fn String[]? Project.deps(&self)
{
	if (self.deps_read) return self.dep_names;
	if (self.libmode)
	{
		self.dep_names = (manifest::load_file(self.file) ?? log::fail("cannot read %s", self.file)~!).dependencies;
	}
	else
	{
		self.dep_names = view_list("dependencies", targets: true)!;
	}
	// c3c takes "ns/name@1.0" entries too; c3l works with library names
	foreach (&d : self.dep_names) *d = manifest::bare_name(*d);
	self.deps_read = true;
	return self.dep_names;
}

// The libraries stored as git submodules in the library directory; see git::submodules.
fn Submodule[] Project.submodules(&self)
{
	if (self.subs_read) return self.subs;
	self.subs_read = true;
	String[] paths = self.libmode ? { "lib" } : self.paths() ?? {};
	if (paths.len) self.subs = git::submodules(paths[0]);
	return self.subs;
}

// The git submodule that stores library `name` (at lib/<name>.c3l), if it is one.
fn Submodule*? Project.submodule(&self, String name)
{
	foreach (&s : self.submodules()) if (s.name == name) return s;
	return NOT_FOUND~;
}

// The project file changed on disk: read it again when asked.
fn void Project.changed(&self)
{
	self.deps_read = false;
	self.paths_read = false;
}

// The dependency-search-paths entries.
fn String[]? Project.paths(&self)
{
	if (!self.paths_read) self.search_paths = view_list("search paths")!;
	self.paths_read = true;
	return self.search_paths;
}

fn bool? Project.has_dep(&self, String name)
{
	foreach (d : self.deps()!) if (d == name) return true;
	return false;
}

faultdef NOT_UPDATED;

<*
 List `name` in the project's "dependencies" (`add`) or take it out.
 NOT_UPDATED when c3c does not read back what was written.
*>
fn void? Project.set_dep(&self, String name, bool add)
{
	self.edit("dependencies", name, add)!;
	if (self.has_dep(name)! != add) return NOT_UPDATED~;
}

<*
 What the project lists for library `e`: a registry library as its full path,
 `[<registry url>:]<namespace>/<name>@<version>:<sha256>` (the registry url
 is left out for the c3lang registry, the one a plain `c3c fetch` asks), a
 git or local library, and anything in a library's manifest.json, as its name.
*>
fn String entry_text(Entry e, bool libmode)
{
	String sum = e.pin.strip_prefix("sha256:");
	if (libmode || e.kind != REGISTRY || !e.id.len || !e.version.len || sum.len != 64) return e.name;
	String origin = registry::base(e.origin);
	String prefix = origin == registry::C3LANG_URL || !origin.len ? "" : string::tformat("%s:", origin);
	return string::tformat("%s%s@%s:%s", prefix, e.id, e.version, sum);
}

// The entries of "dependencies" as written (a library's manifest.json has them too).
fn String[] Project.entries(&self)
{
	String text = (String)file::load_temp(self.file) ?? "";
	return jsonedit::array_items(text, "dependencies");
}

// Does the project list library `e` differently from `entry_text`?
fn bool Project.entry_stale(&self, Entry e)
{
	if (self.libmode) return !(self.has_dep(e.name) ?? false);
	String want = entry_text(e, false);
	foreach (item : self.entries())
	{
		if (manifest::bare_name(item) == e.name) return item != want;
	}
	return true;
}

<*
 List library `e` in the project's "dependencies" with `entry_text`, replacing
 its plain name or an older path. A library's manifest.json only gets the name.
 NOT_UPDATED when c3c does not read back what was written.
*>
fn void? Project.register(&self, Entry e)
{
	if (self.libmode)
	{
		if (self.has_dep(e.name)!) return;
		return self.set_dep(e.name, true);
	}
	String text = (String)file::load_temp(self.file) ?? log::fail("cannot read %s", self.file)~!;
	String edited = jsonedit::put_array(text, "dependencies", e.name, entry_text(e, false), true);
	if (edited != text)
	{
		sys::write_atomic(self.file, edited)!;
		self.changed();
	}
	if (!self.has_dep(e.name)!) return NOT_UPDATED~;
}

fn void? Project.edit(&self, String key, String name, bool add)
{
	String text = (String)file::load_temp(self.file) ?? log::fail("cannot read %s", self.file)~!;
	String edited = jsonedit::edit_array(text, key, name, add);
	if (edited == text) return;
	sys::write_atomic(self.file, edited)!;
	self.changed();
}

// The file of library `name` in the library directory `dir`.
fn String lib_file(String dir, String name) => string::tformat("%s/%s.c3l", dir, name);

<*
 The comma separated values of `c3c project view` for "c3l library <what>":
 the project's line, then (with `targets`) each target's "Additional ..." line.
*>
fn String[]? view_list(String what, bool targets = false) @private
{
	Output o = sys::run({ sys::c3c(), "project", "view" })!;
	String prefix = string::tformat("c3l library %s:", what);
	String extra = string::tformat("Additional %s", prefix);
	List{String} out;
	out.tinit();
	foreach (raw : o.out.tsplit("\n"))
	{
		String line = raw.trim();
		if (targets && line.starts_with(extra)) line = line["Additional ".len..];
		if (!line.starts_with(prefix)) continue;
		String value = line[prefix.len..].trim();
		if (value == "*none*") continue;
		foreach (v : value.tsplit(","))
		{
			if (v.trim().len && !out.contains(v.trim())) out.push(v.trim());
		}
	}
	return out.array_view();
}
