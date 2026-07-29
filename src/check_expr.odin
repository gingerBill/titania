package titania

import "core:fmt"
import "core:strconv"
import "core:mem/virtual"

check_is_integer :: proc(c: ^Checker_Context, o: ^Operand) {
	assert(o.type != nil)

	#partial switch o.type.kind {
	case .Invalid:
		return
	case .Char, .Int, .Byte, .Enum:
		return
	}

	if o.expr != nil {
		error(c, o.expr.pos, "expected an integer-like expression")
	}
}


assign_entity_to_operand :: proc(c: ^Checker_Context, e: ^Entity, o: ^Operand, expr: ^Ast_Expr) {
	switch e.kind {
	case .Invalid:
		error(c, e.pos, "invalid entity")
		o.mode  = .Invalid
		o.type  = t_invalid
		o.value = nil
	case .Nil:
		o.mode  = .Nil
		o.expr  = expr
		o.type  = t_nil
		o.value = nil
	case .Const:
		o.mode  = .Const
		o.type  = e.type
		o.expr  = expr
		o.value = e.value
	case .Type:
		o.mode  = .Type
		o.type  = e.type
		o.expr  = expr
		o.value = nil
	case .Var:
		o.mode  = .LValue
		o.type  = e.type
		o.expr  = expr
		o.value = nil

	case .Proc:
		o.mode  = .RValue
		o.type  = e.type
		o.expr  = expr
		o.value = nil

	case .Import:
		o.mode  = .Invalid
		o.type  = t_invalid
		o.expr  = expr
		o.value = nil

	case .Builtin:
		o.type = t_invalid
		o.mode = .Builtin
		o.expr = expr
		o.builtin_id = e.builtin_id
	}
}

check_expr_or_type :: proc(c: ^Checker_Context, o: ^Operand, expr: ^Ast_Expr) {
	check_expr_internal(c, o, expr)
	switch o.mode {
	case .RValue, .LValue, .Const, .Nil, .Type:
		// okay
	case .No_Value:
		error(c, o.expr.pos, "expected an expression, got no value")
	case .Builtin:
		error(c, o.expr.pos, "unexpected built-in expression used as value")

	case .Invalid:
		// ignore
	}
}
check_expr :: proc(c: ^Checker_Context, o: ^Operand, expr: ^Ast_Expr) {
	check_expr_internal(c, o, expr)
	switch o.mode {
	case .RValue, .LValue, .Const, .Nil:
		// okay
	case .Type:
		error(c, o.expr.pos, "unexpected type when expression was expected")
	case .No_Value:
		error(c, o.expr.pos, "expected an expression, got no value")
	case .Builtin:
		error(c, o.expr.pos, "unexpected built-in expression used as value")
	case .Invalid:
		// ignore
	}
}
check_expr_or_no_value :: proc(c: ^Checker_Context, o: ^Operand, expr: ^Ast_Expr) {
	check_expr_internal(c, o, expr)
	switch o.mode {
	case .RValue, .LValue, .Const, .Nil, .No_Value:
		// okay
	case .Type:
		error(c, o.expr.pos, "unexpected type when expression was expected")
	case .Builtin:
		error(c, o.expr.pos, "unexpected built-in expression used as value")
	case .Invalid:
		// ignore
	}
}


check_selector :: proc(c: ^Checker_Context, o: ^Operand, rhs: ^Ast_Ident) {
	#partial switch o.mode {
	case .RValue, .LValue:
		type := type_deref(o.type)

		#partial switch type.kind {
		case .Record:
			record := type.variant.(^Type_Record)
			if field, ok := scope_lookup_current(record.scope, rhs.tok.text); ok {
				if o.type.kind == .Pointer {
					o.mode = .LValue
				}
				o.type = field.type
				o.value = nil

				rhs.entity = field
				return
			}
			error(c, rhs.pos, "unable to find field '%s' for type '%s'", rhs.tok.text, type_to_string(o.type))
		case:
			error(c, rhs.pos, "%s cannot be used in a selector expression only record types, got %s", type_to_string(o.type))
		}
	case:
		error(c, rhs.pos, "%s cannot be used in a selector expression", addressing_mode_string[o.mode])
	}
}


check_expr_internal :: proc(c: ^Checker_Context, o: ^Operand, expr: ^Ast_Expr) {
	defer {
		o.expr = expr
		expr.type = o.type
		if o.mode == .Const {
			expr.value = o.value
		}
	}

	switch e in expr.variant {
	case ^Ast_Bad_Expr:
		error(c, e.pos, "bad expression found")

	case ^Ast_Ident:
		found, ok := scope_lookup(c.scope, e.tok.text)
		if !ok {
			error(c, e.pos, "'%s' has not been declared in scope", e.tok.text)
			o.type = t_invalid
			o.mode = .Invalid
			return
		}
		if p, ok := found.scope.procedure.?; ok && p != c.curr_proc {
			error(c, e.pos, "'%s' is declared in a different procedure's scope '%s'", e.tok.text, p.name)
		}
		assign_entity_to_operand(c, found, o, expr)
		e.entity = found

	case ^Ast_Literal:
		#partial switch e.tok.kind {
		case .Integer:
			o.mode  = .Const
			o.expr  = expr
			o.type  = t_int
			o.value, _ = strconv.parse_i64(e.tok.text)
		case .Real:
			o.mode  = .Const
			o.expr  = expr
			o.type  = t_real
			o.value, _ = strconv.parse_f64(e.tok.text)
		case .String:
			allocator := virtual.arena_allocator(c.arena)
			str, _, ok := strconv.unquote_string(e.tok.text, allocator)
			if !ok {
				error(c, e.tok.pos, "unable to unquote the following string: %s", e.tok.text)
			}

			o.mode  = .Const
			o.expr  = expr
			o.value = str
			o.type  = type_new_string(c.arena, len(str))
		case .Nil:
			o.mode = .Nil
			o.expr = expr
			o.type = t_nil
		case .True:
			o.mode  = .Const
			o.expr  = expr
			o.value = true
			o.type  = t_bool
		case .False:
			o.mode  = .Const
			o.expr  = expr
			o.value = false
			o.type  = t_bool
		case:
			error(c, e.tok.pos, "unknown literal")
		}
	case ^Ast_Qual_Ident:
		rhs := e.rhs.tok.text

		x, x_ok := scope_lookup(c.scope, e.lhs.tok.text)
		if !x_ok {
			error(c, e.pos, "'%s' has not been declared in scope", e.lhs.tok.text)
			o.type = t_invalid
			o.mode = .Invalid
			return
		}
		e.lhs.entity = x
		if x.kind == .Import {
			found, found_ok := scope_lookup(x.import_scope, rhs)
			if !found_ok {
				error(c, e.pos, "'%s' does not exist in the x '%s'", rhs, e.lhs.tok.text)
				o.type = t_invalid
				o.mode = .Invalid
				return
			}
			assign_entity_to_operand(c, found, o, expr)
			e.entity = found
			return
		}

		lhs: Operand
		check_expr(c, o, e.lhs)
		check_selector(c, o, e.rhs)


	case ^Ast_Unary_Expr:
		#partial switch e.op.kind {
		case .Add, .Sub:
			check_expr(c, o, e.expr)
			if o.type != nil {
				#partial switch o.type.kind {
				case .Int, .Byte, .Char, .Real, .Enum:
					// okay
				case:
					error(c, e.op.pos, "%s is only supported for numeric types", e.op.text)
				}
			}

			if e.op.kind == .Sub && o.mode == .Const {
				switch v in o.value {
				case i64: o.value = -v
				case f64: o.value = -v
				case string: // ignore
				case bool:   // ignore
				}
			}
		case:
			error(c, e.op.pos, "invalid unary operator, got '%s'", e.op.text)
		}

	case ^Ast_Binary_Expr:
		lhs, rhs: Operand

		#partial switch e.op.kind {
		case .Is:
			check_expr(c, &lhs, e.lhs)
			check_expr_or_type(c, &rhs, e.rhs)

			o.value = false
			o.mode = .Const
			o.type = t_bool
			if rhs.mode != .Type {
				error(c, rhs.expr.pos, "expected a type for 'is'")
			}
			o.value = types_equal(lhs.type, rhs.type)
			return

		case .In:
			check_expr(c, &lhs, e.lhs)
			check_expr(c, &rhs, e.rhs)

			o.value = nil
			o.mode = .RValue
			o.type = t_bool
			if !operand_is_value(rhs) || rhs.type.kind != .Set {
				error(c, rhs.expr.pos, "expected a set value for 'in', got %s", type_to_string(rhs.type))
			}
			if !operand_is_value(lhs) || !type_is_integer_like(lhs.type) {
				error(c, lhs.expr.pos, "expected an integer-like value to test against a test for 'in', got '%s'", type_to_string(lhs.type))
			}
			return
		}

		check_expr(c, &lhs, e.lhs)
		check_expr(c, &rhs, e.rhs)

		o.value = nil
		o.mode = .RValue
		o.type = lhs.type
		if is_relation(e.op.kind) {
			o.type = t_bool
		}

		if !types_equal(lhs.type, rhs.type) {
			error(c, e.op.pos, "mismatching types")
		} else if lhs.mode == .Const && rhs.mode == .Const {
			o.value = check_const_binary_expr(c, lhs.value, e.op.kind, rhs.value)
			if o.value == nil {
				error(c, e.op.pos, "%s is not supported for %s", e.op.text, type_to_string(lhs.type))
			} else {
				o.mode = .Const
			}
		} else {
			#partial switch e.op.kind {
			case .Add, .Sub, .Mul, .Quo:
				if !type_is_numeric(lhs.type) {
					error(c, e.op.pos, "'%s' is only supported for numeric types, got %s", e.op.text, type_to_string(lhs.type))
				}
			case .Mod:
				if !type_is_integer_like(lhs.type) {
					error(c, e.op.pos, "'%s' is only supported for integer-like types, got %s", e.op.text, type_to_string(lhs.type))
				}
			case .Xor:
				if !type_is_integer_like(lhs.type) && lhs.type.kind != .Bool {
					error(c, e.op.pos, "'%s' is only supported for integer-like or boolean types, got %s", e.op.text, type_to_string(lhs.type))
				}
			case .Equal, .Not_Equal:
				if !type_is_numeric(lhs.type) && lhs.type.kind != .Set {
					error(c, e.op.pos, "'%s' is only supported for numeric types, got %s", e.op.text, type_to_string(lhs.type))
				}
			case .Less_Than, .Greater_Than, .Less_Than_Equal, .Greater_Than_Equal:
				if !type_is_numeric(lhs.type) {
					error(c, e.op.pos, "'%s' is only supported for numeric types, got %s", e.op.text, type_to_string(lhs.type))
				}
			case .And, .Or:
				if lhs.type.kind != .Bool {
					error(c, e.op.pos, "'%s' is only supported for boolean types, got %s", e.op.text, type_to_string(lhs.type))
				}
			}
		}

	case ^Ast_Deref_Expr:
		check_expr(c, o, e.expr)
		if o.type.kind != .Pointer {
			error(c, e.expr.pos, "expected a pointer expression to dereference")
			o.mode = .Invalid
		} else {
			o.type = type_deref(o.type)
			o.mode = .LValue
			o.value = nil
		}

	case ^Ast_Selector_Expr:
		check_expr_internal(c, o, e.lhs)
		check_selector(c, o, e.rhs)


	case ^Ast_Paren_Expr:
		check_expr(c, o, e.expr)

	case ^Ast_Set_Expr:
		o.type = t_set
		o.mode = .RValue
		for element in e.elements {
			lhs, rhs: Operand

			check_expr(c, &lhs, element.lhs)
			if !type_is_integer_like(lhs.type) {
				error(c, lhs.expr.pos, "expected an integer-like value for a set expression, got %s", type_to_string(lhs.type))
			}

			if erhs, ok := element.rhs.?; ok {
				check_expr(c, &rhs, erhs)
				if !type_is_integer_like(rhs.type) {
					error(c, rhs.expr.pos, "expected an integer-like value for a set expression, got %s", type_to_string(rhs.type))
				}
			}
		}

	case ^Ast_Index_Expr:
		check_expr(c, o, e.expr)
		i: Operand
		check_expr(c, &i, e.index)
		check_is_integer(c, &i)

		if o.type.kind != .Array {
			error(c, e.expr.pos, "cannot index a non-array type")
			o.mode = .Invalid
			o.type = t_invalid
			o.value = nil
		} else {
			if o.mode != .LValue {
				error(c, e.expr.pos, "cannot index a non l-value")
			}
			o.mode = .LValue
			o.type = o.type.variant.(^Type_Array).elem
			o.value = nil
		}

	case ^Ast_Call_Expr:
		check_expr_internal(c, o, e.call)
		#partial switch o.mode {
		case .Builtin:
			check_builtin(c, o, e.parameters[:])
		case .Type:
			o.mode = .RValue
			o.type = o.type
			if len(e.parameters) != 1 {
				error(c, e.call.pos, "expect only 1 parameter for a type conversion, got %d", len(e.parameters))
			}
			if len(e.parameters) >= 1 {
				p: Operand
				check_expr(c, &p, e.parameters[0])

				dst := o.type.kind
				src := p.type.kind
				if dst == src {
					return
				}

				#partial switch src {
				case .Bool:
					#partial switch dst {
					case .Int, .Byte:
						// okay
						if b, ok := p.value.(bool); ok {
							o.value = i64(1 if b else 0)
							o.mode = .Const
						}
					case:
						error(c, p.expr.pos, "cannot cast from %s to %s", type_to_string(o.type), type_to_string(p.type))
					}
				case .Char:
					#partial switch dst {
					case .Int, .Byte:
						if i, ok := p.value.(i64); ok {
							o.value = i64(i)
							o.mode = .Const
						}
					case:
						error(c, p.expr.pos, "cannot cast from %s to %s", type_to_string(o.type), type_to_string(p.type))
					}
				case .Int:
					#partial switch dst {
					case .Real:
						if i, ok := p.value.(i64); ok {
							o.value = f64(i)
							o.mode = .Const
						}
					case .Char, .Byte:
						if i, ok := p.value.(i64); ok {
							o.value = i64(u64(i) & 0xff)
							o.mode = .Const
						}
					case:
						error(c, p.expr.pos, "cannot cast from %s to %s", type_to_string(o.type), type_to_string(p.type))
					}
				case .Real:
					#partial switch dst {
					case .Int:
						if i, ok := p.value.(f64); ok {
							o.value = i64(i)
							o.mode = .Const
						}
					case .Byte:
						if i, ok := p.value.(f64); ok {
							o.value = i64(u64(i) & 0xff)
							o.mode = .Const
						}
					case:
						error(c, p.expr.pos, "cannot cast from %s to %s", type_to_string(o.type), type_to_string(p.type))
					}
				case .Byte:
					#partial switch dst {
					case .Int, .Char:
						if i, ok := p.value.(i64); ok {
							o.value = i64(i)
							o.mode = .Const
						}

					case .Real:
						if i, ok := p.value.(i64); ok {
							o.value = f64(i)
							o.mode = .Const
						}
					case:
						error(c, p.expr.pos, "cannot cast from %s to %s", type_to_string(o.type), type_to_string(p.type))
					}
				case .Pointer:
					#partial switch dst {
					case .Int, .Pointer:
						// okay
					case:
						error(c, p.expr.pos, "cannot cast from %s to %s", type_to_string(o.type), type_to_string(p.type))
					}
				}

			}

			if o.mode != .Const {
				o.value = nil
			}

		case .RValue, .LValue:
			if o.type.kind != .Proc {
				error(c, e.call.pos, "expected a procedure value, got %s", type_to_string(o.type))
				o.mode = .No_Value
				o.type = t_invalid
				return
			}

			defer {
				o.mode = .No_Value
				o.type = t_invalid
			}

			sig := o.type.variant.(^Type_Proc)
			if len(sig.parameters) != len(e.parameters) {
				error(c, e.call.pos, "expected %d parameters, got %d", len(sig.parameters), len(e.parameters))

				// Type check them any way
				for param in e.parameters {
					p: Operand
					check_expr(c, &p, param)
				}

				return
			}

			for param, i in e.parameters {
				src: Operand
				check_expr(c, &src, param)
				dst := sig.parameters[i].type
				if !types_equal(src.type, dst) {
					error(c, src.expr.pos, "parameter-%d types do not match, got %s expected %s", i, type_to_string(src.type), type_to_string(dst))
				}
			}

		case:
			o.mode = .No_Value
			o.type = t_invalid
		}
	}
}

check_const_binary_expr :: proc(c: ^Checker_Context, lhs: Const_Value, op: Token_Kind, rhs: Const_Value) -> (res: Const_Value) {
	if x, y, ok := type_assert2(lhs, rhs, i64); ok {
		#partial switch op {
		case .Add: return x + y
		case .Sub: return x - y
		case .Mul: return x * y
		case .Quo: return x / y
		case .Mod: return x % y
		case .Xor: return x ~ y

		case .Equal:              return x == y
		case .Not_Equal:          return x != y
		case .Less_Than:          return x < y
		case .Less_Than_Equal:    return x <= y
		case .Greater_Than:       return x > y
		case .Greater_Than_Equal: return x >= y
		}
	} else if x, y, ok := type_assert2(lhs, rhs, f64); ok {
		#partial switch op {
		case .Add: return x + y
		case .Sub: return x - y
		case .Mul: return x * y
		case .Quo: return x / y

		case .Equal:              return x == y
		case .Not_Equal:          return x != y
		case .Less_Than:          return x < y
		case .Less_Than_Equal:    return x <= y
		case .Greater_Than:       return x > y
		case .Greater_Than_Equal: return x >= y
		}
	} else if x, y, ok := type_assert2(lhs, rhs, bool); ok {
		#partial switch op {
		case .Equal:     return x == y
		case .Not_Equal: return x != y
		case .And:       return x & y
		case .Or:        return x | y
		case .Xor:       return x ~ y
		}
	} else if x, y, ok := type_assert2(lhs, rhs, string); ok {
		if op == .Add {
			z, _ := virtual.make_slice(c.arena, []byte, len(x)+len(y))
			copy(z, x)
			copy(z[len(x):], y)
			return string(z)
		}
		return nil
	}

	return nil
}
