# Titania Programming Language

Based on the [Oberon-07](https://people.inf.ethz.ch/wirth/Oberon/Oberon07.Report.pdf) programming language designed by the late [Niklaus Wirth](https://en.wikipedia.org/wiki/Niklaus_Wirth).

This is designed to be a language to teach compiler development with.

Meaning behind the name:
 * Titania is the wife of Oberon (Fairy King) in Shakespeare's _A Midsummer Night's Dream_
 * <https://en.wikipedia.org/wiki/Titania_(A_Midsummer_Night%27s_Dream)>
 * This is just a codename, and probably not final for this teaching language

## Grammar


```
module = "module" ident ";" [import_list] decl_sequence
         ["begin" stmt_sequence] "end" [";"].

import_list = "import" import_decl {"," import_decl} ";".
decl_sequence = ["const" {const_decl ";"}]
                ["type"  {type_decl  ";"}]
                ["var"   {var_decl   ";"}]
                [{proc_decl          ";"}].

const_decl = ident "=" const_expr.
type_decl = ident "="" struct_type.
var_decl = ident_list ":" type.

proc_decl = "proc" ident [formal_parameters] ";" proc_body.
proc_body = decl_sequence ["begin" stmt_sequence] ["return" expr] "end".


const_expr = expr.
expr = simple_expr {relation simple_expr}.

simple_expr = ["+" | "-"] unary_expr {add_operator unary_expr}.
unary_expr = ["+" | "-"] term.
term = factor {mul_operator factor}.

factor = integer | real | string | nil | true | false | set |
         "(" expr ")" | "not" expr | designator.

element = expr [".." expr].

ident_list = ident {"," ident}.
qual_ident = [ident "."] ident.

struct_type = array_type | record_type | pointer_type | proc_type.
array_type = "["" const_expr {"," const_expr} "]" type.
record_type = "record" ["(" qual_ident ")"] [field_list_sequence] "end".
pointer_type = "^" type.
proc_type = "proc" formal_parameters.
field_list = ["using"] ident_list ":" type.
formal_parmeters = "(" [fp_section {";" fp_section}] [";"] ")".
formal_type = "[" "]" qual_ident.

stmt_sequence = stmt {";" stmt} [";"].
stmt = [assignment | proc_call | if_stmt | case_stmt | while_stmt | repeat_stmt | for_stmt ].

assignment = designator ":=" expr

if_stmt = "if" expr "then" stmt_sequence
          {"elseif" expr "then" stmt_sequence}
          ["else" stmt_sequence]
          "end".

case_stmt = "case" expr "of" case {"|" case} "end".
case = [case_label_list ":" stmt_sequence].
case_list = label_range {"," label_range}.
label_range = label [".." label].
label = integer | string | qual_ident.

while_stmt = "while" expr "then" stmt_sequence
             {"elseif" expr "then" stmt_sequence}
             "end".
repeat_stmt = "repeat" stmt_sequence "until" expr.
for_stmt = "for" ident ":=" expr "to" expr ["by" const_expr] "then" stmt_sequence "end".


designator = qual_ident {selector}.
selector = "." ident |
           "[" expr_list "]" |
           "^" |
           "(" [expr_list] ")".
expr_list = expr {"," expr}.


add_operator = "+" | "-" | "xor" | "or".
mul_operator = "*" | "/" | "%"   | "and".
relation     = "=" | "<>" | "<" | "<=" | ">" | ">=" | "in" | "is".
```

### Keywords
```
and    else    if      nil   record  true   while
begin  elseif  import  not   repeat  type   xor
by     end     in      of    return  until
case   false   is      or    then    using
const  for     module  proc  to      var
```


### Operators

```
+    .   (   )   =  <>
-    ,   [   ]   <  <=
*    ;   {   }   >  >=
/    |   :=  :   ..
%    ^
```

### Tokenizer Semicolon Insertion Rules

When a newline is seen after the following token kind, a semicolon is inserted, otherwise no semicolon is inserted:

* Identifiers
* Integer, Real, String, Boolean literals
* `nil`
* `^`
* `)`, `]`, `}`
* `end`


### Built-in Procedures

Note: These will be added to as the compiler develops

```
abs(x)            - absolute value of
lsh(x, y)         - logical shift left
ash(x, y)         - arithmetic shift right
ror(x, y)         - rotate right
chr(i)            - convert int to char
ord(c)            - convert char to int
inc(x)            - x := x + 1
inc(x, y)         - x := x + y
dec(x)            - x := x - 1
dec(x, y)         - x := x - y
incl(x, y)        - include y in set x
excl(x, y)        - exclude y in set x
odd(x)            - x % 2 = 0
floor(x)          - round-down for real
ceil(x)           - round-up   for real
assert(cond)      - assert when cond is false
new(ptr)          - allocate memory
delete(ptr)       - free memory
addr(x)           - address of addressable memory
size_of(x)        - size of the type of 'x'
align_of(x)       - alignment of the type of 'x'
copy(dst, src, n) - non-overlapping memory copying from `src` to `dst` of `n` bytes
print(...)        - variadic print without newline
println(...)      - variadic print with newline
len(x)            - length of an array 'x'

pack(var x: real; n: int)        -
unpack(var x: real; var n: int)  -
```
