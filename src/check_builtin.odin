package titania

import "core:fmt"
import "core:unicode/utf8"

Builtin_Id :: enum {
	Invalid,

	abs, // absolute value

	lsh,
	ash,
	ror,

	chr,
	ord,

	inc,
	dec,

	incl,
	excl,

	odd,

	floor,
	ceil,

	assert,
	new,
	delete,

	addr,
	size_of,
	align_of,

	copy,

	print,
	println,
}


@(rodata)
builtin_strings := [Builtin_Id]string {
	.Invalid  = "",

	.abs      = "abs",

	.lsh      = "lsh",
	.ash      = "ash",
	.ror      = "ror",

	.chr      = "chr",
	.ord      = "ord",

	.inc      = "inc",
	.dec      = "dec",

	.incl     = "incl",
	.excl     = "excl",

	.odd      = "odd",

	.floor    = "floor",
	.ceil     = "ceil",

	.assert   = "assert",
	.new      = "new",
	.delete   = "delete",

	.addr     = "addr",
	.size_of  = "size_of",
	.align_of = "align_of",

	.copy     = "copy",

	.print    = "print",
	.println  = "println",
}


check_builtin :: proc(c: ^Checker_Context, o: ^Operand, parameters: []^Ast_Expr) {

	o.type = t_invalid

	id := o.builtin_id
	name := builtin_strings[id]

	switch id {
	case .Invalid:
		return
	case .abs:
		if len(parameters) != 1 {
			error(c, o.expr.pos, "expected 1 parameter to '%s', got %d", name, len(parameters))
		}
		o.mode = .RValue
		o.type = t_int

		if len(parameters) > 0 {
			p: Operand
			check_expr(c, &p, parameters[0])
			if !type_is_numeric(p.type) {
				error(c, o.expr.pos, "expected a numeric value to '%s', got %s", name, type_to_string(p.type))
			}
			o.type = p.type
		}

	case .lsh, .ash, .ror:
		if len(parameters) != 1 {
			error(c, o.expr.pos, "expected 1 parameter to '%s', got %d", name, len(parameters))
		}
		o.mode = .RValue
		o.type = t_int

		if len(parameters) > 0 {
			p: Operand
			check_expr(c, &p, parameters[0])
			if !type_is_integer_like(p.type) {
				error(c, o.expr.pos, "expected an integer-like value to '%s', got %s", name, type_to_string(p.type))
			}
			o.type = p.type
		}

	case .chr:
		if len(parameters) != 1 {
			error(c, o.expr.pos, "expected 1 parameter to '%s', got %d", name, len(parameters))
		}
		if len(parameters) > 0 {
			p: Operand
			check_expr(c, &p, parameters[0])
			if !types_equal(p.type, t_int) {
				error(c, o.expr.pos, "expected an int parameter to '%s', got %s", name, type_to_string(p.type))
			}
		}

		o.type = t_char
		o.mode = .RValue

	case .ord:
		if len(parameters) != 1 {
			error(c, o.expr.pos, "expected 1 parameter to '%s', got %d", name, len(parameters))
		}
		o.mode = .RValue

		if len(parameters) > 0 {
			p: Operand
			check_expr(c, &p, parameters[0])
			if p.mode == .Const {
				v, ok := p.value.(string)
				if !ok {
					error(c, o.expr.pos, "expected a constant string parameter to '%s", name)
				} else {
					r, w := utf8.decode_rune_in_string(v)
					o.value = i64(r)
					o.mode = .Const
					if w != len(v) {
						error(c, o.expr.pos, "expected a constant string that contains a single unicode codepoint, got %q", v)
					}
				}
			} else {
				error(c, o.expr.pos, "expected a constant string parameter to '%s', got %s", name, type_to_string(p.type))
			}
		}

		o.type = t_int

	case .inc, .dec:
		if len(parameters) != 1 && len(parameters) != 2 {
			error(c, o.expr.pos, "expected 1 parameter to '%s', got %d", name, len(parameters))
		}
		o.mode = .No_Value
		o.type = t_invalid
		if len(parameters) > 0 {
			p: Operand
			check_expr(c, &p, parameters[0])
			if p.mode == .LValue && type_is_numeric(p.type) {
				// Okay
			} else {
				error(c, o.expr.pos, "expected an addressable numeric value to '%s'", name)
			}

			if len(parameters) > 1 {
				offset: Operand
				check_expr(c, &offset, parameters[1])
				if !types_equal(p.type, offset.type) {
					error(c, o.expr.pos, "types must match for '%s', got %s vs %s", name, type_to_string(p.type), type_to_string(offset.type))
				}
			}
		}

	case .incl, .excl:
		if len(parameters) != 2 {
			error(c, o.expr.pos, "expected 1 or 2 parameters to '%s', got %d", name, len(parameters))
		}
		o.mode = .No_Value
		o.type = t_invalid
		if len(parameters) > 1 {
			dst: Operand
			val: Operand
			check_expr(c, &dst, parameters[0])
			check_expr(c, &val, parameters[1])
			if !(dst.mode == .LValue && dst.type.kind == .Set) {
				error(c, o.expr.pos, "expected an addressable set to '%s'", name)
			}
			if !type_is_integer_like(val.type) {
				error(c, o.expr.pos, "expected an integer-like type set to '%s', got %s", name, type_to_string(val.type))
			}
		}

	case .odd:
		if len(parameters) != 1 {
			error(c, o.expr.pos, "expected 1 parameter to '%s', got %d", name, len(parameters))
		}
		o.mode = .RValue
		o.type = t_bool

		if len(parameters) > 0 {
			p: Operand
			check_expr(c, &p, parameters[0])
			if p.mode == .Const {
				#partial switch v in p.value {
				case i64:
					o.mode = .Const
					o.value = v % 2 == 0
					o.type = t_bool
				case:
					error(c, o.expr.pos, "expected a integer-like value to '%s', got %s", name, type_to_string(p.type))
				}
			} else if !type_is_integer_like(p.type) {
				error(c, o.expr.pos, "expected a integer-like value to '%s', got %s", name, type_to_string(p.type))
			}
		}

	case .floor, .ceil:
		if len(parameters) != 1 {
			error(c, o.expr.pos, "expected 1 parameter to '%s', got %d", name, len(parameters))
		}
		o.mode = .RValue
		o.type = t_real

		if len(parameters) > 0 {
			p: Operand
			check_expr(c, &p, parameters[0])
			if p.type.kind != .Real {
				error(c, o.expr.pos, "expected a real value to '%s', got %s", name, type_to_string(p.type))
			}
		}

	case .assert:
		panic("TODO(bill): builtin.assert")

	case .new:
		o.mode = .No_Value
		o.type = t_invalid
		o.value = nil
		if len(parameters) != 1 {
			error(c, o.expr.pos, "expected 1 parameter to '%s', got %d", name, len(parameters))
		}
		if len(parameters) > 0 {
			p: Operand
			check_expr(c, &p, parameters[0])
			if p.mode != .LValue {
				error(c, p.expr.pos, "parameter must be addressable for '%s'", name)
			} else if  p.type.kind != .Pointer {
				error(c, p.expr.pos, "parameter must be pointer for '%s', got %s", name, type_to_string(p.type))
			}
		}

	case .delete:
		o.mode = .No_Value
		o.type = t_invalid
		o.value = nil
		if len(parameters) != 1 {
			error(c, o.expr.pos, "expected 1 parameter to '%s', got %d", name, len(parameters))
		}
		if len(parameters) > 0 {
			p: Operand
			check_expr(c, &p, parameters[0])
			if p.type.kind != .Pointer {
				error(c, p.expr.pos, "parameter must be pointer for '%s', got %s", name, type_to_string(p.type))
			}
		}

	case .addr:
		o.mode = .No_Value
		o.type = t_invalid
		o.value = nil
		if len(parameters) != 1 {
			error(c, o.expr.pos, "expected 1 parameter to '%s', got %d", name, len(parameters))
		}
		if len(parameters) > 0 {
			p: Operand
			check_expr(c, &p, parameters[0])
			if p.type.kind != .Invalid {
				o.type = type_new_pointer(c.arena, p.type)
				o.mode = .RValue
			}
			if p.mode != .LValue {
				error(c, p.expr.pos, "parameter must be addressable for '%s'", name)
			}
		}

	case .size_of:
		o.mode = .Const
		o.type = t_int
		o.value = i64(0)
		if len(parameters) != 1 {
			error(c, o.expr.pos, "expected 1 parameter to '%s', got %d", name, len(parameters))
		}
		if len(parameters) > 0 {
			p: Operand
			check_expr(c, &p, parameters[0])
			if o.mode == .Type || operand_is_value(p) {
				o.value = type_size_of(p.type)
			} else {
				error(c, p.expr.pos, "expected a value or type to '%s'", name)
			}
		}

	case .align_of:
		o.mode = .Const
		o.type = t_int
		o.value = i64(1)
		if len(parameters) != 1 {
			error(c, o.expr.pos, "expected 1 parameter to '%s', got %d", name, len(parameters))
		}
		if len(parameters) > 0 {
			p: Operand
			check_expr(c, &p, parameters[0])
			if o.mode == .Type || operand_is_value(p) {
				o.value = type_align_of(p.type)
			} else {
				error(c, p.expr.pos, "expected a value or type to '%s'", name)
			}
		}

	case .copy:
		o.mode = .No_Value
		o.type = t_invalid
		if len(parameters) != 3 {
			error(c, o.expr.pos, "expected 3 parameters to '%s', got %d", name, len(parameters))
			return
		}
		dst, src, n: Operand
		check_expr(c, &dst, parameters[0])
		check_expr(c, &src, parameters[1])
		check_expr(c, &n,   parameters[2])
		if dst.type.kind != .Pointer {
			error(c, dst.expr.pos, "destination (parameter-0) must be a pointer, got %s", type_to_string(dst.type))
		}
		if src.type.kind != .Pointer {
			error(c, src.expr.pos, "source (parameter-1) must be a pointer, got %s", type_to_string(src.type))
		}
		if !type_is_integer_like(n.type) {
			error(c, n.expr.pos, "length (parameter-2) must be an integer-like value, got %s", type_to_string(n.type))
		}
		return

	case .print, .println:
		o.mode = .No_Value
		o.type = t_invalid
		for param in parameters {
			p: Operand
			check_expr(c, &p, param)
		}
	}
}
