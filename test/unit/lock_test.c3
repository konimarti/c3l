module c3l::lock_test;

import std::io, c3l::lock;

const String SAMPLE = lock::HEADER +++
	"app\tgit\thttps://h/app\t-\tv1.0.0\tcommit:abc\tcommit:abc\tdirect\tmid\n"
	"mid\tregistry\thttps://r\tns/mid\t1.2.0\tsha256:x\tsha256:x\tdep\tleaf,app\n"
	"leaf\tvendor\thttps://v\tleaf\tlatest\tsha256:y\tsha256:y\tdep\t-\n"
	"lost\tpath\t../lost\t-\t-\t-\t-\tdep\t-\n";

fn String tmp_lock(String content)
{
	String f = string::tformat("%s/c3l-lock-test.lock", path::temp_directory(tmem)!!);
	file::save(f, content)!!;
	return f;
}

fn void round_trip() @test
{
	String f = tmp_lock(SAMPLE);
	Lock l = lock::load(f)!!;
	assert(l.entries.len() == 4);
	Entry* mid = l.get("mid")!!;
	assert(mid.kind == REGISTRY && mid.role == DEP && mid.id == "ns/mid");
	assert(mid.requires.len == 2 && mid.requires[1] == "app");
	assert(l.get("leaf")!!.requires.len == 0);
	l.save()!!;
	String back = (String)file::load_temp(f)!!;
	assert(back.starts_with(lock::HEADER));
	assert(back.contains("\nleaf\tvendor") && back.index_of("app\t")!! < back.index_of("leaf\t")!!);
	assert(back.contains("\tdep\t-\n"));
	assert(lock::load(f)!!.entries.len() == 4);
	file::delete(f);
}

fn void old_format_refused() @test
{
	String f = tmp_lock(lock::HEADER +++ "a\tgit\turl\t-\tv1\tcommit:x\tcommit:x\n");
	assert(@catch(lock::load(f)));
	file::delete(f);
}

fn void put_del() @test
{
	String f = tmp_lock(SAMPLE);
	Lock l = lock::load(f)!!;
	l.put({ .name = "mid", .kind = GIT, .role = DIRECT });
	assert(l.entries.len() == 4 && l.get("mid")!!.kind == GIT);
	l.put({ .name = "new", .kind = PATH });
	assert(l.entries.len() == 5);
	l.del("new");
	assert(!l.has("new") && l.entries.len() == 4);
	file::delete(f);
}

fn void graph() @test
{
	String f = tmp_lock(SAMPLE);
	Lock l = lock::load(f)!!;
	assert(l.reaches("app", "leaf"));
	assert(l.reaches("mid", "app"));   // cycle app -> mid -> app
	assert(!l.reaches("leaf", "app"));
	String[] d = l.dependents("app");
	assert(d.len == 1 && d[0] == "mid");
	String[] o = l.orphans();
	assert(o.len == 1 && o[0] == "lost");
	file::delete(f);
}
