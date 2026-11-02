<*
 Operating system helpers: files, hashes, subprocesses.
*>
module c3l::sys;

import std::io, std::os, std::sort, std::collections::list, std::hash::sha256, std::encoding::hex;
import std::compression::zip, libc, c3l::log;

// The compiler to call: $C3C or c3c on PATH.
fn String c3c() => env::tget_var("C3C") ?? "c3c";

enum Stderr
{
	DISCARD,
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

// "sha256:<hex>" of a file's contents.
fn String? sha256_file(String path)
{
	File f = file::open(path, "rb")!;
	defer (void)f.close();
	Sha256 h;
	h.init();
	char[65536] buf;
	while (true)
	{
		sz n = f.read(&buf)!;
		if (n <= 0) break;
		h.update(buf[:n]);
	}
	return string::tformat("sha256:%s", hex::encode(tmem, &&h.final()));
}

<*
 "content:<hex>": sha256 over the files of a zip, sorted by name (per file: the
 name, a 0 byte, the size as 8 bytes little endian, the bytes). Unlike the sha256
 of the zip itself it does not depend on how the zip was written, only on what
 is in it.
*>
fn String? content_hash(String path)
{
	ZipArchive z = zip::open(tmem, path)!;
	defer (void)z.close();
	List{String} names;
	names.tinit();
	for (sz i = 0; i < z.count(); i++)
	{
		ZipEntry e = z.stat_at(i)!;
		if (!e.is_directory) names.push(e.name);
	}
	sort::quicksort(&names, fn int(String a, String b) => a.compare_to(b));
	Sha256 h;
	h.init();
	foreach (name : names)
	{
		char[] data = z.read_file_all(tmem, name)!;
		h.update(name);
		h.update({ 0 });
		ulong size = data.len;
		char[8] le;
		for (int i = 0; i < 8; i++) le[i] = (char)(size >> (8 * i));
		h.update(&le);
		h.update(data);
	}
	return string::tformat("content:%s", hex::encode(tmem, &&h.final()));
}

// Where a symbolic link points, as stored in it.
fn String? read_link(String link)
{
	char[4096] buf;
	sz n = libc::readlink(link.zstr_tcopy(), &buf, buf.len);
	if (n < 0 || n >= buf.len) return NOT_FOUND~;
	return ((String)buf[:n]).tcopy();
}

// The path of `to` relative to the directory `from`; both absolute and normalized.
fn String relative(String from, String to)
{
	String[] a = from.tsplit("/", skip_empty: true);
	String[] b = to.tsplit("/", skip_empty: true);
	sz common;
	while (common < a.len && common < b.len && a[common] == b[common]) common++;
	DString out = dstring::temp();
	for (sz i = common; i < a.len; i++) out.append(out.len() ? "/.." : "..");
	for (sz i = common; i < b.len; i++)
	{
		if (out.len()) out.append_char('/');
		out.append(b[i]);
	}
	return out.len() ? out.str_view() : ".";
}

// A new private directory in `base` (default: the system temp directory); the caller removes it.
fn String? temp_dir(String base = "", String prefix = "c3l")
{
	if (!base.len) base = (String)path::temp_directory(tmem) ?? "/tmp";
	ZString dir = mkdtemp(string::tformat("%s/%s.XXXXXXXX", base, prefix).zstr_tcopy());
	if (!dir) return log::fail("cannot create a temporary directory")~;
	return dir.str_view();
}

fn void? link(String target, String link)
{
	if (symlink(target.zstr_tcopy(), link.zstr_tcopy())) return log::fail("cannot link %s", link)~;
}

// Remove a file, a symlink (never what it points to) or a directory tree.
fn void remove(String p)
{
	if (!path::is_link((Path)p) && file::is_dir(p))
	{
		(void)path::rmtree((Path)p);
		return;
	}
	(void)file::delete(p);
}

fn bool exists(String p) => path::is_link((Path)p) || file::exists(p);

extern fn ZString mkdtemp(ZString template) @private;
extern fn CInt symlink(ZString target, ZString link) @private;

// The C3 version of the local compiler ("0.8.6"), empty if unknown.
fn String c3_version()
{
	String out = (run({ c3c(), "--version" }, MERGE) ?? (Output){}).out;
	foreach (line : out.tsplit("\n"))
	{
		if (!line.starts_with("C3 Compiler Version:")) continue;
		String v = line["C3 Compiler Version:".len..].trim();
		sz end;
		while (end < v.len && (v[end].is_digit() || v[end] == '.')) end++;
		return v[:end];
	}
	return "";
}

// This platform as registries name targets ("linux-x64"), empty if unknown.
fn String host_target()
{
	String os = env::LINUX ? "linux" : env::DARWIN ? "macos" : env::WIN32 ? "windows" : env::FREEBSD ? "freebsd" : "";
	String arch = env::X86_64 ? "x64" : env::AARCH64 ? "aarch64" : "";
	return os.len && arch.len ? os.tconcat("-").tconcat(arch) : "";
}
