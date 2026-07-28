package titania

import "core:fmt"
import "core:unicode/utf8"


Pos :: struct {
	offset: int,
	line:   int,
	column: int,
}

Token :: struct {
	using pos: Pos,
	kind: Token_Kind,
	text: string,
}


Tokenizer :: struct {
	using pos: Pos,
	data: string,

	filename: string,

	ch: rune, // current rune/character
	w:  int,  // current rune width in bytes

	curr_line_offset: int,

	insert_semicolon: bool,

	error_count: int,
}

Token_Kind :: enum {
	Invalid,
	EOF,

	Add,
	Sub,
	Mul,
	Quo,
	Mod,
	Dot,
	Comma,
	Semicolon,
	Paren_Open,
	Paren_Close,
	Bracket_Open,
	Bracket_Close,
	Brace_Open,
	Brace_Close,
	Assign,
	Caret,
	Equal,
	Not_Equal,
	Less_Than,
	Greater_Than,
	Less_Than_Equal,
	Greater_Than_Equal,
	Ellipsis,
	Colon,

	Ident,
	Integer,
	Real,
	String,

	And,
	Begin,
	By,
	Case,
	Const,
	Else,
	Elseif,
	End,
	False,
	For,
	If,
	Import,
	In,
	Is,
	Module,
	Nil,
	Not,
	Or,
	Proc,
	Record,
	Repeat,
	Return,
	Switch,
	Then,
	To,
	True,
	Type,
	Until,
	Using,
	Var,
	While,
	Xor,
}

@(rodata)
token_kind_string := [Token_Kind]string{
	.Invalid = "",
	.EOF     = "eof",

	.Add                = "+",
	.Sub                = "-",
	.Mul                = "*",
	.Quo                = "/",
	.Mod                = "%",
	.Dot                = ".",
	.Comma              = ",",
	.Semicolon          = ";",
	.Paren_Open         = "(",
	.Paren_Close        = ")",
	.Bracket_Open       = "[",
	.Bracket_Close      = "]",
	.Brace_Open         = "{",
	.Brace_Close        = "}",
	.Assign             = ":=",
	.Caret              = "^",
	.Equal              = "=",
	.Not_Equal          = "<>",
	.Less_Than          = "<",
	.Greater_Than       = ">",
	.Less_Than_Equal    = "<=",
	.Greater_Than_Equal = ">=",
	.Ellipsis           = "..",
	.Colon              = ":",

	.Ident   = "identifier",
	.Integer = "integer literal",
	.Real    = "real literal",
	.String  = "string literal",

	.And     = "and",
	.Begin   = "begin",
	.By      = "by",
	.Case    = "case",
	.Const   = "const",
	.Else    = "else",
	.Elseif  = "elseif",
	.End     = "end",
	.False   = "false",
	.For     = "for",
	.If      = "if",
	.Import  = "import",
	.In      = "in",
	.Is      = "is",
	.Module  = "module",
	.Nil     = "nil",
	.Not     = "not",
	.Or      = "or",
	.Proc    = "proc",
	.Record  = "record",
	.Repeat  = "repeat",
	.Return  = "return",
	.Switch  = "switch",
	.Then    = "then",
	.To      = "to",
	.True    = "true",
	.Type    = "type",
	.Until   = "until",
	.Using   = "using",
	.Var     = "var",
	.While   = "while",
	.Xor     = "xor",
}


tokenizer_init :: proc(t: ^Tokenizer, filename: string, data: string) {
	t^ = Tokenizer{
		pos = {line = 1},
		data = data,
		filename = filename,
	}
	next_rune(t)
	if t.ch == utf8.RUNE_BOM {
		next_rune(t)
	}
}

next_rune :: proc(t: ^Tokenizer) -> rune {
	if t.offset < len(t.data) {
		t.offset += t.w
		t.ch, t.w = utf8.decode_rune_in_string(t.data[t.offset:])
		t.pos.column = t.offset - t.curr_line_offset
	}

	if t.offset >= len(t.data) {
		t.ch = utf8.RUNE_EOF
		t.w = 1
	}
	return t.ch
}

peek_rune :: proc(t: ^Tokenizer) -> rune {
	prev := t^
	ch := next_rune(t)
	t^ = prev
	return ch
}


is_valid_string_literal :: proc(str: string) -> bool {
	s := str
	if len(s) < 2 {
		return false
	}
	quote := s[0]
	if s[0] != s[len(s)-1] {
		return false
	}
	switch quote {
	case '"':
		// okay
	case:
		return false
	}
	s = s[1 : len(s)-1]

	i := 0
	for i < len(s) {
		c := s[i]
		switch {
		case c == '\\':
			i += 1
			if i >= len(s) {
				return false
			}
			switch s[i] {
			case '"', '\'', '\\', '/', 'b', 'n', 'r', 't', 'f':
				i += 1

			case '\r':
				if i+1 < len(s) && s[i+1] == '\n' {
					i += 2
				} else {
					return false
				}
			case '\n':
				i += 1
			case 'u':
				if i >= len(s) {
					return false
				}
				hex := s[i+1:]
				if len(hex) < 4 {
					return false
				}
				hex = hex[:4]
				i += 5

				for j := 0; j < 4; j += 1 {
					c2 := hex[j]
					switch c2 {
					case '0'..='9', 'a'..='z', 'A'..='Z':
						// Okay
					case:
						return false
					}
				}

			case: return false
			}

		case c == quote, c < ' ':
			return false

		case c < utf8.RUNE_SELF:
			i += 1

		case:
			r, width := utf8.decode_rune_in_string(s[i:])
			if r == utf8.RUNE_ERROR && width == 1 {
				return false
			}
			i += width
		}
	}
	if i == len(s) {
		return true
	}
	return true
}

get_token :: proc(t: ^Tokenizer) -> (token: Token) {
	skip_whitespace :: proc(t: ^Tokenizer) -> rune {
		for t.offset < len(t.data) {
			switch t.ch {
			case ' ', '\t', '\r', '\f', '\v':
				next_rune(t)
			case '\n':
				if !t.insert_semicolon {
					t.line += 1
					t.curr_line_offset = t.offset
					t.pos.column = 1
					next_rune(t)
					break
				}
				return t.ch
			case:
				return t.ch
			}
		}
		return t.ch
	}

	skip_hex_digits :: proc(t: ^Tokenizer) {
		for t.offset < len(t.data) {
			switch t.ch {
			case '0'..='9', 'a'..='f', 'A'..='F':
				next_rune(t)
			case:
				return
			}
		}
	}

	skip_digits :: proc(t: ^Tokenizer) {
		for t.offset < len(t.data) {
			switch t.ch {
			case '0'..='9':
				next_rune(t)
			case:
				return
			}
		}
	}

	scan_escape :: proc(t: ^Tokenizer) {
		// TODO(bill): scan_escape
	}


	skip_whitespace(t)

	token.pos = t.pos
	token.kind = .Invalid

	ch := t.ch
	next_rune(t)

	switch ch {
	case utf8.RUNE_ERROR:
		syntax_error(t, token.pos, "illegal character found: %c", ch)
		// illegal character

	case utf8.RUNE_EOF, '\x00':
		token.kind = .EOF
		if t.insert_semicolon {
			t.insert_semicolon = false
			token.kind = .Semicolon
			token.text = "\n"
			return
		}

	case '\n':
		token.kind = .Semicolon
		token.text = "\n"

		t.insert_semicolon = false
		t.line += 1
		t.curr_line_offset = t.offset
		t.pos.column = 1

		return

	case '+':  token.kind = .Add
	case '-':  token.kind = .Sub
	case '*':  token.kind = .Mul
	case '/':
		token.kind = .Quo
		if t.ch == '/' {
			for t.offset < len(t.data) {
				if t.ch == '\n' {
					return get_token(t)
				}
				next_rune(t)
			}
		} else if t.ch == '*' {
			for t.offset < len(t.data) {
				next_rune(t)
				if t.ch == '\n' {
					t.pos.line += 1
					t.curr_line_offset = t.pos.offset
				}
				if t.ch == '*' {
					next_rune(t)
					if t.ch == '/' {
						next_rune(t)
						return get_token(t)
					}
				}
			}
			syntax_error(t, token.pos, "non-closing block comment")
			token.kind = .EOF

		}
	case '%':  token.kind = .Mod
	case '.':
		token.kind = .Dot
		if t.ch == '.' { // ..
			next_rune(t)
			token.kind = .Ellipsis
		}
	case ',':  token.kind = .Comma
	case ';':  token.kind = .Semicolon
	case '(':  token.kind = .Paren_Open
	case ')':  token.kind = .Paren_Close
	case '[':  token.kind = .Bracket_Open
	case ']':  token.kind = .Bracket_Close
	case '{':  token.kind = .Brace_Open
	case '}':  token.kind = .Brace_Close
	case ':':
		token.kind = .Colon
		if t.ch == '=' { // :=
			next_rune(t)
			token.kind = .Assign
		}
	case '^':  token.kind = .Caret
	case '=':  token.kind = .Equal
	case '<':
		token.kind = .Less_Than
		if t.ch == '=' { // <=
			next_rune(t)
			token.kind = .Less_Than_Equal
		} else if t.ch == '>' { // <>
			next_rune(t)
			token.kind = .Not_Equal
		}
	case '>':
		token.kind = .Greater_Than
		if t.ch == '=' { // >=
			next_rune(t)
			token.kind = .Greater_Than_Equal
		}

	case '0'..='9':
		token.kind = .Integer
		if ch == '0' && t.ch == 'x' { // hexadecimal number
			next_rune(t)
			skip_hex_digits(t)
			break
		}
		skip_digits(t)
		if t.ch == '.' && peek_rune(t) != '.' {
			next_rune(t)
			token.kind = .Real
			skip_digits(t)
			if t.ch == 'e' {
				next_rune(t)
				if t.ch == '+' || t.ch == '-' {
					next_rune(t)
				}
				skip_digits(t)
			}
		}

	case '"':
		token.kind = .String
		for t.offset < len(t.data) {
			ch := t.ch
			if ch == '\n' || ch < 0 {
				syntax_error(t, token.pos, "string literal no terminated")
				break
			}
			next_rune(t)
			if ch == '"' {
				break
			}
			if ch == '\\' {
				scan_escape(t)
			}
		}

		str := t.data[token.offset : t.offset]
		if !is_valid_string_literal(str) {
			syntax_error(t, token.pos, "invalid string literal")
		}

	case 'A'..='Z', 'a'..='z', '_':
		token.kind = .Ident
		ident_loop: for t.offset < len(t.data) {
			switch t.ch {
			case 'A'..='Z', 'a'..='z', '_':
				next_rune(t)
			case '0'..='9':
				next_rune(t)
			case:
				break ident_loop
			}
		}

		str := t.data[token.offset : t.offset]
		for keyword in Token_Kind.String + Token_Kind(1) ..< Token_Kind(len(Token_Kind)) {
			if token_kind_string[keyword] == str {
				token.kind = keyword
				break
			}
		}

	case:
		syntax_error(t, token.pos, "invalid character found: %q", ch)
	}

	#partial switch token.kind {
	case .Ident, .Integer, .Real, .String,
	     .Nil, .Caret, .False, .True,
	     .Paren_Close, .Bracket_Close, .Brace_Close,
	     .End:
		t.insert_semicolon = true
	case:
		t.insert_semicolon = false
	}

	token.text = t.data[token.offset : t.offset]
	return
}