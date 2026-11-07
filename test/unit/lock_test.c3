module c3l::lock_test;

import std::io, c3l::lock, c3l::sys;

const String SAMPLE = lock::HEADER +++
	"app\tgit\thttps://h/app\t-\tv1.0.0\tcommit:0123456789abcdef0123456789abcdef01234567\tcommit:0123456789abcdef0123456789abcdef01234567\tdirect\tmid\n"
	"mid\tregistry\thttps://r\tns/mid\t1.2.0\tsha256:1111111111111111111111111111111111111111111111111111111111111111\tsha256:1111111111111111111111111111111111111111111111111111111111111111\tdep\tleaf,app\n"
	"leaf\tregistry\thttps://v\tc3lang/leaf\t1.0.0\tsha256:2222222222222222222222222222222222222222222222222222222222222222\tsha256:2222222222222222222222222222222222222222222222222222222222222222\tdep\t-\n"
	"lost\tpath\t../lost\t-\t-\t-\t-\tdep\t-\n";

fn void drop(String lock_file) => sys::remove(lock_file[:lock_file.rindex_of_char('/')!!]);

// A lockfile in a fresh temporary directory (parallel runs do not collide).
fn String tmp_lock(String content)
{
	String f = string::tformat("%s/c3l.lock", sys::temp_dir()!!);
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
	assert(back.contains("\nleaf\tregistry") && back.index_of("app\t")!! < back.index_of("leaf\t")!!);
	assert(back.contains("\tdep\t-\n"));
	assert(lock::load(f)!!.entries.len() == 4);
	drop(f);
}

fn void vendor_lines_point_to_migrate() @test
{
	String why;
	String z = "sha256:0000000000000000000000000000000000000000000000000000000000000000";
	Lock? l = lock::parse(string::tformat("%s%s", lock::HEADER, string::tformat("x\tvendor\thttps://v\tx\tlatest\t%s\t%s\tdirect\t-\n", z, z)), "c3l.lock", &why);
	assert(@catch(l) && why.contains("run 'c3l migrate'"), "%s", why);
}

fn void old_format_refused() @test
{
	String f = tmp_lock(lock::HEADER +++ "a\tgit\turl\t-\tv1\tcommit:x\tcommit:x\n");
	assert(@catch(lock::load(f)));
	drop(f);
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
	drop(f);
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
	assert(string::join(tmem, l.chain("leaf"), " -> ") == "app -> mid -> leaf", "how the project gets there");
	assert(string::join(tmem, l.chain("app"), " -> ") == "app", "added directly");
	assert(!l.chain("lost").len, "nothing reaches it");
	drop(f);
}

// A lock may come from someone else's repository: what c3l cannot have written is refused.
fn void damaged_lines_refused() @test
{
	String c40 = "0123456789abcdef0123456789abcdef01234567";
	String[] bad = {
		"../x\tgit\thttps://h/x\t-\tHEAD\tcommit:" +++ "0123456789abcdef0123456789abcdef01234567" +++ "\tcommit:0123456789abcdef0123456789abcdef01234567\tdirect\t-\n",
		"x\tgit\thttps://h/x\t-\tHEAD\tcommit:--upload-pack=touch /tmp/p;false\tcommit:x\tdirect\t-\n",
		"x\tgit\t-oProxyCommand=x\t-\tHEAD\tcommit:0123456789abcdef0123456789abcdef01234567\tcommit:0123456789abcdef0123456789abcdef01234567\tdirect\t-\n",
		"x\tregistry\thttps://r\tns/x\t1.0.0\tsha256:zz\tsha256:zz\tdirect\t-\n",
		"x\tregistry\thttps://r\t../x\t1.0.0\tsha256:" +++ "0000000000000000000000000000000000000000000000000000000000000000" +++ "\tsha256:0000000000000000000000000000000000000000000000000000000000000000\tdirect\t-\n",
		"x\tpath\t../x\t-\t-\t-\t-\tdirect\tok,../evil\n",
		"x\tgit\text::sh -c touch% http://h\t-\tHEAD\tcommit:0123456789abcdef0123456789abcdef01234567\tcommit:0123456789abcdef0123456789abcdef01234567\tdirect\t-\n",
		"x\tgit\thttps://me:token@h/x\t-\tHEAD\tcommit:0123456789abcdef0123456789abcdef01234567\tcommit:0123456789abcdef0123456789abcdef01234567\tdirect\t-\n",
	};
	foreach (line : bad)
	{
		String f = tmp_lock(string::tformat("%s%s", lock::HEADER, line));
		assert(@catch(lock::load(f)), "accepted: %s", line);
		drop(f);
	}
	String crlf = string::tformat("%sx\tgit\thttps://h/x\t-\tHEAD\tcommit:%s\tcommit:%s\tdirect\t-\r\n", lock::HEADER, c40, c40);
	assert(@ok(lock::parse(crlf, "c3l.lock", &&(String){})), "a lock checked out with CRLF");
	String why;
	assert(@catch(lock::parse("x\tsvn\th\t-\t-\t-\t-\tdirect\t-\n", "c3l.lock", &why)));
	assert(why.contains("unknown kind 'svn'"), "%s", why);
	String good = string::tformat("%sx\tgit\thttps://h/x\t-\tHEAD\tcommit:%s\tcontent:%s\tdirect\t-\n", lock::HEADER, c40, "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef");
	String f = tmp_lock(good);
	assert(@ok(lock::load(f)), "a git entry with the archive's content hash is valid");
	drop(f);
}
