package titania

@(require) import "base:intrinsics"

import "core:mem"
import "core:mem/virtual"

@(require_results)
ast_new :: proc(m: ^Module, pos: Pos, $T: typeid) -> ^T {
	ptr, err := virtual.new(&m.arena, T)
	_ = err
	ptr.pos = pos
	when intrinsics.type_has_field(T, "variant") {
		ptr.variant = ptr
	}
	return ptr
}

@(require_results)
ast_allocator :: proc(m: ^Module) -> mem.Allocator {
	return virtual.arena_allocator(&m.arena)
}

@(require_results)
module_clone_string :: proc(m: ^Module, s: string) -> string {
	v, _ := virtual.make_slice(&m.arena, []byte, len(s))
	copy(v, s)
	return string(s)
}

Ast_Import :: struct {
	pos: Pos,
	tok: Token, // "import"
	optional_name: Maybe(^Ast_Ident),
	module:        ^Ast_Ident,
}


Ast_Decl :: struct {
	pos: Pos,
	variant: union #shared_nil {
		^Ast_Const_Decl,
		^Ast_Type_Decl,
		^Ast_Var_Decl,
		^Ast_Proc_Decl,
	},
}

Ast_Const_Decl :: struct {
	using base: Ast_Decl,
	tok: Token, // "const"
	name: ^Ast_Ident,
	expr: ^Ast_Expr,
}
Ast_Type_Decl :: struct {
	using base: Ast_Decl,
	tok: Token, // "type"
	name: ^Ast_Ident,
	type: Ast_Type,
}
Ast_Var_Decl :: struct {
	using base: Ast_Decl,
	tok: Token, // "var"
	names: [dynamic]^Ast_Ident,
	type: Ast_Type,
}
Ast_Proc_Decl :: struct {
	using base: Ast_Decl,
	tok:        Token, // "proc"
	name:       ^Ast_Ident,
	parameters: [dynamic]^Ast_Formal_Parameter,

	decls: [dynamic]^Ast_Decl,
	body:  ^Ast_Stmt_Sequence,

	return_expr: Maybe(^Ast_Expr),
}

Ast_Formal_Parameter :: struct {
	pos: Pos,
	is_var: bool,
	names:  [dynamic]^Ast_Ident,
	type:   Ast_Type,
}


Ast_Stmt_Sequence :: struct {
	pos: Pos,
	stmts: [dynamic]^Ast_Stmt
}

Ast_Stmt :: struct {
	pos: Pos,
	variant: union #shared_nil {
		^Ast_If_Stmt,
		^Ast_Switch_Stmt,
		^Ast_While_Stmt,
		^Ast_Repeat_Stmt,
		^Ast_For_Stmt,
		^Ast_Expr_Stmt,
		^Ast_Assign_Stmt,
		^Ast_Return_Stmt,
	},
}

Ast_If_Stmt :: struct {
	using base: Ast_Stmt,
	tok_if:       Token, // "if" or "elseif"
	cond:         ^Ast_Expr,
	tok_then:     Token, // "then"
	body:         ^Ast_Stmt_Sequence,
	elseif_stmts: [dynamic]^Ast_If_Stmt,
	else_stmt:    Maybe(^Ast_Stmt_Sequence)
}

Ast_Switch_Stmt :: struct {
	using base: Ast_Stmt,
	tok_switch: Token, // "switch"
	cond:       ^Ast_Expr,
	tok_then:   Token, // "then"

	cases: [dynamic]^Ast_Case,
}

Ast_Case :: struct {
	pos: Pos,
	tok_case:  Token, // "case"
	labels:    [dynamic]^Ast_Label_Range,
	tok_colon: Token, // ":"
	body:      ^Ast_Stmt_Sequence,
}

Ast_Label_Range :: struct {
	pos: Pos,
	lo: ^Ast_Expr,
	hi: Maybe(^Ast_Expr),
}


Ast_While_Stmt :: struct {
	using base: Ast_Stmt,
	tok_while:    Token, // "while"
	cond:         ^Ast_Expr,
	tok_do:       Token, // "do"
	body:         ^Ast_Stmt_Sequence,
	elseif_stmts: [dynamic]^Ast_While_Elseif_Stmt,
}

Ast_While_Elseif_Stmt :: struct {
	pos: Pos,
	tok:  Token,
	cond: ^Ast_Expr,
	body: ^Ast_Stmt_Sequence,
}


Ast_Repeat_Stmt :: struct {
	using base: Ast_Stmt,
	tok_repeat: Token, // "repeat"
	body:       ^Ast_Stmt_Sequence,
	tok_until:  Token, // "until"
	cond:       ^Ast_Expr,
}

Ast_For_Stmt :: struct {
	using base: Ast_Stmt,
	tok_for: Token, // "for"
	name:    ^Ast_Ident,
	assign:  Token, // ":="
	lo_cond: ^Ast_Expr,
	tok_to:  Token, // "to"
	hi_cond: ^Ast_Expr,
	tok_by:  Token, // "by"
	by_cond: Maybe(^Ast_Expr),
	tok_do:  Token, // "do"
	body:    ^Ast_Stmt_Sequence,
}

Ast_Expr_Stmt :: struct {
	using base: Ast_Stmt,
	expr: ^Ast_Expr,
}

Ast_Assign_Stmt :: struct {
	using base: Ast_Stmt,
	lhs: ^Ast_Expr,
	tok: Token, // ":="
	rhs: ^Ast_Expr,
}

Ast_Return_Stmt :: struct {
	using base: Ast_Stmt,
	tok: Token, // "return"
}



Ast_Expr :: struct {
	pos: Pos,

	value: Const_Value,
	type:  ^Type,

	variant: union #shared_nil {
		^Ast_Bad_Expr,
		^Ast_Ident,
		^Ast_Literal,
		^Ast_Qual_Ident,
		^Ast_Unary_Expr,
		^Ast_Binary_Expr,
		^Ast_Deref_Expr,
		^Ast_Selector_Expr,
		^Ast_Paren_Expr,
		^Ast_Set_Expr,
		^Ast_Index_Expr,
		^Ast_Call_Expr,
	},
}

Ast_Bad_Expr :: struct {
	using base: Ast_Expr,
	tok: Token,
}

Ast_Ident_Or_Qual_Ident :: union #shared_nil {
	^Ast_Ident,
	^Ast_Qual_Ident,
}

Ast_Ident :: struct {
	using base: Ast_Expr,
	tok:    Token,
	entity: ^Entity,
}

Ast_Literal :: struct {
	using base: Ast_Expr,
	tok: Token,
}

Ast_Qual_Ident :: struct {
	using base: Ast_Expr,
	lhs: ^Ast_Ident,
	rhs: ^Ast_Ident,
	entity: ^Entity,
}

Ast_Unary_Expr :: struct {
	using base: Ast_Expr,
	op:   Token,
	expr: ^Ast_Expr,
}

Ast_Binary_Expr :: struct {
	using base: Ast_Expr,
	lhs: ^Ast_Expr,
	op:  Token,
	rhs: ^Ast_Expr,
}

Ast_Deref_Expr :: struct {
	using base: Ast_Expr,
	expr: ^Ast_Expr,
	tok:  Token, // "^"
}

Ast_Selector_Expr :: struct {
	using base: Ast_Expr,
	lhs: ^Ast_Expr,
	tok: Token, // "."
	rhs: ^Ast_Ident,
}

Ast_Index_Expr :: struct {
	using base: Ast_Expr,
	expr: ^Ast_Expr,
	indices: [dynamic]^Ast_Expr,
}


Ast_Call_Expr :: struct {
	using base: Ast_Expr,
	call: ^Ast_Expr,
	parameters: [dynamic]^Ast_Expr,
}

Ast_Paren_Expr :: struct {
	using base: Ast_Expr,
	open: Token, // "("
	expr: ^Ast_Expr,
	close: Token, // ")"
}

Ast_Set_Expr :: struct {
	using base: Ast_Expr,
	open:     Token, // "{"
	elements: [dynamic]^Ast_Element,
	close:    Token, // "}"
}

Ast_Element :: struct {
	pos: Pos,
	lhs: ^Ast_Expr,
	rhs: Maybe(^Ast_Expr),
}


Ast_Type :: union #shared_nil {
	^Ast_Ident,
	^Ast_Qual_Ident,
	^Ast_Structured_Type,
}

Ast_Structured_Type :: struct {
	pos: Pos,
	variant: union #shared_nil {
		^Ast_Array_Type,
		^Ast_Pointer_Type,
		^Ast_Record_Type,
		^Ast_Proc_Type,
		^Ast_Enum_Type,
	},
}

Ast_Array_Type :: struct {
	using type_base: Ast_Structured_Type,
	counts: [dynamic]^Ast_Expr, // 'nil' when passed to procedures
	elem:   Ast_Type,
}

Ast_Pointer_Type :: struct {
	using type_base: Ast_Structured_Type,
	elem: Ast_Type,
}

Ast_Record_Type :: struct {
	using type_base: Ast_Structured_Type,
	tok: Token, // "record"

	fields: [dynamic]^Ast_Field_List,
}

Ast_Field_List :: struct {
	pos: Pos,
	is_using: bool,
	names: [dynamic]^Ast_Ident,
	type:  Ast_Type,
}



Ast_Proc_Type :: struct {
	using type_base: Ast_Structured_Type,
	tok:        Token, // "proc"
	parameters: [dynamic]^Ast_Formal_Parameter,
}

Ast_Enum_Field :: struct {
	pos:   Pos,
	name:  ^Ast_Ident,
	value: Maybe(^Ast_Expr),
}

Ast_Enum_Type :: struct {
	using type_base: Ast_Structured_Type,
	tok:    Token, // "enum"
	fields: [dynamic]^Ast_Enum_Field,
}
