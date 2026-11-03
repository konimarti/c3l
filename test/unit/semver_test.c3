module c3l::semver_test @test;

import c3l::semver;

fn void compare()
{
	String[3][] cases = {
		{ "1.0.0", "1.0.0", "0" }, { "1.0.1", "1.0.0", "1" }, { "1.0.0", "1.0.1", "-1" },
		{ "1.10.0", "1.9.0", "1" }, { "v2.0", "1.9.9", "1" }, { "1.0.0", "1.0.0-rc.1", "1" },
		{ "1.0.0-rc.1", "1.0.0", "-1" }, { "1.0.0-rc.2", "1.0.0-rc.10", "-1" },
		{ "1.0.0-alpha", "1.0.0-alpha.1", "-1" }, { "1.0.0-alpha.1", "1.0.0-beta", "-1" },
		{ "1.0.0-1", "1.0.0-alpha", "-1" }, { "1.0.0+b1", "1.0.0+b2", "0" },
	};
	foreach (c : cases)
	{
		assert(semver::compare(c[0], c[1]) == c[2].to_int()!!, "compare %s %s", c[0], c[1]);
	}
}

fn void valid()
{
	foreach (v : (String[]){ "1", "v1.2", "1.2.3", "1.2.3-rc.1", "1.2.3+b.5", "1.2.3-a-b+c" })
	{
		assert(semver::valid(v), "%s should be valid", v);
	}
	foreach (v : (String[]){ "", "v", "1.2.3.4", "1.x", "1.2.3-", "1.2.3+", "main", "1..2" })
	{
		assert(!semver::valid(v), "%s should be invalid", v);
	}
}

fn void strict()
{
	foreach (v : (String[]){ "0.1.0", "1.2.3", "1.2.3-rc.1" })
	{
		assert(semver::strict(v), "%s should be strict", v);
	}
	foreach (v : (String[]){ "v1.2.3", "1.2", "01.2.3", "1.2.3+b", "1.2.3-.x" })
	{
		assert(!semver::strict(v), "%s should not be strict", v);
	}
}

fn void newer_and_major()
{
	assert(semver::newer("1.1.0", "v1.0.9"));
	assert(!semver::newer("main", "1.0.0"));
	String[2][] compat = {
		{ "v12.3.4", "12.x" }, { "3", "3.x" }, { "1.0.0-rc.1", "1.x" }, { "0.3.9", "0.3.x" }, { "0.3", "0.3.x" },
		{ "0.0.5", "0.0.5" }, { "0", "0.0.0" }, { "01.2.3", "1.x" },
	};
	foreach (c : compat) assert(semver::compat(c[0]) == c[1], "%s: %s", c[0], semver::compat(c[0]));
	assert(semver::prerelease("v1.0.0-rc.1") && !semver::prerelease("1.0.0+b1") && !semver::prerelease("main"));
}
