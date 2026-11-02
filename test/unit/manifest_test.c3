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
	assert(m.provides == "app" && m.version == "1.0.0" && m.has_vendor && m.has_c3l_requires);
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
	assert(m.provides == "x" && !m.version.len && !m.requires.len && !m.has_vendor);
	assert(@catch(manifest::parse("not json")));
}

fn void invalid_names_are_not_requirements() @test
{
	Manifest m = manifest::parse(`{ "provides": "x", "dependencies": [ "ok", "a\nevil\tgit", "../up" ] }`)!!;
	assert(m.requires.len == 1 && m.requires[0].name == "ok");
	assert(m.invalid == "a\nevil\tgit");
}
