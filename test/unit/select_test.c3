module c3l::select_test;

import std::io, c3l::select;

const String[] PLATFORMS = { "linux-x64", "macos-x64", "macos-aarch64", "windows-x64" };

fn String paths(Selection s)
{
	DString d = dstring::temp();
	foreach (p : s.picked) d.appendf("%s ", p.path);
	return d.str_view().trim();
}

fn String rule_of(Selection s, String path)
{
	foreach (p : s.picked) if (p.path == path) return p.rule;
	return "";
}

fn void no_sources_takes_the_top_directory_only() @test
{
	String[] files = { "manifest.json", "a.c3", "b.c3i", "tools/x.c3", ".github/ci.yml", "project.json", "LICENSE", "README.md", "notes.txt" };
	Selection s = select::choose(`{ "provides": "x" }`, files, {}, PLATFORMS, false);
	assert(s.errors.len == 0, "%s", s.errors);
	assert(paths(s) == "LICENSE README.md a.c3 b.c3i manifest.json", "%s", paths(s));
	assert(rule_of(s, "LICENSE") == "licence" && rule_of(s, "README.md") == "readme" && rule_of(s, "manifest.json") == "manifest");
	assert(s.left_out.len == 4);
}

fn void double_star_directories_and_wildcards() @test
{
	String[] files = { "manifest.json", "src/a.c3", "src/deep/b.c3", "src/deep/c.c3t", "src/.hid/h.c3", "src/n.txt", "x/y.c3", "x/z/w.c3", "o/p.c3" };
	Selection s = select::choose(`{ "provides": "x", "sources": [ "src/**", "x/*", "o" ] }`, files, {}, PLATFORMS, false);
	assert(s.errors.len == 0, "%s", s.errors);
	assert(paths(s) == "manifest.json o/p.c3 src/a.c3 src/deep/b.c3 src/deep/c.c3t x/y.c3", "%s", paths(s));
	assert(rule_of(s, "x/y.c3") == "source pattern x/*");
}

fn void targets_and_overrides() @test
{
	String[] files = { "manifest.json", "top.c3", "a/x.c3", "b/y.c3", "c/z.c3" };
	String m = `{ "provides": "x", "sources": [ "top.c3" ], "targets": { "linux-x64": { "sources": [ "a/**" ], "sources-override": [ "b" ] }, "macos-x64": { "sources": [ "./c/*" ] } } }`;
	Selection s = select::choose(m, files, {}, PLATFORMS, false);
	assert(s.errors.len == 0, "%s", s.errors);
	assert(paths(s) == "a/x.c3 b/y.c3 c/z.c3 manifest.json top.c3", "%s", paths(s));
}

fn void top_directory_when_a_target_has_no_sources() @test
{
	String[] files = { "manifest.json", "top.c3", "a/x.c3" };
	Selection s = select::choose(`{ "provides": "x", "targets": { "linux-x64": { "sources": [ "a/**" ] }, "macos-x64": {} } }`, files, {}, PLATFORMS, false);
	assert(paths(s) == "a/x.c3 manifest.json top.c3", "%s", paths(s));
	s = select::choose(`{ "provides": "x", "targets": { "linux-x64": { "sources": [ "a/**" ] } } }`, files, {}, PLATFORMS, false);
	assert(paths(s) == "a/x.c3 manifest.json", "%s", paths(s));
}

fn void c_sources_headers_and_include_dirs() @test
{
	String[] files = {
		"manifest.json", "c/one.c", "c/one.h", "c/two.hpp", "c/note.txt", "c/sub/s.c", "c/sub/s.h",
		"inc/i.h", "inc/deep/d.h", "inc/other.c", "m/a.m", "m/a.inc",
	};
	String m = `{ "provides": "x", "sources": [], "c-sources": [ "c/one.c", "m/*" ], "c-include-dirs": [ "inc" ] }`;
	Selection s = select::choose(m, files, {}, PLATFORMS, false);
	assert(s.errors.len == 0, "%s", s.errors);
	assert(paths(s) == "c/one.c c/one.h c/two.hpp inc/deep/d.h inc/i.h m/a.inc m/a.m manifest.json", "%s", paths(s));
	assert(rule_of(s, "c/one.h") == "header" && rule_of(s, "inc/i.h") == "header" && rule_of(s, "m/a.m") == "source pattern m/*");
}

fn void platform_libraries_and_the_os_fallback() @test
{
	String[] files = { "manifest.json", "linux-x64/libx.a", "macos/libx.a", "macos/sub/y.a", "windows-x64/x.lib", "elf-x64/q.a", "other/z.a" };
	Selection s = select::choose(`{ "provides": "x", "targets": { "linux-x64": {}, "macos-x64": {} } }`, files, {}, PLATFORMS, false);
	assert(paths(s) == "linux-x64/libx.a macos/libx.a macos/sub/y.a manifest.json", "%s", paths(s));
	assert(rule_of(s, "macos/libx.a") == "platform library macos");
	// without targets: every platform c3c knows, only those that exist
	s = select::choose(`{ "provides": "x" }`, files, {}, PLATFORMS, false);
	assert(paths(s) == "linux-x64/libx.a macos/libx.a macos/sub/y.a manifest.json windows-x64/x.lib", "%s", paths(s));
	// linklib-dir
	String[] nested = { "manifest.json", "libs/linux-x64/a.a", "linux-x64/b.a" };
	s = select::choose(`{ "provides": "x", "linklib-dir": "libs", "targets": { "linux-x64": {} } }`, nested, {}, PLATFORMS, false);
	assert(paths(s) == "libs/linux-x64/a.a manifest.json", "%s", paths(s));
}

fn void exec_names_files() @test
{
	String[] files = { "manifest.json", "build.sh", "scripts/gen.py", "other.sh" };
	Selection s = select::choose(`{ "provides": "x", "exec": [ "sh ./build.sh" ], "targets": { "linux-x64": { "exec": [ "python3 'scripts/gen.py' --x" ] } } }`, files, {}, PLATFORMS, false);
	assert(paths(s) == "build.sh manifest.json scripts/gen.py", "%s", paths(s));
	assert(rule_of(s, "build.sh") == "exec");
	assert(s.warnings.len == 1);
}

fn void lock_by_entries() @test
{
	String[] files = { "manifest.json", "c3l.lock" };
	assert(paths(select::choose(`{ "provides": "x" }`, files, {}, PLATFORMS, true)) == "c3l.lock manifest.json");
	assert(paths(select::choose(`{ "provides": "x" }`, files, {}, PLATFORMS, false)) == "manifest.json");
}

fn void problems() @test
{
	String[] files = { "manifest.json", "a.c3", "src/b.c3" };
	String[] ignored = { "gen/g.c3", "gen/h.c3" };
	Selection s = select::choose(`{ "provides": "x", "sources": [ "gen/**" ] }`, files, ignored, PLATFORMS, false);
	assert(s.errors.len == 1 && s.errors[0].contains("gen/**") && s.errors[0].contains("ignores"), "%s", s.errors);
	s = select::choose(`{ "provides": "x", "sources": [ "../x/**", "/abs/a.c3", "a/../../b.c3" ] }`, files, {}, PLATFORMS, false);
	assert(s.errors.len == 3, "%s", s.errors);
	s = select::choose(`{ "provides": "x", "sources": [ "missing.c3", "nothing/**", "a.txt" ] }`, files, {}, PLATFORMS, false);
	assert(s.errors.len == 1 && s.warnings.len == 2, "%s %s", s.errors, s.warnings);
	s = select::choose(`{ "provides": "x", "linklib-dir": "../up" }`, files, {}, PLATFORMS, false);
	assert(s.errors.len == 1);
	s = select::choose(`{ "provides": "x" }`, { "a.c3" }, {}, PLATFORMS, false);
	assert(s.errors.len == 1, "no manifest.json");
}

fn void normalize_like_c3c() @test
{
	assert(select::normalize("./a\\b/")!! == "a/b");
	assert(select::normalize(".")!! == "" && select::normalize("./")!! == "");
	assert(@catch(select::normalize("../a")));
	assert(@catch(select::normalize("a/../b")));
	assert(@catch(select::normalize("/a")));
	assert(@catch(select::normalize("C:/a")));
	assert(@catch(select::normalize("")));
}
