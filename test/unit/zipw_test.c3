module c3l::zipw_test;

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
