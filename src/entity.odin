package titania

Entity_Kind :: enum u32 {
	Invalid,

	Nil,

	Const,
	Type,
	Var,
	Proc,
	Import,
	Builtin,
}

@(rodata)
entity_kind_string := [Entity_Kind]string{
	.Invalid = "invalid",
	.Nil     = "nil",
	.Const   = "const",
	.Type    = "type",
	.Var     = "var",
	.Proc    = "proc",
	.Import  = "import name",
	.Builtin = "builtin proc",
}

Entity_Flags :: distinct bit_set[Entity_Flag; u32]
Entity_Flag :: enum {
	Parameter,
	By_Var,
	Using,
}

Entity :: struct {
	kind:   Entity_Kind,
	flags:  Entity_Flags,
	scope:  ^Scope,
	module: ^Module,

	pos:  Pos,
	name: string,
	type: ^Type,

	decl: ^Ast_Decl,

	import_scope: ^Scope,
	value:  Const_Value,
	builtin_id: Builtin_Id,

	backend_offset: i32,
	backend_global: bool,
}
