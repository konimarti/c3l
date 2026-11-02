<*
 Messages: `[INFO]` on stdout, `[WARN]` and `[ERROR]` on stderr, coloured when
 stdout is a terminal. An error is reported where it happens, with `fail`:
 `return log::fail("cannot read %s", file)~;` prints it and gives serp::FAILED,
 which serp turns into exit code 1 without printing anything else.
*>
module c3l::log;

import std::io, libc, serp;

fn void info(String format, args...) @format(0)
{
	io::printfn("%s %s", tag("INFO", "32"), string::tformat(format, ...args));
}

fn void warn(String format, args...) @format(0)
{
	io::eprintfn("%s %s", tag("WARN", "33"), string::tformat(format, ...args));
}

fn void error(String format, args...) @format(0)
{
	io::eprintfn("%s %s", tag("ERROR", "31"), string::tformat(format, ...args));
}

fn fault fail(String format, args...) @format(0)
{
	error("%s", string::tformat(format, ...args));
	return serp::FAILED;
}

fn String tag(String name, String colour) @private
{
	if (!libc::isatty(1)) return string::tformat("[%s]", name);
	return string::tformat("\e[%sm[%s]\e[0m", colour, name);
}
