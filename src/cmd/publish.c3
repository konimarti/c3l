<*
 Commands for library authors: check, pack, publish.
*>
module c3l;

import std::io, serp, c3l::log, c3l::sys, c3l::publish, c3l::registry;

fn void? check_run(Ctx* ctx)
{
	Package p = publish::check(ctx.arg(0, "."), settings(ctx)!);
	if (p.errors) return serp::FAILED~;
}

fn void? pack_run(Ctx* ctx)
{
	Settings s = settings(ctx)!;
	s.offline = true;
	Package p = publish::check(ctx.arg(0, "."), s);
	if (p.errors) return log::fail("not packing: %d problem(s) found", p.errors)~;
	if (s.list) return;  // --list: what would be packed, no package
	String out = ctx.flag_string("output");
	if (!out.len) out = string::tformat("%s/%s-%s.c3l", (String)(path::tcwd() ?? (Path)"."), p.name, p.version);
	log::info("packed %s (%s)", out, p.pack(out)!);
}

fn void? publish_run(Ctx* ctx)
{
	Settings s = settings(ctx)!;
	String base = registry::base(s.registry);
	bool guessed;
	if (registry::detect(base, s.registry_type, &guessed)! != C3PKG)
	{
		String hint = guessed ? ". The type was detected automatically; if this is a c3pkg registry, retry or pass --registry-type c3pkg" : "";
		return log::fail("registry %s is read-only (type 'static'); publishing needs a registry with an upload API such as c3pkg%s", base, hint)~;
	}
	Package p = publish::check(ctx.arg(0, "."), s);
	if (p.errors) return log::fail("not publishing: %d problem(s) found", p.errors)~;
	String tmp = sys::temp_dir()!;
	defer sys::remove(tmp);
	String file = string::tformat("%s/%s-%s.c3l", tmp, p.name, p.version);
	String sha = p.pack(file)!;
	if (ctx.flag_bool("dry-run"))
	{
		log::info("dry run: would publish %s %s (C3 %s, %s) to %s", p.name, p.version, p.c3_version, sha, base);
		return;
	}
	log::info("publishing %s %s to %s", p.name, p.version, base);
	p.upload(s, file, sha)!;
}

fn Settings? settings(Ctx* ctx)
{
	return {
		.registry = registry::publish_target(ctx.flag_strings("registry"))!,
		.registry_type = ctx.flag_string("registry-type"),
		.version = ctx.flag_string("version"),
		.c3_version = ctx.flag_string("c3-version"),
		.token_file = ctx.flag_string("token-file"),
		.allow_dirty = ctx.flag_bool("allow-dirty"),
		.no_build = ctx.flag_bool("no-build"),
		.offline = ctx.flag_bool("offline"),
		.list = ctx.flag_bool("list"),
		.description = ctx.flag_string("description"),
		.license = ctx.flag_string("license"),
		.tags = ctx.flag_string("tags"),
		.docs_url = ctx.flag_string("docs-url"),
		.git_url = ctx.flag_string("git-url"),
	};
}

// The flags check, pack and publish share.
fn Command* publish_flags(Command* c)
{
	return c
		.usage_args("[dir]")
		.accepts(serp::max_args(1))
		.flag({ .name = "version", .kind = STRING, .value_name = "X.Y.Z", .desc = "the version (default: semver tag on HEAD, manifest.json, project.json)" })
		.flag({ .name = "c3-version", .kind = STRING, .desc = "the C3 version it is published for (default: c3c --version)" })
		.flag({ .name = "allow-dirty", .desc = "allow uncommitted changes" })
		.flag({ .name = "no-build", .desc = "skip the compile check" })
		.flag({ .name = "offline", .desc = "do not ask the registry about existing versions" })
		.flag({ .name = "description", .kind = STRING, .desc = "package description (required on the first publish)" });
}
