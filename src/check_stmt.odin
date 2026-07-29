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


// A case label must be a compile-time constant with an integer-like value
// (byte/char/int all fold to an i64 in this compiler's flat integer model).
@(require_results)
check_case_label :: proc(c: ^Checker_Context, expr: ^Ast_Expr) -> (val: i64, ok: bool) {
	o: Operand
	check_expr(c, &o, expr)
	if o.mode != .Const {
		error(c, expr.pos, "case label must be a constant expression")
		return 0, false
	}
	v, is_int := o.value.(i64)
	if !is_int {
		error(c, expr.pos, "case label must be an integer-like constant, got %s", type_to_string(o.type))
		return 0, false
	}
	return v, true
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

	case ^Ast_Switch_Stmt:
		cond: Operand
		check_expr(c, &cond, s.cond)
		if cond.type != nil && !type_is_integer_like(cond.type) {
			error(c, s.cond.pos, "switch condition must be an integer-like type (byte, char, enum, or int), got %s", type_to_string(cond.type))
		}

		// Track the inclusive [lo, hi] spans already used so overlaps are caught.
		seen: [dynamic][2]i64
		defer delete(seen)

		for kase in s.cases {
			for label in kase.labels {
				lo, lo_ok := check_case_label(c, label.lo)
				hi := lo
				if hi_expr, has_hi := label.hi.?; has_hi {
					h, hi_ok := check_case_label(c, hi_expr)
					if lo_ok && hi_ok {
						if h < lo {
							error(c, label.pos, "empty case label range: lower bound %d exceeds upper bound %d", lo, h)
						} else {
							hi = h
						}
					}
				}
				if lo_ok {
					for span in seen {
						if lo <= span[1] && span[0] <= hi {
							error(c, label.pos, "case label %d..%d overlaps an earlier label", lo, hi)
							break
						}
					}
					append(&seen, [2]i64{lo, hi})
				}
			}
			check_stmt_sequence(c, kase.body)
		}

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
			error(c, s.name.pos, "cannot assign to '%s' as it is not addressable", name)
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
			error(c, s.lhs.pos, "cannot assign to left-hand-side as it is not addressable", )
		}
		if rhs.mode == .Nil {
			#partial switch lhs.type.kind {
			case .Pointer, .Set, .Slice:
				// okay
			case:
				error(c, lhs.expr.pos, "'nil' can only be assigned to pointers and set types, got %s", type_to_string(lhs.type))
			}
		} else if !types_equal(lhs.type, rhs.type) {
			if rhs.type.kind == .Array && lhs.type.kind == .Slice {
				if types_equal(rhs.type.variant.(^Type_Array).elem,
				               lhs.type.variant.(^Type_Slice).elem) {
					return
				}
			}

			error(c, s.lhs.pos, "cannot assign to left-hand-side as types do not match, %s vs %s", type_to_string(lhs.type), type_to_string(rhs.type))
		}

	case ^Ast_Return_Stmt:
		// do nothing
	}

}
