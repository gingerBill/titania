package titania

import "core:os"
import "core:fmt"

Parser :: struct {
	tok: Tokenizer,

	file_data: []byte,

	prev_token: Token,
	curr_token: Token,

	module: ^Module,
}

parser_init :: proc(p: ^Parser, filename: string) -> bool {
	p^ = {}

	data, err := os.read_entire_file(filename, context.allocator)
	if err != nil {
		fmt.println("Failed to read file: ", filename, "with error", err)
		return false
	}

	p.file_data = data
	tokenizer_init(&p.tok, filename, string(data))

	advance_token(p)

	return true
}

parser_fini :: proc(p: ^Parser) {
	delete(p.file_data)
}

advance_token :: proc(p: ^Parser) -> Token {
	p.prev_token = p.curr_token
	p.curr_token = get_token(&p.tok)
	return p.prev_token
}

@(require_results)
allow_token :: proc(p: ^Parser, kind: Token_Kind) -> bool {
	if p.curr_token.kind == kind {
		advance_token(p)
		return true
	}
	return false
}

@(require_results)
peek_token :: proc(p: ^Parser, kind: Token_Kind) -> bool {
	if p.curr_token.kind == kind {
		return true
	}
	return false
}

expect_token :: proc(p: ^Parser, kind: Token_Kind) -> (Token, bool) #optional_ok {
	prev := p.curr_token
	advance_token(p)
	if prev.kind == kind {
		return prev, true
	}
	if prev.kind == .Semicolon && prev.text == "\n" {
		syntax_error(&p.tok, prev.pos, "expected %s, got newline", token_kind_string[kind])
	} else {
		syntax_error(&p.tok, prev.pos, "expected %s, got %s", token_kind_string[kind], token_kind_string[prev.kind])
	}
	return prev, false
}

parse :: proc(p: ^Parser, module: ^Module) -> bool {
	return parse_module(p, module)
}

// module = "module" ident ";" [import_list] decl_sequence
//          ["begin" stmt_sequence] "end" [";"]
parse_module :: proc(p: ^Parser, module: ^Module) -> bool {
	p.module = module

	module.filename = module_clone_string(module, p.tok.filename)

	module.tok  = expect_token(p, .Module) or_return
	module.name = expect_token(p, .Ident)  or_return

	module.imports.allocator = ast_allocator(p.module)
	module.decls.allocator   = ast_allocator(p.module)

	expect_token(p, .Semicolon)  or_return

	if peek_token(p, .Import) {
		module.imports = parse_import_list(p)
	}

	module.decls = parse_decl_sequence(p)

	if allow_token(p, .Begin) {
		module.entry = parse_stmt_sequence(p)
	}
	expect_token(p, .End) or_return
	_ = allow_token(p, .Semicolon)
	if p.curr_token.kind != .EOF {
		syntax_error(&p.tok, p.curr_token.pos, "unexpected token after module's 'end', got %s", p.curr_token.text)
	}

	return true
}

// import_list = "import" import_decl {"," import_decl} ";"
parse_import_list :: proc(p: ^Parser) -> (list: [dynamic]^Ast_Import) {
	list.allocator = ast_allocator(p.module)
	tok, _ := expect_token(p, .Import)
	lhs := parse_import_decl(p, tok)
	append(&list, lhs)
	for allow_token(p, .Comma) {
		rhs := parse_import_decl(p, tok)
		append(&list, rhs)
	}
	expect_token(p, .Semicolon)
	return list
}

parse_ident :: proc(p: ^Parser) -> ^Ast_Ident {
	tok, _ := expect_token(p, .Ident)
	ident := ast_new(p.module, tok.pos, Ast_Ident)
	ident.tok = tok
	return ident
}

// import_decl = ident [":=" ident]
parse_import_decl :: proc(p: ^Parser, tok: Token) -> ^Ast_Import {
	imp := ast_new(p.module, tok.pos, Ast_Import)
	imp.tok = tok
	name_or_module := parse_ident(p)
	if allow_token(p, .Assign) {
		module := parse_ident(p)

		imp.optional_name = name_or_module
		imp.module = module
	} else {
		imp.module = name_or_module
	}

	return imp
}

// decl_sequence = {["const" {const_decl ";"}]
//                  ["type"  {type_decl  ";"}]
//                  ["var"   {var_decl   ";"}]
//                  [proc_decl           ";"]}
parse_decl_sequence :: proc(p: ^Parser) -> (decls: [dynamic]^Ast_Decl) {
	decls.allocator = ast_allocator(p.module)

	for {
		any_decl := false
		switch {
		case peek_token(p, .Const):
			any_decl = true
			tok := expect_token(p, .Const)
			for peek_token(p, .Ident) {
				any_decl = true
				append(&decls, parse_const_decl(p, tok))
				expect_token(p, .Semicolon)
			}
		case peek_token(p, .Type):
			any_decl = true
			tok := expect_token(p, .Type)
			for peek_token(p, .Ident) {
				any_decl = true
				append(&decls, parse_type_decl(p, tok))
				expect_token(p, .Semicolon)
			}
		case peek_token(p, .Var):
			any_decl = true
			tok := expect_token(p, .Var)
			for peek_token(p, .Ident) {
				any_decl = true
				append(&decls, parse_var_decl(p, tok))
				expect_token(p, .Semicolon)
			}
		case peek_token(p, .Proc):
			any_decl = true
			append(&decls, parse_proc_decl(p))
			expect_token(p, .Semicolon)
		case:
			return
		}
	}

	return
}

// const_decl = ident "=" const_expr
parse_const_decl :: proc(p: ^Parser, tok: Token) -> ^Ast_Const_Decl {
	decl := ast_new(p.module, tok.pos, Ast_Const_Decl)
	decl.tok = tok
	decl.name = parse_ident(p)
	expect_token(p, .Equal)
	decl.expr = parse_const_expr(p)
	return decl
}
// type_decl = ident ":" struct_type
parse_type_decl :: proc(p: ^Parser, tok: Token) -> ^Ast_Type_Decl {
	decl := ast_new(p.module, tok.pos, Ast_Type_Decl)
	decl.tok = tok
	decl.name = parse_ident(p)
	expect_token(p, .Colon)
	decl.type = parse_struct_type(p)
	return decl
}
// var_decl = ident_list ":" type
parse_var_decl :: proc(p: ^Parser, tok: Token) -> ^Ast_Var_Decl {
	decl := ast_new(p.module, tok.pos, Ast_Var_Decl)
	decl.tok = tok
	decl.names = parse_ident_list(p)
	expect_token(p, .Colon)
	decl.type = parse_type(p)
	return decl
}
// proc_decl = "proc" ident formal_parameters ";" proc_body
parse_proc_decl :: proc(p: ^Parser) -> ^Ast_Proc_Decl {
	decl := ast_new(p.module, p.curr_token.pos, Ast_Proc_Decl)

	decl.tok = expect_token(p, .Proc)
	decl.name = parse_ident(p)
	decl.parameters = parse_formal_parameters(p)

	expect_token(p, .Semicolon)

	// proc_body = decl_sequence ["begin" stmt_sequence] "end"
	decl.decls = parse_decl_sequence(p)
	if allow_token(p, .Begin) {
		decl.body = parse_stmt_sequence(p)
	}
	expect_token(p, .End)

	return decl
}



// const_expr = expr
parse_const_expr :: proc(p: ^Parser) -> ^Ast_Expr {
	return parse_expr(p)
}

// expr = simple_expr {relation simple_expr}
parse_expr :: proc(p: ^Parser) -> ^Ast_Expr {
	lhs := parse_simple_expr(p)
	if is_relation(p.curr_token.kind) {
		op := advance_token(p)

		bin := ast_new(p.module, op.pos, Ast_Binary_Expr)

		rhs := parse_simple_expr(p)

		bin.lhs = lhs
		bin.op = op
		bin.rhs = rhs
		return bin
	}
	return lhs
}

is_relation :: proc(kind: Token_Kind) -> bool {
	#partial switch kind {
	case .Equal, .Not_Equal,
	     .Less_Than, .Less_Than_Equal, .Greater_Than, .Greater_Than_Equal,
	     .In, .Is:
		return true
	}
	return false
}

// simple_expr = ["+" | "-"] unary_expr {add_operator unary_expr}
parse_simple_expr :: proc(p: ^Parser) -> ^Ast_Expr {
	if peek_token(p, .Add) || peek_token(p, .Sub) {
		return parse_unary_expr(p)
	}
	lhs := parse_unary_expr(p)
	for is_add_operator(p.curr_token.kind) {
		op := advance_token(p)
		rhs := parse_unary_expr(p)

		bin := ast_new(p.module, op.pos, Ast_Binary_Expr)
		bin.lhs = lhs
		bin.op  = op
		bin.rhs = rhs
		lhs = bin
	}

	return lhs
}

// unary_expr = ["+" | "-"] term
parse_unary_expr :: proc(p: ^Parser) -> ^Ast_Expr {
	if peek_token(p, .Add) || peek_token(p, .Sub) {
		expr := ast_new(p.module, p.curr_token.pos, Ast_Unary_Expr)
		expr.op = advance_token(p)
		expr.expr = parse_term(p)
		return expr
	}
	return parse_term(p)
}


// term = factor {mul_operator factor}
parse_term :: proc(p: ^Parser) -> ^Ast_Expr {
	lhs := parse_factor(p)
	for is_mul_operator(p.curr_token.kind) {
		op := advance_token(p)
		rhs := parse_factor(p)

		bin := ast_new(p.module, op.pos, Ast_Binary_Expr)
		bin.lhs = lhs
		bin.op  = op
		bin.rhs = rhs
		lhs = bin
	}

	return lhs
}

// factor = integer | real | string | nil | true | false | set |
//          "(" expr ")" | "not" expr | designator
parse_factor :: proc(p: ^Parser) -> ^Ast_Expr {
	#partial switch p.curr_token.kind {
	case .Integer, .Real, .String, .Nil, .True, .False:
		lit := ast_new(p.module, p.curr_token.pos, Ast_Literal)
		lit.tok = advance_token(p)
		return lit
	case .Brace_Open: // set = "{" [element {"," element} [","]} "}"
		set := ast_new(p.module, p.curr_token.pos, Ast_Set_Expr)
		set.elements.allocator = ast_allocator(p.module)


		set.open = expect_token(p, .Brace_Open)
		for !peek_token(p, .Bracket_Close) &&
		    !peek_token(p, .End) &&
		    !peek_token(p, .EOF) {
			element := parse_element(p)
			append(&set.elements, element)
			if !allow_token(p, .Comma) {
				break
			}
		}
		set.close = expect_token(p, .Brace_Close)
		return set

	case .Paren_Open:
		paren := ast_new(p.module, p.curr_token.pos, Ast_Paren_Expr)
		paren.open  = expect_token(p, .Paren_Open)
		paren.expr  = parse_expr(p)
		paren.close = expect_token(p, .Paren_Close)
		return paren
	case .Not:
		unary := ast_new(p.module, p.curr_token.pos, Ast_Unary_Expr)
		unary.op = expect_token(p, .Not)
		unary.expr = parse_factor(p)
		return unary
	}
	return parse_designator(p)
}

// element = expr [".." expr]
parse_element :: proc(p: ^Parser) -> ^Ast_Element {
	element := ast_new(p.module, p.curr_token.pos, Ast_Element)
	element.lhs = parse_expr(p)
	if allow_token(p, .Ellipsis) {
		element.rhs = parse_expr(p)
	}
	return element
}

is_add_operator :: proc(kind: Token_Kind) -> bool {
	#partial switch kind {
	case .Add, .Sub, .Xor, .Or:
		return true
	}
	return false
}

is_mul_operator :: proc(kind: Token_Kind) -> bool {
	#partial switch kind {
	case .Mul, .Quo, .Mod, .And:
		return true
	}
	return false
}


// ident_list = ident {"," ident}
parse_ident_list :: proc(p: ^Parser) -> (list: [dynamic]^Ast_Ident) {
	list.allocator = ast_allocator(p.module)
	append(&list, parse_ident(p))
	for allow_token(p, .Comma) {
		append(&list, parse_ident(p))
	}
	return
}

// type = qual_ident | struct_type
parse_type :: proc(p: ^Parser) -> Ast_Type {
	if peek_token(p, .Ident) {
		return parse_qual_ident_as_type(p)
	}
	return parse_struct_type(p)
}

// qual_ident = [ident "."] ident
@(require_results)
parse_qual_ident :: proc(p: ^Parser) -> Ast_Ident_Or_Qual_Ident {
	lhs := parse_ident(p)
	if allow_token(p, .Dot) {
		dot := p.prev_token
		rhs := parse_ident(p)
		qual := ast_new(p.module, dot.pos, Ast_Qual_Ident)
		qual.lhs = lhs
		qual.rhs = rhs
		return qual
	}
	return lhs
}

@(require_results)
parse_qual_ident_as_type :: proc(p: ^Parser) -> Ast_Type {
	q := parse_qual_ident(p)
	switch v in q {
	case ^Ast_Ident:
		return v
	case ^Ast_Qual_Ident:
		return v
	}
	return nil
}

@(require_results)
parse_qual_ident_as_expr :: proc(p: ^Parser) -> ^Ast_Expr {
	q := parse_qual_ident(p)
	switch v in q {
	case ^Ast_Ident:
		return v
	case ^Ast_Qual_Ident:
		return v
	}
	return nil
}



// struct_type = array_type | slice_type | record_type | pointer_type | proc_type | enum_type
parse_struct_type :: proc(p: ^Parser) -> ^Ast_Structured_Type {
	switch {
	case allow_token(p, .Bracket_Open):
		// array_type = "["" const_expr "]" type
		// slice_type = "["" "]" type
		curr_pos := p.curr_token.pos
		if !peek_token(p, .Bracket_Close) {
			array := ast_new(p.module, curr_pos, Ast_Array_Type)
			count := parse_const_expr(p)
			expect_token(p, .Bracket_Close)
			elem := parse_type(p)
			array.elem = elem
			array.count = count
			return array
		} else {
			slice := ast_new(p.module, curr_pos, Ast_Slice_Type)
			expect_token(p, .Bracket_Close)
			elem := parse_type(p)
			slice.elem = elem
			return slice
		}
	case peek_token(p, .Record):
		// record_type = "record" [field_list_sequence] "end"
		type := ast_new(p.module, p.curr_token.pos, Ast_Record_Type)
		type.tok = expect_token(p, .Record)

		if !peek_token(p, .End) {
			type.fields = parse_field_list_sequence(p)
		}
		expect_token(p, .End)

		return type
	case allow_token(p, .Caret):
		// pointer_type = "^" type
		ptr := ast_new(p.module, p.curr_token.pos, Ast_Pointer_Type)
		ptr.elem = parse_type(p)
		return ptr
	case allow_token(p, .Proc):
		// proc_type = "proc" formal_parameters
		sig := ast_new(p.module, p.curr_token.pos, Ast_Proc_Type)
		sig.parameters = parse_formal_parameters(p)
		return sig
	case peek_token(p, .Enum):
		// enum_type = "enum" [enum_field_sequence] "end"
		type := ast_new(p.module, p.curr_token.pos, Ast_Enum_Type)
		type.tok = expect_token(p, .Enum)

		if !peek_token(p, .End) {
			type.fields = parse_enum_field_sequence(p)
		}
		expect_token(p, .End)

		return type
	}

	return nil
}

// field_list_sequence = field_list {";" field_list} ";"
parse_field_list_sequence :: proc(p: ^Parser) -> (list: [dynamic]^Ast_Field_List) {
	list.allocator = ast_allocator(p.module)
	for {
		#partial switch p.curr_token.kind {
		case .End, .EOF:
			return
		}
		fields := parse_field_list(p)
		append(&list, fields)
		if !allow_token(p, .Semicolon) {
			break
		}
	}
	return
}

// field_list = ["using"] ident_list ":" type
parse_field_list :: proc(p: ^Parser) -> ^Ast_Field_List {
	fields := ast_new(p.module, p.curr_token.pos, Ast_Field_List)
	if allow_token(p, .Using) {
		fields.is_using = true
	}
	fields.names = parse_ident_list(p)
	expect_token(p, .Colon)
	fields.type = parse_type(p)
	return fields
}


// enum_field_sequence = enum_field {";" enum_field} ";"
parse_enum_field_sequence :: proc(p: ^Parser) -> (list: [dynamic]^Ast_Enum_Field) {
	list.allocator = ast_allocator(p.module)
	for {
		#partial switch p.curr_token.kind {
		case .End, .EOF:
			return
		}
		// enum_field = ident ["=" const_expr]
		field := ast_new(p.module, p.curr_token.pos, Ast_Enum_Field)
		field.name = parse_ident(p)
		if allow_token(p, .Equal) {
			field.value = parse_const_expr(p)
		}
		append(&list, field)
		if !allow_token(p, .Semicolon) {
			break
		}
	}
	return
}



// formal_parmeters = "(" [fp_section {";" fp_section}] [";"] ")"
parse_formal_parameters :: proc(p: ^Parser) -> (parameters: [dynamic]^Ast_Formal_Parameter) {
	parameters.allocator = ast_allocator(p.module)

	expect_token(p, .Paren_Open)

	for !peek_token(p, .Paren_Close) && !peek_token(p, .EOF) {
		// fp_section {["var"] ident {"," ident} ":" formal_type}

		param := ast_new(p.module, p.curr_token.pos, Ast_Formal_Parameter)
		param.names.allocator = ast_allocator(p.module)

		if allow_token(p, .Var) {
			param.is_var = true
		}
		append(&param.names, parse_ident(p))
		for allow_token(p, .Comma) {
			append(&param.names, parse_ident(p))
		}
		expect_token(p, .Colon)
		param.type = parse_formal_type(p)

		append(&parameters, param)

		_ = allow_token(p, .Semicolon)
	}

	expect_token(p, .Paren_Close)

	return
}

// formal_type = "[" "]" qual_ident
parse_formal_type :: proc(p: ^Parser) -> Ast_Type {
	if allow_token(p, .Bracket_Open) {
		pos := p.prev_token.pos
		expect_token(p, .Bracket_Close)
		array := ast_new(p.module, pos, Ast_Slice_Type)
		array.elem = parse_qual_ident_as_type(p)
		return &array.type_base
	}
	return parse_qual_ident_as_type(p)
}

// stmt_sequence = stmt {";" stmt} [";"]
parse_stmt_sequence :: proc(p: ^Parser) -> (seq: ^Ast_Stmt_Sequence) {
	seq = ast_new(p.module, p.curr_token.pos, Ast_Stmt_Sequence)
	seq.stmts.allocator = ast_allocator(p.module)

	for {
		#partial switch p.curr_token.kind {
		case .EOF, .End, .Until, .Else, .Elseif, .Case:
			return
		}

		stmt := parse_stmt(p)
		if stmt != nil {
			append(&seq.stmts, stmt)
		}
		if !allow_token(p, .Semicolon) {
			break
		}
	}
	return
}

// stmt = [assignment | proc_call | if_stmt | switch_stmt | while_stmt | repeat_stmt | for_stmt ]
parse_stmt :: proc(p: ^Parser) -> ^Ast_Stmt {
	#partial switch p.curr_token.kind {
	case .If:
		return parse_if_stmt(p)
	case .Switch:
		return parse_switch_stmt(p)
	case .While:
		return parse_while_stmt(p)
	case .Repeat:
		return parse_repeat_stmt(p)
	case .For:
		return parse_for_stmt(p)
	case .Return:
		return parse_return_stmt(p)
	case .Semicolon:
		expect_token(p, .Semicolon)
		return nil
	}

	tok := p.curr_token
	lhs := parse_designator(p)
	// assignment = designator ":=" expr
	if allow_token(p, .Assign) {
		assign_stmt := ast_new(p.module, tok.pos, Ast_Assign_Stmt)
		assign_stmt.lhs = lhs
		assign_stmt.tok = p.prev_token
		assign_stmt.rhs = parse_expr(p)
		return assign_stmt
	}

	expr_stmt := ast_new(p.module, lhs.pos, Ast_Expr_Stmt)
	expr_stmt.expr = lhs
	return expr_stmt
}

// if_stmt = "if" expr "then" stmt_sequence
//           {"elseif" expr "then" stmt_sequence}
//           ["else" stmt_sequence]
//           "end"
parse_if_stmt :: proc(p: ^Parser) -> ^Ast_If_Stmt {
	stmt := ast_new(p.module, p.curr_token.pos, Ast_If_Stmt)
	stmt.tok_if   = expect_token(p, .If)
	stmt.cond     = parse_expr(p)
	stmt.tok_then = expect_token(p, .Then)
	stmt.body     = parse_stmt_sequence(p)

	stmt.elseif_stmts.allocator = ast_allocator(p.module)
	for allow_token(p, .Elseif) {
		elseif_stmt := ast_new(p.module, p.curr_token.pos, Ast_If_Stmt)
		elseif_stmt.tok_if   = p.prev_token
		elseif_stmt.cond     = parse_expr(p)
		elseif_stmt.tok_then = expect_token(p, .Then)
		elseif_stmt.body     = parse_stmt_sequence(p)
		append(&stmt.elseif_stmts, elseif_stmt)
	}
	if allow_token(p, .Else) {
		stmt.else_stmt = parse_stmt_sequence(p)
	}
	expect_token(p, .End)

	return stmt
}

// switch_stmt = "switch" expr "then" {case} "end"
parse_switch_stmt :: proc(p: ^Parser) -> ^Ast_Switch_Stmt {
	stmt := ast_new(p.module, p.curr_token.pos, Ast_Switch_Stmt)
	stmt.tok_switch = expect_token(p, .Switch)
	stmt.cond       = parse_expr(p)
	stmt.tok_then   = expect_token(p, .Then)

	stmt.cases.allocator = ast_allocator(p.module)

	lhs := pase_case(p)
	append(&stmt.cases, lhs)
	for peek_token(p, .Case) {
		rhs := pase_case(p)
		append(&stmt.cases, rhs)
	}

	expect_token(p, .End)

	return stmt
}

// case = "case" case_label_list ":" stmt_sequence
pase_case :: proc(p: ^Parser) -> ^Ast_Case {
	c := ast_new(p.module, p.curr_token.pos, Ast_Case)
	c.tok_case  = expect_token(p, .Case)
	c.labels    = parse_case_list(p)
	c.tok_colon = expect_token(p, .Colon)
	c.body      = parse_stmt_sequence(p)
	return c
}

// case_list = label_range {"," label_range}
parse_case_list :: proc(p: ^Parser) -> (list: [dynamic]^Ast_Label_Range) {
	list.allocator = ast_allocator(p.module)
	lhs := parse_label_range(p)
	append(&list, lhs)
	for allow_token(p, .Comma) {
		rhs := parse_label_range(p)
		append(&list, rhs)
	}
	return
}

// label_range = label [".." label]
parse_label_range :: proc(p: ^Parser) -> ^Ast_Label_Range {
	range := ast_new(p.module, p.curr_token.pos, Ast_Label_Range)
	range.lo = parse_label(p)
	if allow_token(p, .Ellipsis) {
		range.hi = parse_label(p)
	}
	return range
}

// label = integer | string | qual_ident
parse_label :: proc(p: ^Parser) -> ^Ast_Expr {
	#partial switch p.curr_token.kind {
	case .Integer:
		return parse_expr(p)
	case .String:
		return parse_expr(p)
	case .Ident:
		return parse_qual_ident_as_expr(p)
	}
	syntax_error(&p.tok, p.curr_token, "expected an integer, string, or identifier as a label")
	return parse_do_bad_expr(p)
}

parse_do_bad_expr :: proc(p: ^Parser) -> ^Ast_Bad_Expr {
	bad := ast_new(p.module, p.curr_token.pos, Ast_Bad_Expr)
	bad.tok = p.curr_token
	return bad
}



// while_stmt = "while" expr "then" stmt_sequence
//              {"elseif" expr "then" stmt_sequence}
//              "end"
parse_while_stmt :: proc(p: ^Parser) -> ^Ast_While_Stmt {
	stmt := ast_new(p.module, p.curr_token.pos, Ast_While_Stmt)

	stmt.tok_while = expect_token(p, .While)
	stmt.cond = parse_expr(p)
	stmt.tok_do = expect_token(p, .Then)
	stmt.body = parse_stmt_sequence(p)

	stmt.elseif_stmts.allocator = ast_allocator(p.module)

	for allow_token(p, .Elseif) {
		elseif_stmt := ast_new(p.module, p.prev_token.pos, Ast_While_Elseif_Stmt)

		elseif_stmt.tok = p.prev_token
		elseif_stmt.cond = parse_expr(p)
		expect_token(p, .Then)
		elseif_stmt.body = parse_stmt_sequence(p)

		append(&stmt.elseif_stmts, elseif_stmt)
	}
	expect_token(p, .End)

	return stmt
}

// repeat_stmt = "repeat" stmt_sequence "until" expr
parse_repeat_stmt :: proc(p: ^Parser) -> ^Ast_Repeat_Stmt {
	stmt := ast_new(p.module, p.curr_token.pos, Ast_Repeat_Stmt)
	stmt.tok_repeat = expect_token(p, .Repeat)
	stmt.body       = parse_stmt_sequence(p)
	stmt.tok_until  = expect_token(p, .Until)
	stmt.cond       = parse_expr(p)
	return stmt
}

// for_stmt = "for" ident ":=" expr "to" expr ["by" const_expr] "then" stmt_sequence "end"
parse_for_stmt :: proc(p: ^Parser) -> ^Ast_For_Stmt {
	stmt := ast_new(p.module, p.curr_token.pos, Ast_For_Stmt)

	stmt.tok_for = expect_token(p, .For)
	stmt.name    = parse_ident(p)
	stmt.assign  = expect_token(p, .Assign)
	stmt.lo_cond = parse_expr(p)
	stmt.tok_to  = expect_token(p, .To)
	stmt.hi_cond = parse_expr(p)
	if allow_token(p, .By) {
		stmt.tok_by = p.prev_token
		stmt.by_cond = parse_const_expr(p)
	}
	stmt.tok_do = expect_token(p, .Then)
	stmt.body   = parse_stmt_sequence(p)
	expect_token(p, .End)
	return stmt
}

// return_stmt = "return"
parse_return_stmt :: proc(p: ^Parser) -> ^Ast_Return_Stmt {
	stmt := ast_new(p.module, p.curr_token.pos, Ast_Return_Stmt)
	stmt.tok = expect_token(p, .Return)
	return stmt
}


// designator = qual_ident {selector}
parse_designator :: proc(p: ^Parser) -> ^Ast_Expr {
	lhs := parse_qual_ident_as_expr(p)

	for {
		#partial switch p.curr_token.kind {
		case .Dot, .Bracket_Open, .Caret, .Paren_Open:
			sel := parse_selector(p, lhs)
			lhs = sel
		case:
			return lhs
		}
	}
}
// selector = "." ident | "[" expr_list "]" | "^" | "(" [expr_list] ")"
parse_selector :: proc(p: ^Parser, lhs: ^Ast_Expr) -> ^Ast_Expr {
	switch {
	case allow_token(p, .Dot):
		sel := ast_new(p.module, lhs.pos, Ast_Selector_Expr)
		sel.lhs = lhs
		sel.tok = p.prev_token
		sel.rhs = parse_ident(p)
		return sel
	case allow_token(p, .Bracket_Open):
		index := ast_new(p.module, lhs.pos, Ast_Index_Expr)
		index.expr = lhs
		index.index = parse_expr(p)
		expect_token(p, .Bracket_Close)
		return index

	case allow_token(p, .Caret):
		deref := ast_new(p.module, lhs.pos, Ast_Deref_Expr)
		deref.expr = lhs
		deref.tok = p.prev_token
		return deref

	case allow_token(p, .Paren_Open):
		call := ast_new(p.module, lhs.pos, Ast_Call_Expr)
		call.call = lhs
		if p.curr_token.kind != .Paren_Close {
			call.parameters = parse_expr_list(p)
		}
		expect_token(p, .Paren_Close)
		return call
	}

	return lhs
}

// expr_list = expr {"," expr}
parse_expr_list :: proc(p: ^Parser) -> (list: [dynamic]^Ast_Expr) {
	list.allocator = ast_allocator(p.module)
	lhs := parse_expr(p)
	append(&list, lhs)
	for allow_token(p, .Comma) {
		rhs := parse_expr(p)
		append(&list, rhs)
	}
	return
}