package titania

import "core:fmt"
import "core:rexcode/isa"
import x86 "core:rexcode/isa/x86"

Gen :: struct {
	m:           ^Module,
	code:        [dynamic]x86.Instruction,
	labels:      [dynamic]isa.Label_Definition,
	proc_labels: map[^Entity]u32,

	iat_printf:  u64,
	iat_exit:    u64,
	fmt_int:     u64,
	fmt_int_nl:  u64,
	fmt_nl:      u64,
	global_base: u64,

	error_count: int,
}

g: ^Gen

@(rodata)
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

new_label :: proc() -> u32 {
	return isa.label(&g.labels, &g.code)
}
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

callee_entity :: proc(e: ^Ast_Expr) -> ^Entity {
	#partial switch v in e.variant {
	case ^Ast_Ident:      return v.entity
	case ^Ast_Qual_Ident: return v.entity
	}
	return nil
}

push_const_value :: proc(value: Const_Value, pos: Pos) -> bool {
	#partial switch v in value {
	case i64:
		mov_ri(x86.RAX, v)
		push_r(x86.RAX)
		return true
	case bool:
		mov_ri(x86.RAX, v ? 1 : 0)
		push_r(x86.RAX)
		return true
	case f64:
		gen_error(pos, "backend: real values are not supported")
		mov_ri(x86.RAX, 0)
		push_r(x86.RAX)
		return true
	case string:
		gen_error(pos, "backend: string values are not supported")
		mov_ri(x86.RAX, 0)
		push_r(x86.RAX)
		return true
	}
	return false
}

gen_expr :: proc(e: ^Ast_Expr) {
	if push_const_value(e.value, e.pos) {
		return
	}
	#partial switch v in e.value {
	case i64:
		mov_ri(x86.RAX, v)
		push_r(x86.RAX)
		return
	case bool:
		mov_ri(x86.RAX, v ? 1 : 0)
		push_r(x86.RAX);
		return
	case f64:
		gen_error(e.pos, "backend: real values are not supported")
		mov_ri(x86.RAX, 0)
		push_r(x86.RAX)
		return
	case string:
		gen_error(e.pos, "backend: string values are not supported")
		mov_ri(x86.RAX, 0)
		push_r(x86.RAX)
		return
	}

	switch v in e.variant {
	case ^Ast_Paren_Expr:
		gen_expr(v.expr)
	case ^Ast_Ident:
		gen_load_entity(v.entity, e.pos)
	case ^Ast_Qual_Ident:
		gen_load_entity(v.entity, e.pos)
	case ^Ast_Unary_Expr:
		gen_expr(v.expr)
		if v.op.kind == .Sub {
			pop_r(x86.RAX)
			emit(x86.inst_r(.NEG, x86.RAX))
			push_r(x86.RAX)
		}
	case ^Ast_Binary_Expr:
		gen_binary(v)
	case ^Ast_Call_Expr:
		gen_call(v)
		push_r(x86.RAX)
	case ^Ast_Bad_Expr, ^Ast_Literal, ^Ast_Deref_Expr, ^Ast_Selector_Expr, ^Ast_Set_Expr, ^Ast_Index_Expr:
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
		case:
			gen_error(pos, "backend: unsupported constant")
			mov_ri(x86.RAX, 0)
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

gen_binary_internal :: proc(op: Token, pos: Pos) {
	pop_r(x86.RCX) // rhs
	pop_r(x86.RAX) // lhs
	#partial switch op.kind {
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
		#partial switch op.kind {
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
		gen_error(pos, "backend: unsupported operator '%s'", op.text)
	}
	push_r(x86.RAX)
}


gen_binary :: proc(v: ^Ast_Binary_Expr) {
	gen_expr(v.lhs)
	gen_expr(v.rhs)
	gen_binary_internal(v.op, v.pos)
}

gen_call :: proc(v: ^Ast_Call_Expr) {
	ent := callee_entity(v.call)
	if ent == nil {
		gen_error(v.pos, "backend: unknown call target")
		mov_ri(x86.RAX, 0)
		return
	}
	if ent.kind == .Builtin {
		gen_builtin(ent.builtin_id, v)
		return
	}
	if ent.kind != .Proc {
		gen_error(v.pos, "backend: call target is not a procedure")
		mov_ri(x86.RAX, 0)
		return
	}
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
}

gen_builtin :: proc(id: Builtin_Id, v: ^Ast_Call_Expr) {
	switch id {
	case .print, .println:
		last := len(v.parameters) - 1
		for p, i in v.parameters {
			addr := g.fmt_int
			if id == .println && i == last {
				addr = g.fmt_int_nl
			}

			gen_expr(p)
			pop_r(x86.RDX)
			mov_ri(x86.RCX, i64(addr))
			mov_ri(x86.RAX, i64(g.iat_printf))
			aligned_call_ptr(x86.RAX)
		}
		if id == .println && len(v.parameters) == 0 {
			mov_ri(x86.RCX, i64(g.fmt_nl))
			mov_ri(x86.RAX, i64(g.iat_printf))
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

	case .chr:
		gen_error(v.pos, "backend: builtin 'chr' is not supported")
		mov_ri(x86.RAX, 0)

	case .inc, .dec:
		p := v.parameters[0]
		gen_expr(p)
		if len(v.parameters) > 1 {
			gen_expr(v.parameters[1])
		} else {
			push_const_value(i64(1), p.pos)
		}
		gen_binary_internal({kind = .Add if id == .inc else .Sub}, v.pos)
		gen_store(p)

	case .incl:
		gen_error(v.pos, "backend: builtin 'incl' is not supported")
		mov_ri(x86.RAX, 0)

	case .excl:
		gen_error(v.pos, "backend: builtin 'excl' is not supported")
		mov_ri(x86.RAX, 0)

	case .odd:
		gen_expr(v.parameters[0])
		pop_r(x86.RAX)
		emit(x86.inst_r_i(.AND, x86.RAX, 1, 4))

	case .floor:
		gen_error(v.pos, "backend: builtin 'floor' is not supported")
		mov_ri(x86.RAX, 0)

	case .ceil:
		gen_error(v.pos, "backend: builtin 'ceil' is not supported")
		mov_ri(x86.RAX, 0)

	case .assert:
		gen_error(v.pos, "backend: builtin 'assert' is not supported")
		mov_ri(x86.RAX, 0)

	case .new:
		gen_error(v.pos, "backend: builtin 'new' is not supported")
		mov_ri(x86.RAX, 0)

	case .delete:
		gen_error(v.pos, "backend: builtin 'delete' is not supported")
		mov_ri(x86.RAX, 0)

	case .addr:
		gen_error(v.pos, "backend: builtin 'addr' is not supported")
		mov_ri(x86.RAX, 0)

	case .size_of, .align_of:
		panic("size_of/align_of should have been constant-folded by the frontend")

	case .ord, .len:
		// Always constant-folded by the checker; unreachable in practice.
		gen_error(v.pos, "backend: '%s' should have been constant-folded", builtin_strings[id])
		mov_ri(x86.RAX, 0)


	case .copy:
		gen_error(v.pos, "backend: builtin 'copy' is not supported")
		mov_ri(x86.RAX, 0)

	case .Invalid: fallthrough
	case:
		gen_error(v.pos, "backend: builtin is not supported")
		mov_ri(x86.RAX, 0)
	}
}

gen_store :: proc(lhs: ^Ast_Expr) {
	#partial switch v in lhs.variant {
	case ^Ast_Ident:
		if v.entity == nil || v.entity.kind != .Var {
			gen_error(lhs.pos, "backend: invalid assignment target")
			return
		}
		store_var_rax(v.entity)
	case:
		gen_error(lhs.pos, "backend: unsupported assignment target")
	}
}

gen_branch_if_false :: proc(cond: ^Ast_Expr, target: u32) {
	gen_expr(cond)
	pop_r(x86.RAX)
	emit(x86.inst_r_r(.TEST, x86.RAX, x86.RAX))
	emit(x86.inst_rel(.JE, target, 4))
}

gen_stmts :: proc(seq: ^Ast_Stmt_Sequence) {
	for stmt in seq.stmts {
		gen_stmt(stmt)
	}
}

gen_stmt :: proc(s: ^Ast_Stmt) {
	switch v in s.variant {
	case ^Ast_Assign_Stmt:
		gen_expr(v.rhs)
		pop_r(x86.RAX)
		gen_store(v.lhs)
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

	for ei_stmt in v.elseif_stmts {
		n2 := fwd_label()
		gen_branch_if_false(ei_stmt.cond, n2)
		gen_stmts(ei_stmt.body)
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

	for ei_stmt in v.elseif_stmts {
		s2 := fwd_label()
		gen_branch_if_false(ei_stmt.cond, s2)
		gen_stmts(ei_stmt.body)
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
	if bc, bc_ok := v.by_cond.?; bc_ok {
		if sv, sv_ok := bc.value.(i64); sv_ok {
			step = sv
		} else {
			gen_error(bc.pos, "backend: for-loop 'by' must be a constant integer")
		}
	}

	top := new_label()
	end := fwd_label()

	load_var_rax(e)
	gen_expr(v.hi_cond)
	pop_r(x86.RCX)
	emit(x86.inst_r_r(.CMP, x86.RAX, x86.RCX))
	emit(x86.inst_rel(.JG, end, 4)) // assumes a positive step

	gen_stmts(v.body)

	load_var_rax(e)
	emit(x86.inst_r_i(.ADD, x86.RAX, step, 4))
	store_var_rax(e)
	emit(x86.inst_rel(.JMP, top, 4))
	set_label(end)
}

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
				off += 8
			}
		}
	}
	return align_forward_i64(off, 16)
}

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
				off += 8
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
			if i >= 4 {
				break
			}
			emit(x86.inst_m_r(.MOV, x86.mem_base_disp(x86.RBP, -pe.backend_offset), 8, ARG_REGS[i]))
		}
	}

	gen_stmts(pd.body)

	if re, ok := pd.return_expr.?; ok {
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
	mov_ri(x86.RAX, i64(g.iat_exit))
	aligned_call_ptr(x86.RAX)
	emit(x86.inst_none(.RET))
}

// Entry point of the backend: turn a checked module into a Windows exe.
generate :: proc(m: ^Module, out_filename: string) -> bool {
	gg := Gen{m = m}
	g = &gg
	defer g = nil
	defer delete(gg.code)
	defer delete(gg.labels)

	region, iat_printf, iat_exit, fmt_int, fmt_int_nl, fmt_nl := pe_create_imports()
	g.iat_printf = iat_printf
	g.iat_exit   = iat_exit
	g.fmt_int    = fmt_int
	g.fmt_int_nl = fmt_int_nl
	g.fmt_nl     = fmt_nl

	globals_size := assign_globals(m)
	g.global_base = u64(IMAGE_BASE + TEXT_BASE + IMPORT_REGION_SIZE)
	code_rva := u32(TEXT_BASE + IMPORT_REGION_SIZE + int(globals_size))
	code_va  := u64(IMAGE_BASE) + u64(code_rva)

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

	code_buf := make([]u8, len(g.code) * 16 + 64)
	relocs: [dynamic]x86.Relocation
	errs:   [dynamic]x86.Error
	defer delete(code_buf)
	defer delete(relocs)
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
	append(&section, ..code)

	image_size := u32(align_forward_i64(i64(TEXT_BASE) + i64(len(section)), SECT_ALIGN))
	pe_err := pe_write_exe(out_filename, section[:], code_rva, image_size,
	                       TEXT_BASE, 40, TEXT_BASE + 64, 16)
	return pe_err == nil
}
