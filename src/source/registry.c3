<*
 A c3c fetch registry, spoken to directly (the same protocol `c3c fetch` uses):

   <base>/info/<ns>/<name>         {library, description, latest, updated, tags,
                                    versions: {<version>: {checksum, size, url, ...}}}
   <base>/download/<ns>/<name>@<v> the .c3l archive, unless the version has a "url"
   <base>/index.json               {libraries: [{library, description, latest, tags}]}
                                    (c3pkg has none; it has <base>/search?q= instead)

 `base` is the URL as `c3c --fetch-url` takes it, without a trailing slash.
*>
module c3l::registry;

import std::io, std::os, std::collections::list, std::collections::object, std::encoding::json, std::net::url;
import c3l::http, c3l::log, c3l::lock, c3l::sys;

const String DEFAULT = "https://www.c3pkg.eu";

<*
 A registry c3l looks libraries up in. These are the defaults, in the order search
 lists them; `add` asks all of them and refuses when a library is in more than one.
*>
struct Registry
{
	String name;  // c3pkg, c3lang; the URL for one that was given as a URL
	String url;   // base URL
}

const Registry[] DEFAULTS = {
	{ "c3pkg", "https://www.c3pkg.eu" },
	{ "c3lang", "https://raw.githubusercontent.com/c3lang/vendor/refs/heads/registry" },
};

<*
 The defaults; $C3L_C3PKG_URL and $C3L_C3LANG_URL replace a URL (for tests and mirrors).
*>
fn Registry[] defaults()
{
	List{Registry} out;
	out.tinit();
	foreach (d : DEFAULTS)
	{
		String url = env::tget_var(string::tformat("C3L_%s_URL", d.name.to_upper_tcopy())) ?? "";
		out.push({ d.name, url.len ? base(url) : d.url });
	}
	return out.array_view();
}

<*
 The registries to use: the --registry values (URLs, or the names of the defaults), else
 the comma-separated $C3L_REGISTRY, else the defaults. Anything given replaces the defaults.
*>
fn Registry[]? configured(String[] given)
{
	String[] items = given;
	if (!items.len)
	{
		String env = env::tget_var("C3L_REGISTRY") ?? "";
		if (env.len) items = env.tsplit(",", skip_empty: true);
	}
	List{Registry} out;
	out.tinit();
	if (!items.len)
	{
		foreach (d : defaults()) out.push(d);
		return out.array_view();
	}
	foreach (raw : items)
	{
		String item = raw.trim();
		Registry r;
		if (item.starts_with("http://") || item.starts_with("https://"))
		{
			r = { base(item), base(item) };
		}
		else
		{
			bool known;
			foreach (d : defaults()) if (d.name == item) { r = d; known = true; }
			if (!known) return log::fail("unknown registry '%s': give a URL (https://...) or one of %s", item, default_names())~;
		}
		bool dup;
		foreach (have : out) if (have.url == r.url) dup = true;
		if (!dup) out.push(r);
	}
	return out.array_view();
}

// Whether the user chose the registries (--registry or $C3L_REGISTRY) instead of the defaults.
fn bool is_explicit(String[] given) => given.len > 0 || (env::tget_var("C3L_REGISTRY") ?? "").len > 0;

<*
 The registry `publish` uploads to: the one given, else the first default (c3pkg).
 Several given is an error: a package goes to one registry.
*>
fn String? publish_target(String[] given)
{
	Registry[] regs = configured(given)!;
	if (is_explicit(given) && regs.len > 1) return log::fail("publish uploads to one registry, but %d were given (%s)", regs.len, names(regs))~;
	return regs[0].url;
}

fn String default_names() => names(defaults());

// "c3pkg, c3lang"
fn String names(Registry[] regs)
{
	List{String} out;
	out.tinit();
	foreach (r : regs) out.push(r.name);
	return string::join(tmem, out.array_view(), ", ");
}

<*
 What a registry can do besides the fetch protocol:
   STATIC  any HTTP server or directory with the fetch protocol: read-only
   C3PKG   www.c3pkg.eu's API: published versions, per-version data, uploads
*>
enum Api : char (String name)
{
	STATIC { "static" },
	C3PKG { "c3pkg" },
}

faultdef UNREACHABLE, NO_SEARCH;

struct Info
{
	Object* record;
	String latest;
	Object* versions;
}

// "https://r/x//" -> "https://r/x"
fn String base(String url)
{
	while (url.ends_with("/")) url = url[:url.len - 1];
	return url;
}

// <namespace>/<name>
fn bool is_id(String s)
{
	return lock::valid_id(s);
}

// The library's record; UNREACHABLE when the registry has none or cannot be reached.
fn Info? info(String base, String id)
{
	Response r = http::get(string::tformat("%s/info/%s", base, id));
	if (!r.ok()) return UNREACHABLE~;
	return info_from(r.body);
}

// The info record in `body` (what <base>/info/<id> answered).
fn Info? info_from(String body)
{
	Object* o = json::tparse(body) ?? null;
	Object* versions = o && o.is_map() ? o.get("versions") ?? null : null;
	if (!versions || !versions.is_map()) return UNREACHABLE~;
	return { .record = o, .latest = o.get_string("latest") ?? "", .versions = versions };
}

fn void Info.print(&self)
{
	foreach (key : (String[]){ "library", "description", "latest", "updated" })
	{
		io::printfn("%-12s %s", string::tformat("%s:", key), self.record.get_string(key) ?? "");
	}
	io::printn("Versions:");
	self.versions.@each_entry(; String version, Object* v)
	{
		io::printfn("  %-16s %s", version, v.is_map() ? v.get_string("checksum") ?? "" : "");
	};
}

fn bool Info.has(&self, String version) => self.versions.has_key(version);

// The published versions that were not yanked (a yanked one is never offered, but `has` knows it).
fn String[] Info.list(&self)
{
	List{String} out;
	out.tinit();
	self.versions.@each_entry(; String version, Object* v)
	{
		if (!self.yanked(version)) out.push(version);
	};
	return out.array_view();
}

// "sha256:<hex>" as the registry lists it, empty if it lists none.
fn String Info.checksum(&self, String version)
{
	Object* v = self.versions.get(version) ?? null;
	return v && v.is_map() ? v.get_string("checksum") ?? "" : "";
}

<*
 Where the archive of `version` is: the version's own "url" in the info record
 (an http(s) URL, e.g. a release asset), else <base>/download/<id>@<version>.
*>
fn String Info.download_url(&self, String base, String id, String version)
{
	Object* v = self.versions.get(version) ?? null;
	String url = v && v.is_map() ? v.get_string("url") ?? "" : "";
	if (url.starts_with("http://") || url.starts_with("https://")) return url;
	return string::tformat("%s/download/%s@%s", base, id, version);
}

// The registry withdrew this version (c3pkg: yanked); it is still served for those who locked it.
fn bool Info.yanked(&self, String version)
{
	Object* v = self.versions.get(version) ?? null;
	return v && v.is_map() && (v.get_bool("yanked") ?? false);
}

fn Response download(String url, String file)
{
	return http::download(url, file);
}

struct Hit
{
	String name;
	String version;
	String about;
	String registry;  // where it was found (search_all)
}

<*
 The libraries matching `query` (or tagged `tag`): the registry's search API if
 it has one (c3pkg), else its index.json. `total` gets how many match in all;
 the search API returns only the first page.
*>
fn Hit[]? search(String base, String query, String tag, long* total, long timeout = 30)
{
	String q = string::tformat("%s/search?q=%s", base, url::encode(tmem, query, QUERY));
	if (tag.len) q = string::tformat("%s&tag=%s", q, url::encode(tmem, tag, QUERY));
	Object* found = libraries(q, timeout);
	bool filter = !found;
	if (filter) found = libraries(string::tformat("%s/index.json", base), timeout);
	if (!found) return NO_SEARCH~;

	Object* list = found.get("libraries")!!;
	List{Hit} hits;
	hits.tinit();
	for (sz i = 0; i < list.get_len(); i++)
	{
		Object* lib = list.get_at(i);
		String name = lib.get_string("library") ?? "";
		if (filter && (!name.contains(query) || (tag.len && !has_tag(lib, tag)))) continue;
		hits.push({ name, lib.get_string("latest") ?? "", lib.get_string("description") ?? "", "" });
	}
	*total = filter ? hits.len() : found.get_long("total") ?? hits.len();
	return hits.array_view();
}

// {libraries: [...]} from `url`, or null
fn Object* libraries(String url, long timeout) @private
{
	Response r = http::get(url, timeout);
	if (!r.ok()) return null;
	Object* o = json::tparse(r.body) ?? null;
	if (!o || !o.is_map()) return null;
	Object* list = o.get("libraries") ?? null;
	return list && list.is_array() ? o : null;
}

fn bool has_tag(Object* lib, String tag) @private
{
	Object* tags = lib.get("tags") ?? null;
	if (!tags || !tags.is_array()) return false;
	for (sz i = 0; i < tags.get_len(); i++) if ((tags.get_string_at(i) ?? "") == tag) return true;
	return false;
}

<*
 The registry's API: `forced` (--registry-type, $C3L_REGISTRY_TYPE) or detected
 by probing the c3pkg API; `guessed` tells which.
*>
fn Api? detect(String base, String forced, bool* guessed)
{
	*guessed = !forced.len;
	if (forced.len) return runtime::@enum_lookup(Api, "name", forced) ?? log::fail("unknown registry type '%s' (known: static, c3pkg)", forced)~!;
	if (!base.starts_with("http")) return STATIC;
	Response r = http::get(string::tformat("%s/api/v1/packages?per_page=1", base), 10);
	return r.ok() && (r.body.starts_with("{") || r.body.starts_with("[")) ? C3PKG : STATIC;
}

faultdef NO_PACKAGE;

// The published versions of `name` (c3pkg); NO_PACKAGE if it is new, UNREACHABLE if the registry cannot tell.
fn String[]? versions(String base, String name)
{
	Response r = http::get(string::tformat("%s/api/v1/packages/%s/versions", base, name));
	if (r.status == 404) return NO_PACKAGE~;
	Object* o = r.ok() ? json::tparse(r.body) ?? null : null;
	Object* list = o && o.is_map() ? o.get("versions") ?? null : null;
	if (!list || !list.is_array()) return UNREACHABLE~;
	List{String} out;
	out.tinit();
	for (sz i = 0; i < list.get_len(); i++)
	{
		Object* v = list.get_at(i);
		if (v.is_map()) out.push(v.get_string("version") ?? "");
	}
	return out.array_view();
}

// What the registry knows about one version (c3pkg): c3_version, targets, sha256_file.
fn Object*? index(String base, String id, String version)
{
	String name = id[(id.rindex_of_char('/') ?? -1) + 1..];
	Response r = http::get(string::tformat("%s/index/%s/%s.json", base, name, version));
	Object* o = r.ok() ? json::tparse(r.body) ?? null : null;
	if (!o || !o.is_map()) return UNREACHABLE~;
	return o;
}

<*
 Warn when a version was published for another C3 release or does not list
 this platform; false when it warned. Silent when the registry has no such data.
*>
fn bool compatible(String base, String id, String version)
{
	Object* o = index(base, id, version) ?? null;
	if (!o) return true;
	bool ok = true;
	String theirs = o.get_string("c3_version") ?? "";
	String mine = sys::c3_version();
	if (theirs.len && mine.len && minor(theirs) != minor(mine))
	{
		log::warn("%s@%s was published for C3 %s, you have c3c %s (C3 is pre-1.0: minor releases can break libraries)", id, version, theirs, mine);
		ok = false;
	}
	Object* targets = o.get("targets") ?? null;
	String host = sys::host_target();
	if (!host.len || !targets || !targets.is_array() || !targets.get_len()) return ok;
	List{String} list;
	list.tinit();
	for (sz i = 0; i < targets.get_len(); i++) list.push(targets.get_string_at(i) ?? "");
	if (list.contains(host)) return ok;
	log::warn("%s@%s does not list this platform (%s); it supports: %s", id, version, host, string::join(tmem, list.array_view(), ","));
	return false;
}

// "0.7.1" -> "0.7", "0.8" -> "0.8"
fn String minor(String v) @private
{
	String[] parts = v.tsplit(".");
	return parts.len < 2 ? v : string::tformat("%s.%s", parts[0], parts[1]);
}
