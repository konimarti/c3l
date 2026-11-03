// Copyright (C) 2025-2026 Koni Marti <koni.marti@gmail.com>. All Rights Reserved.
// This file is licensed under the MIT.
//
// c3l - reproducible dependencies for C3 projects.
module c3l;

import std::io, serp, c3l::registry, c3l::sys;

const String VERSION = "2.0.0";

fn int main(String[] args)
{
	Command* app = serp::app("c3l", VERSION, "reproducible dependencies for C3 projects")
		.persistent_flag({ .name = "registry", .kind = STRING, .env = "C3L_REGISTRY", .default_value = registry::DEFAULT,
			.value_name = "URL", .desc = "registry base URL for new installs, search, info and publish" })
		.persistent_flag({ .name = "strict", .desc = "a C3 release or platform mismatch, or a dependency cycle, is an error" })
		.persistent_flag({ .name = "allow-host", .kind = STRING, .value_name = "HOST",
			.desc = "trust a git or registry host named by a dependency (repeatable)" })
		.persistent_flag({ .name = "dry-run", .desc = "with update, prune, publish: show what would change" })
		.persistent_flag({ .name = "frozen", .desc = "with sync: fail if lock and project disagree, never write the lock" })
		.persistent_flag({ .name = "fail-fast", .desc = "with sync, update: stop at the first failure" })
		.persistent_flag({ .name = "force", .desc = "with remove: remove even if another library requires it" })
		.persistent_flag({ .name = "registry-type", .kind = STRING, .env = "C3L_REGISTRY_TYPE", .choices = { "static", "c3pkg" },
			.desc = "the registry's API (default: detected)" });
	defer app.free();

	app.add(serp::cmd("init", "create c3l.lock (and a project with 'c3c init name')", &init_run)
		.usage_args("[name]")
		.accepts(serp::max_args(1)));
	app.add(serp::cmd("add", "install a library, verify it, lock it", &add_run)
		.aka("fetch").aka("f").aka("get").aka("g")
		.usage_args("<ns/name[@version]> | vendor:<name> | <git-url>[@ref] [ref] | <./dir>")
		.accepts(serp::range_args(1, 2)));
	app.add(serp::cmd("remove", "remove a library, its project entry and lock line", &remove_run)
		.aka("rm").aka("r").aka("delete")
		.usage_args("<name>")
		.accepts(serp::exact_args(1)));
	app.add(serp::cmd("prune", "remove dependency libraries nothing needs any more", &prune_run)
		.accepts(serp::no_args()));
	app.add(serp::cmd("update", "update to the newest version, or to name@ref", &update_run)
		.aka("u")
		.usage_args("[name[@ref]]...")
		.accepts(serp::any_args()));
	app.add(serp::cmd("sync", "restore exactly what c3l.lock says", &sync_run)
		.aka("pull").aka("p")
		.accepts(serp::no_args()));
	app.add(serp::cmd("migrate", "convert a c3po project.lock.json or a c3l 0.x .c3l.deps to c3l.lock", &migrate_run).accepts(serp::no_args()));
	app.add(serp::cmd("list", "show locked libraries and their state", &list_run)
		.aka("ls").aka("l")
		.accepts(serp::no_args())
		.flag({ .name = "tree", .desc = "show the dependency graph" }));
	app.add(serp::cmd("verify", "check installed files against c3l.lock", &verify_run).accepts(serp::no_args()));
	app.add(serp::cmd("outdated", "show libraries with newer versions", &outdated_run).accepts(serp::no_args()));
	app.add(serp::cmd("why", "show which libraries require <name>", &why_run)
		.usage_args("<name>")
		.accepts(serp::exact_args(1)));
	app.add(serp::cmd("search", "search the registry", &search_run)
		.aka("s")
		.usage_args("<text|tag:name>")
		.accepts(serp::min_args(1)));
	app.add(serp::cmd("info", "show the registry record of a library", &info_run)
		.usage_args("<namespace>/<name>")
		.accepts(serp::exact_args(1)));
	app.add(publish_flags(serp::cmd("check", "verify a library is ready to publish (no upload)", &check_run)));
	app.add(publish_flags(serp::cmd("pack", "build the deterministic <name>-<version>.c3l", &pack_run))
		.flag({ .name = "output", .kind = STRING, .value_name = "FILE", .desc = "where to write the package" }));
	app.add(publish_flags(serp::cmd("publish", "check, pack and upload to the registry", &publish_run))
		.flag({ .name = "token-file", .kind = STRING, .value_name = "FILE", .desc = "API token (or $C3L_TOKEN, $C3PKG_TOKEN)" })
		.flag({ .name = "license", .kind = STRING, .value_name = "ID", .desc = "SPDX license id" })
		.flag({ .name = "tags", .kind = STRING, .value_name = "a,b", .desc = "comma separated tags" })
		.flag({ .name = "docs-url", .kind = STRING, .value_name = "URL", .desc = "documentation URL" })
		.flag({ .name = "git-url", .kind = STRING, .value_name = "URL", .desc = "repository URL" }));
	app.add(serp::cmd("version", "print the version", &version_run).accepts(serp::no_args()));
	sys::setup();
	sys::catch_signals();
	int status = app.execute(args);
	return sys::interrupted ? 130 : status;
}

fn void? version_run(Ctx* ctx)
{
	ctx.println("c3l %s", VERSION)!;
}
