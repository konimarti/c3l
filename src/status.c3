<*
 Installed libraries: their state on disk, and whether their source has something newer.
*>
module c3l::install;

import std::io, std::compression::zip, c3l::lock, c3l::sys, c3l::semver;
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
 archive of the locked commit: `git archive` stores the commit in the zip comment.
*>
fn Status status(Entry* e, String dir)
{
	String f = string::tformat("%s/%s.c3l", dir, e.name);
	bool link = path::is_link((Path)f);
	if (e.kind == PATH)
	{
		if (link && file::is_dir(f)) return OK;
		return link || file::exists(f) ? MODIFIED : MISSING;
	}
	if (file::is_dir(f)) return UNPACKED;
	if (!file::is_file(f)) return MISSING;
	if (e.kind == GIT)
	{
		ZipArchive? z = zip::open(tmem, f);
		if (catch z) return MODIFIED;
		defer (void)z.close();
		return string::tformat("commit:%s", z.comment.trim()) == e.pin ? OK : MODIFIED;
	}
	return (sys::sha256_file(f) ?? "") == e.hash ? OK : MODIFIED;
}

faultdef UNKNOWN;

<*
 The newer version of a library, "" when it is up to date, UNKNOWN when the
 source cannot tell. A tag or registry version is compared as semver; a moving
 source (HEAD, a branch, the vendor collection) is newer when its tip is not the
 locked one, shown as HEAD@<short id>.
*>
fn String? newer(Entry* e)
{
	String latest;
	switch (e.kind)
	{
		case REGISTRY:
			latest = registry::info(e.origin, e.id).latest ?? UNKNOWN~!;
		case VENDOR:
			String digest = vendor::find(e.id).digest ?? UNKNOWN~!;
			if (!digest.len) return UNKNOWN~;
			return digest == e.pin ? "" : string::tformat("HEAD@%s", digest.strip_prefix("sha256:")[:12]);
		case GIT:
			String tip;
			switch
			{
				case e.version == "HEAD": tip = git::head(e.origin)!;
				case e.version.starts_with("branch:"): tip = git::branch_commit(e.origin, e.version["branch:".len..])!;
				case e.version.starts_with("commit:"): return "";
				default: latest = git::highest_tag(e.origin)!;
			}
			if (!latest.len && !tip.len) return UNKNOWN~;
			if (tip.len) return string::tformat("commit:%s", tip) == e.pin ? "" : string::tformat("HEAD@%s", tip[:12]);
		case PATH:
			return "";
	}
	return semver::newer(latest, e.version) ? latest : "";
}
