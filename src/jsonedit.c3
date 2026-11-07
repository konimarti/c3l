<*
 Edit top-level members of a JSON5 file (project.json, manifest.json) without
 touching anything else: comments, layout and the other keys stay as they are,
 only the one value is rewritten.
*>
module c3l::jsonedit;

import std::collections::list, c3l::manifest;

faultdef BROKEN;  // an unclosed string or comment: the file is left alone

<*
 `text` with `name` added to (or removed from) the top-level array `key`.
 Adding to a missing key creates it right after the opening brace. A file the
 scanner cannot follow (an unclosed string, comment or array) is returned as it
 is; the caller checks the result.
*>
fn String edit_array(String text, String key, String name, bool add)
{
	List{String} items;
	items.tinit();
	sz? start = find_value(text, key);
	if (@catch(start) == BROKEN) return text;
	Scanner sc = { .s = text, .p = start ?? 0 };
	bool found = @ok(start) && sc.peek() == '[';
	if (found)
	{
		int depth;  // of arrays and objects inside the one being edited
		for (sc.p++, sc.skip_space(); sc.p < text.len && (depth || text[sc.p] != ']'); sc.skip_space())
		{
			char c = text[sc.p];
			if (c == '"' || c == '\'')
			{
				String item = sc.read_string();
				if (!depth) items.push(item);
				continue;
			}
			if (c == '[' || c == '{') depth++;
			if (c == ']' || c == '}') depth--;
			sc.p++;
		}
		if (sc.broken || sc.p >= text.len) return text;
	}

	DString list = dstring::temp("[");
	bool present;
	foreach (item : items)
	{
		if (item == name || manifest::bare_name(item) == name)  // "ns/name@1.0" is the library "name"
		{
			present = true;
			if (!add) continue;
		}
		list.appendf("%s\"%s\"", list.len() > 1 ? ", " : " ", item);
	}
	if (add && !present) list.appendf("%s\"%s\"", list.len() > 1 ? ", " : " ", name);
	list.append(list.len() > 1 ? " ]" : "]");

	if (found) return string::tformat("%s%s%s", text[:start!!], list, text[sc.p + 1..]);
	if (!add) return text;
	return insert_first(text, string::tformat("\"%s\": %s", key, list));
}

// `text` with the top-level string `key` set to `value` (added first if missing).
fn String set_string(String text, String key, String value)
{
	sz? at = find_value(text, key);
	if (@catch(at) == BROKEN) return text;
	if (catch at) return insert_first(text, string::tformat("\"%s\" : \"%s\"", key, value));
	Scanner sc = { .s = text, .p = at };
	if (sc.peek() != '"' && sc.peek() != '\'') return text;
	sc.read_string();
	if (sc.broken) return text;
	return string::tformat("%s\"%s\"%s", text[:at], value, text[sc.p..]);
}

// `member` (`"key": value`) as the first member of the top-level object.
fn String insert_first(String text, String member) @private
{
	sz? brace = text.index_of_char('{');
	if (catch brace) return text;
	Scanner sc = { .s = text, .p = brace + 1 };
	sc.skip_space();
	String sep = sc.peek() == '}' ? "\n" : ",";  // an empty object needs no comma
	return string::tformat("%s\n  %s%s%s", text[:brace + 1], member, sep, text[brace + 1..]);
}

// Where the value of the top-level member `key` starts; NOT_FOUND or BROKEN.
fn sz? find_value(String text, String key) @private
{
	Scanner sc = { .s = text };
	int depth;
	while (sc.p < text.len && !sc.broken)
	{
		char c = text[sc.p];
		String k;
		switch
		{
			case c == '/' && sc.p + 1 < text.len && (text[sc.p + 1] == '/' || text[sc.p + 1] == '*'):
				sc.skip_space();
				continue;
			case c == '"' || c == '\'':
				k = sc.read_string();
			case c.is_alpha() || c == '_' || c == '$':  // a JSON5 key without quotes (or true, null, ...)
				sz from = sc.p;
				while (sc.p < text.len && (text[sc.p].is_alnum() || text[sc.p] == '_' || text[sc.p] == '$' || text[sc.p] == '-')) sc.p++;
				k = text[from:sc.p - from];
			case c == '{' || c == '[':
				depth++;
				sc.p++;
				continue;
			case c == '}' || c == ']':
				depth--;
				sc.p++;
				continue;
			default:
				sc.p++;
				continue;
		}
		if (depth != 1 || k != key) continue;
		sc.skip_space();
		if (sc.peek() != ':') continue;
		sc.p++;
		sc.skip_space();
		return sc.p;
	}
	return sc.broken ? BROKEN~ : NOT_FOUND~;
}

struct Scanner @private
{
	String s;
	sz p;
	bool broken;  // an unclosed string or comment
}

fn char Scanner.peek(&self) => self.p < self.s.len ? self.s[self.p] : 0;

// whitespace, // and /* */ comments
fn void Scanner.skip_space(&self)
{
	String s = self.s;
	while (self.p < s.len)
	{
		char c = s[self.p];
		if (c == ' ' || c == '\t' || c == '\n' || c == '\r')
		{
			self.p++;
		}
		else if (c == '/' && s[self.p + 1..].starts_with("/"))
		{
			while (self.p < s.len && s[self.p] != '\n') self.p++;
		}
		else if (c == '/' && s[self.p + 1..].starts_with("*"))
		{
			sz? end = s[self.p + 2..].index_of("*/");
			if (catch end)
			{
				self.p = s.len;
				self.broken = true;
				return;
			}
			self.p += end + 4;
		}
		else
		{
			return;
		}
	}
}

<*
 The string at p, as the body of a double-quoted JSON string; p moves past
 the closing quote. A single-quoted string loses its \' escapes and gets its
 double quotes escaped.
*>
fn String Scanner.read_string(&self)
{
	char quote = self.s[self.p++];
	DString out = dstring::temp();
	while (self.p < self.s.len && self.s[self.p] != quote)
	{
		char c = self.s[self.p];
		if (c == '\\' && self.p + 1 < self.s.len)
		{
			char next = self.s[self.p + 1];
			if (quote == '\'' && next == '\'')
			{
				out.append_char('\'');
			}
			else
			{
				out.append_char(c);
				out.append_char(next);
			}
			self.p += 2;
			continue;
		}
		if (quote == '\'' && c == '"') out.append_char('\\');
		out.append_char(c);
		self.p++;
	}
	if (self.p >= self.s.len)
	{
		self.broken = true;
		return out.str_view();
	}
	self.p++;
	return out.str_view();
}
