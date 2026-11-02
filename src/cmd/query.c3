<*
 Commands that look but do not install: init, list, verify, why, outdated,
 search, info.
*>
module c3l;

import std::io, std::os, std::collections::list, serp;
import c3l::log, c3l::sys, c3l::lock, c3l::project, c3l::install, c3l::registry;

fn void? init_run(Ctx* ctx)
{
	String name = ctx.arg(0);
	if (name.len && !file::exists("project.json") && !file::exists("project.json5"))
	{
		if (process::run({ sys::c3c(), "init", name }, INHERIT_ENV | INHERIT_STDIO) ?? 1) return log::fail("c3c init failed")~;
		if (posix::chdir(name.zstr_tcopy())) return log::fail("cannot enter %s", name)~;
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
		foreach (e : p.lock.entries)
		{
			if (e.role != DIRECT) continue;
			io::printfn("%s %s", e.name, e.version);
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
		if (e.kind == VENDOR) where = string::tformat("vendor:%s", e.id);
		String st = install::status(e, dir).name;
		if (!has(deps, e.name) && !(p.libmode && e.role == DEP)) st = string::tformat("%s,not-in-project", st);
		if (e.role == DEP) st = string::tformat("%s,dep", st);
		io::printfn("%-20s %-8s %-12s %-10s %s", e.name, e.kind.name, e.version, st, where);
	}
	sz untracked;
	foreach (d : deps)
	{
		if (p.lock.has(d)) continue;
		io::printfn("%-20s %-8s %-12s %-10s (in %s, not in %s)", d, "-", "-", "untracked", p.file, p.lock.file);
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
		if (has(path, r))
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
		Status st = install::status(e, dir);
		if (st != OK)
		{
			io::eprintfn("%s: %s", e.name, st.name);
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
		io::eprintfn("%s: in %s but not in %s", d, p.file, p.lock.file);
		bad = true;
	}
	if (bad) return log::fail("verification failed")~;
	sz n = p.lock.entries.len();
	log::info("%d librar%s verified", n, n == 1 ? "y" : "ies");
}

fn void? why_run(Ctx* ctx)
{
	Project p = project::find()!;
	String name = ctx.arg(0).strip_suffix(".c3l");
	Entry* e = p.lock.get(name) ?? log::fail("'%s' is not in %s", name, p.lock.file)~!;
	if (e.role == DIRECT) log::info("%s is a direct dependency of the project", name);
	print_why(&p.lock, name, "", { name });
}

// Who requires `name`, recursively.
fn void print_why(Lock* l, String name, String indent, String[] seen)
{
	foreach (d : l.dependents(name))
	{
		if (has(seen, d))
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
	foreach (&e : p.lock.entries)
	{
		String newer = install::newer(e) ?? "";
		if (!newer.len) continue;
		io::printfn("%-20s %-12s -> %s", e.name, e.version, newer);
		n++;
	}
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
	registry::search(registry_url(ctx), query, tag)!;
}

fn void? info_run(Ctx* ctx)
{
	String base = registry_url(ctx);
	Info info = registry::info(base, ctx.arg(0)) ?? log::fail("%s: not found or registry not reachable (%s)", ctx.arg(0), base)~!;
	info.print();
	if (info.latest.len) registry::compatible(base, ctx.arg(0), info.latest);
}

// The registry for new installs and lookups: --registry > $C3L_REGISTRY > www.c3pkg.eu
fn String registry_url(Ctx* ctx) => registry::base(ctx.flag_string("registry"));

fn bool has(String[] list, String s)
{
	foreach (x : list) if (x == s) return true;
	return false;
}

fn String[] with(String[] list, String s)
{
	List{String} out;
	out.tinit_with_array(list);
	out.push(s);
	return out.array_view();
}
