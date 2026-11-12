<*
 Which files of a library directory belong in its package: what the manifest
 and the C3 compiler's library loading read, and nothing else. A pure
 function of the manifest, the files git offers (candidates) and the files it
 ignores, so it can be tested without a repository.

 Patterns mean what they mean to c3c in a library's "sources": a file is
 itself, a directory is every file below it, `dir/*` the files directly in it,
 `dir/**` every file below it; hidden entries (a name starting with '.') are
 not found by a directory or a wildcard.
*>
module c3l::select;

import std::collections::list, std::collections::object, std::encoding::json, std::sort, c3l::manifest;

// A packed file and the rule that took it.
struct Pick
{
	String path;
	String rule;
}

struct Selection
{
	Pick[] picked;     // sorted by path
	String[] left_out; // candidates that are not packed
	String[] errors;
	String[] warnings;
}

const String[] C3_EXT = { ".c3", ".c3i", ".c3t" };
const String[] C_EXT = { ".c", ".m" };
const String[] HEADER_EXT = { ".h", ".hh", ".hpp", ".hxx", ".inc" };

faultdef BAD_PATH;

struct Chooser @private
{
	String[] cand;
	String[] ign;
	List{Pick} picked;
	List{String} errors;
	List{String} warnings;
}

<*
 @param manifest : "the text of manifest.json"
 @param candidates : "the library's files git tracks or does not ignore, without lib/, build/ and the like"
 @param ignored : "the files git ignores (to tell a pattern that names only those)"
 @param platforms : "every platform name c3c knows, for a manifest without \"targets\""
 @param lock_entries : "c3l.lock has at least one entry"
*>
fn Selection choose(String manifest, String[] candidates, String[] ignored, String[] platforms, bool lock_entries)
{
	Chooser c = { .cand = candidates, .ign = ignored };
	c.picked.tinit();
	c.errors.tinit();
	c.warnings.tinit();
	c.run(manifest, platforms, lock_entries);
	sort::quicksort(&c.picked, fn int(Pick a, Pick b) => a.path.compare_to(b.path));
	List{String} left;
	left.tinit();
	foreach (f : candidates)
	{
		if (!c.taken(f)) left.push(f);
	}
	return { c.picked.array_view(), left.array_view(), c.errors.array_view(), c.warnings.array_view() };
}

fn void Chooser.run(&self, String text, String[] platforms, bool lock_entries)
{
	Object* root = json::tparse(text) ?? null;
	if (!root || !root.is_map())
	{
		self.errors.push("manifest.json cannot be read as JSON");
		return;
	}
	if (self.has("manifest.json"))
	{
		self.pick("manifest.json", "manifest");
	}
	else
	{
		self.errors.push("manifest.json is not among the files git offers (is it ignored?)");
	}
	if (lock_entries && self.has("c3l.lock")) self.pick("c3l.lock", "lock");
	foreach (f : self.cand)
	{
		if (f.contains("/")) continue;
		if (starts_with_nocase(f, "LICENSE")) self.pick(f, "licence");
		if (starts_with_nocase(f, "README")) self.pick(f, "readme");
	}

	// what the manifest and each target name
	List{String} tkeys;
	tkeys.tinit();
	List{String} sources, csources, includes, execs;
	sources.tinit();
	csources.tinit();
	includes.tinit();
	execs.tinit();
	sources.push_all(manifest::strings(root, "sources"));
	bool top_sources = sources.len() > 0;
	csources.push_all(manifest::strings(root, "c-sources"));
	includes.push_all(manifest::strings(root, "c-include-dirs"));
	execs.push_all(manifest::strings(root, "exec"));
	bool any_target_without_sources;
	Object* targets = root.get("targets") ?? null;
	bool has_targets = targets && targets.is_map();
	if (has_targets)
	{
		targets.@each_entry(; String key, Object* t)
		{
			tkeys.push(key);
			String[] own = manifest::strings(t, "sources");
			String[] over = manifest::strings(t, "sources-override");
			if (!own.len && !over.len) any_target_without_sources = true;
			sources.push_all(own);
			sources.push_all(over);
			csources.push_all(manifest::strings(t, "c-sources"));
			csources.push_all(manifest::strings(t, "c-sources-override"));
			includes.push_all(manifest::strings(t, "c-include-dirs"));
			includes.push_all(manifest::strings(t, "c-include-dirs-override"));
			execs.push_all(manifest::strings(t, "exec"));
		};
	}

	// C3 sources; without "sources" the library's top directory is compiled
	foreach (pat : sources) self.take_pattern("sources", pat, C3_EXT, string::tformat("source pattern %s", pat), false);
	if (!top_sources && (!has_targets || any_target_without_sources))
	{
		foreach (f : self.cand)
		{
			if (!f.contains("/") && has_ext(f, C3_EXT)) self.pick(f, "top directory (no \"sources\")");
		}
	}

	// C sources, the headers next to them and in the include directories
	List{String} header_dirs;
	header_dirs.tinit();
	foreach (pat : csources)
	{
		foreach (f : self.take_pattern("c-sources", pat, C_EXT, string::tformat("source pattern %s", pat), false))
		{
			String dir = dirname(f);
			if (header_dirs.contains(dir)) continue;
			header_dirs.push(dir);
			foreach (h : self.cand)
			{
				if (dirname(h) == dir && has_ext(h, HEADER_EXT)) self.pick(h, "header");
			}
		}
	}
	foreach (pat : includes) self.take_pattern("c-include-dirs", pat, HEADER_EXT, "header", true);

	// prebuilt libraries
	String base = root.get_string("linklib-dir") ?? "";
	if (base.len)
	{
		if (try n = normalize(base))
		{
			base = n;
		}
		else
		{
			self.errors.push(string::tformat("manifest.json \"linklib-dir\": '%s' points outside the library", base));
			base = "";
		}
	}
	String[] wanted = has_targets ? tkeys.array_view() : platforms;
	foreach (p : wanted)
	{
		String dir = base.len ? string::tformat("%s/%s", base, p) : p;
		if (self.take_dir(dir)) continue;
		// c3c falls back to the operating system's directory: "macos-x64" -> "macos"
		if (try i = p.index_of_char('-'))
		{
			String os = p[:i];
			self.take_dir(base.len ? string::tformat("%s/%s", base, os) : os);
		}
	}

	// exec: the files a command names
	bool exec_files;
	foreach (cmd : execs)
	{
		exec_files = true;
		foreach (word : cmd.tsplit(" ", skip_empty: true))
		{
			String w = word.trim("\"'");
			if (try n = normalize(w))
			{
				if (n.len && self.has(n)) self.pick(n, "exec");
			}
		}
	}
	if (exec_files)
	{
		self.warnings.push("manifest.json runs \"exec\" commands: only the files they name are packed; c3l cannot see what else a script uses");
	}
}

// Files matching `pat`; errors and warnings for what matches nothing. `dirs`: the pattern is a directory.
fn String[] Chooser.take_pattern(&self, String key, String pat, String[] exts, String rule, bool dirs)
{
	String? n = normalize(pat);
	if (catch n)
	{
		self.errors.push(string::tformat("manifest.json \"%s\": '%s' points outside the library (no absolute paths, no '..')", key, pat));
		return {};
	}
	bool literal;
	String[] found = expand(n, self.cand, exts, &literal);
	if (literal && !dirs && !has_ext(n, exts))
	{
		self.errors.push(string::tformat("manifest.json \"%s\": '%s' is not a %s file", key, pat, exts[0]));
		return {};
	}
	foreach (f : found) self.pick(f, rule);
	if (found.len) return found;
	bool unused;
	String[] hidden = expand(n, self.ign, exts, &unused);
	if (hidden.len)
	{
		self.errors.push(string::tformat("manifest.json \"%s\": '%s' matches only files git ignores (%s%s)", key, pat, hidden[0], hidden.len > 1 ? ", ..." : ""));
	}
	else if (!dirs && has_ext(n, exts))
	{
		self.errors.push(string::tformat("manifest.json \"%s\": '%s' names no file", key, pat));
	}
	else
	{
		self.warnings.push(string::tformat("manifest.json \"%s\": '%s' matches no file", key, pat));
	}
	return {};
}

// Every file below `dir`; false when there is none.
fn bool Chooser.take_dir(&self, String dir)
{
	bool found;
	String prefix = string::tformat("%s/", dir);
	foreach (f : self.cand)
	{
		if (!f.starts_with(prefix)) continue;
		self.pick(f, string::tformat("platform library %s", dir));
		found = true;
	}
	return found;
}

fn bool Chooser.has(&self, String path)
{
	foreach (f : self.cand) if (f == path) return true;
	return false;
}

fn bool Chooser.taken(&self, String path)
{
	foreach (&p : self.picked) if (p.path == path) return true;
	return false;
}

fn void Chooser.pick(&self, String path, String rule)
{
	if (!self.taken(path)) self.picked.push({ path, rule });
}

<*
 The files of `pool` that `pat` (normalized) selects; `literal` is set when
 it names one file of the pool.
*>
fn String[] expand(String pat, String[] pool, String[] exts, bool* literal) @private
{
	List{String} out;
	out.tinit();
	foreach (f : pool)
	{
		if (f == pat)
		{
			*literal = true;
			out.push(f);
			return out.array_view();
		}
	}
	bool recursive = true;
	String base = pat.len ? string::tformat("%s/", pat) : "";
	if (pat == "**" || pat.ends_with("/**"))
	{
		base = pat[:pat.len - 2];
	}
	else if (pat == "*" || pat.ends_with("/*"))
	{
		base = pat[:pat.len - 1];
		recursive = false;
	}
	foreach (f : pool)
	{
		if (!f.starts_with(base)) continue;
		String rest = f[base.len..];
		if (!recursive && rest.contains("/")) continue;
		if (hidden_part(rest) || !has_ext(f, exts)) continue;
		out.push(f);
	}
	return out.array_view();
}

<*
 A path as c3c names it inside a library: '\' is '/', a leading "./" goes;
 absolute paths and any ".." are refused. "." is the library's directory ("").
*>
fn String? normalize(String p)
{
	DString s = dstring::temp();
	foreach (c : p) s.append_char(c == '\\' ? '/' : c);
	String n = s.str_view();
	while (n.starts_with("./")) n = n[2..];
	while (n.len > 1 && n.ends_with("/")) n = n[:n.len - 1];
	if (n == "." || (!n.len && p.len)) return "";
	if (!n.len || n[0] == '/' || (n.len > 1 && n[1] == ':')) return BAD_PATH~;
	foreach (part : n.tsplit("/")) if (part == "..") return BAD_PATH~;
	return n;
}

fn bool hidden_part(String rest) @private
{
	foreach (part : rest.tsplit("/")) if (part.len && part[0] == '.') return true;
	return false;
}

fn bool has_ext(String path, String[] exts) @private
{
	String name = path[(path.rindex_of_char('/') ?? -1) + 1..];
	foreach (e : exts) if (name.len > e.len && name.ends_with(e)) return true;
	return false;
}

fn String dirname(String path) @private
{
	return path[:path.rindex_of_char('/') ?? 0];
}

fn bool starts_with_nocase(String s, String prefix) @private
{
	if (s.len < prefix.len) return false;
	foreach (i, c : prefix)
	{
		char d = s[i];
		if (d >= 'a' && d <= 'z') d -= 32;
		if (d != c) return false;
	}
	return true;
}
