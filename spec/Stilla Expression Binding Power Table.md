# Stilla Expression Binding Power Table

> **Version:** v1.3 Draft
>
> Normative expression grammar of the Stilla core language, in Pratt-parser
> form. The companion grammar document (Stilla Core Grammar Draft.abnf)
> defines the language down to the statement level and stops there: its
> single `expression` production is expanded by this document, which fixes
> the precedence and associativity of every operator and the exact shape of
> every expression form so that a Pratt (precedence-climbing) parser can be
> implemented without additional grammar decisions.
>
> Relationship to the other specifications:
>
> - **Stilla Core Grammar Draft.abnf** — normative below the expression
>   level: lexical tokens, types, patterns, statements, declarations. It
>   references this document for `expression`.
> - **the Core specification** — normative meaning of the constructs (its
>   operator discussions, e.g. Types & Ownership §16, describe the same structure this
>   document fixes syntactically).
>
> This document replaces the layered expression productions that earlier
> drafts of Stilla Core Grammar Draft.abnf carried (`logic-or`,
> `logic-and`, `comparison`, `bitwise-or`/`bitwise-xor`/`bitwise-and`,
> `shift`, `addition`, `multiply`, `unary`, `cast`, `postfix`, and their
> descendants). The grouping semantics are identical; only the presentation
> changes, from a context-free precedence ladder to binding powers. The
> conformance suites (grammar_spec_tests.zig) therefore continue to assert
> the same parses.

## Contents

1. [Parsing model](#parsing-model)
2. [Binding power table](#binding-power-table)
3. [Operator-by-operator notes](#operator-by-operator-notes)
4. [Prefix operators](#prefix-operators)
5. [The postfix chain](#the-postfix-chain)
6. [Primary forms and the path-expression decision table](#primary-forms-and-the-path-expression-decision-table)
7. [Parser algorithm](#parser-algorithm)
8. [Worked examples](#worked-examples)
9. [Migration map](#migration-map)

## Parsing model

An expression is parsed by a precedence-climbing (Pratt) loop over a
recursive-descent nud/led split:

- **nud** (null denotation) — parses an expression with no operator to its
  left: a literal, a parenthesized or tuple form, a path expression, a
  control-flow form, or a **prefix operator** applied to a nested
  expression.
- **led** (left denotation) — parses the continuation after a completed
  left operand: an **infix operator** (which recursively parses its right
  operand at the operator's right binding power) or a **postfix suffix**
  (which does not recurse).

Every infix operator carries two binding powers:

| Power | Meaning |
| --- | --- |
| `lbp` | Left binding power — how tightly a completed left operand binds to this operator. The parse loop consumes the operator only while `lbp ≥ min_bp`. |
| `rbp` | Right binding power — the minimum `min_bp` passed to the recursive parse of the right operand. |

Conventions used throughout this document:

- Larger power = tighter binding. `lbp` ranges 1 (loosest) to 10
  (tightest); the postfix chain binds tighter than any infix operator.
- Left-associative operators set `rbp = lbp + 1`: the right operand is
  parsed at a power the operator itself cannot reach, so equal-precedence
  operators stay in the left-associating loop.
- A non-associative or non-chaining operator is a *semantic restriction*
  on top of its powers; it is stated explicitly where it applies, because
  powers alone cannot express it (the parse loop would otherwise accept a
  chain).
- Stilla has no right-associative infix operator.
- Whitespace and comments never affect grouping (they separate tokens only).
- Like the rest of the grammar, expressions require no more than one token
  of lookahead beyond the decision points documented in
  [the path-expression decision table](#primary-forms-and-the-path-expression-decision-table)
  and the parser notes in Stilla Core Grammar Draft.abnf. The rules of this
  document are the expression-half of those notes.

## Binding power table

| Operator(s) | Kind | `lbp` | `rbp` | Grouping / rule |
| --- | --- | --- | --- | --- |
| `or` | infix | 1 | 2 | left-associative |
| `and` | infix | 2 | 3 | left-associative |
| `==` `!=` `<` `<=` `>` `>=` | infix | 3 | 4 | non-associative and non-chaining; right operand is parsed at the bitwise-`\|` level (4) |
| `\|` | infix | 4 | 5 | left-associative |
| `^` | infix | 5 | 6 | left-associative |
| `&` | infix | 6 | 7 | left-associative |
| `<<` `>>` | infix | 7 | 8 | left-associative |
| `+` `-` | infix | 8 | 9 | left-associative |
| `*` `/` `%` | infix | 9 | 10 | left-associative |
| `as` | infix, right side is a **type** | 10 | — | left-chaining: `x as A as B` groups `(x as A) as B` |
| `.` `(` `)` `::` | postfix suffix | ∞ | — | binds tighter than every infix operator; see [The postfix chain](#the-postfix-chain) |
| `-` `!` `move` | prefix | — | 10 | operand is parsed at power 10 (the `as` level); see [Prefix operators](#prefix-operators) |

Levels in one ascending line (loosest → tightest):

```
or < and < comparison < | < ^ < & < <<,>> < +,- < *,/,% < `- ! move` (prefix) < as < postfix-suffix
```

or, comparing the former ABNF rules:

```
logic-or < logic-and < comparison < bitwise-or < bitwise-xor < bitwise-and
  < shift < addition < multiply < cast < postfix
```

The prefix operators `-` and `!` bind between `* / %` and `as`: a prefix
operand may contain a cast but never a `* / %` chain (`-x * y` is
`(-x) * y`, and `-x as int32` is `-(x as int32)`). The postfix chain binds
tighter than everything.

## Operator-by-operator notes

- **`or` / `and`** — ordinary left-associative boolean operators
  (Types & Ownership §16). `a or b and c` groups `a or (b and c)`.
- **Comparisons** — a comparison's right operand is parsed at the
  bitwise-`|` level, so `a < b | c` groups `a < (b | c)` and `a == b + c`
  groups `a == (b + c)`, but `a < b or c` groups `(a < b) or c`.
  Comparisons are **non-associative and non-chaining**: at most one
  comparison operator may appear in a single unparenthesized expression
  level, so `a < b < c` and `a == b == c` are rejected and every operand
  of a chained comparison must be parenthesized (`(a < b) == c`). This
  mirrors the former rule `comparison = bitwise-or [ comparison-op
  bitwise-or ]`, which admitted no second comparison at all. The RHS
  never opens a nested comparison either: it is parsed at power 4, which
  excludes comparison (3) and looser levels.
- **Bitwise operators** — sit between comparison and shift, like C and
  Python (Types & Ownership §16.1): `|` loosest, `&` tightest. `a | b ^ c` groups
  `a | (b ^ c)`; `a & b | c` groups `(a & b) | c`; all three are
  left-associative; all bind tighter than comparisons (`a & b == c` is
  `(a & b) == c`) and looser than shifts (`a & b << c` is `a & (b << c)`).
- **Shifts** — `a + b << c` groups `(a + b) << c`, like C and Zig
  (Types & Ownership §16.3); a shifted expression used in arithmetic must be
  parenthesized.
- **`as` (cast)** — the only infix operator whose right side is a *type*
  rather than an expression: `x as type`, chained for repeated casts
  (Types & Ownership §16). Because the right side is a type, `as` is implemented as a
  postfix-style loop inside the led, not as a recursive expression parse.
  It binds tighter than `* / %` (a cast operand of an arithmetic operator
  need not be parenthesized: `x as int32 * y` is `(x as int32) * y`) and
  tighter than the prefix operators (`-x as int32` is `-(x as int32)` — the
  cast is the operand of the enclosing prefix, not vice versa).
  A cast result is **not** part of the postfix chain: member access on a
  cast requires parentheses, `(x as int32).max` (the former rule
  `cast = postfix *( as type )` admitted no suffix after the last
  `as`). Note that the cast target type consumes any following dotted
  segments itself (`x as builtin.str`), because a type path is part of
  the type grammar.
- **Postfix suffixes** — `.` member access, `( args )` call, and
  `:: [ type-args ]` specialization bind tighter than every infix and
  prefix operator and are applied left-to-right as a chain on the result
  of a primary form (see [The postfix chain](#the-postfix-chain)).

## Prefix operators

Prefix operators are nuds. `-` and `!` parse their operand at power 10
(the `as` level), so:

- `-x as int32` groups `-(x as int32)` — a cast is tighter than its
  enclosing prefix operator;
- `-x * y` groups `(-x) * y` — a prefix operator binds tighter than `* / %`
  and is only reachable as an operand of them (the former rule
  `multiply = unary *( multiply-op unary )`);
- `- - x` and `! ! x` nest arbitrarily (subject to the parser's nesting
  depth guard);
- `a * -b` parses: the right operand of `*` is parsed at power 10, whose
  nud phase accepts the prefix operator.

| Prefix form | Operand | Note |
| --- | --- | --- |
| `- expression` | parsed at power 10 | numeric negation (Types & Ownership §16). There is **no negative literal**: `-1` is negation applied to the literal `1`, matching the lexical grammar, where `-` is never part of an `integer` or `float` token. |
| `! expression` | parsed at power 10 | logical negation (Types & Ownership §16). |
| `move identifier` | a single identifier, not an expression | names a complete local binding to move (Types & Ownership §10.4); there is no general borrow expression. `move` does not recurse: `move x as int32` does not parse. |

## The postfix chain

After a primary form has been parsed, the postfix suffixes apply in a
left-to-right chain, tighter than every operator:

| Suffix | Token | Applies after |
| --- | --- | --- |
| member access | `.` `identifier` | any primary or postfix-chain result |
| call | `(` `arg-list` `)` | any primary or postfix-chain result |
| generic specialization | `::` `[` `type-args` `]` | any primary or postfix-chain result **except** a bare type path (see below) |

Chain-level rules:

- **Reserved-word member names** (the expression half of parser note 4 in
  Stilla Core Grammar Draft.abnf): the token after `.` is read as a member
  name even when it is a reserved word, so `f().str` and `(m).box` parse;
  the reserved-word spelling is only recognized as a keyword at a decision
  point, never after a member-access dot.
- **`::` after a type path** (parser note 2, expression half): a `::`
  immediately following a *type path* is consumed by the path-expression
  nud as a variant or specialization (see the decision table below); the
  postfix specialization suffix applies only after *other* primary forms
  and postfix chains, e.g. `f(x)::[int32]`. There is no ambiguity to
  resolve: the nud always consumes a `::` that directly follows the path
  it parsed.
- A cast result cannot be extended by the postfix chain
  (`x as int32 .foo` does not parse; `(x as int32).foo` does), and the
  chain cannot be reopened after an infix operator without parentheses
  (`a + b.foo` is `a + (b.foo)`, so the chain opens only inside the
  right operand's own nud).
- After `.` / `::` the following identifier is read as a name even if it
  is reserved (the path-segment rule of the type grammar applies to member
  suffixes too).

## Primary forms and the path-expression decision table

Primary forms (nuds) with no operator to their left:

| Form | Shape | Note |
| --- | --- | --- |
| literal | `integer`, `float`, `string`, `true`, `false` | tokens of the lexical grammar |
| void | `(` `)` | the empty tuple, the unique value of type `void` |
| paren / tuple | `( expression )`, `( e, ... )`, `( e, )` | `(e)` is a parenthesized expression, not a single-element tuple; a one-element tuple is written `(e,)` |
| list literal | `[ e, ... ]` (optional trailing comma) | there is no index-read suffix; `[` after a path is always type arguments |
| lambda | `fn ( param-list ) -> type block` | `fn` in expression position; no type parameters; the return type is required (Core Language §6.3) |
| `if` | `if ( expression ) block [ else ( block / if-expression ) ]` | control-flow expression |
| `match` | `match ( expression ) { pattern => expression, ... }` | at least one arm required |
| `import` | `import ( string )` | module-level initializer only (static semantics) |
| block | `{ statement* [ expression ] }` | a block is an expression |
| path expression | see below | identifier-leading form |

**Path-expression nud decision table.** An identifier-leading expression is
parsed as `type-path [ type-args ] path-tail`. The type path itself
consumes every `.`-separated identifier segment (`a.b.c` is one path); the
decisions after it are pure lookahead on the next token and require no
backtracking:

| After the type path (and optional `[ type-args ]`) the next token is… | Path-tail branch | Meaning |
| --- | --- | --- |
| `{` | struct construction | `S { field: expression, ... }` (trailing comma optional); every field exactly once, static semantics |
| `::` followed by `identifier` | union variant | `U::Variant`, `U::Variant( args )` — variant construction |
| `::` followed by `[` | specialization | `G::[type, ...]` — generic specialization (eliminated at compile time) |
| anything else | empty | an ordinary value or member expression; the postfix chain, infix operators, or an enclosing form continue |

Consequences of the table:

- `[` after a path is always `type-args`, never an index or list literal.
- `Foo { ... }` after a path always constructs; a braced block after a
  bare path is never a block expression (parenthesize if a block value is
  meant, e.g. `({ ... })` in the rare position where it could be
  confused).
- Once the nud consumed a `::` form, `::` cannot appear again as a
  postfix specialization until another postfix suffix intervenes
  (`U::V::[T]` — see the `::`-after-type-path rule above). As with every
  expression decision, one token after the decision point suffices:
  `identifier`, `[`, or anything else.

## Parser algorithm

The following pseudocode is the normative reading of the table; a parser
must produce exactly the groupings the table and notes describe.

```
parse_expression(min_bp):                    # top level calls with min_bp = 0
    left = parse_nud()                       # primary or prefix op, with
                                             # its own postfix chain

    loop:
        if next token ends the expression:
            return left

        if next token is `as` and lbp(as) >= min_bp:
            consume `as`
            target = parse_type()            # right side is a TYPE
            left = make_cast(left, target)   # as may repeat (left chain)
            continue

        op = next infix operator
        if lbp(op) < min_bp:
            return left
        consume op
        if op is a comparison operator:      # non-associative, non-chaining
            right = parse_expression(4)      # rhs is bitwise-or and tighter
            left = make_comparison(op, left, right)
            if next token is a comparison operator:   # `a < b < c`
                error "comparisons do not chain"
        else:                                # left-associative
            right = parse_expression(rbp(op))
            left = make_binary(op, left, right)

parse_nud():
    if next token is a prefix operator (`-`, `!`):
        consume; operand = parse_expression(10); return prefix node
    if next token is `move`:
        consume; name = expect(identifier); return move node
    node = parse_primary_form()              # decision table above; nested
                                             # expressions inside a form are
                                             # parsed with min_bp = 0
    loop:                                    # the postfix chain
        if next token is `.`:
            consume; member = read member name (reserved words allowed)
            node = make_member(node, member)
        elif next token is `(`:
            consume; args = parse_arg_list(); node = make_call(node, args)
        elif next token is `::` and node is not a bare-type-path nud:
            consume; types = parse_type_args(); node = make_specialize(...)
        else:
            return node                     # back to the infix loop
```

Notes on the algorithm:

- The postfix chain lives entirely inside `parse_nud` (and inside a
  primary form's own nested parses). It never re-opens after an infix
  operator or a cast, which is what makes `x as int32 .foo` and
  `a + b .foo` fail exactly as the ABNF-form grammar did.
- The `as`-loop and the comparison chain check are the two places the
  binding powers alone are not expressive enough; the former because the
  right side is a type, the latter because Stilla comparisons are
  non-chaining by design.
- `parse_type`, `parse_type_args`, `parse_arg_list`, and the parsing of
  the forms inside `parse_primary_form` (blocks, patterns, parameters)
  come from the statement/type/pattern grammar in Stilla Core Grammar
  Draft.abnf; only their embedded *expressions* re-enter
  `parse_expression`.

## Worked examples

All groupings below follow directly from the table.

| Source | Parse | Former ABNF basis |
| --- | --- | --- |
| `a or b and c` | `a or (b and c)` | `logic-and` binds tighter than `logic-or` |
| `a == b or c` | `(a == b) or c` | comparison tighter than `or` |
| `a & b == c` | `(a & b) == c` | comparison looser than `&` |
| `a == b + c` | `a == (b + c)` | rhs of comparison parsed at power 4 |
| `a < b < c` | rejected | comparisons do not chain |
| `a == b == c` | rejected | comparisons do not chain |
| `a < b and c == d` | `(a < b) and (c == d)` | one comparison per and-operand |
| `a \| b ^ c` | `a \| (b ^ c)` | `^` tighter than `\|` |
| `a & b \| c` | `(a & b) \| c` | `&` tighter than `\|`, left-associative |
| `a & b << c` | `a & (b << c)` | shift tighter than `&` |
| `a + b << c` | `(a + b) << c` | shift looser than `+`, like C/Zig |
| `a * -b` | `a * (-b)` | prefix reachable as a multiply operand |
| `-x * y` | `(-x) * y` | prefix binds tighter than `*` |
| `-x as int32` | `-(x as int32)` | cast tighter than prefix `-` |
| `x as int32 as str` | `(x as int32) as str` | `as` chains left |
| `x as int32 * y` | `(x as int32) * y` | cast tighter than `*` |
| `-f().x` | `-(f().x)` | postfix tighter than prefix |
| `S { a: 1 }.a` | `(S { a: 1 }).a` | postfix after construction |
| `f(x)::[int32]` | `specialize(f(x), [int32])` | `::` after a non-path primary |
| `G::[int32]::[str]` | `specialize(specialize(G, [int32]), [str])` | nud consumes first `::`, chain consumes second |
| `move x + 1` | `(move x) + 1` | move is a complete operand |
| `(a < b) == (c < d)` | comparison of comparisons | parenthesized operands are new expressions |

## Migration map

| Former ABNF rule (removed from Stilla Core Grammar Draft.abnf) | Now specified by |
| --- | --- |
| `expression` | this document, §[Parser algorithm](#parser-algorithm); the ABNF keeps the name as its statement-level point of contact |
| `logic-or`, `logic-and` | §[Binding power table](#binding-power-table), levels 1–2 |
| `comparison`, `comparison-op` | §[Binding power table](#binding-power-table), level 3, and §[Operator-by-operator notes](#operator-by-operator-notes) (non-chaining) |
| `bitwise-or`, `bitwise-xor`, `bitwise-and` | §[Binding power table](#binding-power-table), levels 4–6 |
| `shift`, `shift-op` | §[Binding power table](#binding-power-table), level 7 |
| `addition`, `add-op` | §[Binding power table](#binding-power-table), level 8 |
| `multiply`, `multiply-op` | §[Binding power table](#binding-power-table), level 9 |
| `unary`, `move-expression` | §[Prefix operators](#prefix-operators) |
| `cast` | §[Binding power table](#binding-power-table) (`as` row) and §[Operator-by-operator notes](#operator-by-operator-notes) |
| `postfix`, `postfix-suffix`, `member-suffix`, `call-suffix`, `specialization-suffix` | §[The postfix chain](#the-postfix-chain) |
| `primary`, `path-expression`, `path-tail`, `struct-field-init` | §[Primary forms and the path-expression decision table](#primary-forms-and-the-path-expression-decision-table) |
| `paren-or-tuple`, `list-literal`, `lambda`, `if-expression`, `match-expression`, `match-arm`, `import-expression`, `arg-list` | §[Primary forms and the path-expression decision table](#primary-forms-and-the-path-expression-decision-table) |
| `literal` | §[Primary forms and the path-expression decision table](#primary-forms-and-the-path-expression-decision-table); the tokens remain in the ABNF lexical grammar |
| parser note 2 (`::` after a type path), parser note 4's expression half (reserved-word member names) | §[The postfix chain](#the-postfix-chain) and the decision table |
