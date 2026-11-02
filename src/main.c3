// Copyright (C) 2025-2026 Koni Marti <koni.marti@gmail.com>. All Rights Reserved.
// This file is licensed under the MIT.
//
// c3l - reproducible dependencies for C3 projects.
module c3l;

import std::io;
import serp;

const String VERSION = "1.1.0";

fn int main(String[] args)
{
	Command* app = serp::app("c3l", VERSION, "reproducible dependencies for C3 projects");
	defer app.free();
	app.add(serp::cmd("version", "print the version", &version_run).accepts(serp::no_args()));
	return app.execute(args);
}

fn void? version_run(Ctx* ctx)
{
	ctx.println("c3l %s", VERSION)!;
}
