<*
 Git sources, through the git command. A remote that cannot be reached
 answers with nothing; the caller says what was missing.
*>
module c3l::git;

import std::io, std::os, std::collections::list, c3l::log, c3l::sys, c3l::semver, c3l::lock;

struct Ref
{
	String name;
	String commit;
}

// Tags with their commits (annotated tags peeled).
fn Ref[]? tags(String url)
{
	List{Ref} out;
	out.tinit();
	foreach (r : ls_remote({ "--tags", "--end-of-options", url })!)
	{
		String name = r.name.strip_prefix("refs/tags/");
		bool peeled = name.ends_with("^{}");
		name = name.strip_suffix("^{}");
		Ref*? have = find(&out, name);
		if (try have)
		{
			if (peeled) have.commit = r.commit;
			continue;
		}
		out.push({ name, r.commit });
	}
	return out.array_view();
}

// The highest semver tag, empty if there is none; prereleases only if asked for.
fn String highest(Ref[] tags, bool prereleases = false)
{
	String best;
	foreach (t : tags)
	{
		if (!semver::valid(t.name) || (!prereleases && semver::prerelease(t.name))) continue;
		if (!best.len || semver::compare(t.name, best) > 0) best = t.name;
	}
	return best;
}

// The commit of tag `name`, empty if there is no such tag.
fn String commit_of(Ref[] tags, String name)
{
	foreach (t : tags) if (t.name == name) return t.commit;
	return "";
}

fn String? head(String url) => first(ls_remote({ "--end-of-options", url, "HEAD" })!);

fn String? branch_commit(String url, String branch)
{
	return first(ls_remote({ "--heads", "--end-of-options", url, string::tformat("refs/heads/%s", branch) })!);
}

<*
 Check out `commit` (a full commit id) of `url` in `dir`/src and return that path:
 a shallow fetch of just that commit, else a clone (of the tag or branch `ref`,
 if given). `dir` is a private temporary directory. URLs and refs come from
 manifests, so they are never passed where git would take them as options.
*>
fn String? checkout(String url, String commit, String ref, String dir)
{
	if (!is_commit(commit)) return log::fail("'%s' is not a commit id (%s)", commit, url)~;
	String src = string::tformat("%s/src", dir);
	if (run(dir, { "init", "-q", "src" }) && run(src, { "fetch", "-q", "--depth", "1", "--end-of-options", url, commit })
		&& run(src, { "checkout", "-q", "FETCH_HEAD" }))
	{
		return src;
	}
	sys::remove(src);
	bool cloned = ref.len
		? run(dir, { "clone", "-q", "--depth", "1", "--branch", ref, "--end-of-options", url, "src" })
		: run(dir, { "clone", "-q", "--end-of-options", url, "src" });
	if (!cloned) return log::fail("git clone of %s failed%s", url, because())~;
	if (!run(src, { "checkout", "-q", commit }))
	{
		return log::fail("commit %s is not in %s (rewritten or deleted upstream?)", commit, url)~;
	}
	String head = git(src, { "rev-parse", "HEAD" }).out.trim();
	if (head != commit) return log::fail("commit mismatch for %s: expected %s, got %s", url, commit, head)~;
	return src;
}

<*
 Archive the checked out commit in `dir` as a zip, the same way everywhere:
 stored (-0), UTC timestamps, no line-ending or filter conversion. git puts the
 commit id in the zip comment.
*>
fn void? archive(String dir, String out)
{
	String info = string::tformat("%s/.git/info", dir);
	(void)path::mkdir(info, true);
	// export-subst would fill in placeholders that depend on how the commit was fetched
	String attributes = "* -text -filter -ident -working-tree-encoding -export-subst\n";
	file::save(string::tformat("%s/attributes", info), attributes) ?? log::fail("cannot write %s", info)~!;
	env::set_var("TZ", "UTC");
	String abs = (String)out.to_absolute_path(tmem) ?? out;
	if (!run(dir, { "-c", "core.autocrlf=false", "-c", "core.eol=lf", "archive", "--format=zip", "-0", "-o", abs, "HEAD" }))
	{
		return log::fail("git archive failed%s", because())~;
	}
}

<*
 A git URL for comparing: the host and path of the repository, whatever the
 protocol (https://host/p, ssh://git@host/p and git@host:p are the same), the
 host lowercased (the path too on github.com and codeberg.org, which ignore
 case), no trailing "/" or ".git". Local paths and file:// URLs stay as they are.
*>
fn String canonical(String url)
{
	String u = url.strip_suffix("/").strip_suffix(".git");
	String rest;
	if (u.starts_with("git@"))
	{
		rest = u["git@".len..];
		sz? colon = rest.index_of_char(':');
		if (catch colon) return u;
		rest = string::tformat("%s/%s", rest[:colon], rest[colon + 1..]);
	}
	else
	{
		sz? scheme = u.index_of("://");
		if (catch scheme) return u;
		if (u[:scheme].to_lower_tcopy() == "file") return u;
		rest = u[scheme + 3..];
	}
	sz end = rest.index_of_char('/') ?? rest.len;
	String host = rest[:end];
	if (try at = host.rindex_of_char('@')) host = host[at + 1..];  // ssh://git@host
	host = host[:host.index_of_char(':') ?? host.len].to_lower_tcopy();  // a port
	String path = rest[end..];
	if (host == "github.com" || host == "codeberg.org") path = path.to_lower_tcopy();
	return host.tconcat(path);
}

// Is `dir` in a git work tree? git only runs where a .git exists, so c3l works without git outside repositories.
fn bool is_repo(String dir) => repo_root(dir).len && run(dir, { "rev-parse", "--is-inside-work-tree" });

// The non-empty output lines of `git -C dir args...`; none if it fails.
fn String[] lines(String dir, String[] args)
{
	Output o = git(dir, args);
	return o.code ? {} : o.out.tsplit("\n", skip_empty: true);
}

String failure @private;  // what git said when the last command failed

const String[] AUTH_ERRORS @private = {
	"Permission denied", "Repository not found", "could not read Username", "Authentication failed",
};

// "; git: <what it said>" when the last git command failed, else "": for the end of a message.
fn String because()
{
	if (!failure.len) return "";
	foreach (s : AUTH_ERRORS)
	{
		if (failure.contains(s)) return string::tformat("; git: %s (a private repository needs git access: an ssh key, or a credential helper such as 'gh auth setup-git')", failure);
	}
	return string::tformat("; git: %s", failure);
}

// git -C dir args..., true when it exits with 0
fn bool run(String dir, String[] args) @private => git(dir, args).code == 0;

fn Output git(String dir, String[] args) @private => exec({ "-C", dir }, args) ?? (Output){ .code = 1 };

<*
 git with `args`: never asks on the terminal or in a window (c3l runs git
 several times per library), never runs a command named by a URL (ext::),
 takes long paths on Windows.
*>
fn Output? exec(String[] pre, String[] args) @private
{
	List{String} argv;
	argv.tinit();
	argv.push_all({ "git", "-c", "protocol.ext.allow=never", "-c", "core.longpaths=true" });
	argv.push_all(pre);
	argv.push_all(args);
	env::set_var("GIT_TERMINAL_PROMPT", "0");
	env::set_var("GCM_INTERACTIVE", "never");
	Output o = sys::run(argv.array_view())!;
	failure = o.code ? o.reason() : "";
	return o;
}

fn bool is_commit(String s) => lock::is_commit(s);

<*
 A ref c3l passes to git (tag, branch, HEAD or commit, as asked or locked): no
 spaces, quotes or control characters, which could change how the command line
 is split on Windows.
*>
fn bool valid_ref(String s)
{
	foreach (c : s) if (c <= ' ' || c == '"' || c == 0x7f) return false;
	return true;
}

fn Ref[]? ls_remote(String[] args) @private
{
	Output o = exec({ "ls-remote" }, args)!;
	List{Ref} out;
	out.tinit();
	if (o.code) return {};
	foreach (line : o.out.tsplit("\n"))
	{
		String[] f = line.tsplit("\t");
		if (f.len == 2) out.push({ f[1], f[0] });
	}
	return out.array_view();
}

fn String first(Ref[] refs) @private => refs.len ? refs[0].commit : "";

fn Ref*? find(List{Ref}* refs, String name) @private
{
	foreach (&r : refs) if (r.name == name) return r;
	return NOT_FOUND~;
}
