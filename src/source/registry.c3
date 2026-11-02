<*
 A c3c fetch registry, spoken to directly (the same protocol `c3c fetch` uses):

   <base>/info/<ns>/<name>         {library, description, latest, updated, tags,
                                    versions: {<version>: {checksum, ...}}}
   <base>/download/<ns>/<name>@<v> the .c3l archive
   <base>/index.json               {libraries: [{library, description, latest, tags}]}

 `base` is the URL as `c3c --fetch-url` takes it, without a trailing slash.
*>
module c3l::registry;

import std::io, std::collections::object, std::encoding::json, std::net::url;
import c3l::http, c3l::log, c3l::lock;

const String DEFAULT = "https://www.c3pkg.eu";

faultdef UNREACHABLE;

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
	String[] parts = s.tsplit("/");
	return parts.len == 2 && lock::valid_name(parts[0]) && lock::valid_name(parts[1]);
}

// The library's record; UNREACHABLE when the registry has none or cannot be reached.
fn Info? info(String base, String id)
{
	Response r = http::get(string::tformat("%s/info/%s", base, id));
	Object* o = r.ok() ? json::tparse(r.body) ?? null : null;
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

// "sha256:<hex>" as the registry lists it, empty if it lists none.
fn String Info.checksum(&self, String version)
{
	Object* v = self.versions.get(version) ?? null;
	return v && v.is_map() ? v.get_string("checksum") ?? "" : "";
}

fn bool download(String base, String id, String version, String file)
{
	return http::download(string::tformat("%s/download/%s@%s", base, id, version), file).ok();
}

<*
 Print the libraries matching `query` (or tagged `tag`): the registry's search
 API if it has one (c3pkg), else its index.json.
*>
fn void? search(String base, String query, String tag)
{
	String q = string::tformat("%s/search?q=%s", base, url::encode(tmem, query, QUERY));
	if (tag.len) q = string::tformat("%s&tag=%s", q, url::encode(tmem, tag, QUERY));
	Object* found = libraries(q);
	bool filter = !found;
	if (filter) found = libraries(string::tformat("%s/index.json", base));
	if (!found) return log::fail("search failed: %s has no search API and no index.json", base)~;

	Object* list = found.get("libraries")!!;
	sz shown;
	for (sz i = 0; i < list.get_len(); i++)
	{
		Object* lib = list.get_at(i);
		String name = lib.get_string("library") ?? "";
		if (filter && (!name.contains(query) || (tag.len && !has_tag(lib, tag)))) continue;
		io::printfn("%-32s %-10s %s", name, lib.get_string("latest") ?? "", lib.get_string("description") ?? "");
		shown++;
	}
	long total = found.get_long("total") ?? shown;
	io::printfn("(%d of %d shown)", shown, filter ? shown : total);
}

// {libraries: [...]} from `url`, or null
fn Object* libraries(String url) @private
{
	Response r = http::get(url);
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
