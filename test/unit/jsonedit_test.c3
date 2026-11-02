module c3l::jsonedit_test;

import c3l::project;

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
	String s = project::edit_array(JSON5, "dependencies", "three", true);
	assert(s.contains(`"dependencies": [ "one", "two", "three" ],`), "%s", s);
	assert(s.contains(`[ "decoy" ]`) && s.contains(`[ "targetonly" ]`) && s.contains(`"dependency-search-paths": [ "lib" ]`));
	assert(project::edit_array(s, "dependencies", "three", true) == s, "add is idempotent");

	s = project::edit_array(s, "dependencies", "two", false);
	assert(s.contains(`"dependencies": [ "one", "three" ],`), "%s", s);
	assert(project::edit_array(s, "dependencies", "nothere", false) == s, "del missing is a no-op");

	s = project::edit_array(project::edit_array(s, "dependencies", "one", false), "dependencies", "three", false);
	assert(s.contains(`"dependencies": [],`), "%s", s);
}

fn void add_missing_key() @test
{
	String s = project::edit_array(`{ "dependency-search-paths": [ "lib" ], "targets": { "app": {} } }`, "dependencies", "first", true);
	assert(s == "{\n  \"dependencies\": [ \"first\" ], \"dependency-search-paths\": [ \"lib\" ], \"targets\": { \"app\": {} } }", "%s", s);
	assert(project::edit_array(`{ "a": 1 }`, "dependencies", "x", false) == `{ "a": 1 }`);
}

fn void other_key_and_single_quotes() @test
{
	String s = project::edit_array(`{ 'dependency-search-paths': [], "x": "dependency-search-paths" }`, "dependency-search-paths", "lib", true);
	assert(s == `{ 'dependency-search-paths': [ "lib" ], "x": "dependency-search-paths" }`, "%s", s);
}
