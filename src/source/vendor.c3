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

struct Library
{
	String name;
	String about;
}

// The collection when this c3l was released, so 'c3l search' needs no GitHub
// API call; 'c3l add vendor' lists the live collection.
const Library[] SNAPSHOT = {
	{ "box2d", "Box2D 2D physics engine" },
	{ "clang", "libclang, the C interface to Clang" },
	{ "curl", "libcurl, URL transfers (HTTP, FTP, ...)" },
	{ "glfw", "GLFW windows, OpenGL/Vulkan contexts and input" },
	{ "glfw34", "GLFW 3.4 windows, OpenGL/Vulkan contexts and input" },
	{ "ktx", "KTX texture files (Khronos)" },
	{ "lmdb", "LMDB key-value database" },
	{ "lz4", "LZ4 compression" },
	{ "microui", "microui immediate-mode UI" },
	{ "mysql8", "MySQL 8 client" },
	{ "opengl", "OpenGL" },
	{ "pq", "libpq, PostgreSQL client" },
	{ "raylib5", "raylib 5 games library" },
	{ "raylib55", "raylib 5.5 games library" },
	{ "raylib6", "raylib 6 games library" },
	{ "sdl2", "SDL 2 media and input" },
	{ "sdl3", "SDL 3 media and input" },
	{ "sdl3_image", "SDL3_image image loading" },
	{ "sdl3_ttf", "SDL3_ttf TrueType fonts" },
	{ "spng", "libspng PNG decoding and encoding" },
	{ "sqlite3", "SQLite 3 database" },
	{ "tigr", "TIGR tiny graphics library" },
	{ "tinyfiledialogs", "native file and message dialogs" },
	{ "tracy", "Tracy frame profiler" },
	{ "tree_sitter", "tree-sitter incremental parsing" },
	{ "vulkan", "Vulkan" },
	{ "webgpu", "WebGPU" },
};

struct Asset
{
	String name;    // library name, without .c3l
	String digest;  // sha256:<hex>, empty if GitHub lists none
}

Asset[] cached @private;  // read once per command: the GitHub API allows 60 requests an hour

// UNREACHABLE when the GitHub API cannot be read.
fn Asset[]? assets()
{
	if (cached.len) return cached;
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
	cached = out.array_view();
	return cached;
}

// NOT_LISTED when there is no such library.
fn Asset? find(String name)
{
	foreach (a : assets()!) if (a.name == name) return a;
	return NOT_LISTED~;
}
