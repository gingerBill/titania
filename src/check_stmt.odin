package titania

import "core:fmt"

check_is_boolean :: proc(c: ^Checker_Context, o: ^Operand) {
	assert(o.type != nil)
	if o.type.kind != .Bool {
		if o.expr != nil {
			error(c, o.expr.pos, "expected a boolean expression")
		}
	}
}

@(require_results)
check_is_entity_addressable :: proc(c: ^Checker_Context, e: ^Entity) -> bool {
	if e.kind == .Var {
		return true
	}
	return false
}

check_stmt_sequence :: proc(c: ^Checker_Context, seq: ^Ast_Stmt_Sequence) {
	for stmt in seq.stmts {
		check_stmt(c, stmt)
	}
}

check_cond :: proc(c: ^Checker_Context, expr: ^Ast_Expr) {
	cond: Operand
	check_expr(c, &cond, expr)
	check_is_boolean(c, &cond)
}

check_stmt :: proc(c: ^Checker_Context, stmt: ^Ast_Stmt) {
	switch s in stmt.variant {
	case ^Ast_If_Stmt:
		check_cond(c, s.cond)
		check_stmt_sequence(c, s.body)
		for elseif_stmt in s.elseif_stmts {
			check_stmt(c, elseif_stmt)
		}
		if es, ok := s.else_stmt.?; ok {
			check_stmt_sequence(c, es)
		}

	case ^Ast_Case_Stmt:
		cond: Operand
		check_expr(c, &cond, s.cond)
		panic("TODO: case stmt")

	case ^Ast_While_Stmt:
		check_cond(c, s.cond)
		check_stmt_sequence(c, s.body)
		for elseif_stmt in s.elseif_stmts {
			econd: Operand
			check_expr(c, &econd, elseif_stmt.cond)
			check_is_boolean(c, &econd)
			check_stmt_sequence(c, elseif_stmt.body)
		}

	case ^Ast_Repeat_Stmt:
		check_stmt_sequence(c, s.body)
		check_cond(c, s.cond)

	case ^Ast_For_Stmt:
		name := s.name.tok.text
		entity, ok := scope_lookup(c.scope, name)
		s.name.entity = entity
		if !ok {
			error(c, s.name.pos, "'%s' has not been declared", name)
		} else if !check_is_entity_addressable(c, entity) {
			error(c, s.name.pos, "cannot assigned to '%s' as it is not addressable", name)
		}

		lo, hi, by: Operand
		check_expr(c, &lo, s.lo_cond)
		check_expr(c, &hi, s.hi_cond)
		if by_cond, ok := s.by_cond.?; ok {
			check_expr(c, &by, by_cond)
		}

		check_stmt_sequence(c, s.body)


	case ^Ast_Expr_Stmt:
		o: Operand
		check_expr_or_no_value(c, &o, s.expr)
		#partial switch o.mode {
		case .RValue, .LValue, .Const, .Builtin:
			error(c, o.expr.pos, "unused expression found")
		}

	case ^Ast_Assign_Stmt:
		lhs, rhs: Operand
		check_expr(c, &lhs, s.lhs)
		check_expr(c, &rhs, s.rhs)
		if lhs.mode != .LValue {
			error(c, s.lhs.pos, "cannot assigned to left-hand-side as it is not addressable", )
		}
		if rhs.mode == .Nil {
			#partial switch lhs.type.kind {
			case .Pointer, .Set:
				// okay
			case:
				error(c, lhs.expr.pos, "'nil' can only be assigned to pointers and set types, got %s", type_to_string(lhs.type))
			}

		} else if !types_equal(lhs.type, rhs.type) {
			error(c, s.lhs.pos, "cannot assigned to left-hand-side as types do not match, %s vs %s", type_to_string(lhs.type), type_to_string(rhs.type))
		}
	}

}
