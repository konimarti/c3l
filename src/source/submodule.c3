<*
 Git submodules in the library directory. A git library can be stored as a
 submodule at <libdir>/<name>.c3l instead of an archive: c3l.lock describes it the
 same way, git keeps it. git is only asked when the repository's .gitmodules
 names a .c3l path, so other projects run nothing extra.
*>
module c3l::git;

import std::io, std::os, std::collections::list, c3l::log, c3l::sys;

struct Conf @private
{
	String section, path, url, branch;
}

struct Submodule
{
	String name;    // the library
	String path;    // <libdir>/<name>.c3l, as the project names it (for messages)
	String root;    // the top of the repository that records it
	String full;    // its path from `root`, as git names it
	String at;      // root/full
	String commit;  // what the repository records (the gitlink)
	String url;     // from .gitmodules
	String branch;  // from .gitmodules; usually empty
}

<*
 The submodules directly in `libdir` that are named like libraries
 (<name>.c3l) and listed in .gitmodules. A gitlink without a .gitmodules entry
 is not a submodule git can restore; set_aside protects it as a nested repository.
*>
fn Submodule[] submodules(String libdir)
{
	if (!file::is_dir(libdir)) return {};
	String root = repo_root(libdir);
	if (!root.len) return {};
	String gitmodules = string::tformat("%s/.gitmodules", root);
	if (!((String)file::load_temp(gitmodules) ?? "").contains(".c3l")) return {};
	String want = git(libdir, { "rev-parse", "--show-prefix" }).out.trim().strip_suffix("/");  // libdir, from the root

	// "submodule.<section>.<key>\n<value>" per entry (-z: names and values may contain spaces)
	List{Conf} config;
	config.tinit();
	foreach (entry : zlines(root, { "config", "-z", "-f", gitmodules, "--get-regexp", `^submodule\..*\.(path|url|branch)$` }))
	{
		sz? nl = entry.index_of_char('\n');
		if (catch nl) continue;
		String key = entry[:nl];
		String value = entry[nl + 1..];
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
			case "path": c.path = value.strip_suffix("/");
			case "url": c.url = value;
			case "branch": c.branch = value;
		}
	}

	List{Submodule} out;
	out.tinit();
	foreach (entry : zlines(root, { "ls-files", "-s", "-z", "--", want.len ? want : "." }))
	{
		// "160000 <commit> <stage>\t<path from the root>": 160000 is a gitlink; stage 0 = not in a merge conflict
		String[] f = entry.tsplit("\t", 2);
		if (f.len != 2) continue;
		String[] meta = f[0].tsplit(" ");
		if (meta.len != 3 || meta[0] != "160000" || meta[2] != "0") continue;
		String full = f[1];
		String file = full[(full.rindex_of_char('/') ?? -1) + 1..];
		if (full[:full.len - file.len].strip_suffix("/") != want || !file.ends_with(".c3l")) continue;
		foreach (c : config)
		{
			if (c.path != full) continue;
			out.push({
				.name = file.strip_suffix(".c3l"), .path = string::tformat("%s/%s", libdir.strip_suffix("/"), file),
				.root = root, .full = full, .at = string::tformat("%s/%s", root, full),
				.commit = meta[1], .url = c.url, .branch = c.branch,
			});
		}
	}
	return out.array_view();
}

// Is the submodule checked out (its directory has a .git file or directory)?
fn bool Submodule.checked_out(&self) => file::exists(string::tformat("%s/.git", self.at));

// The commit checked out in the submodule; empty if it is not checked out.
fn String Submodule.head(&self) => self.checked_out() ? git(self.at, { "rev-parse", "HEAD" }).out.trim() : "";

// Changes to tracked files, staged or not (untracked files, such as build output, do not count).
fn bool Submodule.edited(&self) => lines(self.at, { "status", "--porcelain", "--untracked-files=no" }).len > 0;

// Commits checked out in the submodule that no branch or tag holds: checking out another commit would drop them.
fn bool Submodule.unsaved(&self) => lines(self.at, { "rev-list", "-n1", "HEAD", "--not", "--branches", "--tags", "--remotes" }).len > 0;

// Check out the commit the repository records, cloning the submodule first if needed.
fn void? Submodule.reset(&self)
{
	if (!run(self.root, { "submodule", "update", "--init", "--checkout", "--", self.full }))
	{
		return log::fail("cannot check out the submodule %s%s", self.path, because())~;
	}
}

<*
 Move the submodule to `commit` and stage it. If the submodule does not have the
 commit yet, it is fetched from `url`, else from `from` (a checkout that has it).
*>
fn void? Submodule.move(&self, String commit, String url, String from)
{
	if (!is_commit(commit)) return log::fail("'%s' is not a commit id", commit)~;
	if (!self.has(commit))
	{
		bool got = url.len && run(self.at, { "fetch", "-q", "--end-of-options", url, commit });
		if (!got && from.len) got = run(self.at, { "fetch", "-q", "--end-of-options", from, commit });
		if (!got || !self.has(commit)) return log::fail("cannot fetch commit %s into %s%s", commit, self.path, because())~;
	}
	if (!run(self.at, { "checkout", "-q", commit })) return log::fail("cannot check out %s in %s%s", commit, self.path, because())~;
	if (!run(self.root, { "add", "--", self.full })) return log::fail("cannot stage %s%s", self.path, because())~;
	self.commit = commit;
}

// Does the submodule have `commit`?
fn bool Submodule.has(&self, String commit) => run(self.at, { "cat-file", "-e", string::tformat("%s^{commit}", commit) });

// The tags at `commit` in the submodule.
fn String[] Submodule.tags_at(&self, String commit) => lines(self.at, { "tag", "--points-at", commit });

<*
 Can the git repository in `dir` (a clone, such as c3l 0.x made, or a nested
 repository git does not know as a submodule) be replaced without losing work:
 no changes, no untracked files, no commit that no branch or tag holds?
*>
fn bool disposable(String dir)
{
	Output st = git(dir, { "status", "--porcelain" });
	if (st.code || st.out.trim().len) return false;
	Output unsaved = git(dir, { "rev-list", "-n1", "HEAD", "--not", "--branches", "--tags", "--remotes" });
	return !unsaved.code && !unsaved.out.trim().len;
}

// The first 12 characters of a commit id, for messages.
fn String abbrev(String commit) => commit[:commit.len < 12 ? commit.len : 12];

// The NUL separated records of `git -C dir args...` (with -z); none if it fails.
fn String[] zlines(String dir, String[] args) @private
{
	Output o = git(dir, args);
	return o.code ? {} : o.out.tsplit("\0", skip_empty: true);
}

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
