module c3l::jsonedit_test;

import c3l::jsonedit;

const String JSON5 = `{
  // top comment with "dependencies": [ "decoy" ]
  "langrev": "1",
  "dependency-search-paths": [ "lib" ],
  "dependencies": [
    "one", // first
    "two"
  ],
  "targets": {
    "app": { "type": "executable", "dependencies": [ "targetonly" ] },
  },
}`;

fn void add_del_keep_the_rest() @test
{
	String s = jsonedit::edit_array(JSON5, "dependencies", "three", true);
	assert(s.contains(`"dependencies": [ "one", "two", "three" ],`), "%s", s);
	assert(s.contains(`[ "decoy" ]`) && s.contains(`[ "targetonly" ]`) && s.contains(`"dependency-search-paths": [ "lib" ]`));
	assert(jsonedit::edit_array(s, "dependencies", "three", true) == s, "add is idempotent");

	s = jsonedit::edit_array(s, "dependencies", "two", false);
	assert(s.contains(`"dependencies": [ "one", "three" ],`), "%s", s);
	assert(jsonedit::edit_array(s, "dependencies", "nothere", false) == s, "del missing is a no-op");

	s = jsonedit::edit_array(jsonedit::edit_array(s, "dependencies", "one", false), "dependencies", "three", false);
	assert(s.contains(`"dependencies": [],`), "%s", s);
}

fn void add_missing_key() @test
{
	String s = jsonedit::edit_array(`{ "dependency-search-paths": [ "lib" ], "targets": { "app": {} } }`, "dependencies", "first", true);
	assert(s == "{\n  \"dependencies\": [ \"first\" ], \"dependency-search-paths\": [ \"lib\" ], \"targets\": { \"app\": {} } }", "%s", s);
	assert(jsonedit::edit_array(`{ "a": 1 }`, "dependencies", "x", false) == `{ "a": 1 }`);
}

fn void other_key_and_single_quotes() @test
{
	String s = jsonedit::edit_array(`{ 'dependency-search-paths': [], "x": "dependency-search-paths" }`, "dependency-search-paths", "lib", true);
	assert(s == `{ 'dependency-search-paths': [ "lib" ], "x": "dependency-search-paths" }`, "%s", s);
}

fn void set_top_level_string() @test
{
	String m = `{
  "targets-note" : { "version" : "9" },
  // "version": "0"
  "provides" : "demo",
  "version" : "0.1.0"
}`;
	String s = jsonedit::set_string(m, "version", "1.2.0");
	assert(s.contains(`"version" : "1.2.0"`) && s.contains(`{ "version" : "9" }`) && s.contains(`// "version": "0"`), "%s", s);
	assert(jsonedit::set_string(`{ "provides": "x" }`, "version", "1.0.0") == "{\n  \"version\" : \"1.0.0\", \"provides\": \"x\" }");
}

fn void broken_files_are_left_alone() @test
{
	String[] broken = { `{ "dependencies": [ "a", `, `{ "dependencies": [ "a" /* x `, `{ "dependencies": [ "a`, `{ "x": "`, `` };
	foreach (t : broken) assert(jsonedit::edit_array(t, "dependencies", "b", true) == t, "%s", t);
	assert(jsonedit::set_string(`{ "version": "1.0`, "version", "2.0.0") == `{ "version": "1.0`);
}

fn void json5_edge_cases() @test
{
	assert(jsonedit::edit_array(`{ "dependencies": [ ["x"], "a" ] }`, "dependencies", "b", true) == `{ "dependencies": [ "a", "b" ] }`);
	assert(jsonedit::edit_array(`{ dependencies: [ "a" ], other: 1 }`, "dependencies", "b", true) == `{ dependencies: [ "a", "b" ], other: 1 }`);
	assert(jsonedit::edit_array(`{}`, "dependencies", "a", true) == "{\n  \"dependencies\": [ \"a\" ]\n}");
	assert(jsonedit::edit_array(`{ 'dependencies': [ 'it\'s', 'say "hi"' ] }`, "dependencies", "b", true)
		== `{ 'dependencies': [ "it's", "say \"hi\"", "b" ] }`);
	assert(jsonedit::set_string(`{ version: "1.0.0" }`, "version", "2.0.0") == `{ version: "2.0.0" }`);
}
