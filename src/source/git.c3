<*
 Git sources, through the git command. A remote that cannot be reached
 answers with nothing; the caller says what was missing.
*>
module c3l::git;

import std::io, std::os, std::collections::list, c3l::log, c3l::sys, c3l::semver;

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
	foreach (r : ls_remote({ "--tags", url })!)
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

// The highest semver tag, empty if there is none.
fn String highest(Ref[] tags)
{
	String best;
	foreach (t : tags)
	{
		if (!semver::valid(t.name)) continue;
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

fn String? head(String url) => first(ls_remote({ url, "HEAD" })!);

fn String? branch_commit(String url, String branch)
{
	return first(ls_remote({ "--heads", url, string::tformat("refs/heads/%s", branch) })!);
}

<*
 Check out `commit` of `url` into the empty directory `dir`: a shallow fetch of
 just that commit, else a clone (of the tag or branch `ref`, if given).
*>
fn void? checkout(String url, String commit, String ref, String dir)
{
	if (run(dir, { "init", "-q" }) && run(dir, { "remote", "add", "origin", url })
		&& run(dir, { "fetch", "-q", "--depth", "1", "origin", commit }) && run(dir, { "checkout", "-q", "FETCH_HEAD" }))
	{
		return;
	}
	sys::remove(dir);
	bool cloned = ref.len
		? run(".", { "clone", "-q", "--depth", "1", "--branch", ref, url, dir })
		: run(".", { "clone", "-q", url, dir }) && run(dir, { "checkout", "-q", commit });
	if (!cloned) return log::fail("git clone of %s failed", url)~;
	String head = sys::run({ "git", "-C", dir, "rev-parse", "HEAD" })!.out.trim();
	if (head != commit) return log::fail("commit mismatch for %s: expected %s, got %s", url, commit, head)~;
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
	file::save(string::tformat("%s/attributes", info), "* -text -filter -ident -working-tree-encoding\n") ?? log::fail("cannot write %s", info)~!;
	env::set_var("TZ", "UTC");
	String abs = (String)out.to_absolute_path(tmem) ?? out;
	if (!run(dir, { "-c", "core.autocrlf=false", "-c", "core.eol=lf", "archive", "--format=zip", "-0", "-o", abs, "HEAD" }))
	{
		return log::fail("git archive failed")~;
	}
}

fn bool is_repo(String dir) => run(dir, { "rev-parse", "--is-inside-work-tree" });

// The non-empty output lines of `git -C dir args...`; none if it fails.
fn String[] lines(String dir, String[] args)
{
	Output o = git(dir, args);
	return o.code ? {} : o.out.tsplit("\n", skip_empty: true);
}

// git -C dir args..., true when it exits with 0
fn bool run(String dir, String[] args) @private => git(dir, args).code == 0;

fn Output git(String dir, String[] args) @private
{
	List{String} argv;
	argv.tinit();
	argv.push_all({ "git", "-C", dir });
	argv.push_all(args);
	return sys::run(argv.array_view()) ?? (Output){ .code = 1 };
}

fn bool is_commit(String s)
{
	if (s.len != 40) return false;
	foreach (c : s) if (!c.is_xdigit()) return false;
	return true;
}

fn Ref[]? ls_remote(String[] args) @private
{
	List{String} argv;
	argv.tinit();
	argv.push_all({ "git", "ls-remote" });
	argv.push_all(args);
	Output o = sys::run(argv.array_view())!;
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
