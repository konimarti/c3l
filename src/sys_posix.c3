<*
 c3l::sys on POSIX systems (Linux, macOS, BSD). The same functions for
 Windows are in sys_win32.c3.
*>
module c3l::sys @feat(!WIN32);

import std::io, std::os, libc, c3l::log;

// A child's stderr, kept in an anonymous temporary file.
struct Capture
{
	File file;
}

fn Capture? capture()
{
	CFile f = libc::tmpfile();
	if (!f) return log::fail("cannot create a temporary file")~;
	return { .file = { .file = f } };
}

fn ProcessStdio Capture.stdio(&self) => process::bind(libc::fileno(self.file.file));

fn void Capture.close(&self) => (void)self.file.close();

// Rename `from` to `to`, replacing `to` if it exists.
fn bool rename(String from, String to) => !libc::rename(from.zstr_tcopy(), to.zstr_tcopy());

// A new private directory in `base` (default: the system temp directory); the caller removes it.
fn String? temp_dir(String base = "", String prefix = "c3l")
{
	if (!base.len) base = (String)path::temp_directory(tmem) ?? "/tmp";
	ZString dir = mkdtemp(string::tformat("%s/%s.XXXXXX", base, prefix).zstr_tcopy());
	if (!dir) return log::fail("cannot create a temporary directory")~;
	return dir.str_view();
}

fn void? link(String target, String link)
{
	if (symlink(target.zstr_tcopy(), link.zstr_tcopy())) return log::fail("cannot link %s", link)~;
}

// Does the symbolic link `link` point to the directory `dir`?
fn bool points_to(String link, String dir)
{
	char[4096] buf;
	sz n = libc::readlink(link.zstr_tcopy(), &buf, buf.len);
	if (n < 0 || n >= buf.len) return false;
	String target = ((String)buf[:n]).tcopy();
	if (!target.starts_with("/")) target = string::tformat("%s/%s", link.path_tdirname() ?? ".", target);
	String want = (String)dir.to_absolute_path(tmem) ?? dir;
	return ((String)target.to_absolute_path(tmem) ?? target) == want;
}

fn void remove_link(String link) => (void)file::delete(link);

fn void setup_console() {}

extern fn ZString mkdtemp(ZString template) @private;
extern fn CInt symlink(ZString target, ZString link) @private;
