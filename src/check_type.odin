package titania

import "core:fmt"
import "core:mem/virtual"

check_type :: proc(c: ^Checker_Context, ast: Ast_Type) -> ^Type {
	return check_type_internal(c, ast, nil)
}
check_type_internal :: proc(c: ^Checker_Context, ast: Ast_Type, decl: ^Ast_Type_Decl) -> ^Type {
	entity: ^Entity

	if decl != nil {
		assert(decl.type == ast)

		name := decl.name.tok.text
		entity = entity_new(c.arena, .Type, name, t_invalid, c.scope)
		entity.decl = decl
	}


	switch dt in ast {
	case ^Ast_Ident:
		scope_insert_entity(c.scope, entity)

		ident := dt.tok.text
		found, ok := scope_lookup(c.scope, ident)
		if !ok {
			error(c, dt.pos, "'%s' has not been declared in scope", ident)
			return t_invalid
		}
		if found.kind != .Type {
			error(c, dt.pos, "'%s' is not a type, got %s", ident, entity_kind_string[found.kind])
			return t_invalid
		}
		if entity != nil {
			entity.type = found.type
		}
		return found.type

	case ^Ast_Qual_Ident:
		lhs := dt.lhs.tok.text
		rhs := dt.rhs.tok.text
		module, module_ok := scope_lookup(c.scope, lhs)
		if !module_ok {
			error(c, dt.pos, "'%s' has not been declared in scope", lhs)
			return t_invalid
		}
		if module.kind != .Import {
			error(c, dt.pos, "'%s' is not an import name, got %s", module.name, entity_kind_string[module.kind])
			return t_invalid
		}
		found, found_ok := scope_lookup(module.scope, rhs)
		if !found_ok {
			error(c, dt.pos, "'%s' does not exist in the module '%s'", rhs, lhs)
			return t_invalid
		}
		if found.kind != .Type {
			error(c, dt.pos, "'%s.%s' is not a type, got %s", lhs, rhs, entity_kind_string[found.kind])
		}

		if entity != nil {
			entity.type = found.type
		}
		scope_insert_entity(c.scope, entity)

		return found.type

	case ^Ast_Structured_Type:
		switch v in dt.variant {
		case ^Ast_Array_Type:
			t := type_new(c.arena, .Array, Type_Array)
			t.elem = check_type(c, v.elem)
			if entity != nil {
				entity.type = t
			}

			if v.counts != nil {
				counts, _ := virtual.make(c.arena, []i64, len(v.counts))
				index := 0
				for expr in v.counts {
					o: Operand
					check_expr(c, &o, expr)
					if o.mode != .Const {
						error(c, expr.pos, "array counts must be constant")
						continue
					}
					cv, ok := o.value.(i64)
					if !ok {
						error(c, expr.pos, "array counts must be constant integers")
						continue
					}
					if  cv < 0 {
						error(c, expr.pos, "array counts must not be negative, got %d", cv)
						continue
					}

					counts[index] = cv
					index += 1
				}
				t.counts = counts[:index]
			} else {
				error(c, v.pos, "array type declaration without any count specified")
			}


			scope_insert_entity(c.scope, entity)

			return t

		case ^Ast_Pointer_Type:
			t := type_new(c.arena, .Pointer, Type_Pointer)
			t.elem = check_type(c, v.elem)

			scope_insert_entity(c.scope, entity)

			return t

		case ^Ast_Record_Type:
			t := type_new(c.arena, .Record, Type_Record)

			t.entity = entity
			if entity != nil {
				entity.type = t
			}
			scope_insert_entity(c.scope, entity)

			t.scope = scope_push(c)
			defer scope_pop(c)

			t.entity = nil
			field_count := 0
			for field in v.fields {
				field_count += len(field.names)
			}

			t.fields, _ = virtual.make(c.arena, []Type_Field, field_count)
			index := 0
			for field in v.fields {
				type := check_type(c, field.type)

				do_using := false
				if field.is_using {
					if type_deref(type).kind != .Record {
						error(c, field.pos, "'using' can only be applied to record or pointer to record types")
						do_using = false
					} else if len(field.names) > 1 {
						error(c, field.pos, "'using' can only be applied to name in a field list, got %d", len(field.names))
						do_using = false
					} else {
						do_using = true
					}
				}

				for f, i in field.names {
					fname := f.tok.text
					if prev, ok := scope_lookup_current(c.scope, fname); ok {
						error(c, f.tok.pos, "'%s' has been previously defined in this record type", fname)
					} else {
						e := entity_new(c.arena, .Var, fname, type, c.scope)
						scope_insert_entity(c.scope, e)
						t.fields[index] = {e, 0}
						index += 1

						if do_using {
							e.flags += {.Using}

							r := type_deref(type).variant.(^Type_Record)
							for _, v in r.scope.elements {
								scope_insert_entity(t.scope, v)
							}
						}
					}
				}


			}
			t.fields = t.fields[:index]

			return t

		case ^Ast_Proc_Type:
			scope_push(c)
			defer scope_pop(c)
			t := check_proc_type(c, v.parameters[:])
			if entity != nil {
				entity.type = t
				entity.scope = c.scope
			}

			return t

		case ^Ast_Enum_Type:
			t := type_new(c.arena, .Enum, Type_Enum)
			t.entity = entity
			if entity != nil {
				entity.type = t
			}
			scope_insert_entity(c.scope, entity)

			field_count := len(v.fields)

			t.fields, _ = virtual.make(c.arena, []^Entity, field_count)
			iota := i64(0)
			for field, i in v.fields {
				value := iota
				if fv, ok := field.value.?; ok {
					o: Operand
					check_expr(c, &o, fv)
					switch {
					case o.mode != .Const:
						error(c, o.expr.pos, "enum field values must be a constant")
					case o.type != t_int:
						error(c, o.expr.pos, "enum field values must be a constant int, got %s", type_to_string(o.type))
					case:
						value = o.value.(i64) or_break
					}
				}

				e := entity_new(c.arena, .Const, field.name.tok.text, t, c.scope)
				e.pos = field.pos
				e.value = value
				field.name.entity = e
				t.fields[i] = e

				scope_insert_entity(c.scope, e)

				iota = value+1
			}
		}
	}
	return t_invalid
}

@(require_results)
check_proc_type :: proc(c: ^Checker_Context, parameters: []^Ast_Formal_Parameter) -> ^Type_Proc {
	t := type_new(c.arena, .Proc, Type_Proc)

	t.scope = c.scope

	parameter_count := 0
	for p in parameters {
		parameter_count += len(p.names)
	}

	t.parameters, _ = virtual.make(c.arena, []^Entity, parameter_count)

	index := 0
	for fp in parameters {
		type := check_type(c, fp.type)
		for name in fp.names {
			e := entity_new(c.arena, .Var, name.tok.text, type, c.scope)
			e.flags += {.Parameter}
			if fp.is_var {
				e.flags += {.By_Var}
			}
			scope_insert_entity(c.scope, e)
			t.parameters[index] = e
			index += 1
		}
	}

	return t
}