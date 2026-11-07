module c3l::registry_test;

import c3l::registry;

fn void defaults_are_c3pkg_then_c3lang() @test
{
	Registry[] r = registry::configured({})!!;
	assert(r.len == 2 && r[0].name == "c3pkg" && r[1].name == "c3lang", "%d", r.len);
	assert(registry::names(r) == "c3pkg, c3lang");
}

fn void given_registries_replace_the_defaults() @test
{
	Registry[] r = registry::configured({ "c3lang" })!!;
	assert(r.len == 1 && r[0].name == "c3lang");
	r = registry::configured({ "https://r.example/x/", "c3pkg", "https://r.example/x" })!!;
	assert(r.len == 2 && r[0].url == "https://r.example/x" && r[1].name == "c3pkg", "trailing slash and duplicates");
	assert(@catch(registry::configured({ "nonsense" })));
	assert(@catch(registry::configured({ "ftp://x" })));
}

fn void publish_takes_one() @test
{
	assert(registry::publish_target({ "https://a.example" })!! == "https://a.example");
	assert(@catch(registry::publish_target({ "https://a.example", "https://b.example" })));
	assert(registry::publish_target({})!! == registry::defaults()[0].url, "the default list: c3pkg");
}
