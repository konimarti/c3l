<*
 Asking several registries at once: one thread per registry. A thread only does
 the request and copies its answer to the heap; everything else happens in the
 calling thread, in the order of the registries, so output does not depend on
 which registry answers first.
*>
module c3l::registry;

import std::thread, std::collections::list, std::collections::object, std::encoding::json;
import c3l::http;

const long PROBE_TIMEOUT = 10;  // seconds a registry has to answer

struct Failure
{
	String registry;
	String error;
}

// A registry that has the library.
struct Found
{
	Registry registry;
	String latest;
	String body;  // the info record as the registry sent it: the install need not ask again
}

enum JobKind : char { SEARCH, LOOKUP }

struct Job @private
{
	Registry reg;
	JobKind kind;
	String query;  // search: text; lookup: ns/name
	String tag;
	// the answer
	String error;  // not empty: the registry did not answer
	Hit[] hits;
	long total;
	bool found;
	String latest;
	String body;
}

fn int run_job(void* arg) @private
{
	Job* j = arg;
	// a thread other than the main one has no temp allocator until it is given one
	@pool_init(mem, 64 * 1024)
	{
		work(j);
	};
	return 0;
}

fn void work(Job* j) @private
{
	switch (j.kind)
	{
		case SEARCH:
			long total;
			Hit[]? hits = search(j.reg.url, j.query, j.tag, &total, PROBE_TIMEOUT);
			if (catch e = hits)
			{
				j.error = e == NO_SEARCH ? "no search API and no index.json".copy(mem) : "no answer".copy(mem);
				return;
			}
			j.total = total;
			Hit[] out = mem::new_array(Hit, hits.len);
			foreach (i, h : hits)
			{
				out[i] = { h.name.copy(mem), h.version.copy(mem), h.about.copy(mem), j.reg.name.copy(mem) };
			}
			j.hits = out;
		case LOOKUP:
			Response r = http::get(string::tformat("%s/info/%s", j.reg.url, j.query), PROBE_TIMEOUT);
			if (r.status == 404) return;
			if (!r.ok())
			{
				j.error = r.why().copy(mem);
				return;
			}
			Object* o = json::tparse(r.body) ?? null;
			if (!o || !o.is_map())
			{
				j.error = "not a registry answer".copy(mem);
				return;
			}
			j.found = true;
			j.latest = (o.get_string("latest") ?? "").copy(mem);
			j.body = r.body.copy(mem);
	}
}

fn Job[] run_all(Registry[] regs, JobKind kind, String query, String tag) @private
{
	http::warm_up();  // libcurl initialises itself on first use, which is not thread safe
	Job[] jobs = mem::new_array(Job, regs.len);
	Thread[] threads = mem::new_array(Thread, regs.len);
	bool[] started = mem::new_array(bool, regs.len);
	foreach (i, r : regs)
	{
		jobs[i] = { .reg = r, .kind = kind, .query = query, .tag = tag };
		if (regs.len > 1 && @ok(threads[i].create(&run_job, &jobs[i]))) started[i] = true;
	}
	foreach (i, r : regs)
	{
		if (started[i])
		{
			(void)threads[i].join();
		}
		else
		{
			run_job(&jobs[i]);
		}
	}
	return jobs;
}

<*
 Search every registry. The hits come in the order of `regs`, each with the registry
 it is from; `total` is how many match in all; `failures` gets the registries that did not answer.
*>
fn Hit[] search_all(Registry[] regs, String query, String tag, long* total, List{Failure}* failures)
{
	Job[] jobs = run_all(regs, SEARCH, query, tag);
	List{Hit} out;
	out.tinit();
	foreach (&j : jobs)
	{
		if (j.error.len)
		{
			failures.push({ j.reg.name, j.error });
			continue;
		}
		foreach (h : j.hits) out.push(h);
		*total += j.total;
	}
	return out.array_view();
}

<*
 The registries that have library `id` (ns/name), in the order of `regs`;
 `failures` gets the ones that did not answer.
*>
fn Found[] lookup_all(Registry[] regs, String id, List{Failure}* failures)
{
	Job[] jobs = run_all(regs, LOOKUP, id, "");
	List{Found} out;
	out.tinit();
	foreach (&j : jobs)
	{
		if (j.error.len)
		{
			failures.push({ j.reg.name, j.error });
		}
		else if (j.found)
		{
			out.push({ j.reg, j.latest, j.body });
		}
	}
	return out.array_view();
}
