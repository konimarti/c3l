<*
 A library's manifest.json, read from a directory or from inside a .c3l archive,
 together with the library's own c3l.lock when it has one.

 What a library requires, per name, in this order of precedence:
   vendor.c3l.requires   [{name, source, version, registry}]  read only: packages published by c3l 1.1
   c3l.lock              its direct entries                   how c3l libraries declare them
   vendor.c3po.sources   [{name, source}]                     read only: c3po compatibility, at the
                                                              commit c3po's project.lock.json pins, if any
   dependencies          names only (top level and per target), no source
*>
module c3l::manifest;

import std::io, std::collections::list, std::collections::object, std::encoding::json;
import std::compression::zip, c3l::lock;

struct Requirement
{
	String name;
	String source;    // registry id, git URL or vendor:<name>; empty: unknown
	String version;   // empty: any
	String registry;  // registry base URL for a registry source; empty: the default
}

struct Manifest
{
	String provides;
	String version;
	String[] dependencies;  // top level "dependencies"
	Requirement[] requires;
	String invalid;         // a required name that is not a valid library name (not in `requires`)
	String[] notes;         // what was not followed, and why: for the user
}

faultdef NO_MANIFEST, BAD_MANIFEST;

// From a library directory, or a .c3l file (zip archive); with its c3l.lock and c3po's project.lock.json, if any.
fn Manifest? load(String path)
{
	if (file::is_dir(path))
	{
		String lock_text = (String)file::load_temp(string::tformat("%s/c3l.lock", path)) ?? "";
		String c3po_lock = (String)file::load_temp(string::tformat("%s/project.lock.json", path)) ?? "";
		return parse((String)file::load_temp(string::tformat("%s/manifest.json", path)) ?? NO_MANIFEST~!, lock_text, c3po_lock);
	}
	ZipArchive archive = zip::open(tmem, path) ?? NO_MANIFEST~!;
	defer (void)archive.close();
	char[] data = archive.read_file_all(tmem, "manifest.json") ?? NO_MANIFEST~!;
	return parse((String)data, (String)archive.read_file_all(tmem, "c3l.lock") ?? "", (String)archive.read_file_all(tmem, "project.lock.json") ?? "");
}

fn Manifest? load_file(String file)
{
	char[] data = file::load_temp(file) ?? NO_MANIFEST~!;
	return parse((String)data);
}

fn Manifest? parse(String text, String lock_text = "", String c3po_lock = "")
{
	Object* root = json::tparse(text) ?? BAD_MANIFEST~!;
	if (!root.is_map()) return BAD_MANIFEST~;
	Manifest m = {
		.provides = root.get_string("provides") ?? "",
		.version = root.get_string("version") ?? "",
		.dependencies = strings(root, "dependencies"),
	};

	List{Requirement} reqs;
	reqs.tinit();
	Object* vendor = root.get("vendor") ?? null;
	if (vendor && vendor.is_map())
	{
		if (try c3l = vendor.get("c3l"))
		{
			foreach (r : objects(c3l, "requires"))
			{
				add(&m, &reqs, {
					.name = r.get_string("name") ?? "",
					.source = r.get_string("source") ?? "",
					.version = r.get_string("version") ?? "",
					.registry = r.get_string("registry") ?? "",
				});
			}
		}
	}
	List{String} notes;
	notes.tinit();
	if (lock_text.len)
	{
		String why;
		Lock? l = lock::parse(lock_text, "c3l.lock", &why);
		if (try l)
		{
			foreach (r : from_lock(&l)) add(&m, &reqs, r);
		}
		else
		{
			notes.push(string::tformat("its %s; what it locks is not followed", why));
		}
	}
	Object* c3po = vendor && vendor.is_map() ? vendor.get("c3po") ?? null : null;
	if (c3po && c3po.is_map())
	{
		long version = c3po.get_long("c3po-version") ?? 1;
		Object*[] sources = objects(c3po, "sources");
		if (version != 1 && sources.len)
		{
			notes.push(string::tformat("its vendor.c3po block has c3po-version %d (c3l reads 1); its sources are not followed", version));
			sources = {};
		}
		foreach (r : sources)
		{
			String name = r.get_string("name") ?? "";
			add(&m, &reqs, { .name = name, .source = r.get_string("source") ?? "", .version = c3po_commit(c3po_lock, name) });
		}
	}
	foreach (d : m.dependencies) add(&m, &reqs, { .name = d });
	if (try targets = root.get("targets"))
	{
		targets.@each_entry(; String key, Object* target)
		{
			foreach (d : strings(target, "dependencies")) add(&m, &reqs, { .name = d });
		};
	}
	m.requires = reqs.array_view();
	m.notes = notes.array_view();
	return m;
}

// The commit c3po's project.lock.json ({"packages": [{name, commit}]}) pins `name` to; empty if none.
fn String c3po_commit(String text, String name) @private
{
	if (!text.len) return "";
	Object* root = json::tparse(text) ?? null;
	Object* packages = root && root.is_map() ? root.get("packages") ?? null : null;
	for (sz i = 0; packages && packages.is_array() && i < packages.get_len(); i++)
	{
		Object* p = packages.get_at(i);
		if (!p.is_map() || (p.get_string("name") ?? "") != name) continue;
		String commit = p.get_string("commit") ?? "";
		return lock::is_commit(commit) ? commit : "";
	}
	return "";
}

<*
 What a library's own lock says it requires (how consumers read it): its direct entries, each from the
 source it was installed from, at least at the locked version (registry), at
 the locked tag, branch or commit (git). Local directories cannot be fetched by
 anyone else and are left out.
*>
fn Requirement[] from_lock(Lock* l)
{
	List{Requirement} out;
	out.tinit();
	foreach (e : l.entries)
	{
		if (e.role != DIRECT) continue;
		switch (e.kind)
		{
			case REGISTRY:
				out.push({ .name = e.name, .source = e.id, .version = e.version, .registry = e.origin });
			case VENDOR:
				out.push({ .name = e.name, .source = string::tformat("vendor:%s", e.id) });
			case GIT:
				String version = e.version;
				if (version == "HEAD") version = "";  // the tip, whatever it is then
				if (version.starts_with("commit:")) version = e.pin;  // the label has 12 characters
				out.push({ .name = e.name, .source = e.origin, .version = version });
			case PATH:
				break;
		}
	}
	return out.array_view();
}

// The names `m` requires, without itself.
fn String[] Manifest.require_names(&self)
{
	List{String} names;
	names.tinit();
	foreach (r : self.requires) if (r.name != self.provides) names.push(r.name);
	return names.array_view();
}

// first one per name wins; a nameless entry is named after its source
fn void add(Manifest* m, List{Requirement}* reqs, Requirement r) @private
{
	if (!r.name.len) r.name = name_of(r.source);
	if (!r.name.len) return;
	if (!lock::valid_name(r.name))
	{
		if (!m.invalid.len) m.invalid = r.name;
		return;
	}
	foreach (have : *reqs) if (have.name == r.name) return;
	reqs.push(r);
}

// "https://h/x/foo.c3l.git/" -> "foo"
fn String name_of(String source) @private
{
	String s = source;
	while (s.ends_with("/")) s = s[:s.len - 1];
	if (try i = s.rindex_of_char('/')) s = s[i + 1..];
	if (try i = s.rindex_of_char(':')) s = s[i + 1..];
	return s.strip_suffix(".git").strip_suffix(".c3l");
}

fn String[] strings(Object* o, String key) @private
{
	List{String} out;
	out.tinit();
	if (!o.is_map()) return {};
	Object* list = o.get(key) ?? null;
	if (!list || !list.is_array()) return {};
	for (sz i = 0; i < list.get_len(); i++)
	{
		if (try s = list.get_string_at(i)) out.push(s);
	}
	return out.array_view();
}

fn Object*[] objects(Object* o, String key) @private
{
	List{Object*} out;
	out.tinit();
	Object* list = o.is_map() ? o.get(key) ?? null : null;
	if (!list || !list.is_array()) return {};
	for (sz i = 0; i < list.get_len(); i++)
	{
		if (list.get_at(i).is_map()) out.push(list.get_at(i));
	}
	return out.array_view();
}
