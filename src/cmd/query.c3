<*
 Commands that look but do not install: init, list, verify, why, outdated,
 search, info.
*>
module c3l;

import std::io, std::os, std::collections::list, serp;
import c3l::log, c3l::sys, c3l::lock, c3l::project, c3l::install, c3l::registry, c3l::git;

fn void? init_run(Ctx* ctx)
{
	String name = ctx.arg(0);
	if (name.len && !file::exists("project.json") && !file::exists("project.json5"))
	{
		if (process::run({ sys::c3c(), "init", name }, INHERIT_ENV | INHERIT_STDIO) ?? 1) return log::fail("c3c init failed")~;
		path::chdir(name) ?? log::fail("cannot enter %s", name)~!;
	}
	Project p = project::find()!;
	if (p.lock.exists())
	{
		log::info("%s already exists", p.lock.file);
		return;
	}
	p.lock.save()!;
	log::info("created %s", p.lock.file);
	log::info("commit %s; restore libraries on a fresh checkout with 'c3l sync'", p.lock.file);
}

fn void? list_run(Ctx* ctx)
{
	Project p = project::find()!;
	if (ctx.flag_bool("tree"))
	{
		String[] orphans = p.lock.orphans();
		foreach (e : p.lock.entries)
		{
			bool orphan = array::contains(orphans, e.name);
			if (e.role != DIRECT && !orphan) continue;
			io::printfn("%s %s%s", e.name, e.version, orphan ? " (not needed; 'c3l prune' removes it)" : "");
			print_tree(&p.lock, e.name, "  ", { e.name });
		}
		return;
	}
	String dir = p.lib_dir()!;
	String[] deps = p.deps()!;
	foreach (&e : p.lock.entries)
	{
		String where = e.origin;
		if (e.kind == REGISTRY) where = string::tformat("%s (%s)", e.id, e.origin);
		Submodule* sm = p.submodule(e.name) ?? null;
		String st = install::status(e, dir, sm).name;
		if (sm) st = string::tformat("%s,submodule", st);
		if (!array::contains(deps, e.name) && !(p.libmode && e.role == DEP)) st = string::tformat("%s,not-in-project", st);
		if (e.role == DEP) st = string::tformat("%s,dep", st);
		io::printfn("%-20s %-8s %-12s %-10s %s", e.name, e.kind.name, e.version, st, where);
	}
	sz untracked;
	foreach (d : deps)
	{
		if (p.lock.has(d)) continue;
		io::printfn("%-20s %-8s %-12s %-10s (in %s, not in %s)", d, "-", "-", @ok(p.submodule(d)) ? "untracked,submodule" : "untracked", p.file, p.lock.file);
		untracked++;
	}
	if (!p.lock.entries.len() && !untracked) log::info("no libraries (add one with 'c3l add <ns/name>')");
}

// What `name` requires, recursively; `path` is the chain from the root (cycles).
fn void print_tree(Lock* l, String name, String indent, String[] path)
{
	foreach (r : l.get(name).requires ?? {})
	{
		String version = l.get(r).version ?? "(not installed)";
		if (array::contains(path, r))
		{
			io::printfn("%s%s %s (cycle)", indent, r, version);
			continue;
		}
		io::printfn("%s%s %s", indent, r, version);
		print_tree(l, r, indent.tconcat("  "), with(path, r));
	}
}

fn void? verify_run(Ctx* ctx)
{
	Project p = project::find()!;
	String dir = p.lib_dir()!;
	if (!p.lock.exists()) return log::fail("%s not found", p.lock.file)~;
	bool bad;
	foreach (&e : p.lock.entries)
	{
		Submodule* sm = p.submodule(e.name) ?? null;
		Status st = install::status(e, dir, sm);
		if (st != OK)
		{
			io::eprintfn("%s: %s", e.name, install::explain(st, e, sm));
			bad = true;
		}
		foreach (r : e.requires)
		{
			if (p.lock.has(r) || p.has_dep(r)!) continue;
			io::eprintfn("%s: requires %s, which is not installed", e.name, r);
			bad = true;
		}
	}
	foreach (d : p.deps()!)
	{
		if (p.lock.has(d)) continue;
		io::eprintfn("%s: in %s but not in %s (%s)", d, p.file, p.lock.file, how_to_lock(&p, d));
		bad = true;
	}
	if (bad) return log::fail("verification failed")~;
	sz n = p.lock.entries.len();
	log::info("%d librar%s verified", n, n == 1 ? "y" : "ies");
}

fn void? why_run(Ctx* ctx)
{
	Project p = project::find()!;
	String name = lib_name(ctx.arg(0))!;
	Entry* e = p.lock.get(name) ?? log::fail("'%s' is not in %s", name, p.lock.file)~!;
	if (e.role == DIRECT) log::info("%s is a direct dependency of the project", name);
	print_why(&p.lock, name, "", { name });
}

// Who requires `name`, recursively.
fn void print_why(Lock* l, String name, String indent, String[] seen)
{
	foreach (d : l.dependents(name))
	{
		if (array::contains(seen, d))
		{
			io::printfn("%s%s requires %s (cycle)", indent, d, name);
			continue;
		}
		io::printfn("%s%s requires %s", indent, d, name);
		print_why(l, d, indent.tconcat("  "), with(seen, d));
	}
}

fn void? outdated_run(Ctx* ctx)
{
	Project p = project::find()!;
	sz n;
	List{String} unknown;
	unknown.tinit();
	foreach (&e : p.lock.entries)
	{
		sys::check_interrupt()!;
		Newer? newer = install::newer(e);
		if (catch newer)
		{
			log::error("%s: cannot determine the newest version%s", e.name, e.kind == GIT ? git::because() : "");
			unknown.push(e.name);
			continue;
		}
		if (!newer.next.len && !newer.breaking.len) continue;
		String breaking = newer.breaking.len ? string::tformat("(not compatible: %s)", newer.breaking) : "";
		io::printfn("%-20s %-12s -> %-12s %s", e.name, e.version, newer.next.len ? newer.next : e.version, breaking);
		n++;
	}
	if (unknown.len()) return log::fail("could not check %s", string::join(tmem, unknown.array_view(), " "))~;
	if (!n) log::info("everything is up to date");
}

fn void? search_run(Ctx* ctx)
{
	String query = string::join(tmem, ctx.args, " ");
	String tag;
	if (query.starts_with("tag:"))
	{
		tag = query["tag:".len..];
		query = "";
	}
	Registry[] regs = registries(ctx)!;
	List{Failure} failures;
	failures.tinit();
	long total;
	Hit[] hits = registry::search_all(regs, query, tag, &total, &failures);
	foreach (h : hits) io::printfn("%-32s %-10s %-8s %s", h.name, h.version, h.registry, h.about);
	if (hits.len || !failures.len()) io::printfn("(%d of %d shown; searched %s)", hits.len, total, registry::names(regs));
	foreach (f : failures) log::warn("%s: %s", f.registry, f.error);
	if (failures.len() == regs.len) return log::fail("no registry answered")~;
}

fn void? info_run(Ctx* ctx)
{
	String id = ctx.arg(0);
	Registry[] regs = registries(ctx)!;
	List{Failure} failures;
	failures.tinit();
	Found[] found = registry::lookup_all(regs, id, &failures);
	foreach (f : failures) log::warn("%s: %s", f.registry, f.error);
	if (!found.len) return log::fail("%s: not found in %s", id, registry::names(regs))~;
	foreach (f : found)
	{
		if (found.len > 1) io::printfn("== %s (%s)", f.registry.name, f.registry.url);
		Info info = registry::info_from(f.body) ?? log::fail("%s: unreadable answer from %s", id, f.registry.url)~!;
		info.print();
		if (info.latest.len) registry::compatible(f.registry.url, id, info.latest);
	}
}

// The registries for new installs and lookups: --registry (repeatable) > $C3L_REGISTRY > the defaults.
fn Registry[]? registries(Ctx* ctx) => registry::configured(ctx.flag_strings("registry"));

fn String[] with(String[] list, String s)
{
	List{String} out;
	out.tinit_with_array(list);
	out.push(s);
	return out.array_view();
}
