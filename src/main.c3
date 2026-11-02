// Copyright (C) 2025-2026 Koni Marti <koni.marti@gmail.com>. All Rights Reserved.
// This file is licensed under the MIT.
//
// c3l - reproducible dependencies for C3 projects.
module c3l;

import std::io, serp, c3l::registry;

const String VERSION = "1.1.0";

fn int main(String[] args)
{
	Command* app = serp::app("c3l", VERSION, "reproducible dependencies for C3 projects")
		.persistent_flag({ .name = "registry", .kind = STRING, .env = "C3L_REGISTRY", .default_value = registry::DEFAULT,
			.value_name = "URL", .desc = "registry base URL for new installs, search, info and publish" });
	defer app.free();

	app.add(serp::cmd("init", "create c3l.lock (and a project with 'c3c init name')", &init_run)
		.usage_args("[name]")
		.accepts(serp::max_args(1)));
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
	app.add(serp::cmd("version", "print the version", &version_run).accepts(serp::no_args()));
	return app.execute(args);
}

fn void? version_run(Ctx* ctx)
{
	ctx.println("c3l %s", VERSION)!;
}
