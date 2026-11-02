module c3l::resolve_test;

import c3l::install;

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
