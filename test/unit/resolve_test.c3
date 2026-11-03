module c3l::resolve_test;

import c3l::install, c3l::git, c3l::lock;

fn void constraint_operators() @test
{
	assert(install::git_ref(">=1.2.0") == "1.2.0");
	assert(install::git_ref("^v1.2.0") == "v1.2.0");
	assert(install::git_ref("v1.2.0") == "v1.2.0");
	assert(install::plain_version("~v1.2.0") == "1.2.0");
}

fn void hosts() @test
{
	assert(install::host_of("https://user@git.example.org:8443/a/b.git") == "git.example.org");
	assert(install::host_of("git@codeberg.org:o/r.git") == "codeberg.org");
	assert(install::host_of("../local/repo") == "file");
	assert(install::host_of("file:///srv/repo") == "file");
	assert(install::is_git_url("https://h/x") && install::is_git_url("git@h:x") && !install::is_git_url("ns/name"));
}

fn void host_tricks() @test
{
	assert(install::host_of("http://127.0.0.1:2877?@github.com/x/y") == "127.0.0.1");
	assert(install::host_of("http://127.0.0.1:2877#@github.com/x") == "127.0.0.1");
	assert(install::host_of("https://github.com@evil.org/x") == "evil.org");
	assert(install::host_of("https://github.com.evil.org/x") == "github.com.evil.org");
	assert(install::host_of("https://evil.org/github.com") == "evil.org");
	assert(install::host_of("https://GitHub.com/o/r") == "github.com");
	assert(install::host_of("https://evil.org\\@github.com/x") == "", "not a plain host name");
	assert(install::host_of("ns/name") == "");
}

fn void same_git_source() @test
{
	assert(git::canonical("https://GitHub.com/Ecoral360/dessert.c3l.git/") == git::canonical("https://github.com/ecoral360/dessert.c3l"));
	assert(git::canonical("https://example.org/A/b") != git::canonical("https://example.org/a/b"), "case matters elsewhere");
	assert(git::canonical("HTTPS://Example.org/A/b") == "example.org/A/b");
	String https = git::canonical("https://github.com/me/lib");
	assert(git::canonical("git@github.com:me/lib.git") == https, "ssh and https are one repository");
	assert(git::canonical("ssh://git@github.com:22/me/lib") == https);
	assert(git::canonical("https://gitlab.com/me/lib") != https);
	assert(git::canonical("file:///srv/lib") == "file:///srv/lib" && git::canonical("../lib") == "../lib");
}

fn void git_urls() @test
{
	foreach (u : (String[]){ "https://h/x", "HTTP://h/x", "ssh://git@h/x", "git://h/x", "file:///x", "git@h:x", "/x", "./x", "../x" })
	{
		assert(lock::valid_git_url(u), "%s should be valid", u);
	}
	foreach (u : (String[]){ "https://user:token@github.com/x", "https://token@github.com/x", "ext::sh -c x% http://h", "ftp://h/x", "h/x", "git@h", "https://h/x\" -x", "https://h/\nx" })
	{
		assert(!lock::valid_git_url(u), "%s should be refused", u);
	}
	assert(lock::valid_git_url("https://github.com/x/y@v1"), "an @ in the path is no credential");
	foreach (r : (String[]){ "", "v1.2.0", "HEAD", "branch:feature/x", "commit:0123456789ab" }) assert(git::valid_ref(r), "%s", r);
	foreach (r : (String[]){ "v1 --upload-pack=x", "v1\"", "a\tb", "x\n" }) assert(!git::valid_ref(r), "%s", r);
}

fn void newer_versions() @test
{
	String[] v = { "1.2.0", "1.10.0", "2.0.0", "2.1.0-rc.1", "0.9.0", "junk" };
	Newer n = install::pick("1.3.0", v);
	assert(n.next == "1.10.0" && n.major == "2.0.0", "%s %s", n.next, n.major);
	n = install::pick("2.0.0", v);
	assert(!n.next.len && !n.major.len, "prereleases only for a prerelease");
	n = install::pick("v2.1.0-rc.0", v);
	assert(n.next == "2.1.0-rc.1");
}
