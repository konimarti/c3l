<*
 c3l::sys on Windows. The same functions for POSIX systems are in
 sys_posix.c3.
*>
module c3l::sys @feat(WIN32);

import std::io, std::os, std::os::win32, std::math::uuid, libc, c3l::log;

<*
 The capture file is named, in the temp directory (tmpfile() may use the drive
 root), and its handle explicitly inheritable: the child writes to it.
*>
fn Capture? capture()
{
	String p = string::tformat("%s/c3l.%s.err", (String)path::temp_directory(tmem) ?? ".", uuid::generate());
	File f = file::open(p, "w+b") ?? log::fail("cannot create a temporary file")~!;
	Capture c = { .file = f, .path = p };
	if (!win32::setHandleInformation(c.handle(), win32::HANDLE_FLAG_INHERIT, win32::HANDLE_FLAG_INHERIT))
	{
		c.close();
		return log::fail("cannot create a temporary file")~;
	}
	return c;
}

fn Win32_HANDLE Capture.handle(&self) => (Win32_HANDLE)win32::_get_osfhandle(libc::fileno(self.file.file));

fn ProcessStdio Capture.stdio(&self) => process::bind(self.handle());

fn void Capture.close(&self)
{
	(void)self.file.close();
	(void)file::delete(self.path);
}

// Rename `from` to `to`, replacing `to` if it exists (rename() would fail).
fn bool rename(String from, String to)
{
	WString? f = from.to_temp_wstring();
	WString? t = to.to_temp_wstring();
	if (catch f, t) return false;
	return moveFileExW(f, t, MOVEFILE_REPLACE_EXISTING) != 0;
}

// A new private directory in `base` (default: the system temp directory); the caller removes it.
fn String? temp_dir(String base = "", String prefix = "c3l")
{
	if (!base.len) base = (String)path::temp_directory(tmem) ?? ".";
	String dir = string::tformat("%s/%s.%s", base, prefix, uuid::generate());
	if (!(path::mkdir(dir) ?? false)) return log::fail("cannot create a temporary directory")~;
	return dir;
}

<*
 A directory symbolic link. Windows creates them only in Developer Mode or for
 an administrator.
*>
fn void? link(String target, String link)
{
	if (createSymbolicLinkW(link.to_temp_wstring()!, target.to_temp_wstring()!, SYMBOLIC_LINK_DIRECTORY | SYMBOLIC_LINK_UNPRIVILEGED)) return;
	return log::fail("cannot link %s; Windows creates symbolic links only in Developer Mode (Settings, System, For developers) or for an administrator", link)~;
}

// Does the symbolic link `link` point to the directory `dir`? Both are resolved by Windows.
fn bool points_to(String link, String dir)
{
	String got = final_path(link);
	return got.len > 0 && got == final_path(dir);
}

// A directory link is removed as a directory (never what it points to).
fn void remove_link(String link)
{
	if (file::is_dir(link))
	{
		(void)path::rmdir((Path)link);
		return;
	}
	(void)file::delete(link);
}

<*
 Remove a directory tree, never following a link (the stdlib's rmtree walks
 into directory links on Windows) and deleting read-only files (git makes its
 objects read-only).
*>
fn void remove_tree(String dir)
{
	PathList? names = path::ls(tmem, (Path)dir);
	if (catch names) return;
	foreach (name : names)
	{
		String f = string::tformat("%s\\%s", dir, name);
		switch
		{
			case path::is_link((Path)f): remove_link(f);
			case file::is_dir(f): remove_tree(f);
			default:
				if (try w = f.to_temp_wstring()) setFileAttributesW(w, win32::FILE_ATTRIBUTE_NORMAL);
				(void)file::delete(f);
		}
	}
	(void)path::rmdir((Path)dir);
}

<*
 Process settings: the console shows UTF-8 and the colours of log.c3 (ANSI
 escapes), and programs are found on the PATH only, never in the current
 directory (a git.exe in a cloned project).
*>
fn void setup()
{
	env::set_var("NoDefaultCurrentDirectoryInExePath", "1");
	win32::setConsoleOutputCP(UTF8);
	foreach (which : (Win32_DWORD[]){ win32::STD_OUTPUT_HANDLE, win32::STD_ERROR_HANDLE })
	{
		Win32_HANDLE h = win32::getStdHandle(which);
		Win32DwMode mode;
		if (!win32::getConsoleMode(h, &mode)) continue;
		win32::setConsoleMode(h, mode | (Win32DwMode)ENABLE_VIRTUAL_TERMINAL_PROCESSING);
	}
}

// The path Windows resolves `p` to, links followed; empty if it cannot be opened.
fn String final_path(String p) @private
{
	WString? name = p.to_temp_wstring();
	if (catch name) return "";
	Win32_HANDLE h = createFileW(name, 0, FILE_SHARE_READ_WRITE_DELETE, null, win32::OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, null);
	if (h == win32::INVALID_HANDLE_VALUE) return "";
	defer win32::closeHandle(h);
	Char16[1024] buf;
	Win32_DWORD n = getFinalPathNameByHandleW(h, &buf, buf.len, 0);
	if (!n || n >= buf.len) return "";
	return string::tfrom_utf16(buf[:n]) ?? "";
}

const Win32_DWORD MOVEFILE_REPLACE_EXISTING @private = 0x1;
const Win32_DWORD SYMBOLIC_LINK_DIRECTORY @private = 0x1;
const Win32_DWORD SYMBOLIC_LINK_UNPRIVILEGED @private = 0x2;
const Win32_DWORD ENABLE_VIRTUAL_TERMINAL_PROCESSING @private = 0x4;
const Win32_DWORD FILE_SHARE_READ_WRITE_DELETE @private = 0x7;
const Win32_DWORD FILE_FLAG_BACKUP_SEMANTICS @private = 0x02000000;  // needed to open a directory

extern fn char createSymbolicLinkW(WString link, WString target, Win32_DWORD flags) @cname("CreateSymbolicLinkW") @private;
extern fn Win32_BOOL setFileAttributesW(WString name, Win32_DWORD attributes) @cname("SetFileAttributesW") @private;
extern fn Win32_BOOL moveFileExW(WString from, WString to, Win32_DWORD flags) @cname("MoveFileExW") @private;
extern fn Win32_HANDLE createFileW(WString name, Win32_DWORD access, Win32_DWORD share, void* security,
	Win32_DWORD creation, Win32_DWORD flags, Win32_HANDLE template) @cname("CreateFileW") @private;
extern fn Win32_DWORD getFinalPathNameByHandleW(Win32_HANDLE file, Char16* path, Win32_DWORD len, Win32_DWORD flags)
	@cname("GetFinalPathNameByHandleW") @private;
