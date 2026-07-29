package titania

import "core:mem/virtual"

check_decl :: proc(c: ^Checker_Context, decl: ^Ast_Decl) {
	switch v in decl.variant {
	case ^Ast_Const_Decl:
		check_const_decl(c, v)
	case ^Ast_Type_Decl:
		check_type_decl(c, v)
	case ^Ast_Var_Decl:
		check_var_decl(c, v)
	case ^Ast_Proc_Decl:
		check_proc_decl(c, v)
	}
}

check_const_decl :: proc(c: ^Checker_Context, decl: ^Ast_Const_Decl) {
	name := decl.name.tok.text
	entity := entity_new(c.arena, .Const, name, t_invalid, c.scope)
	entity.decl = decl

	o: Operand
	check_expr(c, &o, decl.expr)
	if o.mode != .Const {
		error(c, decl.expr.pos, "expected a constant value for a constant declaration")
	} else {
		entity.value = o.value
		entity.type  = o.type
	}

	scope_insert_entity(c.scope, entity)
}

check_var_decl :: proc(c: ^Checker_Context, decl: ^Ast_Var_Decl) {
	type := check_type(c, decl.type)
	for name in decl.names {
		vname := name.tok.text
		found, ok := scope_lookup_current(c.scope, vname)
		if ok {
			error(c, name.pos, "'%s' has been previously declared in this scope", vname)
			continue
		}
		e := entity_new(c.arena, .Var, vname, type, c.scope)
		name.entity = e
		scope_insert_entity(c.scope, e)
	}
}

check_type_decl :: proc(c: ^Checker_Context, decl: ^Ast_Type_Decl) {
	_ = check_type_internal(c, decl.type, decl)
}

check_proc_decl :: proc(c: ^Checker_Context, decl: ^Ast_Proc_Decl) {
	name := decl.name.tok.text
	entity := entity_new(c.arena, .Proc, name, t_invalid, c.scope)
	entity.decl = decl
	decl.name.entity = entity
	scope_insert_entity(c.scope, entity)

	scope_push(c)
	defer scope_pop(c)

	entity.type = check_proc_type(c, decl.parameters[:])

	prev_proc := c.curr_proc
	c.curr_proc = entity
	defer c.curr_proc = prev_proc

	c.scope.procedure = entity

	// body
	for decl in decl.decls {
		check_decl(c, decl)
	}

	check_stmt_sequence(c, decl.body)

	if re, ok := decl.return_expr.?; ok {
		ret: Operand
		check_expr(c, &ret, re)
	}
}


