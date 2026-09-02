# Stilla Grammar Diagrams

> **Version:** v1.3 Draft
>
> Railroad-style syntax diagrams of the Stilla core language **statement-level
> grammar**, rendered as Mermaid `flowchart` diagrams (GitHub renders Mermaid
> natively; other Markdown viewers may need a Mermaid plugin).
>
> **Non-normative.** The authoritative grammar remains Stilla Core Grammar
> Draft.abnf, which these diagrams transcribe exactly. Two layers are *out of
> scope* here and appear only as labeled chips:
>
> - the **lexical layer** — `identifier`, `integer`, `float`, `string`,
>   `bool-literal`, `wildcard-token` and the comment/escape rules are defined
>   in the Grammar Draft's lexical grammar;
> - the **expression layer** — `expression` is defined normatively in
>   Stilla Expression Binding Power Table.md (binding powers, associativity,
>   primary/prefix/postfix forms), not by productions in the Grammar Draft.
>
> ## Reading conventions
>
> | Shape | Meaning |
> | --- | --- |
> | `(["'token'"])` | a terminal: the literal token or keyword shown |
> | `[rule-name]` | a reference to the rule drawn below (or a lexical token) |
> | `["…"]` | a compact alternative group; the text is the ABNF fragment |
> | `-(dashed)->` labeled `ε` | optional: the bypassed segment may be absent |
> | self-loop edge | repetition; the label states the separator and count |
> | `(("ε"))` | empty (a choice that consumes nothing) |
>
> Each diagram reads left to right. A self-loop on an element means the
> element (with its labeled separator, when one appears) may repeat. An
> `ε` bypass over a segment means that segment is optional, `[ … ]` in ABNF.

## Program structure

### program

```mermaid
flowchart LR
pg0(["program"]) -->|"0..n module items"| pg1["module-item"]
```

### module-item — one of

```mermaid
flowchart LR
mi0(["module-item"]) --> mi1["const-def"]
mi0 --> mi2["func-def"]
mi0 --> mi3["type-def"]
mi0 --> mi4["struct-def"]
mi0 --> mi5["union-def"]
mi0 --> mi6["opaque-def"]
mi0 --> mi7["using-decl"]
```

## Path aliases and module constants

### using-decl

```mermaid
flowchart LR
ud0(["'using'"]) --> ud1["type-path"]
ud1 --> ud2(["'as'"])
ud2 --> ud3[identifier]
ud3 --> ud4(["';'"])
ud1 -.->|"ε — no 'as' alias"| ud4
```

### const-def

```mermaid
flowchart LR
cd0(["'const'"]) --> cd1[identifier]
cd1 --> cd2(["':'"])
cd2 --> cd3["type"]
cd3 --> cd4(["';'"])
cd3 --> cd5(["'='"])
cd5 --> cd6["expression"]
cd6 --> cd7(["';'"])
cd1 -.->|"ε — untyped form"| cd5
```

The right branch (`'const' name ':' type ';'`, no initializer) is a **host
constant**; the initializer branch (`'=' expression ';'`) accepts both the
typed and the untyped spelling.

## Functions

### func-def — body form and host-binding form

```mermaid
flowchart LR
fdn0(["'fn'"]) --> fdn1[identifier]
fdn1 --> fdn2["type-params"]
fdn1 -.->|"ε"| fdn3(["'('"])
fdn2 --> fdn3
fdn3 --> fdn4["param-list"]
fdn4 --> fdn5(["')'"])
fdn5 --> fdn6(["'->'"])
fdn6 --> fdn7["type"]
fdn7 --> fdn8["block"]
fdn7 --> fdn9(["';'"])
```

The return type (`'->' type`) is required in both forms: a function with
no value declares `'-> void'`, and one that never returns normally
declares `'-> never'`. The `';'` form is a host binding.

### param-list

```mermaid
flowchart LR
pl0["param"] -->|"0..n more, each: ',' param"| pl0
```

### param

```mermaid
flowchart LR
pm0(["'borrow' / 'move'"]) --> pm1[identifier]
pm1 --> pm2(["':'"])
pm2 --> pm3["type"]
pm4(("ε")) --> pm1
```

### function-type

```mermaid
flowchart LR
fty0(["'fn'"]) --> fty1(["'('"])
fty1 -.->|"ε — zero params"| fty2(["')'"])
fty1 --> fty3["function-param-type"]
fty3 -->|"0..n more, each: ',' function-param-type"| fty3
fty3 --> fty2
fty2 --> fty4(["'->'"])
fty4 --> fty5["type"]
```

### function-param-type

```mermaid
flowchart LR
fpt0(["'borrow' / 'move'"]) --> fpt1["type"]
fpt2(("ε")) --> fpt1
```

`param-list` is entirely optional (an empty parameter list is valid); the
loop label means `param *( ',' param )` in ABNF. The expression-position
**lambda** (`'fn' '(' param-list ')' '->' type block`) is an expression
form and is defined in Stilla Expression Binding Power Table.md, not here.

## Generic parameters

### type-params

```mermaid
flowchart LR
tpg0(["'['"]) --> tpg1[identifier]
tpg1 -->|"0..n more, each: ',' identifier"| tpg1
tpg1 --> tpg2(["']'"])
```

### type-args

```mermaid
flowchart LR
tga0(["'['"]) --> tga1["type"]
tga1 -->|"0..n more, each: ',' type"| tga1
tga1 --> tga2(["']'"])
```

## Types

### type — one of

```mermaid
flowchart LR
ty0(["type"]) --> ty1["primitive-type"]
ty0 --> ty2["named-type"]
ty0 --> ty3["list-type"]
ty0 --> ty4["box-type"]
ty0 --> ty5["tuple-type"]
ty0 --> ty6["function-type"]
```

### primitive-type — one of the reserved keywords

```mermaid
flowchart LR
pt0(["primitive-type"]) --> pt1["'any'"]
pt0 --> pt2["'byte'"]
pt0 --> pt3["'hostdata'"]
pt0 --> pt4["'int32'"]
pt0 --> pt5["'uint32'"]
pt0 --> pt6["'int64'"]
pt0 --> pt7["'uint64'"]
pt0 --> pt8["'float32'"]
pt0 --> pt9["'float64'"]
pt0 --> pt10["'bool'"]
pt0 --> pt11["'str'"]
pt0 --> pt12["'void'"]
pt0 --> pt13["'never'"]
```

### named-type

```mermaid
flowchart LR
nty0["type-path"] --> nty1["type-args"]
nty0 -.->|"ε"| nty2
nty1 --> nty2
```

### type-path

```mermaid
flowchart LR
tpy0[identifier] -->|"0..n more, each: '.' identifier"| tpy0
```

### list-type

```mermaid
flowchart LR
lty0(["'list'"]) --> lty1(["'['"])
lty1 --> lty2["type"]
lty2 --> lty3(["']'"])
```

### box-type

```mermaid
flowchart LR
bty0(["'box'"]) --> bty1(["'['"])
bty1 --> bty2["type"]
bty2 --> bty3(["']'"])
```

### tuple-type

```mermaid
flowchart LR
tty0(["'tuple'"]) --> tty1(["'['"])
tty1 --> tty2["type"]
tty2 -->|"0..n more, each: ',' type"| tty2
tty2 --> tty3(["']'"])
```

`tuple[]` is not a type — the empty tuple `()` is the unique value of type
`void`. A single-element tuple type `tuple[int32]` is valid and distinct from
`int32`. Path segments may be reserved words as well as identifiers after
`.` and `::` (parser note 4), so `builtin.str` parses.

## Type aliases, structs, unions, opaque types

### type-def

```mermaid
flowchart LR
tda0(["'type'"]) --> tda1[identifier]
tda1 --> tda2["type-params"]
tda1 -.->|"ε"| tda3(["'='"])
tda2 --> tda3
tda3 --> tda4["type"]
tda4 --> tda5(["';'"])
```

### struct-def

```mermaid
flowchart LR
sda0(["'struct'"]) --> sda1[identifier]
sda1 --> sda2["type-params"]
sda1 -.->|"ε"| sda3(["'{'"])
sda2 --> sda3
sda3 --> sda4["field-decl"]
sda4 -->|"0..n fields"| sda4
sda4 --> sda5["drop-decl"]
sda4 --> sda6(["'}'"])
sda5 --> sda6
sda3 -.->|"ε — empty struct"| sda6
```

### field-decl

```mermaid
flowchart LR
fda0[identifier] --> fda1(["':'"])
fda1 --> fda2["type"]
fda2 --> fda3(["';'"])
```

### drop-decl

```mermaid
flowchart LR
dda0(["'drop'"]) --> dda1(["'('"])
dda1 --> dda2[identifier]
dda2 --> dda3(["')'"])
dda3 --> dda4["block"]
```

### union-def

```mermaid
flowchart LR
uda0(["'union'"]) --> uda1[identifier]
uda1 --> uda2["type-params"]
uda1 -.->|"ε"| uda3(["'{'"])
uda2 --> uda3
uda3 --> uda4["variant-decl"]
uda3 -.->|"ε — no variants"| uda5(["'}'"])
uda4 -->|"0..n more, each: ',' variant-decl"| uda4
uda4 --> uda6(["','"])
uda6 --> uda5
uda4 --> uda5
```

### variant-decl

```mermaid
flowchart LR
vda0[identifier] --> vda1(["'('"])
vda0 -.->|"ε — no payload"| vda4(["')'"])
vda1 --> vda2["type"]
vda1 -.->|"ε — empty payload"| vda4
vda2 -->|"0..n more, each: ',' type"| vda2
vda2 --> vda4
```

### opaque-def

```mermaid
flowchart LR
oda0(["'opaque'"]) --> oda1(["'type'"])
oda1 --> oda2[identifier]
oda2 --> oda3["type-params"]
oda2 -.->|"ε"| oda4(["';'"])
oda3 --> oda4
```

A struct may contain at most one `drop-decl`, and it must follow all fields.
A union's variant list may carry a trailing comma. Opaque declarations are
legal only in standard-library or host-provided module interfaces (static
semantics).

## Blocks and statements

### block

```mermaid
flowchart LR
blk0(["'{'"]) --> blk1["statement"]
blk1 -->|"0..n statements"| blk1
blk1 --> blk2["expression"]
blk1 -.->|"ε — no final expression"| blk3(["'}'"])
blk2 --> blk3
blk0 -.->|"ε — empty block"| blk3
```

### statement — one of

```mermaid
flowchart LR
stt0(["statement"]) --> stt1["let-stmt"]
stt0 --> stt2["drop-stmt"]
stt0 --> stt3["using-decl"]
stt0 --> stt4["expr-stmt"]
stt0 --> stt5["empty-stmt"]
```

### let-stmt

```mermaid
flowchart LR
lst0(["'let'"]) --> lst1["pattern"]
lst1 --> lst2(["':'"])
lst2 --> lst3["type"]
lst3 --> lst4(["'='"])
lst1 -.->|"ε — inferred type"| lst4
lst4 --> lst5["expression"]
lst5 --> lst6(["';'"])
```

### drop-stmt

```mermaid
flowchart LR
dst0(["'drop'"]) --> dst1[identifier]
dst1 --> dst2(["';'"])
```

### expr-stmt

```mermaid
flowchart LR
est0["expression"] --> est1(["';'"])
```

### empty-stmt

```mermaid
flowchart LR
emt0(["';'"])
```

### expression — out of scope here

```mermaid
flowchart LR
ext0(["expression"]) --> ext1["Stilla Expression Binding Power Table.md"]
```

Parser rule (parser note 1): in the statement loop, an expression followed
by `;` is an expression statement; an expression followed by `}` is the
block's final expression. `let` patterns must be irrefutable (static
semantics).

## Patterns — overview

### pattern — one of

```mermaid
flowchart LR
ptn0(["pattern"]) --> ptn1["wildcard-pattern"]
ptn0 --> ptn2["literal-pattern"]
ptn0 --> ptn3["type-test-pattern"]
ptn0 --> ptn4["tuple-pattern"]
ptn0 --> ptn5["path-pattern"]
ptn0 --> ptn6["list-pattern"]
```

### wildcard-pattern

```mermaid
flowchart LR
wcp0(["'_'"])
```

### literal-pattern — one of

```mermaid
flowchart LR
ltp0(["literal-pattern"]) --> ltp1["integer"]
ltp0 --> ltp2["'-' integer"]
ltp0 --> ltp3["float"]
ltp0 --> ltp4["'-' float"]
ltp0 --> ltp5["string"]
ltp0 --> ltp6["bool-literal"]
```

### type-test-pattern

```mermaid
flowchart LR
ttp0["type-test-type"] --> ttp1[identifier]
ttp0 -.->|"ε — no binding"| ttp2
ttp1 --> ttp2
```

### type-test-type — testable concrete types

```mermaid
flowchart LR
ttt0(["type-test-type"]) --> ttt1["'byte' 'int32' 'uint32' 'int64' 'uint64' 'float32' 'float64' 'bool' 'str'"]
ttt0 --> ttt2["list-type"]
ttt0 --> ttt3["box-type"]
ttt0 --> ttt4["tuple-type"]
ttt0 --> ttt5["function-type"]
```

Static semantics reject `any`, `never`, and `hostdata` as test types; the
test type must be concrete, and no pattern is defined on `hostdata`. A lone
`_` is the wildcard token (lexical maximal-munch rule: `_foo` is an
identifier, a bare `_` is the wildcard).

## Patterns — tuple, path, list

### tuple-pattern

```mermaid
flowchart LR
tup0(["tuple-pattern"]) --> tup1["void-literal"]
tup0 --> tup2(["'('"])
tup2 --> tup3["pattern"]
tup3 --> tup4(["','"])
tup4 --> tup5["pattern"]
tup4 -.->|"ε — two-element tuple"| tup6(["')'"])
tup5 -->|"0..n more, each: ',' pattern"| tup5
tup5 --> tup6
```

### void-literal

```mermaid
flowchart LR
vlt0(["'('"]) --> vlt1(["')'"])
```

### path-pattern

```mermaid
flowchart LR
ppn0["type-path"] --> ppn1["type-args"]
ppn0 -.->|"ε"| ppn2["pattern-tail"]
ppn1 --> ppn2
```

### pattern-tail — one of

```mermaid
flowchart LR
ptl0(["pattern-tail"]) --> ptl1["'{' field-pattern, repeated with ',' separators, optional trailing ',', '}'}"]
ptl0 --> ptl2["'::' identifier, then optional '(' pattern, repeated with ',' separators, ')'"]
ptl0 --> ptl3["identifier — type-test binding"]
ptl0 --> ptl4["ε — identifier-pattern"]
```

### field-pattern

```mermaid
flowchart LR
fpl0[identifier] --> fpl1(["':'"])
fpl1 --> fpl2["pattern"]
fpl0 -.->|"ε — shorthand field"| fpl3
fpl2 --> fpl3
```

### list-pattern

```mermaid
flowchart LR
lsp0(["'['"]) --> lsp1["list-pattern-items"]
lsp0 -.->|"ε — empty list"| lsp2(["']'"])
lsp1 --> lsp2
```

### list-pattern-items

```mermaid
flowchart LR
lsi0(["list-pattern-items"]) --> lsi1["pattern"]
lsi0 --> lsi6["list-rest"]
lsi1 -->|"0..n more, each: ',' pattern"| lsi1
lsi1 --> lsi2(["','"])
lsi2 --> lsi3["list-rest"]
lsi1 -.->|"ε — no rest"| lsi4
lsi3 --> lsi4
lsi6 --> lsi4
```

### list-rest

```mermaid
flowchart LR
lsr0(["'..'"]) --> lsr1[identifier]
```

Parser notes that resolve the identifier-led forms: a `::` immediately
following a type path enters the variant/union branch (note 2, expression
half — see Stilla Expression Binding Power Table.md); an identifier
immediately after a type path (with optional type-args) marks a type-test
binding, and `list`, `box`, `tuple`, `fn`, and primitive-type keywords at
pattern start likewise begin a `type-test-pattern` (parser note 3). There is
no indexed element-read syntax in pattern position — `[` after a path is
always type-args.
