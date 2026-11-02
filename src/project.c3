<*
 The project c3l works on, in the current directory. A directory with
 project.json(5) is a project: its dependencies and library directory are read
 through `c3c project view`, never guessed. A directory with only manifest.json
 is a library: its dependencies are the manifest's "dependencies", installed in ./lib.
*>
module c3l::project;

import std::io, std::os, std::collections::list, c3l::log, c3l::sys, c3l::manifest, c3l::lock, c3l::jsonedit;

struct Project
{
	String file;
	bool libmode;
	Lock lock;
	String[] dep_names;  // deps(), read once, again after the file changed
	bool deps_read;
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
	String[] paths = view_list("search paths")!;
	if (!paths.len && create)
	{
		self.edit("dependency-search-paths", "lib", true)!;
		log::info("added \"lib\" to dependency-search-paths in %s", self.file);
		paths = view_list("search paths")!;
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
		self.dep_names = view_list("dependencies")!;
	}
	self.deps_read = true;
	return self.dep_names;
}

// The project file changed on disk: read the dependencies again when asked.
fn void Project.changed(&self) => self.deps_read = false;

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

// One comma separated "c3l library <what>:" line of `c3c project view`.
fn String[]? view_list(String what) @private
{
	Output o = sys::run({ sys::c3c(), "project", "view" })!;
	String prefix = string::tformat("c3l library %s:", what);
	foreach (line : o.out.tsplit("\n"))
	{
		if (!line.starts_with(prefix)) continue;
		String value = line[prefix.len..].trim();
		if (value == "*none*") return {};
		List{String} out;
		out.tinit();
		foreach (v : value.tsplit(","))
		{
			if (v.trim().len) out.push(v.trim());
		}
		return out.array_view();
	}
	return {};
}
