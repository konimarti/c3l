module c3l::manifest_test;

import c3l::manifest;

fn void requirements_in_precedence_order() @test
{
	Manifest m = manifest::parse(`{
		// JSONC: comments and trailing commas
		"provides": "app", "version": "1.0.0",
		"dependencies": [ "vk", "plain", "app" ],
		"targets": { "linux-x64": { "dependencies": [ "posixonly" ] }, },
		"vendor": {
			"c3l": { "requires": [ { "name": "vk", "source": "tonis2/vk", "version": "1.0.1", "registry": "https://r" } ] },
			"c3po": { "sources": [ { "source": "https://github.com/x/box2d.c3l.git" }, { "name": "vk", "source": "other" } ] },
		},
	}`)!!;
	assert(m.provides == "app" && m.version == "1.0.0");
	assert(m.dependencies.len == 3);
	assert(m.requires.len == 5, "%d", m.requires.len);
	Requirement vk = m.requires[0];
	assert(vk.name == "vk" && vk.source == "tonis2/vk" && vk.version == "1.0.1" && vk.registry == "https://r");
	assert(m.requires[1].name == "box2d" && m.requires[1].source.ends_with(".git"));
	assert(m.requires[2].name == "plain" && !m.requires[2].source.len);
	assert(m.requires[4].name == "posixonly");
	String[] names = m.require_names();
	assert(names.len == 4 && names[2] == "plain", "self is not a requirement");
}

fn void minimal() @test
{
	Manifest m = manifest::parse(`{ "provides": "x" }`)!!;
	assert(m.provides == "x" && !m.version.len && !m.requires.len);
	assert(@catch(manifest::parse("not json")));
}

fn void invalid_names_are_not_requirements() @test
{
	Manifest m = manifest::parse(`{ "provides": "x", "dependencies": [ "ok", "a\nevil\tgit", "../up" ] }`)!!;
	assert(m.requires.len == 1 && m.requires[0].name == "ok");
	assert(m.invalid == "a\nevil\tgit");
}

fn void requirements_from_the_library_lock() @test
{
	String c = "0123456789abcdef0123456789abcdef01234567";
	String d = "1111111111111111111111111111111111111111111111111111111111111111";
	String lock_text = string::tformat("# c3l.lock v1\n"
		"vk\tregistry\thttps://r\ttonis2/vk\t1.0.1\tsha256:%s\tsha256:%s\tdirect\t-\n"
		"gl\tgit\thttps://h/gl\t-\tcommit:%s\tcommit:%s\tcommit:%s\tdirect\t-\n"
		"tr\tregistry\thttps://r\tns/tr\t2.0.0\tsha256:%s\tsha256:%s\tdep\t-\n"
		"pd\tpath\t../pd\t-\t-\t-\t-\tdirect\t-\n", d, d, c[:12], c, c, d, d);
	Manifest m = manifest::parse(`{ "provides": "x", "dependencies": [ "vk", "gl" ],
		"vendor": { "c3l": { "requires": [ { "name": "gl", "source": "https://h/other" } ] } } }`, lock_text)!!;
	assert(m.requires.len == 2, "%d", m.requires.len);
	assert(m.requires[0].name == "gl" && m.requires[0].source == "https://h/other", "the manifest's block wins");
	Requirement vk = m.requires[1];
	assert(vk.source == "tonis2/vk" && vk.registry == "https://r" && vk.version == "1.0.1");
	Manifest bad = manifest::parse(`{ "provides": "x" }`, "x\tgit\n")!!;
	assert(bad.notes.len == 1 && !bad.requires.len, "a broken lock is a note, not an error");
}

fn void unknown_c3po_version_is_not_followed() @test
{
	Manifest m = manifest::parse(`{ "provides": "x", "vendor": { "c3po": { "c3po-version": 2, "sources": [ { "name": "a", "source": "https://h/a" } ] } } }`)!!;
	assert(!m.requires.len && m.notes.len == 1);
	m = manifest::parse(`{ "provides": "x", "vendor": { "c3po": { "c3po-version": 1, "sources": [ { "name": "a", "source": "https://h/a" } ] } } }`)!!;
	assert(m.requires.len == 1 && !m.notes.len);
}

fn void c3po_sources_at_the_locked_commit() @test
{
	String text = `{ "provides": "x", "vendor": { "c3po": { "sources": [ { "name": "a", "source": "https://h/a" }, { "name": "b", "source": "https://h/b" } ] } } }`;
	String sha = "0123456789abcdef0123456789abcdef01234567";
	String c3po_lock = string::tformat(`{ "packages": [ { "name": "a", "commit": "%s" }, { "name": "b", "commit": "short" } ] }`, sha);
	Manifest m = manifest::parse(text, "", c3po_lock)!!;
	assert(m.requires.len == 2);
	assert(m.requires[0].version == sha, "a: %s", m.requires[0].version);
	assert(m.requires[1].version == "", "b: not a commit, so any version");
	assert(manifest::parse(text)!!.requires[0].version == "", "without project.lock.json: any version");
}

fn void dependency_paths_as_c3c_writes_them() @test
{
	String sum = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
	Manifest m = manifest::parse(string::tformat(`{ "provides": "x", "dependencies": [
		"plain", "ns/a", "ns/b@1.2.3", "https://r.example:8080:ns/c@2.0.0", "ns/d@1.0.0:%s",
		"http://h:ns/e", ], "targets": { "linux-x64": { "dependencies": [ "ns/f@0.1.0" ] } } }`, sum))!!;
	assert(m.requires.len == 7, "%d", m.requires.len);
	assert(m.requires[0].name == "plain" && !m.requires[0].source.len);
	assert(m.requires[1].name == "a" && m.requires[1].source == "ns/a" && !m.requires[1].version.len);
	assert(m.requires[2].name == "b" && m.requires[2].version == "1.2.3" && !m.requires[2].registry.len);
	assert(m.requires[3].name == "c" && m.requires[3].registry == "https://r.example:8080" && m.requires[3].version == "2.0.0");
	assert(m.requires[4].name == "d" && m.requires[4].checksum == string::tformat("sha256:%s", sum));
	assert(m.requires[5].name == "e" && m.requires[5].registry == "http://h");
	assert(m.requires[6].name == "f" && m.requires[6].source == "ns/f");
	assert(!m.invalid.len);
	assert(m.entries.len == 7 && m.entries[1] == "ns/a");
}

fn void invalid_dependency_paths() @test
{
	String sum = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
	String[] bad = {
		string::tformat("ns/a:%s", sum),   // a checksum needs a version
		"ftp://h:ns/a@1.0.0",              // the url is http(s)
		"ns/a@1.0.0:xyz",                  // not a checksum, not a url
		"ns/a/b/c",                        // namespace/name only
		"ns/a@",                           // empty version
	};
	foreach (b : bad)
	{
		Manifest m = manifest::parse(string::tformat(`{ "provides": "x", "dependencies": [ "%s" ] }`, b))!!;
		assert(m.invalid == b && !m.requires.len, "%s", b);
	}
}

fn void bare_names() @test
{
	assert(manifest::bare_name("vk") == "vk");
	assert(manifest::bare_name("tonis2/vk@1.0.1") == "vk");
	assert(manifest::bare_name("https://h:8080:tonis2/vk") == "vk");
	assert(manifest::bare_name("not a/path@") == "not a/path@", "an invalid entry stays as it is");
}
