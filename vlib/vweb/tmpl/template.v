// Copyright (c) 2019-2021 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by an MIT license
// that can be found in the LICENSE file.
module tmpl

import os
import strings

const (
	tab = '	'
)

struct TmplCompiler {
mut:
	src          string
	fn_name      string
	lines        []string
	sb           strings.Builder = strings.new_builder(1000)
	write        bool = false
	tab_level    int  = 0
	i            int
	lstartlength int = 0
}

// compile_file compiles the content of a file by the given path as a template
pub fn compile_file(path string, fn_name string) string {
	html := os.read_file(path) or { panic('html failed') }
	mut t := TmplCompiler{
		src: html
		fn_name: fn_name
	}
	return t.compile_template()
}

enum State {
	html
	css // <style>
	js // <script>
}

fn (mut t TmplCompiler) compile_template() string {
	t.make_src_complete()

	t.lstartlength = t.src.split_into_lines().len * 30
	t.write_file_header()

	t.lines = t.src.split_into_lines()
	t.i = 0
	for ; t.i < t.lines.len; t.i++ {
		mut line := t.lines[t.i]
		t.calc_line(line)
	}
	t.write('_tmpl_res_$t.fn_name := sb.str()')
	t.tab_level--
	t.write('}')

	res := t.sb.str()
	eprintln(res)
	return res
}

fn (mut t TmplCompiler) calc_line(src_line string) {
	mut line := src_line
	eprintln('l: $line')
	if line.contains('@if') {
		eprintln('line')
		idx := line.index('@if') or {
			// Error handling
			t.write_text(line)
			return
		}
		l := line.trim_space()
		before := line[..idx]
		t.write_text(before)
		ident, len := get_ident(line[idx + 3..]) or {
			eprintln(err)
			t.write_text(line)
			return
		}
		after := line[idx + 4 + len..].trim_space()

		if after.len > 0 {
			// Inline
			mut html, mut il := find_in_string(line[idx + 2 + len..].trim_space(), `{`,
				`}`) or {
				eprintln(err)
				t.write_text(line)
				return
			}
			html = html.trim_space()
			t.write('if $ident {')
			t.tab_level++
			t.write_text(html)
			t.tab_level--
			t.write('}')

			// Look for a else
			mut r := line[idx + 2 + len + il..].trim_space()
			for {
				if r.len == 0 {
					break
				}
				data, ll := string_to(r, `{`, 0) or {
					eprintln(err)
					break
				}
				args := data.split_by_whitespace()
				if args[0] != 'else' {
					break
				}
				mut elline := 'else '
				if args.len > 1 {
					if args[1] == 'if' {
						elline += 'if'
						elline += args[2..].join(' ')
					}
				}
				elline += '{'
				t.write(elline)
				t.tab_level++
				html, il = string_to(r[ll..], `}`, 0) or {
					eprintln(err)
					break
				}
				html = html.trim_space()
				t.write_text(html)
				t.tab_level--
				t.write('}')
				r = r[ll + il..]
			}

			return
		}
		t.write('if $ident {')
		t.tab_level++
		for {
			t.i++
			line = t.lines[t.i]
			if line.contains('}') {
				break
			}
			t.calc_line(line)
		}
		mut bidx := line.index('}') or {
			eprintln(err)
			t.write_text(line)
			return
		}
		t.write_text(line[..bidx])
		t.tab_level--
		t.write('}')
		mut r := line[bidx + 1..]
		for {
			if r.len == 0 {
				break
			}
			data, ll := string_to(r, `{`, 0) or {
				eprintln(err)
				break
			}
			args := data.split_by_whitespace()
			if args[0] != 'else' {
				break
			}
			mut elline := 'else '
			if args.len > 1 {
				if args[1] == 'if' {
					elline += 'if'
					elline += ' ' + args[2..].join(' ') + ' '
				}
			}
			elline += '{'
			t.write(elline)
			t.tab_level++
			for {
				t.i++
				line = t.lines[t.i]
				if line.contains('}') {
					break
				}
				eprintln(line)
				t.calc_line(line)
			}
			bidx = line.index('}') or {
				eprintln(err)
				t.write_text(line)
				return
			}
			t.write_text(line[..bidx])
			t.tab_level--
			t.write('}')
			r = line[bidx + 1..]
		}
		return
	}

	t.write_text(line)
}

fn (mut t TmplCompiler) write_file_header() {
	t.write('import strings')
	t.write('// === vweb html template ===')
	t.write('fn vweb_tmpl_${t.fn_name}() {')
	t.tab_level++
	t.write('mut sb := strings.new_builder($t.lstartlength)')
}

fn (mut t TmplCompiler) write(s string) {
	if s.len > 0 {
		t.sb.writeln(t.tabs() + s)
	}
}

fn (mut t TmplCompiler) write_text(s string) {
	if s.len > 0 {
		t.sb.writeln(t.tabs() + "sb.writeln(\'$s\')")
	}
}

fn (mut t TmplCompiler) tabs() string {
	mut s := ''
	for _ in 0 .. t.tab_level {
		s += tab
	}
	return s
}

// add include, js and css statements to the src
fn (mut t TmplCompiler) make_src_complete() {
	// Detect here include, css and js
	mut res := []string{}
	for line in t.src.split_into_lines() {
		if line.contains('@include') {
			idx := line.index('@include') or {
				res << line
				continue
			}
			res << line[0..idx]
			path, len := get_path(line[idx + 9..]) or {
				eprintln(err)
				res << line
				continue
			}
			file_data := os.read_file(os.join_path('templates', '${path}.html')) or { '' }
			res << file_data.split_into_lines()
			res << line[idx + 9 + len..]
			continue
		} else if line.contains('@js') {
			idx := line.index('@js') or {
				res << line
				continue
			}
			mut l := line[0..idx]
			path, len := get_path(line[idx + 4..]) or {
				res << line
				continue
			}
			l += '<script src="$path"></script>'
			l += line[idx + 4 + len..]
			res << line
			continue
		} else if line.contains('@css') {
			idx := line.index('@css') or {
				res << line
				continue
			}
			mut l := line[0..idx]
			path, len := get_path(line[idx + 5..]) or {
				res << line
				continue
			}
			l += '<link href="$path" rel="stylesheet">'
			l += line[idx + 5 + len..]
			res << line
			continue
		}
		res << line
	}
	t.src = res.join('\n')
}

// finds the path between '' in a line returns the path and the len of the path plus ''
fn get_path(s string) ?(string, int) {
	return find_in_string(s, `\'`, `\'`)
}

fn get_ident(s string) ?(string, int) {
	return find_in_string(s, ` `, `{`)
}

fn find_in_string(s string, start byte, end byte) ?(string, int) {
	if s[0] != start {
		return error('Wrong first character')
	}
	return string_to(s, end, 1)
}

fn string_to(s string, to byte, offset int) ?(string, int) {
	mut res := []byte{}
	for i := offset; i < s.len; i++ {
		if s[i] == to {
			return res.bytestr(), i + 1
		}
		res << s[i]
	}
	return error('No ending character found')
}
