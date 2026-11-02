module c3l::publish_test;

import std::io, std::compression::zip, c3l::publish, c3l::sys;

fn void deterministic_and_readable() @test
{
	String dir = sys::temp_dir()!!;
	defer sys::remove(dir);
	(void)path::mkdir(string::tformat("%s/src", dir));
	file::save(string::tformat("%s/manifest.json", dir), `{ "provides": "x" }`)!!;
	file::save(string::tformat("%s/src/x.c3", dir), "module x;\n")!!;
	String[] names = { "manifest.json", "src/x.c3" };
	String a = string::tformat("%s/a.c3l", dir);
	String b = string::tformat("%s/b.c3l", dir);
	publish::write_zip(dir, names, a)!!;
	publish::write_zip(dir, names, b)!!;
	assert(sys::sha256_file(a)!! == sys::sha256_file(b)!!);

	ZipArchive z = zip::open(tmem, a)!!;
	defer (void)z.close();
	assert(z.count() == 2);
	assert((String)z.read_file_all(tmem, "src/x.c3")!! == "module x;\n");
}

fn void requires_from_the_lock() @test
{
	String dir = sys::temp_dir()!!;
	defer sys::remove(dir);
	String c = "0123456789abcdef0123456789abcdef01234567";
	String d = "1111111111111111111111111111111111111111111111111111111111111111";
	file::save(string::tformat("%s/c3l.lock", dir), string::tformat(
		"# c3l.lock v1\n"
		"a\tgit\thttps://h/a\t-\tcommit:%s\tcommit:%s\tcommit:%s\tdirect\t-\n"
		"b\tgit\thttps://h/b\t-\tHEAD\tcommit:%s\tcommit:%s\tdirect\t-\n"
		"r\tregistry\thttps://r\tns/r\t1.2.0\tsha256:%s\tsha256:%s\tdirect\t-\n"
		"t\tregistry\thttps://r\tns/t\t1.0.0\tsha256:%s\tsha256:%s\tdep\t-\n",
		c[:12], c, c, c, c, d, d, d, d))!!;
	String json = publish::requires_json(dir);
	assert(json.contains(string::tformat(`"source": "https://h/a", "version": "commit:%s"`, c)), "full commit: %s", json);
	assert(json.contains(`{ "name": "b", "source": "https://h/b" }`), "HEAD has no version: %s", json);
	assert(json.contains(`"source": "ns/r", "registry": "https://r", "version": "1.2.0"`), "%s", json);
	assert(!json.contains(`"t"`), "only direct dependencies: %s", json);
}
