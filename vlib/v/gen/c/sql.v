// Copyright (c) 2019-2021 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by an MIT license that can be found in the LICENSE file.
module c

import v.ast
import strings
import v.util

// pg,mysql etc
const (
	dbtype = 'sqlite'
)

enum SqlExprSide {
	left
	right
}

enum SqlType {
	sqlite3
	mysql
	psql
	unknown
}

fn (mut g Gen) sql_stmt(node ast.SqlStmt) {
	if node.kind == .create {
		g.sql_create_table(node)
		return
	} else if node.kind == .drop {
		g.sql_drop_table(node)
		return
	}
	g.sql_table_name = g.table.get_type_symbol(node.table_expr.typ).name
	typ := g.parse_db_type(node.db_expr)
	match typ {
		.sqlite3 {
			g.sqlite3_stmt(node, typ)
		}
		.mysql {
			g.mysql_stmt(node, typ)
		}
		else {
			verror('This database type `$typ` is not implemented yet in orm') // TODO add better error
		}
	}
}

fn (mut g Gen) sql_create_table(node ast.SqlStmt) {
	typ := g.parse_db_type(node.db_expr)
	match typ {
		.sqlite3 {
			g.sqlite3_create_table(node, typ)
		}
		.mysql {
			g.mysql_create_table(node, typ)
		}
		else {
			verror('This database type `$typ` is not implemented yet in orm') // TODO add better error
		}
	}
}

fn (mut g Gen) sql_drop_table(node ast.SqlStmt) {
	typ := g.parse_db_type(node.db_expr)
	match typ {
		.sqlite3 {
			g.sqlite3_drop_table(node, typ)
		}
		.mysql {
			g.mysql_drop_table(node, typ)
		}
		else {
			verror('This database type `$typ` is not implemented yet in orm') // TODO add better error
		}
	}
}

fn (mut g Gen) sql_select_expr(node ast.SqlExpr, sub bool, line string) {
	g.sql_table_name = g.table.get_type_symbol(node.table_expr.typ).name
	typ := g.parse_db_type(node.db_expr)
	match typ {
		.sqlite3 {
			g.sqlite3_select_expr(node, sub, line, typ)
		}
		.mysql {
			g.mysql_select_expr(node, sub, line, typ)
		}
		else {
			verror('This database type `$typ` is not implemented yet in orm') // TODO add better error
		}
	}
}

fn (mut g Gen) sql_bind(val string, len string, real_type ast.Type, typ SqlType) {
	match typ {
		.sqlite3 {
			g.sqlite3_bind(val, len, real_type)
		}
		.mysql {
			g.mysql_bind(val, real_type)
		}
		else {}
	}
}

fn (mut g Gen) sql_type_from_v(typ SqlType, v_typ ast.Type) string {
	match typ {
		.sqlite3 {
			return g.sqlite3_type_from_v(v_typ)
		}
		.mysql {
			return g.mysql_get_table_type(v_typ)
		}
		else {
			// add error
		}
	}
	return ''
}

// sqlite3

fn (mut g Gen) sqlite3_stmt(node ast.SqlStmt, typ SqlType) {
	g.sql_i = 0
	g.writeln('\n\t// sql insert')
	db_name := g.new_tmp_var()
	g.sql_stmt_name = g.new_tmp_var()
	g.write('${c.dbtype}__DB $db_name = ')
	g.expr(node.db_expr)
	g.writeln(';')
	g.write('sqlite3_stmt* $g.sql_stmt_name = ${c.dbtype}__DB_init_stmt($db_name, _SLIT("')
	g.sql_defaults(node, typ)
	g.writeln(');')
	if node.kind == .insert {
		// build the object now (`x.name = ... x.id == ...`)
		for i, field in node.fields {
			if g.get_sql_field_type(field) == ast.Type(-1) {
				continue
			}
			x := '${node.object_var_name}.$field.name'
			if field.typ == ast.string_type {
				g.writeln('sqlite3_bind_text($g.sql_stmt_name, ${i + 0}, ${x}.str, ${x}.len, 0);')
			} else if g.table.type_symbols[int(field.typ)].kind == .struct_ {
				// insert again
				expr := node.sub_structs[int(field.typ)]
				tmp_sql_stmt_name := g.sql_stmt_name
				tmp_sql_table_name := g.sql_table_name
				g.sql_stmt(expr)
				g.sql_stmt_name = tmp_sql_stmt_name
				g.sql_table_name = tmp_sql_table_name
				// get last inserted id
				g.writeln('Array_sqlite__Row rows = sqlite__DB_exec($db_name, _SLIT("SELECT last_insert_rowid()")).arg0;')
				id_name := g.new_tmp_var()
				g.writeln('int $id_name = string_int((*(string*)array_get((*(sqlite__Row*)array_get(rows, 0)).vals, 0)));')
				g.writeln('sqlite3_bind_int($g.sql_stmt_name, ${i + 0} , $id_name); // id')
			} else {
				g.writeln('sqlite3_bind_int($g.sql_stmt_name, ${i + 0} , $x); // stmt')
			}
		}
	}
	// Dump all sql parameters generated by our custom expr handler
	binds := g.sql_buf.str()
	g.sql_buf = strings.new_builder(100)
	g.writeln(binds)
	step_res := g.new_tmp_var()
	g.writeln('\tint $step_res = sqlite3_step($g.sql_stmt_name);')
	g.writeln('\tif( ($step_res != SQLITE_OK) && ($step_res != SQLITE_DONE)){ puts(sqlite3_errmsg(${db_name}.conn)); }')
	g.writeln('\tsqlite3_finalize($g.sql_stmt_name);')
}

fn (mut g Gen) sqlite3_select_expr(node ast.SqlExpr, sub bool, line string, sql_typ SqlType) {
	g.sql_i = 0
	/*
	`nr_users := sql db { ... }` =>
	```
		sql_init_stmt()
		sqlite3_bind_int()
		sqlite3_bind_string()
		...
		int nr_users = get_int(stmt)
	```
	*/
	mut cur_line := line
	if !sub {
		cur_line = g.go_before_stmt(0)
	}
	// g.write('${dbtype}__DB_q_int(*(${dbtype}__DB*)${node.db_var_name}.data, _SLIT("$sql_query')
	g.sql_stmt_name = g.new_tmp_var()
	db_name := g.new_tmp_var()
	g.writeln('\n\t// sql select')
	// g.write('${dbtype}__DB $db_name = *(${dbtype}__DB*)${node.db_var_name}.data;')
	g.write('${c.dbtype}__DB $db_name = ') // $node.db_var_name;')
	g.expr(node.db_expr)
	g.writeln(';')
	stmt_name := g.new_tmp_var()
	g.write('string $stmt_name = _SLIT("')
	g.write(g.get_base_sql_select_query(node))
	g.sql_expr_defaults(node, sql_typ)
	g.writeln('");')
	// g.write('sqlite3_stmt* $g.sql_stmt_name = ${dbtype}__DB_init_stmt(*(${dbtype}__DB*)${node.db_var_name}.data, _SLIT("$sql_query')
	g.write('sqlite3_stmt* $g.sql_stmt_name = ${c.dbtype}__DB_init_stmt($db_name, $stmt_name);')
	// Dump all sql parameters generated by our custom expr handler
	binds := g.sql_buf.str()
	g.sql_buf = strings.new_builder(100)
	g.writeln(binds)
	binding_res := g.new_tmp_var()
	g.writeln('int $binding_res = sqlite3_extended_errcode(${db_name}.conn);')
	g.writeln('if ($binding_res != SQLITE_OK) { puts(sqlite3_errmsg(${db_name}.conn)); }')
	//
	if node.is_count {
		g.writeln('$cur_line ${c.dbtype}__get_int_from_stmt($g.sql_stmt_name);')
	} else {
		// `user := sql db { select from User where id = 1 }`
		tmp := g.new_tmp_var()
		styp := g.typ(node.typ)
		mut elem_type_str := ''
		if node.is_array {
			// array_User array_tmp;
			// for { User tmp; ... array_tmp << tmp; }
			array_sym := g.table.get_type_symbol(node.typ)
			array_info := array_sym.info as ast.Array
			elem_type_str = g.typ(array_info.elem_type)
			g.writeln('$styp ${tmp}_array = __new_array(0, 10, sizeof($elem_type_str));')
			g.writeln('while (1) {')
			g.writeln('\t$elem_type_str $tmp = ($elem_type_str) {')
			//
			sym := g.table.get_type_symbol(array_info.elem_type)
			info := sym.info as ast.Struct
			for i, field in info.fields {
				g.zero_struct_field(field)
				if i != info.fields.len - 1 {
					g.write(', ')
				}
			}
			g.writeln('};')
		} else {
			// `User tmp;`
			g.writeln('$styp $tmp = ($styp){')
			// Zero fields, (only the [skip] ones?)
			// If we don't, string values are going to be nil etc for fields that are not returned
			// by the db engine.
			sym := g.table.get_type_symbol(node.typ)
			info := sym.info as ast.Struct
			for i, field in info.fields {
				g.zero_struct_field(field)
				if i != info.fields.len - 1 {
					g.write(', ')
				}
			}
			g.writeln('};')
		}
		//
		g.writeln('int _step_res$tmp = sqlite3_step($g.sql_stmt_name);')
		if node.is_array {
			// g.writeln('\tprintf("step res=%d\\n", _step_res$tmp);')
			g.writeln('\tif (_step_res$tmp == SQLITE_DONE) break;')
			g.writeln('\tif (_step_res$tmp == SQLITE_ROW) ;') // another row
			g.writeln('\telse if (_step_res$tmp != SQLITE_OK) break;')
		} else {
			// g.writeln('printf("RES: %d\\n", _step_res$tmp) ;')
			g.writeln('\tif (_step_res$tmp == SQLITE_OK || _step_res$tmp == SQLITE_ROW) {')
		}
		for i, field in node.fields {
			mut func := 'sqlite3_column_int'
			if field.typ == ast.string_type {
				func = 'sqlite3_column_text'
				string_data := g.new_tmp_var()
				g.writeln('byteptr $string_data = ${func}($g.sql_stmt_name, $i);')
				g.writeln('if ($string_data != NULL) {')
				g.writeln('\t${tmp}.$field.name = tos_clone($string_data);')
				g.writeln('}')
			} else if g.table.type_symbols[int(field.typ)].kind == .struct_ {
				id_name := g.new_tmp_var()
				g.writeln('//parse struct start')
				g.writeln('int $id_name = ${func}($g.sql_stmt_name, $i);')
				mut expr := node.sub_structs[int(field.typ)]
				mut where_expr := expr.where_expr as ast.InfixExpr
				mut ident := where_expr.right as ast.Ident
				ident.name = id_name
				where_expr.right = ident
				expr.where_expr = where_expr

				tmp_sql_i := g.sql_i
				tmp_sql_stmt_name := g.sql_stmt_name
				tmp_sql_buf := g.sql_buf
				tmp_sql_table_name := g.sql_table_name

				g.sql_select_expr(expr, true, '\t${tmp}.$field.name =')
				g.writeln('//parse struct end')

				g.sql_stmt_name = tmp_sql_stmt_name
				g.sql_buf = tmp_sql_buf
				g.sql_i = tmp_sql_i
				g.sql_table_name = tmp_sql_table_name
			} else {
				g.writeln('${tmp}.$field.name = ${func}($g.sql_stmt_name, $i);')
			}
		}
		if node.is_array {
			g.writeln('\t array_push(&${tmp}_array, _MOV(($elem_type_str[]){ $tmp }));')
		}
		g.writeln('}')
		g.writeln('sqlite3_finalize($g.sql_stmt_name);')
		if node.is_array {
			g.writeln('$cur_line ${tmp}_array; ') // `array_User users = tmp_array;`
		} else {
			g.writeln('$cur_line $tmp; ') // `User user = tmp;`
		}
	}
}

fn (mut g Gen) sqlite3_create_table(node ast.SqlStmt, typ SqlType) {
	g.writeln('// sqlite3 table creator')
	create_string := g.table_gen(node, typ)
	g.write('sqlite__DB_exec(')
	g.expr(node.db_expr)
	g.writeln(', _SLIT("$create_string"));')
}

fn (mut g Gen) sqlite3_drop_table(node ast.SqlStmt, typ SqlType) {
	table_name := g.get_table_name(node.table_expr)
	g.writeln('// sqlite3 table drop')
	create_string := 'DROP TABLE $table_name;'
	g.write('sqlite__DB_exec(')
	g.expr(node.db_expr)
	g.writeln(', _SLIT("$create_string"));')
}

fn (mut g Gen) sqlite3_bind(val string, len string, typ ast.Type) {
	match g.sqlite3_type_from_v(typ) {
		'INTEGER' {
			g.sqlite3_bind_int(val)
		}
		'TEXT' {
			g.sqlite3_bind_string(val, len)
		}
		else {
			verror('bad sql type=$typ ident_name=$val')
		}
	}
}

fn (mut g Gen) sqlite3_bind_int(val string) {
	g.sql_buf.writeln('sqlite3_bind_int($g.sql_stmt_name, $g.sql_i, $val);')
}

fn (mut g Gen) sqlite3_bind_string(val string, len string) {
	g.sql_buf.writeln('sqlite3_bind_text($g.sql_stmt_name, $g.sql_i, $val, $len, 0);')
}

fn (mut g Gen) sqlite3_type_from_v(v_typ ast.Type) string {
	if v_typ.is_number() || v_typ == ast.bool_type || v_typ == -1 {
		return 'INTEGER'
	}
	if v_typ.is_string() {
		return 'TEXT'
	}
	return ''
}

// mysql

fn (mut g Gen) mysql_stmt(node ast.SqlStmt, typ SqlType) {
	g.sql_i = 0
	g.writeln('\n\t//mysql insert')
	db_name := g.new_tmp_var()
	g.sql_stmt_name = g.new_tmp_var()
	g.write('mysql__Connection $db_name = ')
	g.expr(node.db_expr)
	g.writeln(';')
	stmt_name := g.new_tmp_var()
	g.write('string $stmt_name = _SLIT("')
	g.sql_defaults(node, typ)
	g.writeln(';')
	g.writeln('MYSQL_STMT* $g.sql_stmt_name = mysql_stmt_init(${db_name}.conn);')
	g.writeln('mysql_stmt_prepare($g.sql_stmt_name, ${stmt_name}.str, ${stmt_name}.len);')

	bind := g.new_tmp_var()
	g.writeln('MYSQL_BIND $bind[$g.sql_i];')
	g.writeln('memset($bind, 0, sizeof(MYSQL_BIND)*$g.sql_i);')
	if node.kind == .insert {
		for i, field in node.fields {
			if g.get_sql_field_type(field) != ast.Type(-1) {
				continue
			}
			g.writeln('//$field.name ($field.typ)')
			x := '${node.object_var_name}.$field.name'
			if g.table.type_symbols[int(field.typ)].kind == .struct_ {
				// insert again
				expr := node.sub_structs[int(field.typ)]
				tmp_sql_stmt_name := g.sql_stmt_name
				tmp_sql_table_name := g.sql_table_name
				g.sql_stmt(expr)
				g.sql_stmt_name = tmp_sql_stmt_name
				g.sql_table_name = tmp_sql_table_name

				res := g.new_tmp_var()
				g.writeln('int ${res}_err = mysql_real_query(${db_name}.conn, "SELECT LAST_INSERT_ID();", 24);')
				g.writeln('if (${res}_err != 0) { puts(mysql_error(${db_name}.conn)); }')
				g.writeln('MYSQL_RES* $res = mysql_store_result(${db_name}.conn);')
				g.writeln('if (mysql_num_rows($res) != 1) { puts("Something went wrong"); }')
				g.writeln('MYSQL_ROW ${res}_row = mysql_fetch_row($res);')
				g.writeln('${x}.id = string_int(tos_clone(${res}_row[0]));')
				g.writeln('mysql_free_result($res);')

				g.writeln('$bind[${i - 1}].buffer_type = MYSQL_TYPE_LONG;')
				g.writeln('$bind[${i - 1}].buffer = &${x}.id;')
				g.writeln('$bind[${i - 1}].is_null = 0;')
				g.writeln('$bind[${i - 1}].length = 0;')
			} else {
				t, sym := g.mysql_buffer_typ_from_field(field)
				g.writeln('$bind[${i - 1}].buffer_type = $t;')
				if sym == 'char' {
					g.writeln('$bind[${i - 1}].buffer = ($sym*) ${x}.str;')
				} else {
					g.writeln('$bind[${i - 1}].buffer = ($sym*) &$x;')
				}
				if sym == 'char' {
					g.writeln('$bind[${i - 1}].buffer_length = ${x}.len;')
				}
				g.writeln('$bind[${i - 1}].is_null = 0;')
				g.writeln('$bind[${i - 1}].length = 0;')
			}
		}
	}
	binds := g.sql_buf.str()
	g.sql_buf = strings.new_builder(100)
	g.writeln(binds)
	// g.writeln('mysql_stmt_attr_set($g.sql_stmt_name, STMT_ATTR_ARRAY_SIZE, 1);')
	res := g.new_tmp_var()
	g.writeln('int $res = mysql_stmt_bind_param($g.sql_stmt_name, $bind);')
	g.writeln('if ($res != 0) { puts(mysql_error(${db_name}.conn)); }')
	g.writeln('$res = mysql_stmt_execute($g.sql_stmt_name);')
	g.writeln('if ($res != 0) { puts(mysql_error(${db_name}.conn)); puts(mysql_stmt_error($g.sql_stmt_name)); }')
	g.writeln('mysql_stmt_close($g.sql_stmt_name);')
	g.writeln('mysql_stmt_free_result($g.sql_stmt_name);')
}

fn (mut g Gen) mysql_select_expr(node ast.SqlExpr, sub bool, line string, typ SqlType) {
	g.sql_i = 0
	mut cur_line := line
	if !sub {
		cur_line = g.go_before_stmt(0)
	}
	g.sql_stmt_name = g.new_tmp_var()
	g.sql_bind_name = g.new_tmp_var()
	db_name := g.new_tmp_var()
	g.writeln('\n\t// sql select')
	g.write('mysql__Connection $db_name = ')
	g.expr(node.db_expr)
	g.writeln(';')

	stmt_name := g.new_tmp_var()
	g.sql_idents = []string{}
	g.sql_idents_types = []ast.Type{}
	g.write('char* ${stmt_name}_raw = "')
	g.write(g.get_base_sql_select_query(node))
	g.sql_expr_defaults(node, typ)
	g.writeln('";')
	g.writeln('string $stmt_name = tos_clone(${stmt_name}_raw);')
	if g.sql_idents.len > 0 {
		vals := g.new_tmp_var()
		g.writeln('Array_string $vals = __new_array_with_default(0, 0, sizeof(string), 0);')
		for i, ident in g.sql_idents {
			g.writeln('array_push(&$vals, _MOV((string[]){string_clone(_SLIT("%${i + 1}"))}));')

			g.write('array_push(&$vals, _MOV((string[]){string_clone(')
			if g.sql_idents_types[i] == ast.string_type {
				g.write('_SLIT(')
			} else {
				sym := g.table.get_type_name(g.sql_idents_types[i])
				g.write('${sym}_str(')
			}
			g.writeln('$ident))}));')
		}
		g.writeln('$stmt_name = string_replace_each($stmt_name, $vals);')
	}
	/*
	g.writeln('MYSQL_STMT* $g.sql_stmt_name = mysql_stmt_init(${db_name}.conn);')
	g.writeln('mysql_stmt_prepare($g.sql_stmt_name, ${stmt_name}.str, ${stmt_name}.len);')

	g.writeln('MYSQL_BIND $g.sql_bind_name[$g.sql_i];')
	g.writeln('memset($g.sql_bind_name, 0, sizeof(MYSQL_BIND)*$g.sql_i);')

	binds := g.sql_buf.str()
	g.sql_buf = strings.new_builder(100)
	g.writeln(binds)

	res := g.new_tmp_var()
	g.writeln('int $res = mysql_stmt_bind_param($g.sql_stmt_name, $g.sql_bind_name);')
	g.writeln('if ($res != 0) { puts(mysql_error(${db_name}.conn)); }')
	g.writeln('$res = mysql_stmt_execute($g.sql_stmt_name);')
	g.writeln('if ($res != 0) { puts(mysql_error(${db_name}.conn)); puts(mysql_stmt_error($g.sql_stmt_name)); }')
	*/
	query := g.new_tmp_var()
	res := g.new_tmp_var()
	fields := g.new_tmp_var()
	/*
	g.writeln('Option_mysql__Result $res = mysql__Connection_real_query(&$db_name, $stmt_name);')
	g.writeln('if (${res}.state != 0) { IError err = ${res}.err; _STR("Something went wrong\\000%.*s", 2, IError_str(err)); }')
	g.writeln('Array_mysql__Row ${res}_rows = mysql__Result_rows(*(mysql__Result*)${res}.data);')*/
	g.writeln('int $query = mysql_real_query(${db_name}.conn, ${stmt_name}.str, ${stmt_name}.len);')
	g.writeln('if ($query != 0) { puts(mysql_error(${db_name}.conn)); }')
	g.writeln('MYSQL_RES* $res = mysql_store_result(${db_name}.conn);')
	g.writeln('MYSQL_ROW $fields = mysql_fetch_row($res);')
	if node.is_count {
		g.writeln('$cur_line string_int(tos_clone($fields[0]));')
	} else {
		tmp := g.new_tmp_var()
		styp := g.typ(node.typ)
		tmp_i := g.new_tmp_var()
		mut elem_type_str := ''
		g.writeln('int $tmp_i = 0;')
		if node.is_array {
			array_sym := g.table.get_type_symbol(node.typ)
			array_info := array_sym.info as ast.Array
			elem_type_str = g.typ(array_info.elem_type)
			g.writeln('$styp ${tmp}_array = __new_array(0, 10, sizeof($elem_type_str));')
			g.writeln('for ($tmp_i = 0; $tmp_i < mysql_num_rows($res); $tmp_i++) {')
			g.writeln('\t$elem_type_str $tmp = ($elem_type_str) {')
			//
			sym := g.table.get_type_symbol(array_info.elem_type)
			info := sym.info as ast.Struct
			for i, field in info.fields {
				g.zero_struct_field(field)
				if i != info.fields.len - 1 {
					g.write(', ')
				}
			}
			g.writeln('};')
		} else {
			g.writeln('$styp $tmp = ($styp){')
			// Zero fields, (only the [skip] ones?)
			// If we don't, string values are going to be nil etc for fields that are not returned
			// by the db engine.
			sym := g.table.get_type_symbol(node.typ)
			info := sym.info as ast.Struct
			for i, field in info.fields {
				g.zero_struct_field(field)
				if i != info.fields.len - 1 {
					g.write(', ')
				}
			}
			g.writeln('};')
		}

		char_ptr := g.new_tmp_var()
		g.writeln('char* $char_ptr = "";')
		for i, field in node.fields {
			g.writeln('$char_ptr = $fields[$i];')
			g.writeln('if ($char_ptr == NULL) { $char_ptr = ""; }')
			name := g.table.get_type_symbol(field.typ).cname
			if g.table.get_type_symbol(field.typ).kind == .struct_ {
				/*
				id_name := g.new_tmp_var()
				g.writeln('//parse struct start') //
				//g.writeln('int $id_name = string_int(tos_clone($fields[$i]));')

				mut expr := node.sub_structs[int(field.typ)]
				mut where_expr := expr.where_expr as ast.InfixExpr
				mut ident := where_expr.right as ast.Ident

				ident.name = '$char_ptr[$i]'
				where_expr.right = ident
				expr.where_expr = where_expr

				tmp_sql_i := g.sql_i
				tmp_sql_stmt_name := g.sql_stmt_name
				tmp_sql_buf := g.sql_buf
				tmp_sql_table_name := g.sql_table_name

				g.sql_select_expr(expr, true, '\t${tmp}.$field.name =')
				g.writeln('//parse struct end')

				g.sql_stmt_name = tmp_sql_stmt_name
				g.sql_buf = tmp_sql_buf
				g.sql_i = tmp_sql_i
				g.sql_table_name := tmp_sql_table_name
				*/
			} else if field.typ == ast.string_type {
				g.writeln('${tmp}.$field.name = tos_clone($char_ptr);')
			} else if field.typ == ast.byte_type {
				g.writeln('${tmp}.$field.name = (byte) string_${name}(tos_clone($char_ptr));')
			} else if field.typ == ast.i8_type {
				g.writeln('${tmp}.$field.name = (i8) string_${name}(tos_clone($char_ptr));')
			} else {
				g.writeln('${tmp}.$field.name = string_${name}(tos_clone($char_ptr));')
			}
		}
		if node.is_array {
			g.writeln('\t array_push(&${tmp}_array, _MOV(($elem_type_str[]) { $tmp }));')
			g.writeln('}')
		}
		g.writeln('string_free(&$stmt_name);')
		g.writeln('mysql_free_result($res);')
		if node.is_array {
			g.writeln('$cur_line ${tmp}_array; ')
		} else {
			g.writeln('$cur_line $tmp; ')
		}
	}
}

fn (mut g Gen) mysql_create_table(node ast.SqlStmt, typ SqlType) {
	g.writeln('// mysql table creator')
	create_string := g.table_gen(node, typ)
	tmp := g.new_tmp_var()
	g.write('Option_mysql__Result $tmp = mysql__Connection_query(&')
	g.expr(node.db_expr)
	g.writeln(', _SLIT("$create_string"));')
	g.writeln('if (${tmp}.state != 0) { IError err = ${tmp}.err; eprintln(_STR("Something went wrong\\000%.*s", 2, IError_str(err))); }')
}

fn (mut g Gen) mysql_drop_table(node ast.SqlStmt, typ SqlType) {
	table_name := g.get_table_name(node.table_expr)
	g.writeln('// mysql table drop')
	create_string := 'DROP TABLE $table_name;'
	tmp := g.new_tmp_var()
	g.write('Option_mysql__Result $tmp = mysql__Connection_query(&')
	g.expr(node.db_expr)
	g.writeln(', _SLIT("$create_string"));')
	g.writeln('if (${tmp}.state != 0) { IError err = ${tmp}.err; eprintln(_STR("Something went wrong\\000%.*s", 2, IError_str(err))); }')
}

fn (mut g Gen) mysql_bind(val string, _ ast.Type) {
	/*
	t := g.mysql_buffer_typ_from_typ(typ)
	mut sym := g.table.get_type_symbol(typ).cname
	if typ == ast.string_type {
		sym = 'char *'
	}
	tmp := g.new_tmp_var()
	g.sql_buf.writeln('$sym $tmp = $val;')
	g.sql_buf.writeln('$g.sql_bind_name[${g.sql_i - 1}].buffer_type = $t;')
	g.sql_buf.writeln('$g.sql_bind_name[${g.sql_i - 1}].buffer = ($sym*) &$tmp;')
	if sym == 'char *' {
		g.sql_buf.writeln('$g.sql_bind_name[${g.sql_i - 1}].buffer_length = ${val}.len;')
	}
	g.sql_buf.writeln('$g.sql_bind_name[${g.sql_i - 1}].is_null = 0;')
	g.sql_buf.writeln('$g.sql_bind_name[${g.sql_i - 1}].length = 0;')*/
	g.write(val)
}

fn (mut g Gen) mysql_get_table_type(typ ast.Type) string {
	mut table_typ := ''
	match typ {
		ast.i8_type, ast.byte_type, ast.bool_type {
			table_typ = 'TINYINT'
		}
		ast.i16_type, ast.u16_type {
			table_typ = 'SMALLINT'
		}
		ast.int_type, ast.u32_type {
			table_typ = 'INT'
		}
		ast.i64_type, ast.u64_type {
			table_typ = 'BIGINT'
		}
		ast.f32_type {
			table_typ = 'BIGINT'
		}
		ast.f64_type {
			table_typ = 'BIGINT'
		}
		ast.string_type {
			table_typ = 'TEXT'
		}
		-1 {
			table_typ = 'SERIAL'
		}
		else {}
	}
	return table_typ
}

fn (mut g Gen) mysql_buffer_typ_from_typ(typ ast.Type) string {
	mut buf_typ := ''
	match typ {
		ast.i8_type, ast.byte_type, ast.bool_type {
			buf_typ = 'MYSQL_TYPE_TINY'
		}
		ast.i16_type, ast.u16_type {
			buf_typ = 'MYSQL_TYPE_SHORT'
		}
		ast.int_type, ast.u32_type {
			buf_typ = 'MYSQL_TYPE_LONG'
		}
		ast.i64_type, ast.u64_type {
			buf_typ = 'MYSQL_TYPE_LONGLONG'
		}
		ast.f32_type {
			buf_typ = 'MYSQL_TYPE_FLOAT'
		}
		ast.f64_type {
			buf_typ = 'MYSQL_TYPE_DOUBLE'
		}
		ast.string_type {
			buf_typ = 'MYSQL_TYPE_STRING'
		}
		else {
			buf_typ = 'MYSQL_TYPE_NULL'
		}
	}
	return buf_typ
}

fn (mut g Gen) mysql_buffer_typ_from_field(field ast.StructField) (string, string) {
	mut typ := g.get_sql_field_type(field)
	mut sym := g.table.get_type_symbol(typ).cname
	buf_typ := g.mysql_buffer_typ_from_typ(typ)

	if typ == ast.string_type {
		sym = 'char'
	}

	return buf_typ, sym
}

// utils

fn (mut g Gen) sql_expr_defaults(node ast.SqlExpr, sql_typ SqlType) {
	if node.has_where && node.where_expr is ast.InfixExpr {
		g.expr_to_sql(node.where_expr, sql_typ)
	}
	if node.has_order {
		g.write(' ORDER BY ')
		g.sql_side = .left
		g.expr_to_sql(node.order_expr, sql_typ)
		if node.has_desc {
			g.write(' DESC ')
		}
	} else {
		g.write(' ORDER BY id ')
	}
	if node.has_limit {
		g.write(' LIMIT ')
		g.sql_side = .right
		g.expr_to_sql(node.limit_expr, sql_typ)
	}
	if node.has_offset {
		g.write(' OFFSET ')
		g.sql_side = .right
		g.expr_to_sql(node.offset_expr, sql_typ)
	}
}

fn (mut g Gen) get_base_sql_select_query(node ast.SqlExpr) string {
	mut sql_query := 'SELECT '
	table_name := g.get_table_name(node.table_expr)
	if node.is_count {
		// `select count(*) from User`
		sql_query += 'COUNT(*) FROM `$table_name` '
	} else {
		// `select id, name, country from User`
		for i, field in node.fields {
			sql_query += '`${g.get_field_name(field)}`'
			if i < node.fields.len - 1 {
				sql_query += ', '
			}
		}
		sql_query += ' FROM `$table_name`'
	}
	if node.has_where {
		sql_query += ' WHERE '
	}
	return sql_query
}

fn (mut g Gen) sql_defaults(node ast.SqlStmt, typ SqlType) {
	table_name := g.get_table_name(node.table_expr)
	if node.kind == .insert {
		g.write('INSERT INTO `$table_name` (')
	} else if node.kind == .update {
		g.write('UPDATE `$table_name` SET ')
	} else if node.kind == .delete {
		g.write('DELETE FROM `$table_name` ')
	}
	if node.kind == .insert {
		for i, field in node.fields {
			if g.get_sql_field_type(field) == ast.Type(-1) {
				continue
			}
			g.write('`${g.get_field_name(field)}`')
			if i < node.fields.len - 1 {
				g.write(', ')
			}
		}
		g.write(') values (')
		for i, field in node.fields {
			if g.get_sql_field_type(field) == ast.Type(-1) {
				continue
			}
			if typ == .sqlite3 {
				g.write('?${i + 0}')
			} else if typ == .mysql {
				g.write('?')
			}
			if i < node.fields.len - 1 {
				g.write(', ')
			}
			g.sql_i++
		}
		g.write(')')
	} else if node.kind == .update {
		for i, col in node.updated_columns {
			g.write(' $col = ')
			g.expr_to_sql(node.update_exprs[i], typ)
			if i < node.updated_columns.len - 1 {
				g.write(', ')
			}
		}
		g.write(' WHERE ')
	} else if node.kind == .delete {
		g.write(' WHERE ')
	}
	if node.kind == .update || node.kind == .delete {
		g.expr_to_sql(node.where_expr, typ)
	}
	g.write('")')
}

fn (mut g Gen) table_gen(node ast.SqlStmt, typ SqlType) string {
	typ_sym := g.table.get_type_symbol(node.table_expr.typ)
	if typ_sym.info !is ast.Struct {
		verror('Type `$typ_sym.name` has to be a struct')
	}
	struct_data := typ_sym.info as ast.Struct
	table_name := g.get_table_name(node.table_expr)
	mut create_string := 'CREATE TABLE IF NOT EXISTS `$table_name` ('

	mut fields := []string{}

	mut primary := '' // for mysql
	mut unique := map[string][]string{}

	for field in struct_data.fields {
		name := g.get_field_name(field)
		mut is_primary := false
		mut no_null := false
		mut is_unique := false
		for attr in field.attrs {
			match attr.name {
				'primary' {
					is_primary = true
					primary = name
				}
				'unique' {
					if attr.arg != '' {
						unique[attr.arg] << name
					} else {
						is_unique = true
					}
				}
				'nonull' {
					no_null = true
				}
				else {}
			}
		}
		mut stmt := ''
		mut converted_typ := g.sql_type_from_v(typ, g.get_sql_field_type(field))
		if converted_typ == '' {
			if g.table.get_type_symbol(field.typ).kind == .struct_ {
				converted_typ = g.sql_type_from_v(typ, ast.int_type)
				g.sql_create_table(ast.SqlStmt{
					db_expr: node.db_expr
					kind: node.kind
					pos: node.pos
					table_expr: ast.TypeNode{
						typ: field.typ
						pos: node.table_expr.pos
					}
				})
			} else {
				eprintln(g.table.get_type_symbol(field.typ).kind)
				verror('unknown type ($field.typ)')
				continue
			}
		}
		stmt = '`$name` $converted_typ'

		if field.has_default_expr && typ != .mysql {
			stmt += ' DEFAULT '
			stmt += field.default_expr.str()
		}
		if no_null {
			stmt += ' NOT NULL'
		}
		if is_unique {
			stmt += ' UNIQUE'
		}
		if is_primary && typ == .sqlite3 {
			stmt += ' PRIMARY KEY'
		}
		fields << stmt
	}
	if unique.len > 0 {
		for k, v in unique {
			mut tmp := []string{}
			for f in v {
				tmp << '`$f`'
			}
			fields << '/* $k */UNIQUE(${tmp.join(', ')})'
		}
	}
	if typ == .mysql {
		fields << 'PRIMARY KEY(`$primary`)'
	}
	create_string += fields.join(', ')
	create_string += ');'
	return create_string
}

fn (mut g Gen) expr_to_sql(expr ast.Expr, typ SqlType) {
	// Custom handling for infix exprs (since we need e.g. `and` instead of `&&` in SQL queries),
	// strings. Everything else (like numbers, a.b) is handled by g.expr()
	//
	// TODO `where id = some_column + 1` needs literal generation of `some_column` as a string,
	// not a V variable. Need to distinguish column names from V variables.
	match expr {
		ast.InfixExpr {
			g.sql_side = .left
			g.expr_to_sql(expr.left, typ)
			match expr.op {
				.ne { g.write(' != ') }
				.eq { g.write(' = ') }
				.gt { g.write(' > ') }
				.lt { g.write(' < ') }
				.ge { g.write(' >= ') }
				.le { g.write(' <= ') }
				.and { g.write(' and ') }
				.logical_or { g.write(' or ') }
				.plus { g.write(' + ') }
				.minus { g.write(' - ') }
				.mul { g.write(' * ') }
				.div { g.write(' / ') }
				else {}
			}
			g.sql_side = .right
			g.expr_to_sql(expr.right, typ)
		}
		ast.StringLiteral {
			// g.write("'$it.val'")
			g.inc_sql_i(typ)
			g.sql_bind('"$expr.val"', expr.val.len.str(), g.sql_get_real_type(ast.string_type),
				typ)
		}
		ast.IntegerLiteral {
			g.inc_sql_i(typ)
			g.sql_bind(expr.val, '', g.sql_get_real_type(ast.int_type), typ)
		}
		ast.BoolLiteral {
			// true/false literals were added to Sqlite 3.23 (2018-04-02)
			// but lots of apps/distros use older sqlite (e.g. Ubuntu 18.04 LTS )
			g.inc_sql_i(typ)
			eval := if expr.val { '1' } else { '0' }
			g.sql_bind(eval, '', g.sql_get_real_type(ast.byte_type), typ)
		}
		ast.Ident {
			// `name == user_name` => `name == ?1`
			// for left sides just add a string, for right sides, generate the bindings
			if g.sql_side == .left {
				// println("sql gen left $expr.name")
				g.sql_left_type = g.get_struct_field_typ(expr.name)
				g.write(expr.name)
			} else {
				g.inc_sql_i(typ)
				info := expr.info as ast.IdentVar
				ityp := info.typ
				if typ == .sqlite3 {
					if ityp == ast.string_type {
						g.sql_bind('${expr.name}.str', '${expr.name}.len', g.sql_get_real_type(ityp),
							typ)
					} else {
						g.sql_bind(expr.name, '', g.sql_get_real_type(ityp), typ)
					}
				} else {
					g.sql_bind('%$g.sql_i.str()', '', g.sql_get_real_type(ityp), typ)
					g.sql_idents << expr.name
					g.sql_idents_types << g.sql_get_real_type(ityp)
				}
			}
		}
		ast.SelectorExpr {
			g.inc_sql_i(typ)
			if expr.expr !is ast.Ident {
				verror('orm selector not ident')
			}
			ident := expr.expr as ast.Ident
			g.sql_bind(ident.name + '.' + expr.field_name, '', g.sql_get_real_type(expr.typ),
				typ)
		}
		else {
			g.expr(expr)
		}
	}
	/*
	ast.Ident {
			g.write('$it.name')
		}
		else {}
	*/
}

fn (mut g Gen) get_struct_field_typ(f string) ast.Type {
	sym := g.table.get_type_symbol(g.table.type_idxs[g.sql_table_name])

	mut typ := ast.Type(-1)

	if sym.kind != .struct_ {
		str := sym.info as ast.Struct
		for field in str.fields {
			if field.name != f {
				continue
			}
			typ = g.get_sql_field_type(field)
			break
		}
	}

	return typ
}

fn (mut g Gen) sql_get_real_type(typ ast.Type) ast.Type {
	if typ != g.sql_left_type && g.sql_left_type >= 0 {
		return g.sql_left_type
	}
	return typ
}

fn (mut g Gen) inc_sql_i(typ SqlType) {
	g.sql_i++
	if typ == .sqlite3 {
		g.write('?')
		g.write('$g.sql_i')
	}
}

fn (mut g Gen) parse_db_type(expr ast.Expr) SqlType {
	match expr {
		ast.Ident {
			if expr.info is ast.IdentVar {
				return g.parse_db_from_type_string(g.table.get_type_name(expr.info.typ))
			}
		}
		ast.SelectorExpr {
			return g.parse_db_from_type_string(g.table.get_type_name(expr.typ))
		}
		else {
			return .unknown
		}
	}
	return .unknown
}

fn (mut g Gen) parse_db_from_type_string(name string) SqlType {
	match name {
		'sqlite.DB' {
			return .sqlite3
		}
		'mysql.Connection' {
			return .mysql
		}
		else {
			return .unknown
		}
	}
}

fn (mut g Gen) get_sql_field_type(field ast.StructField) ast.Type {
	mut typ := field.typ
	for attr in field.attrs {
		if attr.name == 'sql' && !attr.is_string_arg && attr.arg != '' {
			if attr.arg.to_lower() == 'serial' {
				typ = ast.Type(-1)
				break
			}
			typ = g.table.type_idxs[attr.arg]
		}
	}
	return typ
}

fn (mut g Gen) get_table_name(table_expr ast.TypeNode) string {
	info := g.table.get_type_symbol(table_expr.typ).struct_info()
	mut tablename := util.strip_mod_name(g.table.get_type_symbol(table_expr.typ).name)
	for attr in info.attrs {
		if attr.name == 'tablename' && attr.is_string_arg {
			tablename = attr.arg
			break
		}
	}
	return tablename
}

fn (mut g Gen) get_field_name(field ast.StructField) string {
	mut name := field.name
	for attr in field.attrs {
		if attr.name == 'sql' && attr.is_string_arg {
			name = attr.arg
			break
		}
	}
	return name
}
