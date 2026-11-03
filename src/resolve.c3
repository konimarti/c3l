<*
 Following what libraries require. Each library is installed once (the lock is
 the memory); a registry library is raised to the highest minimum asked for, a
 different major version is an error; a cycle is a warning (an error with
 --strict), never a loop.
*>
module c3l::install;

import std::io, std::os, libc;
import c3l::log, c3l::sys, c3l::lock, c3l::manifest, c3l::semver, c3l::registry, c3l::vendor, c3l::git;

const String[] BUILTIN_HOSTS = { "github.com", "codeberg.org" };

fn void? Op.follow(&self, String parent, Requirement[] reqs)
{
	if (!reqs.len) return;
	self.stack.push(parent);
	defer (void)self.stack.remove_last();
	foreach (r : reqs)
	{
		sys::check_interrupt()!;
		self.resolve(parent, r)!;
	}
}

fn void? Op.resolve(&self, String parent, Requirement r)
{
	if (r.name == parent)
	{
		if (self.opts.strict) return log::fail("%s lists itself as a dependency (--strict)", parent)~;
		log::warn("%s lists itself as a dependency; ignored", parent);
		return;
	}
	if (self.stack.contains(r.name)) return self.cycle(self.path_to(r.name));
	if (try e = self.proj.lock.get(r.name))
	{
		if (self.proj.lock.reaches(r.name, parent))
		{
			self.cycle(string::tformat("%s -> ... -> %s (through installed libraries)", self.path_to(r.name), parent))!;
		}
		return self.satisfy(parent, *e, r);
	}
	if (!r.source.len)
	{
		if (self.proj.has_dep(r.name)! || sys::exists(self.file_of(r.name))) return;
		log::warn("%s needs '%s' but declares no source for it; install it with: c3l add <ns/name|git-url>", parent, r.name);
		return;
	}
	if (++self.count > max_deps()) return log::fail("more than %d transitive libraries; refusing (see C3L_MAX_DEPS)", max_deps())~;

	Want w;
	switch
	{
		case r.source.starts_with("vendor:"):
			self.trust(vendor::url())!;
			w = { .kind = VENDOR, .origin = registry::base(vendor::url()), .id = r.source["vendor:".len..] };
		case is_git_url(r.source):
			if (!lock::valid_git_url(r.source)) return log::fail("%s requires '%s' from '%s', which is not a git URL c3l fetches from", parent, r.name, r.source)~;
			self.trust(r.source)!;
			w = { .kind = GIT, .origin = r.source, .ref = git_ref(r.version) };
		case registry::is_id(r.source):
			String origin = self.registry_of(r);
			if (!self.registry_known(origin)) self.trust(origin)!;
			w = { .kind = REGISTRY, .origin = origin, .id = r.source, .ref = plain_version(r.version) };
		default:
			return log::fail("%s requires '%s' from '%s', which is neither <namespace>/<name> nor a git URL", parent, r.name, r.source)~;
	}
	Manifest m = self.install(w, DEP)!;
	if (m.provides != r.name)
	{
		return log::fail("%s requires '%s' from %s, but that library is '%s'", parent, r.name, r.source, m.provides)~;
	}
	log::info("  %s installed for %s", m.provides, parent);
	self.follow(m.provides, m.requires)!;
}

<*
 `r` names a library that is already installed (`e`): it must come from the
 same source; a registry library is raised to a higher minimum of the same major.
*>
fn void? Op.satisfy(&self, String parent, Entry e, Requirement r)
{
	if (r.source.len && !self.same_source(e, r))
	{
		String reg = r.registry.len ? string::tformat("%s ", r.registry) : "";
		return log::fail("'%s' is installed from %s but %s requires it from %s%s. Library names are global in a project; remove one of them", e.name, e.source(), parent, reg, r.source)~;
	}
	if (!r.version.len) return;
	if (e.kind != REGISTRY)
	{
		String want = git_ref(r.version);
		if (want != e.version) log::warn("%s wants %s@%s, keeping the installed %s (the first requirement wins)", parent, e.name, want, e.version);
		return;
	}
	String want = plain_version(r.version);
	if (!semver::valid(want) || !semver::valid(e.version)) return;
	if (semver::major(want) != semver::major(e.version))
	{
		return log::fail("version conflict: %s needs %s %s (major %s) but %s (major %s) is installed", parent, e.name, want, semver::major(want), e.version, semver::major(e.version))~;
	}
	if (semver::compare(e.version, want) >= 0) return;
	log::info("  %s %s -> %s (required by %s)", e.name, e.version, want, parent);
	Manifest m = self.install({ .kind = REGISTRY, .origin = e.origin, .id = e.id, .ref = want }, KEEP)!;
	self.follow(m.provides, m.requires)!;
}

<*
 `name` was just installed at a new version: the libraries that require it
 must accept that major (the same rule as above, seen from the other side).
*>
fn void? Op.check_dependents(&self, String name)
{
	String version = plain_version(self.proj.lock.get(name).version ?? "");
	if (!semver::valid(version)) return;
	foreach (d : self.proj.lock.dependents(name))
	{
		foreach (r : (manifest::load(self.file_of(d)) ?? (Manifest){}).requires)
		{
			String want = plain_version(r.version);
			if (r.name != name || !semver::valid(want) || semver::major(want) == semver::major(version)) continue;
			return log::fail("version conflict: %s needs %s %s (major %s), not %s; update or remove %s first", d, name, want, semver::major(want), version, d)~;
		}
	}
}

fn bool Op.same_source(&self, Entry e, Requirement r)
{
	switch (e.kind)
	{
		case REGISTRY: return registry::is_id(r.source) && r.source == e.id && self.registry_of(r) == e.origin;
		case VENDOR: return r.source == string::tformat("vendor:%s", e.id);
		default: return git::canonical(r.source) == git::canonical(e.origin);
	}
}

// The registry a requirement comes from: the one it names, else the default.
fn String Op.registry_of(&self, Requirement r) => registry::base(r.registry.len ? r.registry : self.opts.registry);

// Known: the default registry, or one a locked library already comes from.
fn bool Op.registry_known(&self, String origin)
{
	if (origin == registry::base(self.opts.registry)) return true;
	foreach (e : self.proj.lock.entries) if (e.kind == REGISTRY && e.origin == origin) return true;
	return false;
}

fn void? Op.cycle(&self, String path)
{
	if (self.opts.strict) return log::fail("dependency cycle: %s (--strict)", path)~;
	log::warn("dependency cycle: %s (each library is installed once)", path);
}

// "a -> b -> name"
fn String Op.path_to(&self, String name)
{
	DString s = dstring::temp();
	foreach (x : self.stack) s.appendf("%s -> ", x);
	s.append(name);
	return s.str_view();
}

<*
 A manifest from the internet can name any git URL: fetch only from trusted
 hosts (built-in, --allow-host, $C3L_ALLOWED_HOSTS separated by commas or
 spaces, typed by the user), or ask.
*>
fn void? Op.trust(&self, String url)
{
	String host = host_of(url);
	if (!host.len) return log::fail("refusing to fetch %s: no host in the URL", url)~;
	foreach (h : BUILTIN_HOSTS) if (h == host) return;
	foreach (list : (env::tget_var("C3L_ALLOWED_HOSTS") ?? "").tsplit(","))
	{
		foreach (h : list.tsplit(" ")) if (h == host) return;
	}
	if (self.opts.hosts.contains(host)) return;
	if (libc::isatty(0) && libc::isatty(2))
	{
		io::eprintf("A dependency wants to fetch from '%s' (%s). Allow? [y/N] ", host, url);
		String answer = io::treadline() ?? "";
		sys::check_interrupt()!;
		if (answer.starts_with("y") || answer.starts_with("Y"))
		{
			self.opts.hosts.push(host);
			return;
		}
	}
	return log::fail("refusing to fetch %s: host '%s' is not trusted. Allow it with --allow-host %s (or $C3L_ALLOWED_HOSTS)", url, host, host)~;
}

<*
 The host a URL fetches from, lowercased: "file" for local paths, empty when
 there is none or it is not a plain host name (so it is never trusted).
*>
fn String host_of(String url)
{
	if (url.starts_with("file://") || sys::is_local_path(url)) return "file";
	String h;
	if (url.starts_with("git@"))
	{
		h = url["git@".len..];
		h = h[:h.index_of_char(':') ?? h.len];
	}
	else
	{
		sz scheme = url.index_of("://") ?? -1;
		if (scheme < 0) return "";
		h = url[scheme + 3..];
		sz end = h.len;  // the authority ends at the path, query or fragment
		foreach (i, c : h)
		{
			if (c != '/' && c != '?' && c != '#') continue;
			end = i;
			break;
		}
		h = h[:end];
		if (h.contains("\\")) return "";  // some URL parsers take it for a '/'
		if (try at = h.rindex_of_char('@')) h = h[at + 1..];
		h = h[:h.index_of_char(':') ?? h.len];
	}
	if (!h.len) return "";
	foreach (c : h) if (!c.is_alnum() && c != '.' && c != '-') return "";
	return h.to_lower_tcopy();
}

fn bool is_git_url(String s)
{
	return s.contains("://") || s.starts_with("git@") || sys::is_local_path(s);
}

// ">=1.2.0", "^1.2.0", "~1.2.0" -> "1.2.0" (the constraint is a minimum either way)
fn String git_ref(String v)
{
	foreach (op : (String[]){ ">=", "^", "~" }) v = v.strip_prefix(op);
	return v;
}

fn String plain_version(String v) => git_ref(v).strip_prefix("v");

fn int max_deps() @private => (env::tget_var("C3L_MAX_DEPS") ?? "200").to_int() ?? 200;
