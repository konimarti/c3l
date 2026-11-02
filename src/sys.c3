<*
 Operating system helpers: files, hashes, subprocesses.
*>
module c3l::sys;

import std::io, std::os, libc, c3l::log;

// The compiler to call: $C3C or c3c on PATH.
fn String c3c() => env::tget_var("C3C") ?? "c3c";

enum Stderr
{
	DISCARD,
	SHOW,
	MERGE,  // into the captured output
}

struct Output
{
	int code;
	String out;
}

<*
 Run a program found on PATH and wait for it; its stdout is returned.
 Fails only when the program cannot be started.
*>
fn Output? run(String[] argv, Stderr err = DISCARD)
{
	SpawnOptions options = INHERIT_ENV;
	ProcessStdio stderr = process::INHERIT;
	File devnull;
	switch (err)
	{
		case DISCARD:
			devnull = file::open("/dev/null", "w") ?? log::fail("cannot open /dev/null")~!;
			stderr = process::bind(libc::fileno(devnull.file));
		case SHOW:
			break;
		case MERGE:
			options |= STDERR_TO_STDOUT;
	}
	defer if (err == DISCARD) (void)devnull.close();

	Process? p = process::spawn(argv, options, {}, process::INHERIT, process::CAPTURE, stderr);
	if (catch p) return log::fail("'%s' is required for this command but was not found", argv[0])~;
	defer (void)p.destroy();

	DString out = dstring::temp();
	char[4096] buf;
	while (true)
	{
		sz n = p.read_stdout(&buf, buf.len) ?? 0;
		if (n <= 0) break;
		out.append(buf[:n]);
	}
	int code = p.join() ?? -1;
	return { code, out.str_view() };
}

// Replace `file` with `data` (written next to it, then renamed).
fn void? write_atomic(String file, char[] data)
{
	String tmp = string::tformat("%s.c3l-tmp", file);
	if (catch file::save(tmp, data))
	{
		return log::fail("cannot write %s", file)~;
	}
	if (libc::rename(tmp.zstr_tcopy(), file.zstr_tcopy()))
	{
		(void)file::delete(tmp);
		return log::fail("cannot write %s", file)~;
	}
}
