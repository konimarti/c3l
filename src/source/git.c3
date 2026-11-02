<*
 Git sources, through the git command. A remote that cannot be reached
 answers with nothing; the caller says what was missing.
*>
module c3l::git;

import std::collections::list, c3l::sys, c3l::semver;

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
		Ref*? have = find(out, name);
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
fn String? highest_tag(String url)
{
	String best;
	foreach (t : tags(url)!)
	{
		if (!semver::valid(t.name)) continue;
		if (!best.len || semver::compare(t.name, best) > 0) best = t.name;
	}
	return best;
}

// The commit of a tag, empty if there is no such tag.
fn String? tag_commit(String url, String tag)
{
	foreach (t : tags(url)!) if (t.name == tag) return t.commit;
	return "";
}

fn String? head(String url) => first(ls_remote({ url, "HEAD" })!);

fn String? branch_commit(String url, String branch)
{
	return first(ls_remote({ "--heads", url, string::tformat("refs/heads/%s", branch) })!);
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

fn Ref*? find(List{Ref} refs, String name) @private
{
	foreach (&r : refs) if (r.name == name) return r;
	return NOT_FOUND~;
}
