<*
 c3l.lock: a header line, then one library per line, 9 tab separated columns

   name kind origin id version pin hash role requires

 origin  where the library is fetched from, exactly as the fetcher wants it:
         registry base URL (no trailing slash), vendor release URL, git URL, directory
 id      <namespace>/<name> (registry), the library name (vendor), "-" otherwise
 version 1.2.3 | tag | HEAD | branch:NAME | commit:SHA12 | latest (vendor) | - (path)
 pin     sha256:<hex> (registry, vendor), commit:<sha> (git), - (path)
 hash    the same as pin, kept as its own column for older readers
 role    direct (asked for by the project) | dep (pulled in by another library)
 requires comma separated names this library requires, "-" if none
*>
module c3l::lock;

import std::io, std::collections::list, std::sort, c3l::log, c3l::sys;

const String HEADER = "# c3l.lock v1 - written by c3l, do not edit by hand\n";

enum Kind : char (String name)
{
	REGISTRY { "registry" },
	VENDOR { "vendor" },
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
 are refused, not guessed.
*>
fn Lock? load(String file)
{
	Lock lock = { .file = file };
	lock.entries.tinit();
	if (!file::exists(file)) return lock;
	String text = (String)file::load_temp(file) ?? log::fail("cannot read %s", file)~!;
	foreach (i, line : text.tsplit("\n"))
	{
		if (!line.len || line.starts_with("#")) continue;
		String[] col = line.tsplit("\t");
		Kind? kind = runtime::@enum_lookup(Kind, "name", col.len == 9 ? col[1] : "");
		Role? role = runtime::@enum_lookup(Role, "name", col.len == 9 ? col[7] : "");
		if (catch kind, role)
		{
			return log::fail("%s line %d does not have 9 columns (written by an older c3l?). Delete it and run 'c3l add' again, or restore the libraries with an older c3l first.", file, i + 1)~;
		}
		lock.entries.push({
			.name = col[0], .kind = kind, .origin = col[2], .id = col[3], .version = col[4],
			.pin = col[5], .hash = col[6], .role = role,
			.requires = col[8] == "-" ? {} : col[8].tsplit(","),
		});
	}
	return lock;
}

// A library name: [A-Za-z0-9][A-Za-z0-9._-]*
fn bool valid_name(String s)
{
	if (!s.len || !s[0].is_alnum()) return false;
	foreach (c : s) if (!c.is_alnum() && c != '.' && c != '_' && c != '-') return false;
	return true;
}

fn bool Lock.exists(&self) => file::exists(self.file);

// Header and entries sorted by name, replaced atomically.
fn void? Lock.save(&self)
{
	if (self.frozen) return;
	sort::quicksort(&self.entries, fn int(Entry a, Entry b) => a.name.compare_to(b.name));
	DString out = dstring::temp(HEADER);
	foreach (e : self.entries)
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
		if (e.name != name && array_has(e.requires, name)) out.push(e.name);
	}
	return out.array_view();
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

fn bool array_has(String[] list, String s) @private
{
	foreach (x : list) if (x == s) return true;
	return false;
}
