#! /usr/bin/env -S vala -X -w -X -I. --vapidir=. --pkg posix --pkg libpcre2-8 --pkg gio-2.0
// rpl: search and replace text in files
//
// © 2025 Reuben Thomas <rrt@sc3d.org>
//
// This program is free software; you can redistribute it and/or modify
// it under the terms of the GNU General Public License as published by
// the Free Software Foundation; either version 3, or (at your option)
// any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU General Public License for more details.
//
// You should have received a copy of the GNU General Public License
// along with this program; if not, see <https://www.gnu.org/licenses/>.


void println(string msg) {
	stdout.printf ("%s\n", msg);
}

void info (string msg) {
	stderr.printf ("%s\n", msg);
}

void warn (string msg) {
	info (@"rpl: $msg");
}

// Returns the size in bytes of the character starting at `s[index]`.
// This exists only because `get_next_char()` doesn't take a `ssize_t index`.
int char_len(string s, ssize_t index) {
	unichar c;
	int ret = 0;
	s.get_next_char(ref ret, out c);
	return ret;
}

ssize_t replace (
	InputStream input,
	OutputStream output,
	Pcre2.Regex old_regex,
	Pcre2.MatchFlags replace_opts,
	StringBuilder new_pattern
) throws IOError {
	bool uses_look_behind = false; // FIXME.
	ssize_t num_matches = 0;
	size_t num_bytes;

	var tonext = new StringBuilder();
	ssize_t tonext_offset = 0; // We can discard `tonext[0 : tonext_offset]`.
	ssize_t match_from = 0;

	while (true) { // Once per buffer.
		// Allocate a new buffer if necessary.
		StringBuilder buf;
		var keep_len = tonext.len - tonext_offset;
		var buf_size = 2 * keep_len + 1024 * 1024;
		if (buf_size > tonext.allocated_len) {
			// Allocate a bigger buffer.
			buf = new StringBuilder.sized (buf_size);
			buf.append_len (tonext.str[tonext_offset : tonext.len], keep_len);
			tonext = null;
		} else {
			// No need to allocate. Reuse the previous buffer.
			buf = (owned) tonext;
			buf.erase (0, tonext_offset);
		}
		match_from -= tonext_offset;

		// Fill the buffer.
		GLib.assert (buf.len < buf.allocated_len);
		input.read_all (buf.data[buf.len : buf.allocated_len], out num_bytes);
		info(@"Read $num_bytes bytes");
		bool end_of_input = num_bytes == 0;
		buf.len += (ssize_t)num_bytes;

		while (true) { // Once per match.
			var do_partial = end_of_input ? 0 : Pcre2.MatchFlags.PARTIAL_HARD;
			int rc;
			var match = old_regex.match (buf, (size_t)match_from, do_partial, out rc);

			if (rc == Pcre2.Error.NOMATCH) {
				// Write out the whole tail.
				output.write_all (buf.data[match_from : buf.len], out num_bytes);
				info(@"Retained $num_bytes bytes");
				match_from = buf.len;
				break;
			} else if (rc == Pcre2.Error.PARTIAL) {
				// Need more input.
				break;
			} else if (rc < 0) {
				warn (@"error in regular expression: $(Pcre2.get_error_message(rc))");
				return -1;
			}

			// Write out the unmatched text.
			output.write_all (buf.data[match_from : match.group_start (0)], out num_bytes);
			info(@"Retained $num_bytes bytes");

			// Write out the replacement for the matched text.
			var replacement = old_regex.substitute (
				buf,
				match_from,
				replace_opts | Pcre2.MatchFlags.NOTEMPTY | Pcre2.MatchFlags.SUBSTITUTE_MATCHED | Pcre2.MatchFlags.SUBSTITUTE_OVERFLOW_LENGTH | Pcre2.MatchFlags.SUBSTITUTE_REPLACEMENT_ONLY,
				match,
				new_pattern,
				out rc
			);
			if (rc < 0) {
				warn (@"error in replacement: $(Pcre2.get_error_message(rc))");
				return -1;
			}
			output.write_all (replacement.data, out num_bytes);
			info(@"Substituted $num_bytes bytes");

			// Move past the match.
			num_matches += 1;
			match_from = (ssize_t)match.group_end (0);
			if (match.group_start (0) == match.group_end (0)) {
				// Special case for zero-length match: skip a character.
				match_from += char_len(buf.str, match_from);
			}
		}

		if (end_of_input) {
			GLib.assert (match_from == buf.len);
			return num_matches;
		}

		tonext = (owned) buf;
		tonext_offset = uses_look_behind ? 0 : match_from;
	}
}


void debug(string name, uint8[] data) {
	stdout.write(name.data);
	stdout.write(" holds '".data);
	stdout.write(data);
	stdout.write("'\n".data);
}

Pcre2.Regex compile_regex(string regex) {
	int rc = 0;
	size_t error_offset = 0;
	var ret = Pcre2.Regex.compile (
		(Pcre2.Uchar[])regex,
		Pcre2.CompileFlags.UCP | Pcre2.CompileFlags.UTF,
		out rc,
		out error_offset
	);
	if (ret == null) {
		warn (@"error in Regex.compile: $(Pcre2.get_error_message(rc))");
		GLib.Process.exit (-1);
	}
	return ret;
}

void main(string[] argv) {
	var input = new MemoryInputStream.from_data("""
It is a truth universally acknowledged, that a single man in possession
of a good fortune must be in want of a wife.

However little known the feelings or views of such a man may be on his
first entering a neighbourhood, this truth is so well fixed in the minds
of the surrounding families, that he is considered as the rightful
property of some one or other of their daughters.

“My dear Mr. Bennet,” said his lady to him one day, “have you heard that
Netherfield Park is let at last?”

Mr. Bennet replied that he had not.

“But it is,” returned she; “for Mrs. Long has just been here, and she
told me all about it.”

Mr. Bennet made no answer.

“Do not you want to know who has taken it?” cried his wife, impatiently.

“_You_ want to tell me, and I have no objection to hearing it.”
""".data);
	var output = new MemoryOutputStream.resizable ();

	var num_matches = replace(
		input,
		output,
		compile_regex("man"),
		(Pcre2.MatchFlags) 0,
		new StringBuilder("gentle$0")
	);
	debug("output", output.get_data());
}
