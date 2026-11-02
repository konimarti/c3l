<*
 Semantic versions (semver 2.0 precedence). c3l accepts a loose form,
 `v?N[.N[.N]][-pre][+build]`, for what it reads (git tags, registry records)
 and the strict form `N.N.N[-pre]` for what it publishes.
*>
module c3l::semver;

fn bool valid(String v)
{
	if (v.starts_with("v")) v = v[1..];
	String core, pre, build;
	if (!split(v, &core, &pre, &build)) return false;
	String[] parts = core.tsplit(".");
	if (parts.len > 3) return false;
	foreach (n : parts) if (!is_number(n)) return false;
	return true;
}

// `N.N.N[-pre]`: no `v`, no leading zeros, no build metadata.
fn bool strict(String v)
{
	String core, pre, build;
	if (!split(v, &core, &pre, &build) || v.contains("+")) return false;
	if (pre.len && !pre[0].is_alnum()) return false;
	String[] parts = core.tsplit(".");
	if (parts.len != 3) return false;
	foreach (n : parts) if (!is_number(n) || (n.len > 1 && n[0] == '0')) return false;
	return true;
}

<*
 -1, 0 or 1. Missing core parts count as 0, build metadata is ignored and
 a prerelease sorts before its release.
*>
fn int compare(String a, String b)
{
	if (a.starts_with("v")) a = a[1..];
	if (b.starts_with("v")) b = b[1..];
	String acore, apre, bcore, bpre, ignored;
	(void)split(a, &acore, &apre, &ignored);
	(void)split(b, &bcore, &bpre, &ignored);

	String[] ac = acore.tsplit(".");
	String[] bc = bcore.tsplit(".");
	for (sz i = 0; i < 3; i++)
	{
		int c = compare_numbers(i < ac.len ? ac[i] : "0", i < bc.len ? bc[i] : "0");
		if (c) return c;
	}
	if (!apre.len || !bpre.len) return sign((long)bpre.len - (long)apre.len);

	String[] ap = apre.tsplit(".");
	String[] bp = bpre.tsplit(".");
	for (sz i = 0; i < ap.len && i < bp.len; i++)
	{
		bool an = is_number(ap[i]);
		bool bn = is_number(bp[i]);
		int c;
		switch
		{
			case an && bn: c = compare_numbers(ap[i], bp[i]);
			case an: c = -1;
			case bn: c = 1;
			default: c = sign(ap[i].compare_to(bp[i]));
		}
		if (c) return c;
	}
	return sign((long)ap.len - (long)bp.len);
}

// a > b, both valid versions.
fn bool newer(String a, String b) => valid(a) && valid(b) && compare(a, b) > 0;

// The major number: "v1.2.3" -> "1".
fn String major(String v)
{
	if (v.starts_with("v")) v = v[1..];
	if (try i = v.index_of_char('.')) return v[:i];
	return v;
}

<*
 "1.2.3-rc.1+b5" -> core "1.2.3", pre "rc.1", build "b5".
 False when a `-` or `+` part is empty or has characters other than [0-9A-Za-z.-].
*>
fn bool split(String v, String* core, String* pre, String* build) @private
{
	*pre = "";
	*build = "";
	if (try i = v.index_of_char('+'))
	{
		*build = v[i + 1..];
		v = v[:i];
		if (!ident_list(*build)) return false;
	}
	if (try i = v.index_of_char('-'))
	{
		*pre = v[i + 1..];
		v = v[:i];
		if (!ident_list(*pre)) return false;
	}
	*core = v;
	return true;
}

fn bool is_number(String s) @private
{
	if (!s.len) return false;
	foreach (c : s) if (!c.is_digit()) return false;
	return true;
}

// [0-9A-Za-z.-]+
fn bool ident_list(String s) @private
{
	if (!s.len) return false;
	foreach (c : s) if (!c.is_alnum() && c != '.' && c != '-') return false;
	return true;
}

// numeric comparison of digit strings of any length
fn int compare_numbers(String a, String b) @private
{
	while (a.len > 1 && a[0] == '0') a = a[1..];
	while (b.len > 1 && b[0] == '0') b = b[1..];
	if (a.len != b.len) return a.len < b.len ? -1 : 1;
	return sign(a.compare_to(b));
}

fn int sign(long x) @private => x < 0 ? -1 : x > 0 ? 1 : 0;
