package titania

import "core:fmt"
import "core:rexcode/isa"
import x86 "core:rexcode/isa/x86"

Gen :: struct {
	m:           ^Module,
	code:        [dynamic]x86.Instruction,
	labels:      [dynamic]isa.Label_Definition,
	proc_labels: map[^Entity]u32,

	imp:         Imports,
	global_base: u64,

	strings:     [dynamic]u8,
	string_base: u64,

	error_count: int,
}

g: ^Gen

ARG_REGS := [4]x86.Register{x86.RCX, x86.RDX, x86.R8, x86.R9}

emit :: proc(inst: x86.Instruction) {
	append(&g.code, inst)
}

gen_error :: proc(pos: Pos, format: string, args: ..any) {
	error_module(g.m, pos, format, ..args)
	g.error_count += 1
}


mov_ri :: proc(r: x86.Register, v: i64) {
	emit(x86.inst_r_i(.MOV, r, v, 8))
}
push_r :: proc(r: x86.Register) {
	emit(x86.inst_r(.PUSH, r))
}
pop_r :: proc(r: x86.Register) {
	emit(x86.inst_r(.POP, r))
}

push_const_int :: proc(v: i64, pos: Pos) {
	mov_ri(x86.RAX, v)
	push_r(x86.RAX)
}

@(require_results)
is_real :: proc(t: ^Type) -> bool {
	return t != nil && t.kind == .Real
}

// Move an 8-byte stack slot into an XMM register (popping it).
pop_xmm :: proc(x: x86.Register) {
	pop_r(x86.RAX)
	emit(x86.inst_r_r(.MOVQ, x, x86.RAX))
}

// Push an XMM register's low 64 bits as an 8-byte stack slot.
push_xmm :: proc(x: x86.Register) {
	emit(x86.inst_r_r(.MOVQ, x86.RAX, x))
	push_r(x86.RAX)
}

@(require_results)
is_aggregate :: proc(t: ^Type) -> bool {
	return t != nil && (t.kind == .Record || t.kind == .Array)
}

@(require_results)
is_string :: proc(t: ^Type) -> bool {
	if t == nil || t.kind != .Array {
		return false
	}
	return t.variant.(^Type_Array).elem.kind == .Char
}

// Storage a variable of type t occupies. Scalars always get a full 8-byte slot (loads/stores are 8-byte); aggregates get their real size, rounded to 8.
@(require_results)
slot_size :: proc(t: ^Type) -> i64 {
	if is_aggregate(t) {
		return align_forward_i64(type_size_of(t), 8)
	}
	return 8
}

// Intern a string literal into the read-only string region (NUL-terminated) and return its absolute virtual address.
@(require_results)
intern_string :: proc(s: string) -> u64 {
	off := i64(len(g.strings))
	append(&g.strings, s)
	append(&g.strings, 0)
	return g.string_base + u64(off)
}

// address in RAX -> scalar value in RAX (sized by t)
load_scalar_rax :: proc(t: ^Type) {
	if type_size_of(t) == 1 {
		emit(x86.inst_r_m(.MOVZX, x86.RAX, x86.mem_base_only(x86.RAX), 1))
	} else {
		emit(x86.inst_r_m(.MOV, x86.RAX, x86.mem_base_only(x86.RAX), 8))
	}
}

// address in RAX, value in RCX -> store [RAX] = RCX (sized by t)
store_scalar :: proc(t: ^Type) {
	if type_size_of(t) == 1 {
		emit(x86.inst_m_r(.MOV, x86.mem_base_only(x86.RAX), 1, x86.CL))
	} else {
		emit(x86.inst_m_r(.MOV, x86.mem_base_only(x86.RAX), 8, x86.RCX))
	}
}

// Copy `size` bytes. Expects [.. src, dst] on the stack (dst on top).
gen_mem_copy :: proc(size: i64) {
	pop_r(x86.RAX) // dst
	pop_r(x86.RCX) // src
	k := i64(0)
	for k + 8 <= size {
		emit(x86.inst_r_m(.MOV, x86.RDX, x86.mem_base_disp(x86.RCX, i32(k)), 8))
		emit(x86.inst_m_r(.MOV, x86.mem_base_disp(x86.RAX, i32(k)), 8, x86.RDX))
		k += 8
	}
	for k < size {
		emit(x86.inst_r_m(.MOVZX, x86.RDX, x86.mem_base_disp(x86.RCX, i32(k)), 1))
		emit(x86.inst_m_r(.MOV, x86.mem_base_disp(x86.RAX, i32(k)), 1, x86.DL))
		k += 1
	}
}

@(require_results)
record_field_offset :: proc(lhs_type: ^Type, field_ent: ^Entity) -> i64 {
	t := lhs_type
	if t.kind == .Pointer {
		t = t.variant.(^Type_Pointer).elem
	}
	if rec, ok := t.variant.(^Type_Record); ok {
		type_init_offsets_for_record(rec)
		for f in rec.fields {
			if f.entity == field_ent {
				return f.offset
			}
		}
	}
	return 0
}

// Push the base address of an aggregate that a selector/index applies to.
// Auto-dereferences a pointer base (Oberon `p.field`).
gen_aggregate_base_addr :: proc(base: ^Ast_Expr) {
	if base.type != nil && base.type.kind == .Pointer {
		gen_expr(base) // pointer value == address of the pointee
	} else {
		gen_addr(base)
	}
}

// Push the address of a variable entity's storage.
gen_entity_addr :: proc(ent: ^Entity, pos: Pos) {
	if ent == nil {
		gen_error(pos, "backend: unresolved identifier")
		mov_ri(x86.RAX, 0)
		push_r(x86.RAX)
		return
	}
	if ent.backend_global {
		mov_ri(x86.RAX, i64(g.global_base + u64(ent.backend_offset)))
	} else {
		emit(x86.inst_r_m(.LEA, x86.RAX, x86.mem_base_disp(x86.RBP, -ent.backend_offset), 8))
	}
	push_r(x86.RAX)
}

// Push the address of `base.field`, auto-dereferencing a pointer base.
gen_field_addr :: proc(base: ^Ast_Expr, field_ent: ^Entity) {
	gen_aggregate_base_addr(base)
	off := record_field_offset(base.type, field_ent)
	pop_r(x86.RAX)
	if off != 0 {
		emit(x86.inst_r_i(.ADD, x86.RAX, i64(off), 4))
	}
	push_r(x86.RAX)
}

// Push the address of an addressable (l-value) expression.
gen_addr :: proc(e: ^Ast_Expr) {
	switch v in e.variant {
	case ^Ast_Paren_Expr:
		gen_addr(v.expr)
	case ^Ast_Ident:
		gen_entity_addr(v.entity, e.pos)
	case ^Ast_Qual_Ident:
		if v.entity != nil {
			gen_entity_addr(v.entity, e.pos) // module-qualified global
		} else {
			gen_field_addr(&v.lhs.base, v.rhs.entity) // record field access
		}
	case ^Ast_Deref_Expr:
		gen_expr(v.expr) // the pointer value is the address
	case ^Ast_Selector_Expr:
		gen_field_addr(v.lhs, v.rhs.entity)
	case ^Ast_Index_Expr:
		arr, ok := v.expr.type.variant.(^Type_Array)
		if !ok {
			gen_error(e.pos, "backend: indexing a non-array")
			mov_ri(x86.RAX, 0)
			push_r(x86.RAX)
			return
		}
		elem := i64(type_size_of(arr.elem))
		gen_aggregate_base_addr(v.expr) // base
		push_const_int(0, e.pos)      // byte-offset accumulator
		for idx, k in v.indices {
			stride := elem
			for d in k + 1..<len(arr.counts) {
				stride *= arr.counts[d]
			}
			gen_expr(idx)
			pop_r(x86.RAX)              // index value
			mov_ri(x86.RCX, stride)
			emit(x86.inst_r_r(.IMUL, x86.RAX, x86.RCX))
			pop_r(x86.RCX)             // accumulator
			emit(x86.inst_r_r(.ADD, x86.RAX, x86.RCX))
			push_r(x86.RAX)
		}
		pop_r(x86.RAX)  // total offset
		pop_r(x86.RCX)  // base
		emit(x86.inst_r_r(.ADD, x86.RAX, x86.RCX))
		push_r(x86.RAX)
	case ^Ast_Bad_Expr,
	     ^Ast_Literal,
	     ^Ast_Unary_Expr,
	     ^Ast_Binary_Expr,
	     ^Ast_Set_Expr,
	     ^Ast_Call_Expr:
		gen_error(e.pos, "backend: expression is not addressable")
		mov_ri(x86.RAX, 0)
		push_r(x86.RAX)
	case:
		gen_error(e.pos, "backend: expression is not addressable")
		mov_ri(x86.RAX, 0)
		push_r(x86.RAX)
	}
}

@(require_results)
new_label :: proc() -> u32 {
	return isa.label(&g.labels, &g.code)
}
@(require_results)
fwd_label :: proc() -> u32 {
	return isa.label_forward(&g.labels)
}
set_label :: proc(id: u32) {
	isa.label_set_at(&g.labels, id, &g.code)
}

aligned_call_label :: proc(id: u32) {
	emit(x86.inst_r_r(.MOV, x86.RBX, x86.RSP))
	emit(x86.inst_r_i(.AND, x86.RSP, -16, 4))
	emit(x86.inst_r_i(.SUB, x86.RSP, 32, 4))
	emit(x86.inst_rel(.CALL, id, 4))
	emit(x86.inst_r_r(.MOV, x86.RSP, x86.RBX))
}

aligned_call_ptr :: proc(ptr_reg: x86.Register) {
	emit(x86.inst_r_r(.MOV, x86.RBX, x86.RSP))
	emit(x86.inst_r_i(.AND, x86.RSP, -16, 4))
	emit(x86.inst_r_i(.SUB, x86.RSP, 32, 4))
	emit(x86.inst_m(.CALL, x86.mem_base_only(ptr_reg), 8))
	emit(x86.inst_r_r(.MOV, x86.RSP, x86.RBX))
}

load_var_rax :: proc(e: ^Entity) {
	if e.backend_global {
		mov_ri(x86.RAX, i64(g.global_base + u64(e.backend_offset)))
		emit(x86.inst_r_m(.MOV, x86.RAX, x86.mem_base_only(x86.RAX), 8))
	} else {
		emit(x86.inst_r_m(.MOV, x86.RAX, x86.mem_base_disp(x86.RBP, -e.backend_offset), 8))
	}
}

store_var_rax :: proc(e: ^Entity) {
	if e.backend_global {
		mov_ri(x86.RCX, i64(g.global_base + u64(e.backend_offset)))
		emit(x86.inst_m_r(.MOV, x86.mem_base_only(x86.RCX), 8, x86.RAX))
	} else {
		emit(x86.inst_m_r(.MOV, x86.mem_base_disp(x86.RBP, -e.backend_offset), 8, x86.RAX))
	}
}

@(require_results)
callee_entity :: proc(e: ^Ast_Expr) -> ^Entity {
	#partial switch v in e.variant {
	case ^Ast_Ident:      return v.entity
	case ^Ast_Qual_Ident: return v.entity
	}
	return nil
}


gen_expr :: proc(e: ^Ast_Expr) {
	#partial switch v in e.value {
	case i64:
		mov_ri(x86.RAX, v)
		push_r(x86.RAX)
		return
	case bool:
		mov_ri(x86.RAX, v ? 1 : 0)
		push_r(x86.RAX)
		return
	case f64:
		mov_ri(x86.RAX, transmute(i64)v)
		push_r(x86.RAX)
		return
	case string:
		mov_ri(x86.RAX, i64(intern_string(v)))
		push_r(x86.RAX)
		return
	}

	// An aggregate's "value" is the address of its storage.
	if is_aggregate(e.type) {
		gen_addr(e)
		return
	}

	switch v in e.variant {
	case ^Ast_Paren_Expr:
		gen_expr(v.expr)
	case ^Ast_Ident:
		gen_load_entity(v.entity, e.pos)
	case ^Ast_Qual_Ident:
		if v.entity != nil {
			gen_load_entity(v.entity, e.pos)
		} else {
			gen_addr(e) // record field access
			pop_r(x86.RAX)
			load_scalar_rax(e.type)
			push_r(x86.RAX)
		}
	case ^Ast_Unary_Expr:
		gen_expr(v.expr)
		if v.op.kind == .Sub {
			if is_real(v.expr.type) {
				pop_r(x86.RAX)
				mov_ri(x86.RCX, transmute(i64)u64(0x8000000000000000)) // flip IEEE sign bit
				emit(x86.inst_r_r(.XOR, x86.RAX, x86.RCX))
				push_r(x86.RAX)
			} else {
				pop_r(x86.RAX)
				emit(x86.inst_r(.NEG, x86.RAX))
				push_r(x86.RAX)
			}
		}
	case ^Ast_Binary_Expr:
		gen_binary(v)
	case ^Ast_Call_Expr:
		gen_call(v)
		push_r(x86.RAX)
	case ^Ast_Selector_Expr, ^Ast_Index_Expr, ^Ast_Deref_Expr:
		// scalar l-value: take its address, then load the value
		gen_addr(e)
		pop_r(x86.RAX)
		load_scalar_rax(e.type)
		push_r(x86.RAX)
	case ^Ast_Literal:
		if e.type != nil && e.type.kind == .Nil {
			mov_ri(x86.RAX, 0)
			push_r(x86.RAX) // nil pointer
		} else {
			gen_error(e.pos, "backend: unsupported literal")
			mov_ri(x86.RAX, 0)
			push_r(x86.RAX)
		}
	case ^Ast_Bad_Expr, ^Ast_Set_Expr:
		gen_error(e.pos, "backend: unsupported expression")
		mov_ri(x86.RAX, 0)
		push_r(x86.RAX)
	}
}

gen_load_entity :: proc(e: ^Entity, pos: Pos) {
	if e == nil {
		gen_error(pos, "backend: unresolved identifier")
		mov_ri(x86.RAX, 0)
		push_r(x86.RAX)
		return
	}
	#partial switch e.kind {
	case .Const:
		#partial switch cv in e.value {
		case i64:  mov_ri(x86.RAX, cv)
		case bool: mov_ri(x86.RAX, cv ? 1 : 0)
		case:      gen_error(pos, "backend: unsupported constant"); mov_ri(x86.RAX, 0)
		}
		push_r(x86.RAX)
	case .Var:
		load_var_rax(e)
		push_r(x86.RAX)
	case:
		gen_error(pos, "backend: cannot use '%s' as a value", e.name)
		mov_ri(x86.RAX, 0)
		push_r(x86.RAX)
	}
}

gen_binary_internal :: proc(op: Token_Kind, pos: Pos, op_text := "") {
	pop_r(x86.RCX) // rhs
	pop_r(x86.RAX) // lhs
	#partial switch op {
	case .Add:
		emit(x86.inst_r_r(.ADD,  x86.RAX, x86.RCX))
	case .Sub:
		emit(x86.inst_r_r(.SUB,  x86.RAX, x86.RCX))
	case .Mul:
		emit(x86.inst_r_r(.IMUL, x86.RAX, x86.RCX))
	case .Quo:
		emit(x86.inst_none(.CQO))
		emit(x86.inst_r(.IDIV, x86.RCX))
	case .Mod:
		emit(x86.inst_none(.CQO))
		emit(x86.inst_r(.IDIV, x86.RCX))
		emit(x86.inst_r_r(.MOV, x86.RAX, x86.RDX))
	case .And:
		emit(x86.inst_r_r(.AND, x86.RAX, x86.RCX))
	case .Or:
		emit(x86.inst_r_r(.OR,  x86.RAX, x86.RCX))
	case .Xor:
		emit(x86.inst_r_r(.XOR, x86.RAX, x86.RCX))
	case .Equal, .Not_Equal,
	     .Less_Than, .Less_Than_Equal,
	     .Greater_Than, .Greater_Than_Equal:

		m: x86.Mnemonic
		#partial switch op {
		case .Equal:              m = .SETE
		case .Not_Equal:          m = .SETNE
		case .Less_Than:          m = .SETL
		case .Less_Than_Equal:    m = .SETLE
		case .Greater_Than:       m = .SETG
		case .Greater_Than_Equal: m = .SETGE
		case: panic("invalid operand")
		}

		emit(x86.inst_r_r(.CMP, x86.RAX, x86.RCX))
		emit(x86.inst_r(m, x86.AL))
		emit(x86.inst_r_r(.MOVZX, x86.RAX, x86.AL))
	case:
		gen_error(pos, "backend: unsupported operator '%s'", op_text)
	}
	push_r(x86.RAX)
}

gen_binary_real :: proc(op: Token_Kind, pos: Pos, op_text := "") {
	pop_xmm(x86.XMM1) // rhs
	pop_xmm(x86.XMM0) // lhs
	#partial switch op {
	case .Add: emit(x86.inst_r_r(.ADDSD, x86.XMM0, x86.XMM1))
	case .Sub: emit(x86.inst_r_r(.SUBSD, x86.XMM0, x86.XMM1))
	case .Mul: emit(x86.inst_r_r(.MULSD, x86.XMM0, x86.XMM1))
	case .Quo: emit(x86.inst_r_r(.DIVSD, x86.XMM0, x86.XMM1))
	case .Equal, .Not_Equal,
	     .Less_Than, .Less_Than_Equal,
	     .Greater_Than, .Greater_Than_Equal:
		emit(x86.inst_r_r(.UCOMISD, x86.XMM0, x86.XMM1))
		m: x86.Mnemonic
		#partial switch op {
		case .Equal:              m = .SETE
		case .Not_Equal:          m = .SETNE
		case .Less_Than:          m = .SETB
		case .Less_Than_Equal:    m = .SETBE
		case .Greater_Than:       m = .SETA
		case .Greater_Than_Equal: m = .SETAE
		case: panic("invalid operand")
		}
		emit(x86.inst_r(m, x86.AL))
		emit(x86.inst_r_r(.MOVZX, x86.RAX, x86.AL))
		push_r(x86.RAX)
		return
	case:
		gen_error(pos, "backend: unsupported real operator '%s'", op_text)
	}
	push_xmm(x86.XMM0)
}

gen_binary :: proc(v: ^Ast_Binary_Expr) {
	gen_expr(v.lhs)
	gen_expr(v.rhs)
	if is_real(v.lhs.type) || is_real(v.rhs.type) {
		if !(is_real(v.lhs.type) && is_real(v.rhs.type)) {
			gen_error(v.pos, "backend: mixed int/real operands require an explicit conversion")
			pop_r(x86.RCX)
			pop_r(x86.RAX)
			mov_ri(x86.RAX, 0)
			push_r(x86.RAX)
			return
		}
		gen_binary_real(v.op.kind, v.pos, v.op.text)
	} else {
		gen_binary_internal(v.op.kind, v.pos, v.op.text)
	}
}

@(require_results)
gen_type_conv :: proc(v: ^Ast_Expr, target_kind: Type_Kind) -> (ok: bool) {
	defer if !ok {
		gen_error(v.pos, "backend: gen_type_conv failed %v", target_kind)
		mov_ri(x86.RAX, 0)
	}

	gen_expr(v)

	if v.type.kind == target_kind  {
		return true
	}

	switch v.type.kind {
	case .Invalid:
		return false
	case .Nil:
		if target_kind == .Pointer {
			// gen already pushed 0
			return true
		}
	case .Bool, .Char, .Byte:
		#partial switch target_kind {
		case .Bool, .Char, .Byte:
			// do nothing
			return true
		case .Int:
			push_const_int(i64(0xff), v.pos)
			gen_binary_internal(.And, v.pos)
			return true
		case .Real:
			push_const_int(i64(0xff), v.pos)
			gen_binary_internal(.And, v.pos)
			pop_r(x86.RAX)
			emit(x86.inst_r_r(.CVTSI2SD, x86.XMM0, x86.RAX))
			push_xmm(x86.XMM0)
			return true
		}
	case .Int:
		#partial switch target_kind {
		case .Bool, .Char, .Byte:
			push_const_int(i64(0xff), v.pos)
			gen_binary_internal(.And, v.pos)
			return true
		case .Real:
			pop_r(x86.RAX)
			emit(x86.inst_r_r(.CVTSI2SD, x86.XMM0, x86.RAX))
			push_xmm(x86.XMM0)
			return true
		case .Pointer:
			// do nothing as they are the same width
			return true
		}
	case .Real:
		#partial switch target_kind {
		case .Byte:
			pop_xmm(x86.XMM0)
			emit(x86.inst_r_r(.CVTTSD2SI, x86.RAX, x86.XMM0))
			push_r(x86.RAX)
			push_const_int(i64(0xff), v.pos)
			gen_binary_internal(.And, v.pos)
			return true
		case .Int:
			pop_xmm(x86.XMM0)
			emit(x86.inst_r_r(.CVTTSD2SI, x86.RAX, x86.XMM0))
			push_r(x86.RAX)
			return true
		}
	case .Set:
		#partial switch target_kind {
		case .Int:
			// do nothing
			return true
		}
	case .Pointer:
		#partial switch target_kind {
		case .Int, .Proc:
			// do nothing as they are the same width
			return true
		}
	case .Array:
		return false
	case .Record:
		return false
	case .Proc:
		#partial switch target_kind {
		case .Int, .Pointer:
			// do nothing as they are the same width
			return true
		}
	}

	return false
}


gen_call :: proc(v: ^Ast_Call_Expr) {
	ent := callee_entity(v.call)
	if ent == nil {
		gen_error(v.pos, "backend: unknown call target")
		mov_ri(x86.RAX, 0)
		return
	}
	#partial switch ent.kind {
	case .Builtin:
		gen_builtin(ent.builtin_id, v)
	case .Type:
		_ = gen_type_conv(v.parameters[0], ent.type.kind)
	case .Proc:
		n := len(v.parameters)
		if n > 4 {
			gen_error(v.pos, "backend: at most 4 arguments are supported")
			mov_ri(x86.RAX, 0)
			return
		}
		for p in v.parameters {
			gen_expr(p)
		}
		for i := n - 1; i >= 0; i -= 1 {
			pop_r(ARG_REGS[i])
		}
		if id, ok := g.proc_labels[ent]; ok {
			aligned_call_label(id)
	} else {
			gen_error(v.pos, "backend: undefined procedure '%s'", ent.name)
		}
	case:
		gen_error(v.pos, "backend: call target is not a procedure")
		mov_ri(x86.RAX, 0)
	}
}

// Builtins. RValue builtins leave their result in RAX (the caller pushes it);
// No_Value builtins (print/println, inc/dec) leave the stack balanced.
gen_builtin :: proc(id: Builtin_Id, v: ^Ast_Call_Expr) {
	switch id {
	case .print, .println:
		last := len(v.parameters) - 1
		for p, i in v.parameters {
			is_last := id == .println && i == last
			gen_expr(p)
			pop_r(x86.RDX) // 2nd printf arg (MS varargs: also the GPR half)
			addr := g.imp.fmts[.int]
			if is_real(p.type) {
				emit(x86.inst_r_r(.MOVQ, x86.XMM1, x86.RDX)) // varargs: FP half in XMM1
				addr = is_last ? g.imp.fmts[.real_nl] : g.imp.fmts[.real]
			} else if is_string(p.type) {
				addr = is_last ? g.imp.fmts[.str_nl] : g.imp.fmts[.str]
			} else {
				addr = is_last ? g.imp.fmts[.int_nl] : g.imp.fmts[.int]
			}
			mov_ri(x86.RCX, i64(addr))
			mov_ri(x86.RAX, i64(g.imp.funcs[.printf]))
			aligned_call_ptr(x86.RAX)
		}
		if id == .println && len(v.parameters) == 0 {
			mov_ri(x86.RCX, i64(g.imp.fmts[.nl]))
			mov_ri(x86.RAX, i64(g.imp.funcs[.printf]))
			aligned_call_ptr(x86.RAX)
		}
		mov_ri(x86.RAX, 0)

	case .abs:
		// abs(x) = (x < 0) ? -x : x, branchless.
		gen_expr(v.parameters[0])
		pop_r(x86.RAX)
		emit(x86.inst_r_r(.MOV, x86.RCX, x86.RAX))
		emit(x86.inst_r(.NEG, x86.RCX))
		emit(x86.inst_r_r(.TEST, x86.RAX, x86.RAX))
		emit(x86.inst_r_r(.CMOVL, x86.RAX, x86.RCX))

	case .odd:
		gen_expr(v.parameters[0])
		pop_r(x86.RAX)
		emit(x86.inst_r_i(.AND, x86.RAX, 1, 4))

	case .chr:
		// int -> char is an identity in our flat integer model.
		gen_expr(v.parameters[0])
		pop_r(x86.RAX)

	case .lsh, .ash, .ror:
		gen_expr(v.parameters[0]) // x
		gen_expr(v.parameters[1]) // n
		pop_r(x86.RCX)            // n (shift/rotate count, uses CL)
		pop_r(x86.RAX)            // x
		if id != .ror {
			// clamp the shift amount to >= 0, matching the frontend
			emit(x86.inst_r_r(.XOR,   x86.RDX, x86.RDX))
			emit(x86.inst_r_r(.TEST,  x86.RCX, x86.RCX))
			emit(x86.inst_r_r(.CMOVL, x86.RCX, x86.RDX))
		}
		mn: x86.Mnemonic
		#partial switch id {
		case .lsh: mn = .SHL
		case .ash: mn = .SAR
		case .ror: mn = .ROR
		}
		emit(x86.inst_r_r(mn, x86.RAX, x86.CL))

	case .inc, .dec:
		p := v.parameters[0]
		assert(p.type.kind == .Int)
		gen_expr(p)
		if len(v.parameters) > 1 {
			gen_expr(v.parameters[1])
		} else {
			push_const_int(i64(1), p.pos)
		}
		gen_binary_internal(.Add if id == .inc else .Sub, v.pos)
		gen_addr(p)
		pop_r(x86.RAX) // address
		pop_r(x86.RCX) // new value
		store_scalar(p.type)

	case .size_of, .align_of:
		panic("size_of/align_of should have been constant-folded by the frontend")

	case .ord, .len:
		// Always constant-folded by the checker; unreachable in practice.
		gen_error(v.pos, "backend: '%s' should have been constant-folded", builtin_strings[id])
		mov_ri(x86.RAX, 0)

	case .incl, .excl:
		gen_error(v.pos, "backend: set builtins are not supported")
		mov_ri(x86.RAX, 0)
	case .floor, .ceil:
		// double floor/ceil(double): arg and result in XMM0
		gen_expr(v.parameters[0])
		pop_xmm(x86.XMM0)
		mov_ri(x86.RAX, i64(id == .floor ? g.imp.funcs[.floor] : g.imp.funcs[.ceil]))
		aligned_call_ptr(x86.RAX)
		emit(x86.inst_r_r(.MOVQ, x86.RAX, x86.XMM0)) // result bits in RAX (RValue)

	case .addr:
		gen_addr(v.parameters[0])
		pop_r(x86.RAX) // address is the result

	case .new:
		// p: ^T ; p := calloc(1, size_of(T))
		p := v.parameters[0]
		size := i64(8)
		if pt, ok := p.type.variant.(^Type_Pointer); ok {
			size = type_size_of(pt.elem)
		}
		mov_ri(x86.RCX, 1)      // count
		mov_ri(x86.RDX, size)   // element size
		mov_ri(x86.RAX, i64(g.imp.funcs[.calloc]))
		aligned_call_ptr(x86.RAX) // RAX = pointer
		push_r(x86.RAX)
		gen_addr(p)
		pop_r(x86.RCX) // &p
		pop_r(x86.RAX) // pointer
		emit(x86.inst_m_r(.MOV, x86.mem_base_only(x86.RCX), 8, x86.RAX))
		mov_ri(x86.RAX, 0)

	case .delete:
		gen_expr(v.parameters[0])
		pop_r(x86.RCX) // pointer to free
		mov_ri(x86.RAX, i64(g.imp.funcs[.free]))
		aligned_call_ptr(x86.RAX)
		mov_ri(x86.RAX, 0)

	case .copy:
		// memmove(dst, src, n)
		gen_expr(v.parameters[0])
		gen_expr(v.parameters[1])
		gen_expr(v.parameters[2])
		pop_r(x86.R8)  // n
		pop_r(x86.RDX) // src
		pop_r(x86.RCX) // dst
		mov_ri(x86.RAX, i64(g.imp.funcs[.memmove]))
		aligned_call_ptr(x86.RAX)
		mov_ri(x86.RAX, 0)

	case .assert:
		// if not cond then println("assertion failed") end
		// ud2
		gen_expr(v.parameters[0])
		pop_r(x86.RAX)
		emit(x86.inst_r_r(.TEST, x86.RAX, x86.RAX))
		ok_label := fwd_label()
		emit(x86.inst_rel(.JNE, ok_label, 4)) // cond true -> skip
		mov_ri(x86.RCX, i64(g.imp.fmts[.assert]))
		mov_ri(x86.RAX, i64(g.imp.funcs[.printf]))
		aligned_call_ptr(x86.RAX)
		emit(x86.inst_none(.UD2)) // trap
		set_label(ok_label)
		mov_ri(x86.RAX, 0)


	case .pack:
		// x := ldexp(x, n)   (x: var real, n: integer)
		x := v.parameters[0]
		n := v.parameters[1]
		gen_expr(x)
		gen_expr(n)                  // evaluate both before touching volatile regs
		pop_r(x86.RDX)               // RDX/EDX = n (2nd arg slot)
		pop_xmm(x86.XMM0)            // XMM0 = x
		mov_ri(x86.RAX, i64(g.imp.funcs[.ldexp]))
		aligned_call_ptr(x86.RAX)    // XMM0 = x * 2^n
		gen_addr(x)
		pop_r(x86.RCX)               // &x
		emit(x86.inst_r_r(.MOVQ, x86.RAX, x86.XMM0))
		emit(x86.inst_m_r(.MOV, x86.mem_base_only(x86.RCX), 8, x86.RAX))
		mov_ri(x86.RAX, 0)


	case .unpack:
		// frexp gives mantissa in [0.5,1); normalize to [1,2) and adjust exponent
		x := v.parameters[0]
		n := v.parameters[1]
		gen_expr(x)
		pop_xmm(x86.XMM0)            // XMM0 = x
		emit(x86.inst_r_i(.SUB, x86.RSP, 16, 4))     // scratch for int* exp
		emit(x86.inst_r_r(.MOV, x86.RDX, x86.RSP))   // RDX = &exp
		mov_ri(x86.RAX, i64(g.imp.funcs[.frexp]))
		aligned_call_ptr(x86.RAX)   // XMM0 = mantissa; [rsp] = exp (int)
		emit(x86.inst_r_m(.MOVSXD, x86.RCX, x86.mem_base_only(x86.RSP), 4)) // RCX = exp
		emit(x86.inst_r_r(.ADDSD, x86.XMM0, x86.XMM0)) // mantissa *= 2 -> [1,2)
		emit(x86.inst_r_i(.SUB, x86.RCX, 1, 4))        // exp -= 1
		emit(x86.inst_r_i(.ADD, x86.RSP, 16, 4))       // free scratch
		// stash results on the stack so gen_addr (which may emit a call) can't clobber them
		emit(x86.inst_r_r(.MOVQ, x86.RAX, x86.XMM0))   // mantissa bits
		push_r(x86.RAX)            // [mantissa]
		push_r(x86.RCX)            // [mantissa, exp]
		// n := exp
		gen_addr(n)
		pop_r(x86.RAX)             // &n
		pop_r(x86.RCX)             // exp
		emit(x86.inst_m_r(.MOV, x86.mem_base_only(x86.RAX), 8, x86.RCX))
		// x := mantissa
		gen_addr(x)
		pop_r(x86.RCX)             // &x
		pop_r(x86.RAX)             // mantissa bits
		emit(x86.inst_m_r(.MOV, x86.mem_base_only(x86.RCX), 8, x86.RAX))
		mov_ri(x86.RAX, 0)

	case .Invalid:
		fallthrough
	case:
		gen_error(v.pos, "backend: builtin is not supported")
		mov_ri(x86.RAX, 0)
	}
}



gen_branch_if_false :: proc(cond: ^Ast_Expr, target: u32) {
	gen_expr(cond)
	pop_r(x86.RAX)
	emit(x86.inst_r_r(.TEST, x86.RAX, x86.RAX))
	emit(x86.inst_rel(.JE, target, 4))
}

gen_stmts :: proc(seq: ^Ast_Stmt_Sequence) {
	for st in seq.stmts {
		gen_stmt(st)
	}
}

gen_stmt :: proc(s: ^Ast_Stmt) {
	switch v in s.variant {
	case ^Ast_Assign_Stmt:
		if is_aggregate(v.lhs.type) {
			gen_expr(v.rhs)  // src address
			gen_addr(v.lhs)  // dst address
			gen_mem_copy(type_size_of(v.lhs.type))
		} else {
			gen_expr(v.rhs)  // value
			gen_addr(v.lhs)  // dst address
			pop_r(x86.RAX)   // dst
			pop_r(x86.RCX)   // value
			store_scalar(v.lhs.type)
		}
	case ^Ast_Expr_Stmt:
		if call, ok := v.expr.variant.(^Ast_Call_Expr); ok {
			gen_call(call)
		} else {
			gen_expr(v.expr)
			pop_r(x86.RAX)
		}
	case ^Ast_If_Stmt:
		gen_if(v)
	case ^Ast_While_Stmt:
		gen_while(v)
	case ^Ast_Repeat_Stmt:
		gen_repeat(v)
	case ^Ast_For_Stmt:
		gen_for(v)
	case ^Ast_Case_Stmt:
		gen_error(v.pos, "backend: case statements are not supported")
	}
}

gen_if :: proc(v: ^Ast_If_Stmt) {
	end := fwd_label()

	next := fwd_label()
	gen_branch_if_false(v.cond, next)
	gen_stmts(v.body)
	emit(x86.inst_rel(.JMP, end, 4))
	set_label(next)

	for ei in v.elseif_stmts {
		n2 := fwd_label()
		gen_branch_if_false(ei.cond, n2)
		gen_stmts(ei.body)
		emit(x86.inst_rel(.JMP, end, 4))
		set_label(n2)
	}

	if es, ok := v.else_stmt.?; ok {
		gen_stmts(es)
	}
	set_label(end)
}

gen_while :: proc(v: ^Ast_While_Stmt) {
	top := new_label()

	skip := fwd_label()
	gen_branch_if_false(v.cond, skip)
	gen_stmts(v.body)
	emit(x86.inst_rel(.JMP, top, 4))
	set_label(skip)

	for ei in v.elseif_stmts {
		s2 := fwd_label()
		gen_branch_if_false(ei.cond, s2)
		gen_stmts(ei.body)
		emit(x86.inst_rel(.JMP, top, 4))
		set_label(s2)
	}
}

gen_repeat :: proc(v: ^Ast_Repeat_Stmt) {
	top := new_label()
	gen_stmts(v.body)
	gen_expr(v.cond)
	pop_r(x86.RAX)
	emit(x86.inst_r_r(.TEST, x86.RAX, x86.RAX))
	emit(x86.inst_rel(.JE, top, 4)) // loop while condition is false
}

gen_for :: proc(v: ^Ast_For_Stmt) {
	e := v.name.entity
	if e == nil || e.kind != .Var {
		gen_error(v.pos, "backend: invalid for-loop variable")
		return
	}

	gen_expr(v.lo_cond)
	pop_r(x86.RAX)
	store_var_rax(e)

	step := i64(1)
	if bc, ok := v.by_cond.?; ok {
		if sv, ok2 := bc.value.(i64); ok2 {
			step = sv
		} else {
			gen_error(bc.pos, "backend: for-loop 'by' must be a constant integer")
		}
	}

	top := new_label()
	end := fwd_label()

	gen_expr(v.hi_cond) // evaluate the bound first (it may use RAX or emit a call)
	load_var_rax(e)     // then load the loop variable
	pop_r(x86.RCX)      // RCX = hi
	emit(x86.inst_r_r(.CMP, x86.RAX, x86.RCX))
	emit(x86.inst_rel(.JG, end, 4)) // assumes a positive step

	gen_stmts(v.body)

	load_var_rax(e)
	emit(x86.inst_r_i(.ADD, x86.RAX, step, 4))
	store_var_rax(e)
	emit(x86.inst_rel(.JMP, top, 4))
	set_label(end)
}


@(require_results)
assign_globals :: proc(m: ^Module) -> i64 {
	off := i64(0)
	for decl in m.decls {
		if vd, ok := decl.variant.(^Ast_Var_Decl); ok {
			for name in vd.names {
				if name.entity == nil {
					continue
				}
				name.entity.backend_global = true
				name.entity.backend_offset = i32(off)
				off += slot_size(name.entity.type)
			}
		}
	}
	return align_forward_i64(off, 16)
}

@(require_results)
assign_proc_locals :: proc(pd: ^Ast_Proc_Decl) -> i32 {
	off := i32(0)
	if pd.name.entity != nil {
		if pt, ok := pd.name.entity.type.variant.(^Type_Proc); ok {
			for pe in pt.parameters {
				off += 8
				pe.backend_offset = off
				pe.backend_global = false
			}
		}
	}
	for decl in pd.decls {
		if vd, ok := decl.variant.(^Ast_Var_Decl); ok {
			for name in vd.names {
				if name.entity == nil {
					continue
				}
				off += i32(slot_size(name.entity.type))
				name.entity.backend_offset = off
				name.entity.backend_global = false
			}
		}
	}
	return i32(align_forward_i64(i64(off), 16))
}

gen_prologue :: proc(frame: i32) {
	push_r(x86.RBP)
	push_r(x86.RBX)
	emit(x86.inst_r_r(.MOV, x86.RBP, x86.RSP))
	if frame > 0 {
		emit(x86.inst_r_i(.SUB, x86.RSP, i64(frame), 4))
	}
}

gen_epilogue :: proc() {
	emit(x86.inst_r_r(.MOV, x86.RSP, x86.RBP))
	pop_r(x86.RBX)
	pop_r(x86.RBP)
	emit(x86.inst_none(.RET))
}

gen_proc :: proc(pd: ^Ast_Proc_Decl) {
	ent := pd.name.entity
	if ent == nil {
		return
	}
	if id, ok := g.proc_labels[ent]; ok {
		set_label(id)
	}

	frame := assign_proc_locals(pd)
	gen_prologue(frame)

	if pt, ok := ent.type.variant.(^Type_Proc); ok {
		for pe, i in pt.parameters {
			if is_aggregate(pe.type) {
				gen_error(pd.name.pos, "backend: aggregate (record/array) parameters are not supported yet")
			}
			if i >= 4 {
				break
			}
			emit(x86.inst_m_r(.MOV, x86.mem_base_disp(x86.RBP, -pe.backend_offset), 8, ARG_REGS[i]))
		}
	}

	gen_stmts(pd.body)

	if re, ok := pd.return_expr.?; ok {
		if is_aggregate(re.type) {
			gen_error(pd.name.pos, "backend: returning a record/array is not supported yet")
		}
		gen_expr(re)
		pop_r(x86.RAX)
	}

	gen_epilogue()
}

gen_entry :: proc(m: ^Module) {
	gen_prologue(0)
	if entry, ok := m.entry.?; ok {
		gen_stmts(entry)
	}
	mov_ri(x86.RCX, 0)
	mov_ri(x86.RAX, i64(g.imp.funcs[.exit]))
	aligned_call_ptr(x86.RAX)
	emit(x86.inst_none(.RET))
}

// Entry point of the backend: turn a checked module into a Windows exe.
@(require_results)
generate :: proc(m: ^Module, out_filename: string) -> bool {
	gg := Gen{m = m}
	g = &gg
	defer g = nil
	defer delete(gg.code)
	defer delete(gg.labels)
	defer delete(gg.strings)

	region, imp := pe_create_imports()
	g.imp = imp

	globals_size := assign_globals(m)
	g.global_base = u64(IMAGE_BASE + TEXT_BASE + IMPORT_REGION_SIZE)
	g.string_base = g.global_base + u64(globals_size)

	g.proc_labels = make(map[^Entity]u32)
	defer delete(g.proc_labels)
	for decl in m.decls {
		if pd, ok := decl.variant.(^Ast_Proc_Decl); ok {
			if pd.name.entity != nil {
				g.proc_labels[pd.name.entity] = fwd_label()
			}
		}
	}

	gen_entry(m)
	for decl in m.decls {
		if pd, ok := decl.variant.(^Ast_Proc_Decl); ok {
			gen_proc(pd)
		}
	}

	if g.error_count > 0 {
		return false
	}

	strings_size := align_forward_i64(i64(len(g.strings)), 16)
	code_rva := u32(TEXT_BASE + IMPORT_REGION_SIZE + int(globals_size) + int(strings_size))
	code_va  := u64(IMAGE_BASE) + u64(code_rva)

	code_buf := make([]u8, len(g.code) * 16 + 64)
	defer delete(code_buf)
	relocs: [dynamic]x86.Relocation
	defer delete(relocs)
	errs: [dynamic]x86.Error
	defer delete(errs)

	n, ok := x86.encode(g.code[:], g.labels[:], code_buf, &relocs, &errs, true, code_va, ._64)
	if !ok || len(errs) > 0 {
		fmt.eprintfln("backend: instruction encoding failed (%d errors)", len(errs))
		return false
	}
	code := code_buf[:n]

	section: [dynamic]u8
	defer delete(section)
	append(&section, ..region[:])
	for _ in 0..<globals_size {
		append(&section, 0)
	}
	append(&section, ..g.strings[:])
	for _ in 0..<(strings_size - i64(len(g.strings))) {
		append(&section, 0)
	}
	append(&section, ..code)

	image_size := u32(align_forward_i64(i64(TEXT_BASE) + i64(len(section)), SECT_ALIGN))
	pe_write_exe(out_filename, section[:], code_rva, image_size,
	             TEXT_BASE, 40, TEXT_BASE + 64, 16)
	return true
}
