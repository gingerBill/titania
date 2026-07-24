package titania

import "core:fmt"
import "core:mem/virtual"

Addressing_Mode :: enum {
	Invalid,
	No_Value,
	Nil,
	RValue,
	LValue,
	Const,
	Type,
	Builtin,
}

@(rodata)
addressing_mode_string := [Addressing_Mode]string {
	.Invalid  = "<invalid>",
	.No_Value = "no value",
	.Nil      = "nil",
	.RValue   = "rvalue",
	.LValue   = "lvalue",
	.Const    = "const",
	.Type     = "type",
	.Builtin  = "builtin",
}

Operand :: struct {
	expr:       ^Ast_Expr,
	type:       ^Type,
	mode:       Addressing_Mode,
	value:      Const_Value,
	builtin_id: Builtin_Id,
}

@(require_results)
operand_is_value :: proc(o: Operand) -> bool {
	#partial switch o.mode {
	case .RValue, .LValue, .Const:
		return true
	}
	return false
}

Checker_Info :: struct {
	arena: virtual.Arena,
	builtin_scope: ^Scope,

	modules: map[string]^Module,
}

Checker_Context :: struct {
	info: ^Checker_Info,

	// current stuff
	arena:  ^virtual.Arena,
	module: ^Module,
	scope:  ^Scope,
	mode:   Addressing_Mode,
	value:  Const_Value,
	curr_proc: ^Entity,
}

Module :: struct {
	arena: virtual.Arena `fmt:"-"`,

	filename: string,

	tok:  Token,
	name: Token,

	imports: [dynamic]^Ast_Import,

	decls: [dynamic]^Ast_Decl,

	entry: Maybe(^Ast_Stmt_Sequence),

	scope: ^Scope,

	info: ^Checker_Info,

	error_count: int,
}

Scope :: struct {
	parent:    ^Scope,
	elements:  map[string]^Entity,
	module:    ^Module,
	procedure: Maybe(^Entity),
}

Const_Value :: union {
	i64,
	f64,
	string,
	bool,
}

@(require_results)
entity_new :: proc(arena: ^virtual.Arena, kind: Entity_Kind, name: string, type: ^Type, scope: ^Scope) -> ^Entity {
	e, err := virtual.new(arena, Entity)
	_ = err
	e.kind  = kind
	e.name  = name
	e.type  = type
	e.scope = scope
	return e
}

@(require_results)
scope_new :: proc(m: ^Module, parent: ^Scope) -> ^Scope {
	s, err := virtual.new(&m.arena, Scope)
	s.module = m
	s.parent = parent
	return s
}

@(require_results)
scope_lookup_current :: proc(s: ^Scope, name: string) -> (e: ^Entity, ok: bool) {
	return s.elements[name]
}

@(require_results)
scope_lookup :: proc(s: ^Scope, name: string) -> (e: ^Entity, ok: bool) {
	s := s
	for s != nil {
		e, ok = scope_lookup_current(s, name)
		if ok {
			return
		}
		s = s.parent
	}
	return
}

scope_push :: proc(c: ^Checker_Context) -> ^Scope {
	c.scope = scope_new(c.module, c.scope)
	return c.scope
}
scope_pop :: proc(c: ^Checker_Context) -> ^Scope {
	s := c.scope
	c.scope = s.parent
	return s
}

scope_insert_entity :: proc(s: ^Scope, e: ^Entity) -> bool {
	if e == nil {
		return true
	}

	assert(e.name  != "")
	assert(e.scope != nil)
	if e.name in s.elements {
		if e.module != nil {
			error(e.module, e.pos, "'%s' has already been defined in this scope", e.name)
		}
		return false
	}
	s.elements[e.name] = e
	return true
}

checker_info_init :: proc(info: ^Checker_Info) {
	info.builtin_scope, _ = virtual.new(&info.arena, Scope)
	s := info.builtin_scope

	scope_insert_entity(s, entity_new(&info.arena, .Type, "invalid", t_invalid, s))
	scope_insert_entity(s, entity_new(&info.arena, .Type, "bool",    t_bool,    s))
	scope_insert_entity(s, entity_new(&info.arena, .Type, "char",    t_char,    s))
	scope_insert_entity(s, entity_new(&info.arena, .Type, "int",     t_int,     s))
	scope_insert_entity(s, entity_new(&info.arena, .Type, "real",    t_real,    s))
	scope_insert_entity(s, entity_new(&info.arena, .Type, "byte",    t_byte,    s))
	scope_insert_entity(s, entity_new(&info.arena, .Type, "set",     t_set,     s))

	for name, id in builtin_strings {
		(name != "") or_continue

		e := entity_new(&info.arena, .Builtin, name, t_invalid, s)
		e.builtin_id = id
		scope_insert_entity(s, e)
	}
}

check_module :: proc(info: ^Checker_Info, m: ^Module) {
	m.info = info
	m.scope = scope_new(m, info.builtin_scope)

	c := &Checker_Context{}
	c.module = m
	c.scope = m.scope
	c.arena = &info.arena

	if m.name.text not_in info.modules {
		info.modules[m.name.text] = m
	} else {
		error(c, m.name.pos, "module '%s' already exists", m.name.text)
	}

	for imp in m.imports {
		name := imp.module.tok.text
		optional_name := name
		if new_name, ok := imp.optional_name.?; ok {
			optional_name = new_name.tok.text
		}

		if name == "builtin" {
			e := entity_new(&info.arena, .Import, optional_name, t_invalid, c.scope)
			e.import_scope = info.builtin_scope
			scope_insert_entity(c.scope, e)
		} else if found, ok := info.modules[name]; ok {
			e := entity_new(&info.arena, .Import, optional_name, t_invalid, c.scope)
			e.import_scope = found.scope
			scope_insert_entity(c.scope, e)
		} else {
			error(c, imp.module.tok.pos, "module '%s' could not be found", name)
		}
	}

	for decl in m.decls {
		check_decl(c, decl)
	}

	if entry, ok := m.entry.?; ok {
		check_stmt_sequence(c, entry)
	}
}



type_assert2 :: proc(lhs, rhs: $V, $T: typeid) -> (T, T, bool) {
	x, x_ok := lhs.(T)
	y, y_ok := rhs.(T)
	return x, y, x_ok & y_ok
}