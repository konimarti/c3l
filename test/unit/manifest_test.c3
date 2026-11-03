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
