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
	// a library stored as a git submodule
	NOT_CHECKED_OUT { "not-checked-out" },  // c3l sync checks it out
	MOVED { "moved" },                      // checked out at another commit than the repository records
	EDITED { "edited" },                    // local changes
	DRIFT { "lock-differs" },               // the repository records another commit than c3l.lock
	OTHER_SOURCE { "other-source" },        // c3l.lock gets the library from elsewhere
}

<*
 Compare the library file in `dir` with its lock entry. A git library is an
 archive of the locked commit (`git archive` stores the commit in the zip
 comment) with the locked contents. A path library is a link to its directory.
*>
fn Status status(Entry* e, String dir, Submodule* sub = null)
{
	if (sub) return submodule_status(e, sub);
	String f = project::lib_file(dir, e.name);
	bool link = path::is_link((Path)f);
	if (e.kind == PATH)
	{
		if (!link) return file::exists(f) ? MODIFIED : MISSING;
		if (!sys::points_to(f, e.origin)) return MODIFIED;
		return file::is_dir(f) ? OK : MISSING;
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

<*
 A library stored as a git submodule: it must come from the same repository as
 c3l.lock says, the repository must record the locked commit, and that commit
 must be checked out without local changes.
*>
fn Status submodule_status(Entry* e, Submodule* s)
{
	if (e.kind != GIT || !s.url.len || git::canonical(s.url) != git::canonical(e.origin)) return OTHER_SOURCE;
	if (string::tformat("commit:%s", s.commit) != e.pin) return DRIFT;
	if (!s.checked_out()) return NOT_CHECKED_OUT;
	if (s.head() != s.commit) return MOVED;
	if (s.edited()) return EDITED;
	return OK;
}

// What a submodule status means and what to do about it, for messages.
fn String explain(Status st, Entry* e, Submodule* s)
{
	switch (st)
	{
		case NOT_CHECKED_OUT:
			return string::tformat("the submodule %s is not checked out ('c3l sync' checks it out)", s.path);
		case MOVED:
			return string::tformat("the submodule %s is checked out at %s, the repository records %s ('c3l sync' or 'git submodule update' goes back)", s.path, abbrev(s.head()), abbrev(s.commit));
		case EDITED:
			return string::tformat("the submodule %s has local changes (c3l never discards them; commit or discard them with git)", s.path);
		case DRIFT:
			String locked = e.pin.strip_prefix("commit:");
			String back = e.version.starts_with("commit:") ? locked : e.version;
			return string::tformat("the submodule %s is at %s, but c3l.lock has %s: 'c3l update %s@%s' locks the submodule's commit, 'c3l update %s@%s' moves the submodule to the locked one",
				s.path, abbrev(s.commit), abbrev(locked), e.name, s.commit, e.name, back);
		case OTHER_SOURCE:
			if (!s.url.len) return string::tformat("%s is a git submodule without a URL in .gitmodules", s.path);
			return string::tformat("%s is a git submodule of %s, but c3l.lock gets %s from %s; remove one of them", s.path, s.url, e.name, e.source());
		default:
			return st.name;
	}
}

fn String abbrev(String commit) @private => commit[:commit.len < 12 ? commit.len : 12];

faultdef UNKNOWN;

struct Newer
{
	String next;   // what update moves to; empty when up to date
	String breaking;  // a newer version that is not compatible (semver::compat), taken only when asked for
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
 Of `versions`, the newest one above `current` that is compatible with it
 (semver::compat), and the newest that is not. Prereleases only when `current` is one.
*>
fn Newer pick(String current, String[] versions)
{
	Newer n;
	bool pre = semver::prerelease(current);
	foreach (v : versions)
	{
		if (!semver::newer(v, current) || (!pre && semver::prerelease(v))) continue;
		String* best = semver::compat(v) == semver::compat(current) ? &n.next : &n.breaking;
		if (!best.len || semver::compare(v, *best) > 0) *best = v;
	}
	return n;
}
