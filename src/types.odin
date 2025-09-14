package titania

import "core:fmt"
import "core:io"
import "core:strings"
import "core:mem/virtual"

Type_Kind :: enum u8 {
	Invalid,

	Bool,
	Char,
	Int,
	Real,
	Byte,

	Set,

	Pointer,
	Array,
	Record,
	Proc,
}

Type :: struct {
	kind:   Type_Kind,
	size:   i64,
	align:  i64,

	variant: union {
		^Type_Pointer,
		^Type_Array,
		^Type_Record,
		^Type_Proc,
	},
}

Type_Pointer :: struct {
	using base: Type,
	elem: ^Type,
}

Type_Array :: struct {
	using base: Type,
	counts: []i64, // 'nil' if a procedure parameter
	elem:   ^Type,
}

Type_Record :: struct {
	using base: Type,
	scope:   ^Scope,
	entity:  ^Entity,
	subtype: ^Type_Record,
	fields:  []Type_Field,
}

Type_Field :: struct {
	entity: ^Entity,
	offset: i64,
}


Type_Proc :: struct {
	using base: Type,
	parameters: []^Entity,
	scope:      ^Scope,
}


t_invalid := &Type{kind = .Invalid, size = 0, align = 1}
t_bool    := &Type{kind = .Bool,    size = 1, align = 1}
t_char    := &Type{kind = .Char,    size = 1, align = 1}
t_int     := &Type{kind = .Int,     size = 8, align = 8}
t_real    := &Type{kind = .Real,    size = 8, align = 8}
t_byte    := &Type{kind = .Byte,    size = 1, align = 1}
t_set     := &Type{kind = .Set,     size = 8, align = 8}


@(require_results)
align_forward_i64 :: proc(x, y: i64) -> i64 {
	assert(y > 0)
	assert(y & (y-1) == 0)
	return x + (y-1) &~ (y-1)
}

type_init_offsets_for_record :: proc(record: ^Type_Record) {
	if record.size == 0 || record.align == 0 {
		max_alignment := i64(1)
		offset := i64(0)
		for &field in record.fields {
			al := type_align_of(field.entity.type)
			max_alignment = max(max_alignment, al)

			offset = align_forward_i64(offset, al)
			field.offset = offset

			sz := type_size_of(field.entity.type)
			offset += sz
		}
		size := align_forward_i64(offset, max_alignment)
		record.size = size
		record.align = max_alignment
	}
}

@(require_results)
type_size_of :: proc(t: ^Type) -> i64 {
	switch t.kind {
	case: fallthrough
	case .Invalid:
		return 0
	case .Bool, .Char, .Int, .Real, .Byte, .Set:
		return t.size
	case .Array:
		array := t.variant.(^Type_Array)
		sz := i64(type_size_of(array.elem))
		for count in array.counts {
			sz *= count
		}
		return i64(sz)
	case .Record:
		record := t.variant.(^Type_Record)

		type_init_offsets_for_record(record)
		return t.size
	case .Proc, .Pointer:
		// pointer size is 8
		return 8
	}
}

@(require_results)
type_align_of :: proc(t: ^Type) -> i64 {
	if record, ok := t.variant.(^Type_Record); ok {
		type_init_offsets_for_record(record)
	}
	assert(t.align > 0)
	return t.align
}

@(require_results)
type_new :: proc(arena: ^virtual.Arena, kind: Type_Kind, $T: typeid) -> ^T {
	t, err := virtual.new(arena, T)
	t.variant = t
	_ = err
	t.kind  = kind
	return t
}

@(require_results)
type_new_string :: proc(arena: ^virtual.Arena, len: int) -> ^Type {
	t := type_new(arena, .Array, Type_Array)
	t.elem = t_char
	t.counts, _ = virtual.make_slice(arena, []i64, 1)
	t.counts[0] = i64(len)
	return t
}

@(require_results)
type_new_pointer :: proc(arena: ^virtual.Arena, elem: ^Type) -> ^Type {
	t := type_new(arena, .Pointer, Type_Pointer)
	t.elem = elem
	return t
}



@(require_results)
types_equal :: proc(x, y: ^Type) -> bool {
	if x == y {
		return true
	}
	if x == nil || y == nil {
		return false
	}
	(x.kind == y.kind) or_return

	#partial switch x.kind {
	case .Pointer:
		a := x.variant.(^Type_Pointer) or_return
		b := y.variant.(^Type_Pointer) or_return
		return types_equal(a.elem, b.elem)

	case .Array:
		a := x.variant.(^Type_Array) or_return
		b := y.variant.(^Type_Array) or_return
		types_equal(a.elem, b.elem) or_return
		(len(a.counts) == len(b.counts)) or_return
		for _, i in a.counts {
			(a.counts[i] == b.counts[i]) or_return
		}
		return true

	case .Record:
		a := x.variant.(^Type_Record) or_return
		b := y.variant.(^Type_Record) or_return
		if a.entity != nil && a.entity == b.entity {
			return true
		}
		if a.entity != nil && b.entity != nil {
			return false
		}
		(len(a.fields) == len(b.fields)) or_return
		for _, i in a.fields {
			ae, be := a.fields[i].entity, b.fields[i].entity
			(ae.name == be.name) or_return
			types_equal(ae.type, be.type) or_return
		}
		return true
	case .Proc:
		panic("TODO(bill)")
		// return false
	}
	return true

}

@(require_results)
type_deref :: proc(x: ^Type) -> ^Type {
	if x.kind == .Pointer {
		return x.variant.(^Type_Pointer).elem
	}
	return x
}

@(require_results)
type_is_numeric :: proc(t: ^Type) -> bool {
	#partial switch t.kind {
	case .Byte, .Char, .Int, .Real:
		return true
	}
	return false
}


@(require_results)
type_is_integer_like :: proc(t: ^Type) -> bool {
	#partial switch t.kind {
	case .Byte, .Char, .Int:
		return true
	}
	return false
}

type_to_string_to_writer :: proc(w: io.Writer, t: ^Type) {
	if t == nil {
		fmt.wprint(w, "<nil>")
	} else {
		switch t.kind {
		case .Invalid:
			fmt.wprint(w, "<invalid>")
		case .Bool:
			fmt.wprint(w, "bool")
		case .Char:
			fmt.wprint(w, "char")
		case .Int:
			fmt.wprint(w, "int")
		case .Real:
			fmt.wprint(w, "real")
		case .Byte:
			fmt.wprint(w, "byte")
		case .Set:
			fmt.wprint(w, "set")
		case .Pointer:
			fmt.wprint(w, "^")
			type_to_string_to_writer(w, t.variant.(^Type_Pointer).elem)
		case .Array:
			fmt.wprint(w, "[")
			fmt.wprint(w, "]")
			type_to_string_to_writer(w, t.variant.(^Type_Array).elem)
		case .Record:
			record := t.variant.(^Type_Record)
			if record.entity != nil {
				fmt.wprint(w, record.entity.name)
				return
			}

			fmt.wprint(w, "record ")
			for field, i in record.fields {
				if i > 0 {
					fmt.wprintf(w, "; ")
				}
				fmt.wprintf(w, "%s: ", field.entity.name)
				type_to_string_to_writer(w, field.entity.type)
			}
			fmt.wprint(w, "end")
		case .Proc:
			fmt.wprint(w, "proc(")
			sig := t.variant.(^Type_Proc)
			for param, i in sig.parameters {
				if i > 0 {
					fmt.wprintf(w, "; ")
				}
				fmt.wprintf(w, "%s: ", param.name)
				type_to_string_to_writer(w, param.type)
			}

			fmt.wprint(w, ")")
		}
	}

}


type_to_string :: proc(t: ^Type, allocator := context.temp_allocator) -> string {
	sb := strings.builder_make(allocator)
	w := strings.to_writer(&sb)

	type_to_string_to_writer(w, t)

	return strings.to_string(sb)

}

