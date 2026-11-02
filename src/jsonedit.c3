<*
 Edit one top-level string array of a JSON5 file (project.json "dependencies")
 without touching anything else: comments, layout and the other keys stay as
 they are, only the array itself is rewritten.
*>
module c3l::project;

import std::collections::list;

<*
 `text` with `name` added to (or removed from) the top-level array `key`.
 Adding to a missing key creates it right after the opening brace.
*>
fn String edit_array(String text, String key, String name, bool add)
{
	Scanner sc = { .s = text };
	List{String} items;
	items.tinit();
	sz start, end;
	bool found;
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
				if (sc.peek() != '[') break;
				start = sc.p++;
				for (sc.skip_space(); sc.p < text.len && text[sc.p] != ']'; sc.skip_space())
				{
					if (sc.peek() == '"' || sc.peek() == '\'')
					{
						items.push(sc.read_string());
						continue;
					}
					sc.p++;
				}
				end = sc.p + 1;
				found = true;
			case c == '{' || c == '[':
				depth++;
				sc.p++;
			case c == '}' || c == ']':
				depth--;
				sc.p++;
			default:
				sc.p++;
		}
		if (found) break;
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

	if (found) return string::tformat("%s%s%s", text[:start], list, text[end..]);
	if (!add) return text;
	sz brace = text.index_of_char('{') ?? 0;
	return string::tformat("%s\n  \"%s\": %s,%s", text[:brace + 1], key, list, text[brace + 1..]);
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
