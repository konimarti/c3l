<*
 Installed libraries: their state on disk, and whether their source has something newer.
*>
module c3l::install;

import std::io, std::collections::list, std::compression::zip, c3l::lock, c3l::sys, c3l::semver, c3l::project;
import c3l::registry, c3l::vendor, c3l::git;

enum Status : char (String name)
{
	OK { "ok" },
	MODIFIED { "modified" },
	MISSING { "missing" },
	UNPACKED { "unpacked" },  // a directory where c3l keeps a .c3l file (c3c's default)
}

<*
 Compare the library file in `dir` with its lock entry. A git library is an
 archive of the locked commit (`git archive` stores the commit in the zip
 comment) with the locked contents. A path library is a link to its directory.
*>
fn Status status(Entry* e, String dir)
{
	String f = project::lib_file(dir, e.name);
	bool link = path::is_link((Path)f);
	if (e.kind == PATH)
	{
		if (!link) return file::exists(f) ? MODIFIED : MISSING;
		if (!file::is_dir(f)) return MISSING;
		return sys::points_to(f, e.origin) ? OK : MODIFIED;
	}
	if (file::is_dir(f)) return UNPACKED;
	if (!file::is_file(f)) return MISSING;
	if (e.kind == GIT)
	{
		ZipArchive? z = zip::open(tmem, f);
		if (catch z) return MODIFIED;
		defer (void)z.close();
		if (string::tformat("commit:%s", z.comment.trim()) != e.pin) return MODIFIED;
		if (!e.hash.starts_with("content:")) return OK;  // a lock of c3l 1.1 has no content hash
		return (sys::content_hash(f) ?? "") == e.hash ? OK : MODIFIED;
	}
	return (sys::sha256_file(f) ?? "") == e.hash ? OK : MODIFIED;
}

faultdef UNKNOWN;

struct Newer
{
	String next;   // what update moves to; empty when up to date
	String major;  // a newer major version, taken only when asked for (name@version)
}

<*
 What is newer than the locked version, UNKNOWN when the source cannot tell.
 Tags and registry versions are compared as semver; a moving source (HEAD, a
 branch, the vendor collection) is newer when its tip is not the locked one,
 shown as HEAD@<short id>.
*>
fn Newer? newer(Entry* e)
{
	switch (e.kind)
	{
		case REGISTRY:
			Info info = registry::info(e.origin, e.id) ?? UNKNOWN~!;
			return pick(e.version, info.list());
		case VENDOR:
			String digest = vendor::find(e.id).digest ?? UNKNOWN~!;
			if (!digest.len) return UNKNOWN~;
			return { .next = digest == e.pin ? "" : string::tformat("HEAD@%s", digest.strip_prefix("sha256:")[:12]) };
		case GIT:
			String tip;
			switch
			{
				case e.version == "HEAD": tip = git::head(e.origin)!;
				case e.version.starts_with("branch:"): tip = git::branch_commit(e.origin, e.version["branch:".len..])!;
				case e.version.starts_with("commit:"): return {};
				default:
					Ref[] tags = git::tags(e.origin)!;
					if (!tags.len) return UNKNOWN~;
					List{String} names;
					names.tinit();
					foreach (t : tags) names.push(t.name);
					return pick(e.version, names.array_view());
			}
			if (!tip.len) return UNKNOWN~;
			return { .next = string::tformat("commit:%s", tip) == e.pin ? "" : string::tformat("HEAD@%s", tip[:12]) };
		case PATH:
			return {};
	}
}

<*
 Of `versions`, the newest one above `current` with the same major, and the
 newest with a higher major. Prereleases only when `current` is one.
*>
fn Newer pick(String current, String[] versions)
{
	Newer n;
	bool pre = semver::prerelease(current);
	foreach (v : versions)
	{
		if (!semver::newer(v, current) || (!pre && semver::prerelease(v))) continue;
		String* best = semver::major(v) == semver::major(current) ? &n.next : &n.major;
		if (!best.len || semver::compare(v, *best) > 0) *best = v;
	}
	return n;
}
