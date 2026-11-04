<*
 Git submodules in the library directory. A git library can be stored as a
 submodule at lib/<name>.c3l instead of an archive: c3l.lock describes it the
 same way, git keeps it. Read only when the project is in a git repository with a
 .gitmodules file, so projects without submodules never run git for this.
*>
module c3l::git;

import std::io, std::os, std::collections::list, c3l::log, c3l::sys;

struct Conf @private
{
	String section, path, url, branch;
}

struct Submodule
{
	String name;    // the library: lib/<name>.c3l
	String path;    // relative to the project directory
	String at;      // the same, from the current directory
	String commit;  // what the repository records (the gitlink)
	String url;     // from .gitmodules; empty if it has none
	String branch;  // from .gitmodules; usually empty
}

<*
 The submodules directly in `libdir` (relative to `dir`, the project
 directory) that are named like libraries: <name>.c3l.
*>
fn Submodule[] submodules(String dir, String libdir)
{
	if (!has_submodules(dir)) return {};
	String root = repo_root(dir);
	String prefix = git(dir, { "rev-parse", "--show-prefix" }).out.trim();  // the project directory, from the root
	String lib = clean_path(libdir);
	String want = clean_path(string::tformat("%s%s", prefix, lib));

	// .gitmodules: submodule.<section>.path|url|branch (the section may contain dots)
	List{Conf} config;
	config.tinit();
	String gitmodules = string::tformat("%s/.gitmodules", root);
	foreach (line : lines(dir, { "config", "-f", gitmodules, "--get-regexp", `^submodule\..*\.(path|url|branch)$` }))
	{
		sz? space = line.index_of_char(' ');
		if (catch space) continue;
		String key = line[:space];
		String value = line[space + 1..];
		sz dot = key.rindex_of_char('.') ?? 0;
		if (dot <= "submodule.".len) continue;
		String section = key["submodule.".len..dot - 1];
		Conf* c = null;
		foreach (&x : config) if (x.section == section) c = x;
		if (!c)
		{
			config.push({ .section = section });
			c = &config[config.len() - 1];
		}
		switch (key[dot + 1..])
		{
			case "path": c.path = clean_path(value);
			case "url": c.url = value;
			case "branch": c.branch = value;
		}
	}

	List{Submodule} out;
	out.tinit();
	foreach (line : lines(dir, { "ls-files", "-s", "--full-name", "--", lib }))
	{
		// "160000 <commit> 0\t<path from the root>"; 160000 is a gitlink
		if (!line.starts_with("160000 ")) continue;
		sz? tab = line.index_of_char('\t');
		if (catch tab) continue;
		String full = line[tab + 1..];
		String file = full[(full.rindex_of_char('/') ?? -1) + 1..];
		String parent = full[:full.len - file.len].strip_suffix("/");
		if (parent != want || !file.ends_with(".c3l")) continue;
		String path = string::tformat("%s/%s", lib, file);
		Submodule s = { .name = file.strip_suffix(".c3l"), .path = path, .at = dir == "." ? path : string::tformat("%s/%s", dir, path), .commit = line[7:40] };
		foreach (c : config)
		{
			if (c.path != full) continue;
			s.url = c.url;
			s.branch = c.branch;
		}
		out.push(s);
	}
	return out.array_view();
}

// Is `dir` in a git work tree with a .gitmodules file? Without running git.
fn bool has_submodules(String dir)
{
	String root = repo_root(dir);
	return root.len && file::exists(string::tformat("%s/.gitmodules", root));
}

// Is the submodule checked out (its directory has a .git file or directory)?
fn bool Submodule.checked_out(&self) => file::exists(string::tformat("%s/.git", self.at));

// The commit checked out in the submodule; empty if it is not checked out.
fn String Submodule.head(&self) => self.checked_out() ? git(self.at, { "rev-parse", "HEAD" }).out.trim() : "";

// Changes to tracked files, staged or not (untracked files, such as build output, do not count).
fn bool Submodule.edited(&self) => lines(self.at, { "status", "--porcelain", "--untracked-files=no" }).len > 0;

<*
 Check out the commit the repository records, cloning the submodule first if it
 is not there yet (git submodule update --init). Never with local changes.
*>
fn bool Submodule.restore(&self, String dir) => run(dir, { "submodule", "update", "--init", "--", self.path });

<*
 Move the submodule to `commit` and stage it in the repository. If the
 submodule does not have the commit yet, it is fetched from `url`, else from
 `from` (a checkout that has it).
*>
fn void? Submodule.move(&self, String dir, String commit, String url, String from)
{
	if (!is_commit(commit)) return log::fail("'%s' is not a commit id", commit)~;
	if (!self.has(commit))
	{
		bool got = url.len && run(self.at, { "fetch", "-q", "--end-of-options", url, commit });
		if (!got && from.len) got = run(self.at, { "fetch", "-q", "--end-of-options", (String)from.to_absolute_path(tmem) ?? from, commit });
		if (!got || !self.has(commit)) return log::fail("cannot fetch commit %s into %s%s", commit, self.path, because())~;
	}
	if (!run(self.at, { "checkout", "-q", commit })) return log::fail("cannot check out %s in %s%s", commit, self.path, because())~;
	if (!run(dir, { "add", "--", self.path })) return log::fail("cannot stage %s%s", self.path, because())~;
}

fn bool Submodule.has(&self, String commit) => run(self.at, { "cat-file", "-e", string::tformat("%s^{commit}", commit) });

// The tags at `commit` in the submodule.
fn String[] Submodule.tags_at(&self, String commit) => lines(self.at, { "tag", "--points-at", commit });

<*
 The top of the git work tree `dir` is in, without running git: the nearest
 directory upwards with a .git file or directory. Empty if there is none.
*>
fn String repo_root(String dir) @private
{
	Path? abs = dir.to_absolute_path(tmem);
	if (catch abs) return "";
	Path d = abs;
	while (true)
	{
		if (file::exists(string::tformat("%s/.git", (String)d))) return (String)d;
		Path? up = d.parent();
		if (catch up) return "";
		if ((String)up == (String)d) return "";
		d = up;
	}
}

// "./lib/" and "lib\" are "lib".
fn String clean_path(String p) @private
{
	String s = p.treplace("\\", "/");
	while (s.starts_with("./")) s = s[2..];
	while (s.ends_with("/") && s.len > 1) s = s[:s.len - 1];
	return s == "." ? "" : s;
}
