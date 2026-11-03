<*
 A deterministic zip writer: stored entries, fixed timestamps (1980-01-01),
 the order given. The same files always give the same bytes, which the stdlib
 writer cannot promise (it stamps the current time).
*>
module c3l::publish;

import std::io, std::hash::crc32, std::collections::list, c3l::log;

const ushort DOS_DATE = (0 << 9) | (1 << 5) | 1;  // 1980-01-01
const ushort VERSION = 20;
const ushort UTF8_NAMES = 1 << 11;
const uint UNIX_FILE = 0o100644u << 16;

<*
 Write `names` (paths relative to `dir`, in this order) into the zip `out`.
*>
fn void? write_zip(String dir, String[] names, String out)
{
	if (names.len > 0xFFFF) return log::fail("too many files for a .c3l (%d)", names.len)~;
	DString zip = dstring::temp();
	DString central = dstring::temp();
	foreach (name : names)
	{
		char[] data = file::load_temp(string::tformat("%s/%s", dir, name)) ?? log::fail("cannot read %s/%s", dir, name)~!;
		if ((ulong)zip.len() + data.len > 0xFFFF_FFFF) return log::fail("%s is too large for a .c3l", out)~;
		uint crc = crc32::hash(data);
		uint offset = (uint)zip.len();

		le32(&zip, 0x04034b50);
		header(&zip, crc, data.len, name.len);
		zip.append(name);
		zip.append(data);

		le32(&central, 0x02014b50);
		le16(&central, 3 << 8 | VERSION);  // made by: unix
		header(&central, crc, data.len, name.len);
		le16(&central, 0);  // comment length
		le16(&central, 0);  // disk
		le16(&central, 0);  // internal attributes
		le32(&central, UNIX_FILE);
		le32(&central, offset);
		central.append(name);
	}
	uint cd_offset = (uint)zip.len();
	zip.append(central.str_view());
	le32(&zip, 0x06054b50);
	le16(&zip, 0);
	le16(&zip, 0);
	le16(&zip, (ushort)names.len);
	le16(&zip, (ushort)names.len);
	le32(&zip, (uint)central.len());
	le32(&zip, cd_offset);
	le16(&zip, 0);
	file::save(out, zip.str_view()) ?? log::fail("cannot write %s", out)~!;
}

// The fields local and central headers share, from "version needed" to "extra length".
fn void header(DString* s, uint crc, sz size, sz name_len) @private
{
	le16(s, VERSION);
	le16(s, UTF8_NAMES);
	le16(s, 0);  // stored
	le16(s, 0);  // time 00:00:00
	le16(s, DOS_DATE);
	le32(s, crc);
	le32(s, (uint)size);
	le32(s, (uint)size);
	le16(s, (ushort)name_len);
	le16(s, 0);  // extra length
}

fn void le16(DString* s, ushort v) @private
{
	s.append_char((char)v);
	s.append_char((char)(v >> 8));
}

fn void le32(DString* s, uint v) @private
{
	le16(s, (ushort)v);
	le16(s, (ushort)(v >> 16));
}
