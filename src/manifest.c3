<*
 A library's manifest.json, read from a directory or from inside a .c3l archive.

 What a library requires, per name, in this order of precedence:
   vendor.c3l.requires   [{name, source, version, registry}]  c3l's own block
   vendor.c3po.sources   [{name, source}]                     read-only c3po compatibility
   dependencies          names only (top level and per target), no source
*>
module c3l::manifest;

import std::io, std::collections::list, std::collections::object, std::encoding::json;
import std::compression::zip;

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
	bool has_vendor;        // there is a "vendor" block
	bool has_c3l_requires;  // ... and it has vendor.c3l.requires
}

faultdef NO_MANIFEST, BAD_MANIFEST;

// From a library directory, or a .c3l file (zip archive).
fn Manifest? load(String path)
{
	if (file::is_dir(path)) return load_file(string::tformat("%s/manifest.json", path));
	ZipArchive archive = zip::open(tmem, path) ?? NO_MANIFEST~!;
	defer (void)archive.close();
	char[] data = archive.read_file_all(tmem, "manifest.json") ?? NO_MANIFEST~!;
	return parse((String)data);
}

fn Manifest? load_file(String file)
{
	char[] data = file::load_temp(file) ?? NO_MANIFEST~!;
	return parse((String)data);
}

fn Manifest? parse(String text)
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
	if (try vendor = root.get("vendor"))
	{
		m.has_vendor = true;
		if (try c3l = vendor.get("c3l"))
		{
			m.has_c3l_requires = c3l.has_key("requires");
			foreach (r : objects(c3l, "requires"))
			{
				add(&reqs, {
					.name = r.get_string("name") ?? "",
					.source = r.get_string("source") ?? "",
					.version = r.get_string("version") ?? "",
					.registry = r.get_string("registry") ?? "",
				});
			}
		}
		if (try c3po = vendor.get("c3po"))
		{
			foreach (r : objects(c3po, "sources"))
			{
				add(&reqs, { .name = r.get_string("name") ?? "", .source = r.get_string("source") ?? "" });
			}
		}
	}
	foreach (d : m.dependencies) add(&reqs, { .name = d });
	if (try targets = root.get("targets"))
	{
		targets.@each_entry(; String key, Object* target)
		{
			foreach (d : strings(target, "dependencies")) add(&reqs, { .name = d });
		};
	}
	m.requires = reqs.array_view();
	return m;
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
fn void add(List{Requirement}* reqs, Requirement r) @private
{
	if (!r.name.len) r.name = name_of(r.source);
	if (!r.name.len) return;
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
	if (s.ends_with(".git")) s = s[:s.len - 4];
	if (s.ends_with(".c3l")) s = s[:s.len - 4];
	return s;
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
