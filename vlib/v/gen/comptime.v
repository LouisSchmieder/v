// Copyright (c) 2019-2020 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by an MIT license
// that can be found in the LICENSE file.
module gen

import v.ast
import v.table
import v.util

fn (mut g Gen) comptime_call(node ast.ComptimeCall) {
	if node.is_vweb {
		for stmt in node.vweb_tmpl.stmts {
			if stmt is ast.FnDecl {
				// insert stmts from vweb_tmpl fn
				if stmt.name.starts_with('main.vweb_tmpl') {
					g.inside_vweb_tmpl = true
					g.stmts(stmt.stmts)
					g.inside_vweb_tmpl = false
					break
				}
			}
		}
		g.writeln('vweb__Context_html(&app->vweb, _tmpl_res_$g.fn_decl.name); strings__Builder_free(&sb); string_free(&_tmpl_res_$g.fn_decl.name);')
		return
	}
	g.writeln('// $' + 'method call. sym="$node.sym.name"')
	mut j := 0
	result_type := g.table.find_type_idx('vweb.Result') // TODO not just vweb
	if node.method_name == 'method' {
		// `app.$method()`
		m := node.sym.find_method(g.comp_for_method) or {
			return
		}
		/*
		vals := m.attrs[0].split('/')
		args := vals.filter(it.starts_with(':')).map(it[1..])
		println(vals)
		for val in vals {
		}
		*/
		g.write('${util.no_dots(node.sym.name)}_${g.comp_for_method}(')
		g.expr(node.left)
		if m.args.len > 1 {
			g.write(', ')
		}
		for i in 1 .. m.args.len {
			if node.left is ast.Ident {
				left_name := node.left as ast.Ident
				if m.args[i].name == left_name.name {
					continue
				}
			}
			if m.args[i].typ.is_int() || m.args[i].typ.idx() == table.bool_type_idx {
				// Gets the type name and cast the string to the type with the string_<type> function
				type_name := g.table.types[int(m.args[i].typ)].str()
				g.write('string_${type_name}(((string*)${node.args_var}.data) [${i-1}])')
			} else {
				g.write('((string*)${node.args_var}.data) [${i-1}] ')
			}
			if i < m.args.len - 1 {
				g.write(', ')
			}
		}
		g.write(' ); // vweb action call with args')
		return
	}
	for method in node.sym.methods {
		// if method.return_type != table.void_type {
		if method.return_type != result_type {
			continue
		}
		if method.args.len != 1 {
			continue
		}
		// receiver := method.args[0]
		// if !p.expr_var.ptr {
		// p.error('`$p.expr_var.name` needs to be a reference')
		// }
		amp := '' // if receiver.is_mut && !p.expr_var.ptr { '&' } else { '' }
		if j > 0 {
			g.write(' else ')
		}
		g.write('if (string_eq($node.method_name, tos_lit("$method.name"))) ')
		g.write('${util.no_dots(node.sym.name)}_${method.name}($amp ')
		g.expr(node.left)
		g.writeln(');')
		j++
	}
}

fn (mut g Gen) comp_if(mut it ast.CompIf) {
	if it.stmts.len == 0 && it.else_stmts.len == 0 {
		return
	}
	if it.is_typecheck {
		g.writeln('{ // \$if $it.val typecheck start')
		it.type_match = g.tmp_comp_for_ret_type == it.typ
		mut stmts := it.stmts
		if !it.type_match {
			stmts = []ast.Stmt{}
			if it.has_else {
				stmts = it.else_stmts
			}
		}
		g.stmts(stmts)
		g.writeln('} // typecheck end')
		return
	}
	ifdef := g.comp_if_to_ifdef(it.val, it.is_opt)
	g.empty_line = false
	if it.is_not {
		g.writeln('// \$if !$it.val {\n#ifndef ' + ifdef)
	} else {
		g.writeln('// \$if  $it.val {\n#ifdef ' + ifdef)
	}
	// NOTE: g.defer_ifdef is needed for defers called witin an ifdef
	// in v1 this code would be completely excluded
	g.defer_ifdef = if it.is_not { '#ifndef ' + ifdef } else { '#ifdef ' + ifdef }
	// println('comp if stmts $g.file.path:$it.pos.line_nr')
	g.indent--
	g.stmts(it.stmts)
	g.indent++
	g.defer_ifdef = ''
	if it.has_else {
		g.empty_line = false
		g.writeln('#else')
		g.defer_ifdef = if it.is_not { '#ifdef ' + ifdef } else { '#ifndef ' + ifdef }
		g.indent--
		g.stmts(it.else_stmts)
		g.indent++
		g.defer_ifdef = ''
	}
	g.empty_line = false
	g.writeln('#endif\n// } $it.val')
}

fn (mut g Gen) comp_for(node ast.CompFor) {
	sym := g.table.get_type_symbol(g.unwrap_generic(node.typ))
	g.writeln('{ // 2comptime: \$for $node.val_var in ${sym.name}(${node.kind.str()}) {')
	// vweb_result_type := table.new_type(g.table.find_type_idx('vweb.Result'))
	mut i := 0
	// g.writeln('string method = tos_lit("");')
	if node.kind == .methods {
		mut methods := sym.methods.filter(it.attrs.len == 0) // methods without attrs first
		methods_with_attrs := sym.methods.filter(it.attrs.len > 0) // methods without attrs first
		methods << methods_with_attrs
		if methods.len > 0 {
			g.writeln('\tFunctionData $node.val_var;')
			g.writeln('\tmemset(&${node.val_var}, 0, sizeof(FunctionData));')
		}
		for method in methods { // sym.methods {
			/*
			if method.return_type != vweb_result_type { // table.void_type {
				continue
			}
			*/
			g.tmp_comp_for_ret_type = table.Type(0)
			g.comp_for_method = method.name
			g.writeln('\t// method $i')
			g.writeln('\t${node.val_var}.name = tos_lit("$method.name");')
			if method.attrs.len == 0 {
				g.writeln('\t${node.val_var}.attrs = new_array_from_c_array(0, 0, sizeof(string), _MOV((string[0]){}));')
			} else {
				mut attrs := []string{}
				for attrib in method.attrs {
					attrs << 'tos_lit("$attrib")'
				}
				g.writeln('\t${node.val_var}.attrs = new_array_from_c_array($attrs.len, $attrs.len, sizeof(string), _MOV((string[$attrs.len]){' +
					attrs.join(', ') + '}));')
			}
			mut ret_type := g.table.types[0]
			if int(method.return_type) <= g.table.types.len {
				ret_type = g.table.types[int(method.return_type)]
			}
			g.writeln('\t${node.val_var}.ret_type = tos_lit("$ret_type.str()");')
			//
			g.tmp_comp_for_ret_type = method.return_type
			g.stmts(node.stmts)
			i++
			g.writeln('')
		}
	} else if node.kind == .fields {
		// TODO add fields
		if sym.info is table.Struct {
			info := sym.info as table.Struct
			mut fields := info.fields.filter(it.attrs.len == 0)
			fields_with_attrs := info.fields.filter(it.attrs.len > 0)
			fields << fields_with_attrs
			if fields.len > 0 {
				g.writeln('\tFieldData $node.val_var;')
				g.writeln('\tmemset(&${node.val_var}, 0, sizeof(FieldData));')
			}
			for field in fields {
				g.tmp_comp_for_ret_type = table.Type(0)
				g.writeln('\t// field $i')
				g.writeln('\t${node.val_var}.name = tos_lit("$field.name");')
				if field.attrs.len == 0 {
					g.writeln('\t${node.val_var}.attrs = new_array_from_c_array(0, 0, sizeof(string), _MOV((string[0]){}));')
				} else {
					mut attrs := []string{}
					for attrib in field.attrs {
						attrs << 'tos_lit("$attrib")'
					}
					g.writeln('\t${node.val_var}.attrs = new_array_from_c_array($attrs.len, $attrs.len, sizeof(string), _MOV((string[$attrs.len]){' + attrs.join(', ') + '}));')
				}
				mut ret_type := g.table.types[0]
				if field.typ.idx() <= g.table.types.len {
					ret_type = g.table.types[field.typ.idx()]
				}
				g.writeln('\t${node.val_var}.typ = tos_lit("$ret_type.str()");')
				g.tmp_comp_for_ret_type = field.typ
				g.writeln('\t${node.val_var}.is_pub = $field.is_pub;')
				g.writeln('\t${node.val_var}.is_mut = $field.is_mut;')
				g.stmts(node.stmts)
				i++
				g.writeln('')
			}
		}
	}
	g.writeln('} // } comptime for')
}
