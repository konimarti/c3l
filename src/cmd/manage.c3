<*
 Commands that change what is installed: add, remove, prune, update, sync, migrate.
*>
module c3l;

import std::io, std::collections::list, std::collections::object, std::encoding::json, serp;
import c3l::log, c3l::sys, c3l::lock, c3l::project, c3l::manifest, c3l::install, c3l::registry, c3l::vendor, c3l::git;

fn void? add_run(Ctx* ctx)
{
	Project p = project::find()!;
	String arg = ctx.arg(0);
	if (arg == "vendor" || arg == "vendor:")
	{
		Asset[] list = vendor::assets() ?? log::fail("cannot read the vendor library list (%s)", vendor::api())~!;
		foreach (a : list) io::printfn("vendor:%s", a.name);
		return;
	}
	Options opts = options(ctx);
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
		case arg.starts_with("vendor:"):
			if (ref.len || arg.contains("@")) return log::fail("vendor libraries have no versions (the collection is one rolling release); use vendor:<name>")~;
			w = { .kind = VENDOR, .origin = registry::base(vendor::url()), .id = arg["vendor:".len..] };
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
			w = { .kind = REGISTRY, .origin = opts.registry, .id = source, .ref = ref };
		default:
			return log::fail("'%s' is neither <namespace>/<name>[@version], vendor:<name> nor a git URL", arg)~;
	}
	Op op = install::begin(&p, &opts)!;
	defer catch op.rollback();
	op.add(w, DIRECT)!;
	op.commit();
}

fn void? remove_run(Ctx* ctx)
{
	Project p = project::find()!;
	String name = lib_name(ctx.arg(0))!;
	String f = project::lib_file(p.lib_dir()!, name);
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
	String[] orphans = p.lock.orphans();
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
	Options opts = options(ctx);
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
	Options opts = options(ctx);
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
			if (newer.major.len) log::info("%s %s is available, a new major version: 'c3l update %s@%s' moves to it", e.name, newer.major, e.name, newer.major);
			if (!newer.next.len) continue;
			shown = newer.next;
			// a moving source (HEAD, branch, vendor) is fetched again at its locked label
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
			if (!p.lock.has(d)) log::warn("%s is in %s but not in %s ('c3l add' it to lock it)", d, p.file, p.lock.file);
		}
	}
	Options opts = options(ctx);
	List{Entry} entries;
	entries.tinit_with_array(p.lock.entries.array_view());
	List{String} failed;
	failed.tinit();
	foreach (&e : entries)
	{
		sys::check_interrupt()!;
		Status st = install::status(e, dir);
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

<*
 c3po (Ecoral360/c3po) keeps project.lock.json: {"packages": [{name, repo, origin,
 ref, commit}]}. Lock the same commits as git libraries; c3po's files are not touched.
*>
fn void? migrate_run(Ctx* ctx)
{
	Project p = project::find()!;
	if (!file::exists("project.lock.json")) return log::fail("no project.lock.json (c3po) found")~;
	if (p.lock.exists()) return log::fail("%s already exists", p.lock.file)~;
	String dir = p.lib_dir()!;
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
	p.lock.save()!;
	log::info("libraries restored by c3po have no commit stamp; run 'c3l sync' to rebuild them as verified archives");
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

fn Options options(Ctx* ctx)
{
	Options opts = { .strict = ctx.flag_bool("strict"), .registry = registry_url(ctx) };
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
