<*
 c3c's vendor collection (vendor:<name>): the .c3l files of one rolling GitHub
 release. There are no versions, so what c3l pins is the file's sha256, which
 the GitHub API lists for every asset.
*>
module c3l::vendor;

import std::os, std::collections::list, std::collections::object, std::encoding::json;
import c3l::http;

fn String url() => env::tget_var("C3L_VENDOR_URL") ?? "https://github.com/c3lang/vendor/releases/download/latest";
fn String api() => env::tget_var("C3L_VENDOR_API") ?? "https://api.github.com/repos/c3lang/vendor/releases/tags/latest";

faultdef UNREACHABLE, NOT_LISTED;

struct Asset
{
	String name;    // library name, without .c3l
	String digest;  // sha256:<hex>, empty if GitHub lists none
}

// UNREACHABLE when the GitHub API cannot be read.
fn Asset[]? assets()
{
	Response r = http::get(api());
	Object* o = r.ok() ? json::tparse(r.body) ?? null : null;
	Object* list = o && o.is_map() ? o.get("assets") ?? null : null;
	if (!list || !list.is_array()) return UNREACHABLE~;
	List{Asset} out;
	out.tinit();
	for (sz i = 0; i < list.get_len(); i++)
	{
		Object* a = list.get_at(i);
		if (!a.is_map()) continue;
		String name = a.get_string("name") ?? "";
		if (!name.ends_with(".c3l")) continue;
		out.push({ name.strip_suffix(".c3l"), a.get_string("digest") ?? "" });
	}
	return out.array_view();
}

// NOT_LISTED when there is no such library.
fn Asset? find(String name)
{
	foreach (a : assets()!) if (a.name == name) return a;
	return NOT_LISTED~;
}
