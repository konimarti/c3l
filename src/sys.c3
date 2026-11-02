<*
 Operating system helpers: files, hashes, subprocesses.
*>
module c3l::sys;

import std::io, libc, c3l::log;

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
