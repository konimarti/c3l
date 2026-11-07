<*
 c3l.lock: a header line, then one library per line, 9 tab separated columns

   name kind origin id version pin hash role requires

 origin  where the library is fetched from, exactly as the fetcher wants it:
         registry base URL (no trailing slash), vendor release URL, git URL, directory
 id      <namespace>/<name> (registry), the library name (vendor), "-" otherwise
 version 1.2.3 | tag | HEAD | branch:NAME | commit:SHA12 | latest (vendor) | - (path)
 pin     sha256:<hex> (registry, vendor), commit:<sha> (git), - (path)
 hash    what the installed file is checked against: the pin again (registry,
         vendor), content:<hex> of the archive (git, see sys::content_hash;
         commit:<sha> in locks of c3l 1.1), - (path)
 role    direct (asked for by the project) | dep (pulled in by another library)
 requires comma separated names this library requires, "-" if none
*>
module c3l::lock;

import std::io, std::collections::list, std::sort, c3l::log, c3l::sys;

const String HEADER = "# c3l.lock v1 - written by c3l, do not edit by hand\n";

enum Kind : char (String name)
{
	REGISTRY { "registry" },
	GIT { "git" },
	PATH { "path" },
}

enum Role : char (String name)
{
	DIRECT { "direct" },
	DEP { "dep" },
}

struct Entry
{
	String name;
	Kind kind;
	String origin;
	String id;
	String version;
	String pin;
	String hash;
	Role role;
	String[] requires;
}

struct Lock
{
	String file;
	bool frozen; // never written (sync --frozen)
	List{Entry} entries;
}

<*
 Read a lockfile; a missing file is an empty lock. Lines of an older format
 are refused, not guessed, and so is anything a lock written by c3l cannot
 contain: the lock may come from someone else's repository, and its names,
 pins and URLs end up in file names and git command lines.
*>
fn Lock? load(String file)
{
	Lock lock = { .file = file };
	lock.entries.tinit();
	if (!file::exists(file)) return lock;
	String text = (String)file::load_temp(file) ?? log::fail("cannot read %s", file)~!;
	String why;
	Lock? l = parse(text, file, &why);
	if (catch l) return log::fail("%s", why)~;
	return l;
}

faultdef INVALID;

// Lockfile text; INVALID with `why` set to what is wrong where.
fn Lock? parse(String text, String file, String* why)
{
	Lock lock = { .file = file };
	lock.entries.tinit();
	foreach (i, raw : text.tsplit("\n"))
	{
		String line = raw.strip_suffix("\r");  // git for Windows may check it out with CRLF
		if (!line.len || line.starts_with("#")) continue;
		String[] col = line.tsplit("\t");
		if (col.len != 9)
		{
			*why = string::tformat("%s line %d does not have 9 columns (written by an older c3l?). Delete it and run 'c3l add' again, or restore the libraries with an older c3l first.", file, i + 1);
			return INVALID~;
		}
		Kind? kind = runtime::@enum_lookup(Kind, "name", col[1]);
		Role? role = runtime::@enum_lookup(Role, "name", col[7]);
		if (catch kind, role)
		{
			if (col[1] == "vendor")
			{
				*why = string::tformat("%s line %d is a vendor: library (c3l 2.1 and older); the collection moved to the c3lang registry: run 'c3l migrate'", file, i + 1);
				return INVALID~;
			}
			*why = string::tformat("%s line %d: unknown kind '%s' or role '%s'", file, i + 1, col[1], col[7]);
			return INVALID~;
		}
		Entry e = {
			.name = col[0], .kind = kind, .origin = col[2], .id = col[3], .version = col[4],
			.pin = col[5], .hash = col[6], .role = role,
			.requires = col[8] == "-" ? {} : col[8].tsplit(","),
		};
		String bad = e.problem();
		if (bad.len)
		{
			*why = string::tformat("%s line %d: invalid %s; the lockfile is damaged or was edited by hand", file, i + 1, bad);
			return INVALID~;
		}
		lock.entries.push(e);
	}
	return lock;
}

// Where an entry comes from, for messages: registry:<url> <id>, git:<url>, path:<dir>
fn String Entry.source(&self)
{
	switch (self.kind)
	{
		case REGISTRY: return string::tformat("registry:%s %s", self.origin, self.id);
		default: return string::tformat("%s:%s", self.kind.name, self.origin);
	}
}

// What is wrong with an entry, empty if nothing.
fn String Entry.problem(&self)
{
	if (!valid_name(self.name)) return "library name";
	foreach (r : self.requires) if (!valid_name(r)) return "requires";
	if (self.origin.starts_with("-")) return "origin";
	switch (self.kind)
	{
		case REGISTRY:
			if (!is_digest(self.pin) || !is_digest(self.hash)) return "checksum";
			if (!valid_id(self.id)) return "id";
		case GIT:
			if (!valid_git_url(self.origin)) return "git URL";
			if (!is_commit_pin(self.pin) || !(is_commit_pin(self.hash) || is_content(self.hash))) return "commit";
		case PATH:
			break;
	}
	return "";
}

// A library name: [A-Za-z0-9][A-Za-z0-9._-]*
fn bool valid_name(String s)
{
	if (!s.len || !s[0].is_alnum()) return false;
	foreach (c : s) if (!c.is_alnum() && c != '.' && c != '_' && c != '-') return false;
	return true;
}

// A registry id: <namespace>/<name>
fn bool valid_id(String s)
{
	String[] parts = s.tsplit("/");
	return parts.len == 2 && valid_name(parts[0]) && valid_name(parts[1]);
}

// A version as c3c's library paths take it: letters, digits, '_', '-', '.', '+', starting with a letter or digit.
fn bool valid_version(String s)
{
	if (!s.len || !s[0].is_alnum()) return false;
	foreach (c : s) if (!c.is_alnum() && c != '.' && c != '_' && c != '-' && c != '+') return false;
	return true;
}

<*
 A git URL c3l fetches from: http(s)://, ssh://, git:// or file:// URLs,
 git@host:path, or a local path. Nothing git would run (ext::), and no
 credentials in http(s) URLs: the URL is written to the lockfile.
*>
fn bool valid_git_url(String s)
{
	foreach (c : s) if (c < ' ' || c == '"' || c == 0x7f) return false;  // see git::valid_ref
	if (sys::is_local_path(s)) return true;
	if (s.starts_with("git@")) return s.contains(":");
	sz? i = s.index_of("://");
	if (catch i) return false;
	String scheme = s[:i].to_lower_tcopy();
	String rest = s[i + 3..];
	sz end = rest.len;  // of the authority: at the path, query or fragment
	foreach (j, c : rest)
	{
		if (c != '/' && c != '?' && c != '#') continue;
		end = j;
		break;
	}
	switch (scheme)
	{
		case "http":
		case "https": return !rest[:end].contains("@");
		case "ssh":  // a user name is fine (ssh://git@host), a password is not
			String auth = rest[:end];
			return !auth[:auth.rindex_of_char('@') ?? 0].contains(":");
		case "git":
		case "file": return true;
		default: return false;
	}
}

// A full git commit id: 40 hex digits.
fn bool is_commit(String s) => is_hex(s, 40);

fn bool is_commit_pin(String s) @private => s.starts_with("commit:") && is_commit(s["commit:".len..]);

fn bool is_digest(String s) @private => s.starts_with("sha256:") && is_hex(s["sha256:".len..], 64);

fn bool is_content(String s) @private => s.starts_with("content:") && is_hex(s["content:".len..], 64);

fn bool is_hex(String s, sz len)
{
	if (s.len != len) return false;
	foreach (c : s) if (!c.is_xdigit()) return false;
	return true;
}

fn bool Lock.exists(&self) => file::exists(self.file);

// Header and entries sorted by name, replaced atomically.
fn void? Lock.save(&self)
{
	if (self.frozen) return;
	List{Entry} sorted;  // a copy: pointers from get() stay valid
	sorted.tinit_with_array(self.entries.array_view());
	sort::quicksort(&sorted, fn int(Entry a, Entry b) => a.name.compare_to(b.name));
	DString out = dstring::temp(HEADER);
	foreach (e : sorted)
	{
		String reqs = e.requires.len ? string::join(tmem, e.requires, ",") : "-";
		out.appendf("%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", e.name, e.kind.name, e.origin, e.id,
			e.version, e.pin, e.hash, e.role.name, reqs);
	}
	sys::write_atomic(self.file, out.str_view())!;
}

fn Entry*? Lock.get(&self, String name)
{
	foreach (&e : self.entries) if (e.name == name) return e;
	return NOT_FOUND~;
}

fn bool Lock.has(&self, String name) => @ok(self.get(name));

// Add or replace the entry with the same name.
fn void Lock.put(&self, Entry entry)
{
	if (try e = self.get(entry.name))
	{
		*e = entry;
		return;
	}
	self.entries.push(entry);
}

fn void Lock.del(&self, String name)
{
	foreach (i, e : self.entries)
	{
		if (e.name != name) continue;
		self.entries.remove_at(i);
		return;
	}
}

// Can `from` reach `to` through the recorded requirements?
fn bool Lock.reaches(&self, String from, String to)
{
	List{String} queue;
	queue.tinit();
	queue.push(from);
	for (sz i = 0; i < queue.len(); i++)
	{
		if (queue[i] == to) return true;
		Entry*? e = self.get(queue[i]);
		if (catch e) continue;
		foreach (r : e.requires) if (!queue.contains(r)) queue.push(r);
	}
	return false;
}

// The libraries that require `name`.
fn String[] Lock.dependents(&self, String name)
{
	List{String} out;
	out.tinit();
	foreach (e : self.entries)
	{
		if (e.name != name && array::contains(e.requires, name)) out.push(e.name);
	}
	return out.array_view();
}

<*
 How the project gets to `name`: a library it added, then each library that
 requires the next, down to `name` ({ name } when it was added directly); the
 shortest such chain, empty if none.
*>
fn String[] Lock.chain(&self, String name)
{
	List{String} names;  // breadth first, up through the dependents
	List{sz} from;       // from[i]: where names[i] was reached from
	names.tinit();
	from.tinit();
	names.push(name);
	from.push(0);
	for (sz i = 0; i < names.len(); i++)
	{
		Entry*? e = self.get(names[i]);
		if (catch e) continue;
		if (e.role == DIRECT)
		{
			List{String} out;
			out.tinit();
			for (sz j = i; j; j = from[j]) out.push(names[j]);
			out.push(name);
			return out.array_view();
		}
		foreach (d : self.dependents(names[i]))
		{
			if (names.contains(d)) continue;
			names.push(d);
			from.push(i);
		}
	}
	return {};
}

// Dependency libraries that no direct library reaches.
fn String[] Lock.orphans(&self)
{
	List{String} reached;
	reached.tinit();
	foreach (e : self.entries) if (e.role == DIRECT) reached.push(e.name);
	for (sz i = 0; i < reached.len(); i++)
	{
		Entry*? e = self.get(reached[i]);
		if (catch e) continue;
		foreach (r : e.requires) if (self.has(r) && !reached.contains(r)) reached.push(r);
	}
	List{String} out;
	out.tinit();
	foreach (e : self.entries) if (!reached.contains(e.name)) out.push(e.name);
	return out.array_view();
}
