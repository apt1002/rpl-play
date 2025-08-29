#! /usr/bin/env -S vala -X -w -X -I. --vapidir=. --pkg posix --pkg libpcre2-8 --pkg iconv
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

using Posix;
using Pcre2;


void info (string msg) {
	GLib.stderr.printf ("%s", @"$msg\n");
}

void warn (string msg) {
	info (@"rpl: $msg");
}

ssize_t replace (int input_fd,
                 owned StringBuilder initial_buf,
                 string input_filename,
                 int output_fd,
                 Pcre2.Regex old_regex,
                 Pcre2.MatchFlags replace_opts,
                 StringBuilder new_pattern,
                 string? encoding) {
	ssize_t num_matches = 0;
	size_t buf_size = 1024 * 1024;

	var tonext = new StringBuilder ();
	size_t tonext_offset = 0;
	var retry_prefix = new StringBuilder ();
	IConv.IConv? iconv_in = null;
	IConv.IConv? iconv_out = null;
	if (encoding != null) {
		iconv_in = IConv.IConv.open ("UTF-8", encoding);
		iconv_out = IConv.IConv.open (encoding, "UTF-8");
	}
	var buf = (owned) initial_buf;
	ssize_t n_read = buf.len;
	var new_pattern_str = new StringBuilder.sized (new_pattern.len);
	new_pattern_str.append_len (new_pattern.str, new_pattern.len);
	while (true) {
		// If we're not processing initial_buf, read more data.
		if (buf.len == 0) {
			buf.append_len (retry_prefix.str, retry_prefix.len);
			n_read = Posix.read (input_fd, ((uint8*) buf.data) + buf.len, buf_size - buf.len);
			if (n_read < 0) { // GCOVR_EXCL_START
				warn (@"error reading $input_filename: $(GLib.strerror(errno))");
				break;
			} // GCOVR_EXCL_STOP
			buf.len = retry_prefix.len + n_read;
		}

		if (iconv_in != null && buf.len > 0) {
			unowned char[] buf_ptr = (char[]) buf.data;
			size_t buf_len = buf.len;
			// Guess maximum input:output ratio required.
			size_t out_buf_size = buf.len * 8;
			var out_buf = new char[out_buf_size];
			unowned char[] out_buf_ptr = out_buf;
			size_t out_buf_len = out_buf.length;
			var rc = iconv_in.iconv (ref buf_ptr, ref buf_len, ref out_buf_ptr, ref out_buf_len);
			if (rc == -1) {
				// Try carrying invalid input over to next iteration in case it's
				// just incomplete.
				if (buf_ptr != (char[]) buf.data) {
					retry_prefix = new StringBuilder.sized (buf_len);
					retry_prefix.append_len ((string) buf_ptr, (ssize_t) buf_len);
				} else {
					warn (@"error decoding $input_filename: $(GLib.strerror(errno))");
					warn ("You can specify the encoding with --encoding");
					iconv_in.close ();
					iconv_out.close ();
					return -1;
				}
			} else {
				retry_prefix = new StringBuilder ();
			}
			size_t out_len = out_buf_size - out_buf_len;
			buf = new StringBuilder.sized (out_len);
			buf.append_len ((string) out_buf, (ssize_t) out_len);
		}

		StringBuilder search_str;
		// If we have search data held over from last iteration, copy it
		// into a new buffer.
		if (tonext.len > 0) {
			search_str = new StringBuilder.sized (buf_size * 2);
			search_str.append_len ((string) ((char*) tonext.str + tonext_offset), (ssize_t) (tonext.len - tonext_offset));
			search_str.append_len (buf.str, buf.len);
		} else {
			search_str = (owned) buf;
		}
		if (search_str.len == 0) {
			break;
		}

		var result = new StringBuilder ();
		size_t matching_from = 0;
		size_t start_pos;
		size_t end_pos = 0;
		Match? match = null;
		int rc = 0;
		while (true) {
			var do_partial = n_read > 0 ? Pcre2.MatchFlags.PARTIAL_HARD : 0;
			match = old_regex.match (search_str, matching_from, do_partial, out rc);
			if (rc == Pcre2.Error.NOMATCH) {
				tonext = new StringBuilder ();
				tonext_offset = 0;
				result.append_len ((string) ((uint8*) search_str.data + end_pos), (ssize_t) (search_str.len - end_pos));
				break;
			} else if (rc == Pcre2.Error.PARTIAL) {
				tonext_offset = matching_from;
				tonext = (owned) search_str;
				buf_size *= 2;
				break;
			} else if (rc < 0) { // GCOVR_EXCL_START
				if (iconv_in != null) {
					iconv_in.close ();
					iconv_out.close ();
				}
				warn (@"$input_filename: $(get_error_message(rc))");
				return -1; // GCOVR_EXCL_STOP
			}

			start_pos = match.group_start (0);
			result.append_len ((string) ((uint8*) search_str.data + end_pos), (ssize_t) (start_pos - end_pos));
			end_pos = match.group_end (0);
			num_matches += 1;

			var output = old_regex.substitute (
				search_str, matching_from,
				replace_opts | Pcre2.MatchFlags.NOTEMPTY | Pcre2.MatchFlags.SUBSTITUTE_MATCHED | Pcre2.MatchFlags.SUBSTITUTE_OVERFLOW_LENGTH | Pcre2.MatchFlags.SUBSTITUTE_REPLACEMENT_ONLY,
				match,
				new_pattern_str,
				out rc
			);
			if (rc < 0) {
				warn (@"error in replacement: $(get_error_message(rc))");
				return -1;
			}

			result.append_len (output.str, output.len);
			matching_from = end_pos;
			if (start_pos == end_pos)
				matching_from += 1;
		}

		ssize_t write_res = 0;
		if (iconv_out != null) {
			try {
				size_t bytes_written;
				string output = convert_with_iconv (result.str, result.len, (GLib.IConv) iconv_out, null, out bytes_written);
				write_res = Posix.write (output_fd, output, bytes_written);
			} catch (ConvertError e) {
				warn (@"output encoding error: $(GLib.strerror(errno))");
				iconv_in.close ();
				iconv_out.close ();
				return -1;
			}
		} else {
			write_res = Posix.write (output_fd, result.data, result.len);
		}
		if (write_res < 0) { // GCOVR_EXCL_START
			warn (@"write error: $(GLib.strerror(errno))");
		} // GCOVR_EXCL_STOP

		// Reset buffer for next iteration
		buf = new StringBuilder.sized (buf_size);
	}

	return num_matches;
}

void main(string[] argv) {
}
