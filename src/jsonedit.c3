<*
 Edit top-level members of a JSON5 file (project.json, manifest.json) without
 touching anything else: comments, layout and the other keys stay as they are,
 only the one value is rewritten.
*>
module c3l::project;

import std::collections::list;

<*
 `text` with `name` added to (or removed from) the top-level array `key`.
 Adding to a missing key creates it right after the opening brace.
*>
fn String edit_array(String text, String key, String name, bool add)
{
	List{String} items;
	items.tinit();
	sz? start = find_value(text, key);
	Scanner sc = { .s = text, .p = start ?? 0 };
	bool found = @ok(start) && sc.peek() == '[';
	if (found)
	{
		for (sc.p++, sc.skip_space(); sc.p < text.len && text[sc.p] != ']'; sc.skip_space())
		{
			if (sc.peek() == '"' || sc.peek() == '\'')
			{
				items.push(sc.read_string());
				continue;
			}
			sc.p++;
		}
	}

	DString list = dstring::temp("[");
	bool present;
	foreach (item : items)
	{
		if (item == name)
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
	Scanner sc = { .s = text, .p = at ?? 0 };
	if (catch at) return insert_first(text, string::tformat("\"%s\" : \"%s\"", key, value));
	if (sc.peek() != '"' && sc.peek() != '\'') return text;
	sc.read_string();
	return string::tformat("%s\"%s\"%s", text[:at], value, text[sc.p..]);
}

// `member` (`"key": value`) as the first member of the top-level object.
fn String insert_first(String text, String member)
{
	sz brace = text.index_of_char('{') ?? 0;
	return string::tformat("%s\n  %s,%s", text[:brace + 1], member, text[brace + 1..]);
}

// Where the value of the top-level member `key` starts.
fn sz? find_value(String text, String key) @private
{
	Scanner sc = { .s = text };
	int depth;
	while (sc.p < text.len)
	{
		char c = text[sc.p];
		switch
		{
			case c == '/' && sc.p + 1 < text.len && (text[sc.p + 1] == '/' || text[sc.p + 1] == '*'):
				sc.skip_space();
			case c == '"' || c == '\'':
				String k = sc.read_string();
				if (depth != 1 || k != key) break;
				sc.skip_space();
				if (sc.peek() != ':') break;
				sc.p++;
				sc.skip_space();
				return sc.p;
			case c == '{' || c == '[':
				depth++;
				sc.p++;
			case c == '}' || c == ']':
				depth--;
				sc.p++;
			default:
				sc.p++;
		}
	}
	return NOT_FOUND~;
}

struct Scanner @private
{
	String s;
	sz p;
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
			self.p += 2;
			while (self.p < s.len && !s[self.p..].starts_with("*/")) self.p++;
			self.p += 2;
		}
		else
		{
			return;
		}
	}
}

// The string at p (raw, escapes kept), p moves past the closing quote.
fn String Scanner.read_string(&self)
{
	char quote = self.s[self.p++];
	sz from = self.p;
	while (self.p < self.s.len && self.s[self.p] != quote)
	{
		self.p += self.s[self.p] == '\\' ? 2 : 1;
	}
	String str = self.s[from:(self.p < self.s.len ? self.p : self.s.len) - from];
	self.p++;
	return str;
}
