<*
 Commands that change what is installed: add, remove, prune, update, sync, migrate.
*>
module c3l;

import std::io, std::os, std::collections::list, std::collections::object, std::encoding::json, serp;
import c3l::log, c3l::sys, c3l::lock, c3l::project, c3l::manifest, c3l::install, c3l::registry, c3l::git;

fn void? add_run(Ctx* ctx)
{
	Project p = project::find()!;
	String arg = ctx.arg(0);
	if (arg.starts_with("vendor:") || arg == "vendor")
	{
		String name = arg["vendor".len..].strip_prefix(":");
		return log::fail("vendor: libraries are gone; c3c's vendor collection is the c3lang registry now: c3l add c3lang/%s", name.len ? name : "<name>")~;
	}
	Options opts = options(ctx)!;
	$if env::WIN32:  // the lock records it: keep it readable on other systems
		if (sys::is_local_path(arg)) arg = arg.treplace("\\", "/");
	$endif
	foreach (host : install::BUILTIN_HOSTS)  // github.com/o/r: https, as the browser shows it
	{
		if (arg.starts_with(host.tconcat("/"))) arg = string::tformat("https://%s", arg);
	}
	// <source>@<ref>: the @ after the last '/' (git@host:path has one before it)
	String source = arg;
	String ref = ctx.arg(1);
	String last = arg[(arg.rindex_of_char('/') ?? -1) + 1..];
	if (arg.contains("/") && last.contains("@"))
	{
		if (ref.len) return log::fail("give the version either as %s or as a separate argument, not both", arg)~;
		ref = last[last.index_of_char('@')!! + 1..];
		source = arg[:arg.len - ref.len - 1];
	}
	Want w;
	switch
	{
		case is_path_dep(arg):  // the whole argument: a directory name may contain '@'
			if (ctx.arg(1).len) return log::fail("a local directory has no versions; it is linked as it is")~;
			w = { .kind = PATH, .origin = arg };
		case install::is_git_url(source):
			if (!lock::valid_git_url(source))
			{
				return log::fail("'%s' is not a git URL c3l fetches from: use https://, ssh://, git://, file:// or git@host:path, without credentials (the URL is written to %s; for a private repository use an ssh key or a credential helper)", source, p.lock.file)~;
			}
			opts.hosts.push(install::host_of(source));
			w = { .kind = GIT, .origin = source, .ref = ref };
		case registry::is_id(source):
			w = { .kind = REGISTRY, .id = source, .ref = ref };  // the origin: op.registry_for, below
		default:
			return log::fail("'%s' is neither <namespace>/<name>[@version] nor a git URL", arg)~;
	}
	Op op = install::begin(&p, &opts)!;
	defer catch op.rollback();
	if (w.kind == REGISTRY) w.origin = op.registry_for(w.id, "")!;
	op.add(w, DIRECT)!;
	op.commit();
}

fn void? remove_run(Ctx* ctx)
{
	Project p = project::find()!;
	String name = lib_name(ctx.arg(0))!;
	String f = project::lib_file(p.lib_dir()!, name);
	if (try sm = p.submodule(name)) return log::fail("%s is a git submodule; remove it with 'git rm %s' first, then run 'c3l remove %s' again", sm.path, sm.path, name)~;
	if (!path::is_link((Path)f) && file::exists(string::tformat("%s/.git", f)) && !git::disposable(f))
	{
		return log::fail("%s is a git repository with local changes or commits on no branch; save or move it first", f)~;
	}
	bool locked = p.lock.has(name);
	if (!locked && !p.has_dep(name)! && !sys::exists(f)) return log::fail("'%s' is not installed", name)~;
	if (!locked) log::warn("%s is not tracked in %s", name, p.lock.file);
	String[] needed = p.lock.dependents(name);
	if (needed.len && !ctx.flag_bool("force"))
	{
		return log::fail("'%s' is required by: %s. Remove those first, or use --force", name, string::join(tmem, needed, " "))~;
	}
	sys::remove(f);
	unregister(&p, name);
	p.lock.del(name);
	p.lock.save()!;
	log::info("removed %s", name);
	String[] orphans = p.lock.orphans();
	if (orphans.len) log::info("no longer needed: %s (run 'c3l prune' to remove)", string::join(tmem, orphans, " "));
}

fn void? prune_run(Ctx* ctx)
{
	Project p = project::find()!;
	List{String} prunable;
	prunable.tinit();
	foreach (name : p.lock.orphans())
	{
		if (try sm = p.submodule(name))
		{
			log::info("%s is not needed, but it is a git submodule; remove it with 'git rm %s' and 'c3l remove %s'", name, sm.path, name);
			continue;
		}
		prunable.push(name);
	}
	String[] orphans = prunable.array_view();
	if (!orphans.len)
	{
		log::info("nothing to prune");
		return;
	}
	if (ctx.flag_bool("dry-run"))
	{
		foreach (name : orphans) io::printfn("%s: not needed (dry run)", name);
		return;
	}
	Options opts = options(ctx)!;
	Op op = install::begin(&p, &opts)!;
	defer catch op.rollback();
	foreach (name : orphans)
	{
		op.set_aside(name)!;
		unregister(&p, name);
		p.lock.del(name);
		log::info("pruned %s", name);
	}
	p.lock.save()!;
	op.commit();
}

fn void? update_run(Ctx* ctx)
{
	Project p = project::find()!;
	Options opts = options(ctx)!;
	// every argument is checked before anything changes
	List{Entry} todo;
	List{String} wants;  // per entry: the ref asked for, empty for the newest
	todo.tinit();
	wants.tinit();
	if (!ctx.args.len) todo.push_all(p.lock.entries.array_view());
	foreach (arg : ctx.args)
	{
		sz at = arg.index_of_char('@') ?? arg.len;
		String name = lib_name(arg[:at])!;
		if (at + 1 == arg.len) return log::fail("empty version in '%s'", arg)~;
		Entry* e = p.lock.get(name) ?? log::fail("'%s' is not in %s", name, p.lock.file)~!;
		todo.push(*e);
		wants.push(at < arg.len ? arg[at + 1..] : "");
	}
	List{String} failed;
	failed.tinit();
	sz n;
	foreach (i, e : todo)
	{
		sys::check_interrupt()!;
		if (e.kind == PATH) continue;  // a linked directory is always current
		if (e.kind == GIT) opts.hosts.push(install::host_of(e.origin));
		String want = i < wants.len() ? wants[i] : "";
		String shown = want;
		if (!want.len)
		{
			Newer? newer = install::newer(&e);
			if (catch newer)
			{
				log::error("%s: cannot determine the newest version%s", e.name, e.kind == GIT ? git::because() : "");
				failed.push(e.name);
				continue;
			}
			if (newer.breaking.len) log::info("%s %s is available, not compatible with %s: 'c3l update %s@%s' moves to it", e.name, newer.breaking, semver::compat(e.version), e.name, newer.breaking);
			if (!newer.next.len) continue;
			shown = newer.next;
			// a moving source (HEAD, branch) is fetched again at its locked label
			want = newer.next.starts_with("HEAD@") ? e.version : newer.next;
		}
		if (ctx.flag_bool("dry-run"))
		{
			io::printfn("%s: %s -> %s (dry run)", e.name, e.version, shown);
			n++;
			continue;
		}
		if (!apply(&p, &opts, { .kind = e.kind, .origin = e.origin, .id = e.id, .ref = want }, ctx.flag_bool("fail-fast"))!)
		{
			failed.push(e.name);
			continue;
		}
		n++;
	}
	if (failed.len())
	{
		String others = n ? " (the others were updated)" : "";
		return log::fail("could not update %d %s: %s%s", failed.len(), libraries(failed.len()), string::join(tmem, failed.array_view(), " "), others)~;
	}
	if (!n) log::info("nothing to update");
}

fn void? sync_run(Ctx* ctx)
{
	Project p = project::find()!;
	if (!p.lock.exists()) return log::fail("%s not found (nothing to sync; try 'c3l migrate' or 'c3l add')", p.lock.file)~;
	String dir = p.lib_dir(true)!;
	if (ctx.flag_bool("frozen"))
	{
		bool drift;
		foreach (d : p.deps()!)
		{
			if (p.lock.has(d)) continue;
			io::eprintfn("drift: %s is in %s but not in %s", d, p.file, p.lock.file);
			drift = true;
		}
		foreach (e : p.lock.entries)
		{
			if (!listed(&p, e) || p.has_dep(e.name)!) continue;
			io::eprintfn("drift: %s is in %s but not in %s", e.name, p.lock.file, p.file);
			drift = true;
		}
		if (drift) return log::fail("project and lockfile disagree (--frozen)")~;
		p.lock.frozen = true;
	}
	else
	{
		foreach (d : p.deps()!)
		{
			if (p.lock.has(d)) continue;
			log::warn("%s is in %s but not in %s (%s)", d, p.file, p.lock.file, how_to_lock(&p, d));
		}
	}
	Options opts = options(ctx)!;
	List{Entry} entries;
	entries.tinit_with_array(p.lock.entries.array_view());
	List{String} failed;
	failed.tinit();
	foreach (&e : entries)
	{
		sys::check_interrupt()!;
		Submodule* sm = p.submodule(e.name) ?? null;
		Status st = install::status(e, dir, sm);
		if (sm && st != OK)
		{
			if (!sync_submodule(e, sm, st))
			{
				if (ctx.flag_bool("fail-fast")) return serp::FAILED~;
				failed.push(e.name);
				continue;
			}
			st = OK;
		}
		if (st == OK)
		{
			if (listed(&p, *e) && !p.has_dep(e.name)!)
			{
				log::info("registering %s in %s", e.name, p.file);
				if (catch err = p.set_dep(e.name, true))
				{
					if (err == project::NOT_UPDATED) return log::fail("could not register %s in %s", e.name, p.file)~;
					return err~;  // already reported
				}
			}
			continue;
		}
		if (st == MODIFIED) log::warn("%s differs from the lockfile; restoring", e.name);
		if (e.kind == PATH && !file::is_dir(e.origin))
		{
			log::error("path dependency %s: %s does not exist here", e.name, e.origin);
			if (ctx.flag_bool("fail-fast")) return serp::FAILED~;
			failed.push(e.name);
			continue;
		}
		Want w = { .kind = e.kind, .origin = e.origin, .id = e.id, .ref = e.version, .pin = e.pin, .hash = e.hash };
		if (!apply(&p, &opts, w, ctx.flag_bool("fail-fast"))!) failed.push(e.name);
	}
	if (failed.len())
	{
		return log::fail("could not restore %d %s: %s (everything else was restored; run again once fixed)", failed.len(), libraries(failed.len()), string::join(tmem, failed.array_view(), " "))~;
	}
	log::info("in sync with %s", p.lock.file);
}

// How to lock a library that the project lists and the lockfile does not.
fn String how_to_lock(Project* p, String name) => @ok(p.submodule(name)) ? "a git submodule: 'c3l migrate' adopts it" : "'c3l add' it to lock it";

<*
 A library stored as a git submodule is restored by git: checked out at the
 commit the repository records, which c3l.lock must also have. c3l never
 discards local changes or commits in it, or replaces it with an archive.
*>
fn bool sync_submodule(Entry* e, Submodule* s, Status st) @private
{
	if (st == MOVED && s.unsaved())
	{
		log::error("%s: the submodule %s has commits on no branch; c3l does not drop them (create a branch for them, or check out %s yourself)", e.name, s.path, git::abbrev(s.commit));
		return false;
	}
	if (st == NOT_CHECKED_OUT || st == MOVED)
	{
		if (catch s.reset()) return false;
		st = install::submodule_status(e, s);
		if (st == OK) log::info("checked out the submodule %s at %s (commit %s)", s.path, e.version, git::abbrev(s.commit));
	}
	if (st == OK) return true;
	log::error("%s: %s", e.name, install::explain(st, e, s));
	return false;
}

<*
 Bring under c3l what another tool keeps: git submodules in the library
 directory that c3l.lock does not list yet (adopted at the commit the repository
 records), and c3po's project.lock.json or c3l 0.x's .c3l.deps (into a new c3l.lock).
*>
fn void? migrate_run(Ctx* ctx)
{
	bool moved = migrate_vendor_lock()!;
	Project p = project::find()!;
	String old = file::exists("project.lock.json") ? "project.lock.json" : file::exists(".c3l.deps") ? ".c3l.deps" : "";
	if (old == "project.lock.json" && file::exists(".c3l.deps")) log::warn(".c3l.deps is not imported; project.lock.json is");
	bool fresh = !p.lock.exists();
	List{Submodule} subs;
	subs.tinit();
	foreach (sm : p.submodules()) if (!p.lock.has(sm.name)) subs.push(sm);
	if (!old.len && !subs.len())
	{
		if (moved) return;
		return log::fail("nothing to migrate: no project.lock.json (c3po), no .c3l.deps (c3l 0.x) and no git submodule in the library directory that %s does not list", p.lock.file)~;
	}
	if (old.len && !fresh && !subs.len()) return log::fail("%s already exists", p.lock.file)~;
	String[] adopted = subs.len() ? adopt_submodules(&p, ctx, subs.array_view())! : {};
	if (old.len && !fresh)
	{
		log::warn("%s already exists; %s is not imported", p.lock.file, old);
	}
	else if (old.len)
	{
		String dir = p.lib_dir()!;
		if (old == ".c3l.deps")
		{
			migrate_deps(&p, dir, adopted)!;
		}
		else
		{
			migrate_c3po(&p, dir, adopted)!;
		}
		p.lock.save()!;
		log::info("the libraries already in %s are not verified yet; run 'c3l sync' to rebuild them as verified archives", dir);
	}
	if (!old.len && !adopted.len && !moved) return log::fail("no submodule could be adopted (see the warnings)")~;
}

<*
 c3l 2.1 and older locked c3c's vendor collection as `vendor` entries (one rolling release,
 no versions). It is the c3lang registry now: each such line becomes a registry entry for
 c3lang/<name>, at the registry's latest version and checksum. The files in lib/ are not touched
 (they differ from the registry's archives): 'c3l sync' rebuilds them. False when there is none.
*>
fn bool? migrate_vendor_lock() @private
{
	String file = env::tget_var("C3L_LOCK") ?? "c3l.lock";
	if (!file::exists(file)) return false;
	String text = (String)file::load_temp(file) ?? log::fail("cannot read %s", file)~!;
	if (!text.contains("\tvendor\t")) return false;
	Registry c3lang;
	foreach (d : registry::defaults()) if (d.name == "c3lang") c3lang = d;
	List{String} lines;
	lines.tinit();
	int moved;
	foreach (raw : text.tsplit("\n"))
	{
		String[] col = raw.strip_suffix("\r").tsplit("\t");
		if (col.len != 9 || col[1] != "vendor")
		{
			lines.push(raw);
			continue;
		}
		String id = string::tformat("c3lang/%s", col[3]);
		Info info = registry::info(c3lang.url, id) ?? log::fail("%s is not in the c3lang registry (%s); remove its line from %s, or keep it from another source", id, c3lang.url, file)~!;
		String sum = info.checksum(info.latest);
		if (!info.latest.len || !sum.len) return log::fail("the c3lang registry lists no version or checksum for %s", id)~;
		lines.push(string::tformat("%s\tregistry\t%s\t%s\t%s\t%s\t%s\t%s\t%s", col[0], c3lang.url, id, info.latest, sum, sum, col[7], col[8]));
		log::info("%s: vendor:%s is %s %s in the c3lang registry", col[0], col[3], id, info.latest);
		moved++;
	}
	sys::write_atomic(file, string::join(tmem, lines.array_view(), "\n"))!;
	log::info("%d vendor %s moved to the c3lang registry; run 'c3l sync' to reinstall them as verified archives", moved, libraries(moved));
	return true;
}

<*
 Lock git submodules as git libraries: the URL from .gitmodules, the commit the
 repository records, the version a tag at that commit names (else the branch
 .gitmodules follows, else the commit), the content hash an archive of that
 commit would have. Then install what they require, as archives. The names adopted.
*>
fn String[]? adopt_submodules(Project* p, Ctx* ctx, Submodule[] subs) @private
{
	Options opts = options(ctx)!;
	Op op = install::begin(p, &opts)!;
	defer catch op.rollback();
	List{Manifest} adopted;
	adopted.tinit();
	List{String} names;
	names.tinit();
	foreach (&sm : subs)
	{
		sys::check_interrupt()!;
		Manifest? m = adoptable(sm);
		if (catch m) continue;
		String version = submodule_version(sm);
		String pin = string::tformat("commit:%s", sm.commit);
		op.place({ .name = sm.name, .kind = GIT, .origin = sm.url, .id = "-", .version = version, .pin = pin, .hash = submodule_hash(sm)! }, "", DIRECT)!;
		log::info("adopted the submodule %s: %s %s (commit %s)", sm.path, sm.name, version, git::abbrev(sm.commit));
		adopted.push(m);
		names.push(sm.name);
	}
	foreach (m : adopted) op.follow(m.provides, m.requires)!;
	op.commit();
	return names.array_view();
}

// The manifest of a submodule that can be adopted; otherwise a warning says why not.
fn Manifest? adoptable(Submodule* sm) @private
{
	if (sm.url.starts_with("./") || sm.url.starts_with("../"))
	{
		log::warn("%s: skipped, its URL in .gitmodules ('%s') is relative to this repository's remote; consumers need an absolute URL", sm.path, sm.url);
		return NOT_FOUND~;
	}
	if (!lock::valid_git_url(sm.url))
	{
		log::warn("%s: skipped, its URL in .gitmodules ('%s') is not one c3l fetches from (https://, ssh://, git://, file:// or git@host:path, without credentials)", sm.path, sm.url);
		return NOT_FOUND~;
	}
	if (!sm.checked_out())
	{
		if (catch sm.reset()) return NOT_FOUND~;
		log::info("checked out the submodule %s", sm.path);
	}
	String head = sm.head();
	if (head != sm.commit)
	{
		log::warn("%s: skipped, it is checked out at %s but the repository records %s ('git submodule update %s' goes back)", sm.path, git::abbrev(head), git::abbrev(sm.commit), sm.path);
		return NOT_FOUND~;
	}
	Manifest? m = manifest::load(sm.at);
	if (catch m)
	{
		log::warn("%s: skipped, it has no manifest.json (not a C3 library)", sm.path);
		return NOT_FOUND~;
	}
	if (m.provides != sm.name)
	{
		log::warn("%s: skipped, its manifest.json provides '%s'; c3c finds a library as <dir>/<provides>.c3l", sm.path, m.provides);
		return NOT_FOUND~;
	}
	if (sm.edited()) log::warn("%s has local changes; 'c3l verify' reports them until they are committed or discarded", sm.path);
	return m;
}

// A tag at the commit (the highest version if several), else the branch .gitmodules follows, else the commit.
fn String submodule_version(Submodule* sm) @private
{
	String[] names = sm.tags_at(sm.commit);
	List{Ref} tags;
	tags.tinit();
	foreach (n : names) tags.push({ n, sm.commit });
	String best = git::highest(tags.array_view(), prereleases: true);
	if (best.len) return best;
	if (names.len) return names[0];
	if (sm.branch.len && sm.branch != ".") return string::tformat("branch:%s", sm.branch);
	return string::tformat("commit:%s", git::abbrev(sm.commit));
}

// The content hash of the commit, as c3l records it for a git library: from an archive of a local copy.
fn String? submodule_hash(Submodule* sm) @private
{
	String tmp = sys::temp_dir()!;
	defer sys::remove(tmp);
	String src = git::checkout(sm.at, sm.commit, "", tmp)!;
	String zip = string::tformat("%s/lib.zip", tmp);
	git::archive(src, zip)!;
	return sys::content_hash(zip) ?? log::fail("cannot read the archive of %s", sm.path)~;
}

<*
 c3l 0.x kept .c3l.deps: one line per library, "name.c3l dir/name.c3l url [tag]",
 cloned at the tag (none: HEAD). The tag is resolved to its commit now; the file is
 left alone.
*>
fn void? migrate_deps(Project* p, String dir, String[] adopted) @private
{
	String text = (String)file::load_temp(".c3l.deps") ?? log::fail("cannot read .c3l.deps")~!;
	foreach (line : text.tsplit("\n"))
	{
		String[] f = line.trim().tsplit(" ", skip_empty: true);
		if (!f.len) continue;
		String name = f[0].strip_suffix(".c3l");
		String url = f.len > 2 ? f[2] : "";
		String tag = f.len > 3 ? f[3] : "HEAD";
		if (!lock::valid_name(name) || !lock::valid_git_url(url) || !git::valid_ref(tag))
		{
			log::warn("skipping a .c3l.deps line that is not 'name.c3l path url [tag]': %s", line.trim());
			continue;
		}
		if (array::contains(adopted, name)) continue;  // stored as a submodule
		Rev rev = install::resolve_rev(url, tag, "") ?? log::fail("fix or remove the line for %s in .c3l.deps", name)~!;
		String pin = string::tformat("commit:%s", rev.commit);
		String file = project::lib_file(dir, name);
		Manifest m = manifest::load(file) ?? (Manifest){ .provides = name };
		p.lock.put({
			.name = name, .kind = GIT, .origin = url, .id = "-", .version = rev.label,
			.pin = pin, .hash = pin, .role = DIRECT, .requires = m.require_names(),
		});
		log::info("imported %s (%s, commit %s) from .c3l.deps", name, rev.label, rev.commit[:12]);
	}
}

<*
 c3po (Ecoral360/c3po) keeps project.lock.json: {"packages": [{name, repo, origin,
 ref, commit}]}. Lock the same commits as git libraries; c3po's files are not touched.
*>
fn void? migrate_c3po(Project* p, String dir, String[] adopted) @private
{
	String text = (String)file::load_temp("project.lock.json") ?? log::fail("cannot read project.lock.json")~!;
	Object* root = json::tparse(text) ?? log::fail("project.lock.json is not valid JSON")~!;
	Object* packages = root.is_map() ? root.get("packages") ?? null : null;
	for (sz i = 0; packages && packages.is_array() && i < packages.get_len(); i++)
	{
		Object* pkg = packages.get_at(i);
		if (!pkg.is_map()) continue;
		String name = pkg.get_string("name") ?? "";
		String repo = pkg.get_string("repo") ?? "";
		String origin = pkg.get_string("origin") ?? "";
		String commit = pkg.get_string("commit") ?? "";
		String label = pkg.get_string("ref") ?? "";
		if (!lock::valid_name(name) || !git::is_commit(commit))
		{
			log::warn("skipping a c3po entry without a valid name or commit");
			continue;
		}
		String host;
		switch (origin)
		{
			case "github": host = "https://github.com";
			case "codeberg": host = "https://codeberg.org";
			default:
				log::warn("%s: unknown c3po origin '%s', skipping", name, origin);
				continue;
		}
		if (array::contains(adopted, name)) continue;  // stored as a submodule
		if (!label.len) label = "HEAD";
		String f = project::lib_file(dir, name);
		if (!sys::exists(f)) f = string::tformat("%s/%s", dir, repo[(repo.rindex_of_char('/') ?? -1) + 1..]);
		String pin = string::tformat("commit:%s", commit);
		p.lock.put({
			.name = name, .kind = GIT, .origin = string::tformat("%s/%s", host, repo), .id = "-", .version = label,
			.pin = pin, .hash = pin, .role = DIRECT,
			.requires = sys::exists(f) ? (manifest::load(f) ?? (Manifest){ .provides = name }).require_names() : {},
		});
		log::info("imported %s (%s, commit %s) from project.lock.json", name, label, commit[:12]);
	}
}

<*
 Install one library (and what it pulls in) in its own operation; updating or
 restoring keeps its role. Unless `fail_fast`, a failure is rolled back and
 reported as false so the caller can go on with the next one.
*>
fn bool? apply(Project* p, Options* opts, Want w, bool fail_fast)
{
	Op op = install::begin(p, opts)!;
	if (catch e = op.add(w, KEEP))
	{
		op.rollback();
		if (fail_fast || sys::interrupted) return e~;
		return false;
	}
	op.commit();
	return true;
}

fn Options? options(Ctx* ctx)
{
	Options opts = { .strict = ctx.flag_bool("strict"), .registries = registry::configured(ctx.flag_strings("registry"))!, .explicit = registry::is_explicit(ctx.flag_strings("registry")) };
	opts.hosts.tinit_with_array(ctx.flag_strings("allow-host"));
	return opts;
}

// Is `e` listed in the project's dependencies? A library's manifest lists only its direct ones.
fn bool listed(Project* p, Entry e) => !(p.libmode && e.role == DEP);

fn void unregister(Project* p, String name)
{
	if (catch p.set_dep(name, false)) log::warn("could not update %s; remove \"%s\" from 'dependencies' manually", p.file, name);
}

// An explicit local directory (./x, ../x, /x) that is a C3 library: linked, not copied.
fn bool is_path_dep(String s)
{
	return (s == "." || s == ".." || sys::is_local_path(s)) && file::is_dir(s) && file::exists(string::tformat("%s/manifest.json", s));
}

fn String libraries(sz n) => n == 1 ? "library" : "libraries";

// A library name given on the command line, optionally as <name>.c3l.
fn String? lib_name(String arg)
{
	String name = arg.strip_suffix(".c3l");
	if (!lock::valid_name(name)) return log::fail("'%s' is not a library name", arg)~;
	return name;
}
