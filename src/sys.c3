<*
 Operating system helpers: files, hashes, subprocesses.
*>
module c3l::sys;

import std::io, std::os, std::sort, std::collections::list, std::hash::sha256, std::encoding::hex;
import std::compression::zip, libc, serp, c3l::log, c3l::semver;

// The compiler to call: $C3C or c3c on PATH.
fn String c3c() => env::tget_var("C3C") ?? "c3c";

enum Stderr
{
	APART,  // in Output.err
	MERGE,  // into Output.out
}

struct Output
{
	int code;
	String out;
	String err;
}

// The first line the program wrote to stderr (where git says what went wrong), for messages.
fn String Output.reason(&self)
{
	String err = self.err.trim();
	return err[:err.index_of_char('\n') ?? err.len].trim().strip_prefix("fatal: ");
}

bool interrupted;
bool reported @private;

<*
 SIGINT and SIGTERM end the command like a failure, so that rollback and
 cleanup run: a running child (also signalled on Ctrl-C) fails, and run() and
 http transfers fail once the flag is set. A second signal exits at once.
*>
fn void catch_signals()
{
	libc::signal(libc::SIGINT, &on_signal);
	libc::signal(libc::SIGTERM, &on_signal);
}

fn void on_signal(CInt sig) @private
{
	if (interrupted) libc::_exit(128 + sig);
	interrupted = true;
	$if env::WIN32:
		libc::signal(sig, &on_signal);  // the CRT resets it before calling
	$endif
}

// A failure (reported once) after a signal.
fn void? check_interrupt()
{
	if (!interrupted) return;
	if (reported) return serp::FAILED~;
	reported = true;
	return log::fail("interrupted")~;
}

<*
 Run a program found on PATH and wait for it; its stdout is returned, and its
 stderr (kept in a temporary file, so neither stream can block the other).
 Fails when the program cannot be started or c3l was interrupted.
*>
fn Output? run(String[] argv, Stderr err = APART)
{
	check_interrupt()!;
	SpawnOptions options = INHERIT_ENV;
	ProcessStdio stderr = process::INHERIT;
	Capture errors;
	switch (err)
	{
		case APART:
			errors = capture()!;
			stderr = errors.stdio();
		case MERGE:
			options |= STDERR_TO_STDOUT;
	}
	defer if (err == APART) errors.close();

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
	Output o = { .code = p.join() ?? -1, .out = out.str_view() };
	if (err == APART) o.err = errors.read();
	check_interrupt()!;
	return o;
}

// A child's stderr, kept in a temporary file (see capture() in sys_posix.c3 and sys_win32.c3).
struct Capture
{
	File file;
	String path;  // Windows: the file is named, and deleted by close()
}

// What the child wrote to the capture file.
fn String Capture.read(&self)
{
	DString msg = dstring::temp();
	libc::rewind(self.file.file);
	(void)io::copy_to(&self.file, &msg);
	return msg.str_view();
}

// Replace `file` with `data` (written next to it, then renamed).
fn void? write_atomic(String file, char[] data)
{
	String tmp = string::tformat("%s.c3l-tmp", file);
	if (catch file::save(tmp, data))
	{
		return log::fail("cannot write %s", file)~;
	}
	if (!rename(tmp, file))
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

<*
 The path of `to` relative to the directory `from`; both absolute and
 normalized. Joined with the platform's separator; on Windows `to` itself when
 the two are on different drives.
*>
fn String relative(String from, String to)
{
	String sep = env::WIN32 ? "\\" : "/";
	String[] a = from.tsplit(sep, skip_empty: true);
	String[] b = to.tsplit(sep, skip_empty: true);
	$if env::WIN32:
		if (!a.len || !b.len || a[0].to_lower_tcopy() != b[0].to_lower_tcopy()) return to;
	$endif
	sz common;
	while (common < a.len && common < b.len && a[common] == b[common]) common++;
	DString out = dstring::temp();
	for (sz i = common; i < a.len; i++)
	{
		if (out.len()) out.append(sep);
		out.append("..");
	}
	for (sz i = common; i < b.len; i++)
	{
		if (out.len()) out.append(sep);
		out.append(b[i]);
	}
	return out.len() ? out.str_view() : ".";
}

<*
 A path on this machine rather than a URL or a registry id: starting with
 "./" or "../" (also ".\" and "..\" on Windows), or absolute.
*>
fn bool is_local_path(String s)
{
	$if env::WIN32:
		if (s.starts_with("\\\\") || s.starts_with("//")) return false;  // \\server\share: another host
	$endif
	String rest = s.starts_with("..") ? s[2..] : s.starts_with(".") ? s[1..] : s;
	if (rest.len < s.len) return rest.len > 0 && path::is_separator(rest[0]);
	return ((Path)s).is_absolute() ?? false;  // as written: normalizing would refuse "/.."
}

// Remove a file, a symlink (never what it points to) or a directory tree.
fn void remove(String p)
{
	if (path::is_link((Path)p))
	{
		remove_link(p);
		return;
	}
	if (file::is_dir(p))
	{
		remove_tree(p);
		return;
	}
	(void)file::delete(p);
}

fn bool exists(String p) => path::is_link((Path)p) || file::exists(p);

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

bool old_c3c_warned @private;

<*
 Once per run: c3c before 0.8.6 may keep compiling the old sources of a .c3l
 zip that was updated (add, update and sync write such archives).
*>
fn void warn_old_c3c()
{
	if (old_c3c_warned) return;
	old_c3c_warned = true;
	String v = c3_version();
	if (!v.len || semver::compare(v, "0.8.6") >= 0) return;
	log::warn("c3c %s may keep compiling the old sources of an updated .c3l zip (c3c 0.8.6 unpacks it again when only files other than manifest.json changed); update c3c, or delete build/unpacked_c3l", v);
}

// The platform names c3c knows ("linux-x64", "macos-aarch64", ...), as `c3c --list-targets` prints them.
fn String[] platforms()
{
	List{String} out;
	out.tinit();
	String text = (run({ c3c(), "--list-targets" }, MERGE) ?? (Output){}).out;
	foreach (line : text.tsplit("\n"))
	{
		String t = line.trim();
		if (line.starts_with("   ") && t.len && !t.contains(" ")) out.push(t);
	}
	return out.array_view();
}

// This platform as registries name targets ("linux-x64"), empty if unknown.
fn String host_target()
{
	String os = env::LINUX ? "linux" : env::DARWIN ? "macos" : env::WIN32 ? "windows" : env::FREEBSD ? "freebsd" : "";
	String arch = env::X86_64 ? "x64" : env::AARCH64 ? "aarch64" : "";
	return os.len && arch.len ? os.tconcat("-").tconcat(arch) : "";
}
