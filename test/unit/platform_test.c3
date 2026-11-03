// What differs per operating system (sys_posix.c3, sys_win32.c3); runs on all of them.
module c3l::platform_test @test;

import std::io, std::os, std::compression::zip, c3l::sys, c3l::git;

fn void temp_dirs()
{
	String a = sys::temp_dir()!!;
	String b = sys::temp_dir()!!;
	defer { sys::remove(a); sys::remove(b); }
	assert(a != b && file::is_dir(a) && file::is_dir(b));
	file::save(a.tconcat("/f"), "x")!!;
	sys::remove(a);
	assert(!sys::exists(a), "a directory tree is removed");
}

fn void run_captures_output_and_errors()
{
	Output o = sys::run({ "git", "--version" })!!;
	assert(o.code == 0 && o.out.starts_with("git version"), "%s", o.out);
	o = sys::run({ "git", "-C", "c3l-no-such-dir", "status" })!!;
	assert(o.code != 0 && o.reason().len > 0, "stderr is captured: '%s'", o.err);
	assert(@catch(sys::run({ "c3l-no-such-program" })), "a missing program is a failure");
}

fn void rename_replaces()
{
	String dir = sys::temp_dir()!!;
	defer sys::remove(dir);
	String a = dir.tconcat("/a");
	String b = dir.tconcat("/b");
	file::save(a, "new")!!;
	file::save(b, "old")!!;
	assert(sys::rename(a, b), "an existing file is replaced");
	assert((String)file::load_temp(b)!! == "new" && !file::exists(a));
	sys::write_atomic(b, "again")!!;
	assert((String)file::load_temp(b)!! == "again");
}

fn void local_paths()
{
	foreach (p : (String[]){ "./x", "../x" }) assert(sys::is_local_path(p), "%s", p);
	foreach (p : (String[]){ "", ".", "..", "x", ".x", "...", "ns/name", "https://h/x", "git@h:x", "vendor:x" })
	{
		assert(!sys::is_local_path(p), "%s", p);
	}
	$if env::WIN32:
		foreach (p : (String[]){ "C:\\x", "C:/x", ".\\x", "..\\x" }) assert(sys::is_local_path(p), "%s", p);
		foreach (p : (String[]){ "\\\\server\\share\\x", "//server/share/x" }) assert(!sys::is_local_path(p), "%s: another host", p);
	$else
		assert(sys::is_local_path("/x") && sys::is_local_path("/../x"), "absolute, as written");
	$endif
}

fn void relative_paths()
{
	$if env::WIN32:
		assert(sys::relative("C:\\a\\lib", "C:\\a\\src\\x") == "..\\src\\x");
		assert(sys::relative("C:\\a", "D:\\x") == "D:\\x", "another drive stays absolute");
	$else
		assert(sys::relative("/a/lib", "/a/src/x") == "../src/x");
		assert(sys::relative("/a/b", "/a/b") == ".");
	$endif
}

fn void links()
{
	String dir = (String)sys::temp_dir()!!.to_absolute_path(tmem)!!;
	defer sys::remove(dir);
	String target = dir.tconcat("/target");
	path::mkdir(target)!!;
	String link = dir.tconcat("/lib.c3l");
	file::save(target.tconcat("/keep"), "x")!!;
	if (catch sys::link(sys::relative(dir, target), link))
	{
		$if env::WIN32:
			return;  // no Developer Mode
		$else
			assert(false, "cannot link");
		$endif
	}
	assert(sys::exists(link) && file::is_dir(link));
	assert(sys::points_to(link, target) && !sys::points_to(link, dir));
	String outer = dir.tconcat("/backup");  // like an operation's backup directory holding a replaced link
	path::mkdir(outer)!!;
	assert(sys::rename(link, outer.tconcat("/lib.c3l")));
	sys::remove(outer);
	assert(!sys::exists(outer) && file::exists(target.tconcat("/keep")), "removing a tree never follows a link");
}

// A commit checked out and archived: the files as committed (no line-ending conversion), the same hash twice.
fn void git_archive()
{
	String dir = sys::temp_dir()!!;
	defer sys::remove(dir);
	String repo = dir.tconcat("/repo");
	path::mkdir(repo)!!;
	file::save(repo.tconcat("/manifest.json"), "{ \"provides\": \"x\" }\r\n")!!;
	String[][] steps = {
		{ "git", "-C", repo, "init", "-q" },
		{ "git", "-C", repo, "-c", "core.autocrlf=false", "add", "-A" },
		{ "git", "-C", repo, "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", "commit", "-q", "--no-verify", "-m", "x" },
	};
	foreach (argv : steps) assert(sys::run(argv)!!.code == 0, "%s", argv);
	String commit = sys::run({ "git", "-C", repo, "rev-parse", "HEAD" })!!.out.trim();
	String[2] hashes;
	foreach (i, &h : hashes)
	{
		String work = sys::temp_dir(dir)!!;
		String src = git::checkout(repo, commit, "", work)!!;
		String zip = work.tconcat("/x.c3l");
		git::archive(src, zip)!!;
		*h = sys::content_hash(zip)!!;
		ZipArchive z = zip::open(tmem, zip)!!;
		defer (void)z.close();
		assert(((String)z.read_file_all(tmem, "manifest.json")!!).ends_with("\r\n"), "archived as committed");
	}
	assert(hashes[0].starts_with("content:") && hashes[0] == hashes[1]);
}
