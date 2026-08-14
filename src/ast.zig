//! Abstract syntax tree and source locations — compile-time infrastructure
//! for diagnostics (Core §2: files are the unit of source text).
//!
//! Every AST node carries a `Span` — a half-open byte range into the
//! original source text — so the parser, type checker, and runtime traps
//! can all point at the exact text that caused a diagnostic. Nodes store
//! byte offsets rather than line/column pairs: offsets keep nodes small and
//! copy-friendly (Stilla targets machine-generated code, Core §1.1), and
//! line/column numbers are derived on demand from a per-source line index
//! when a message is rendered.

const std = @import("std");

/// Identifies one source file in a compilation, e.g. an index into the
/// compilation's source table.
pub const SourceId = u32;

/// A half-open byte range `[start, end)` into the text of the source
/// identified by `source`. Offsets are `u32` so a `Span` stays one word
/// per field; sources larger than 4 GiB are out of scope.
pub const Span = struct {
    source: SourceId,
    start: u32,
    end: u32,

    pub fn init(source: SourceId, start: u32, end: u32) Span {
        std.debug.assert(start <= end);
        return .{ .source = source, .start = start, .end = end };
    }

    /// Length in bytes of the covered text.
    pub fn len(self: Span) u32 {
        return self.end - self.start;
    }

    /// The smallest span that covers both inputs. The spans must belong to
    /// the same source.
    pub fn merge(a: Span, b: Span) Span {
        std.debug.assert(a.source == b.source);
        return .{ .source = a.source, .start = @min(a.start, b.start), .end = @max(a.end, b.end) };
    }
};

/// A 1-based line/column position, computed only when a diagnostic is
/// rendered. `column` counts bytes since the start of the line — matching
/// the byte offsets in `Span` — so Unicode text reports byte columns rather
/// than codepoint columns.
pub const Loc = struct {
    line: u32,
    column: u32,
};

/// One source file of a compilation, with a line index used to turn byte
/// offsets into `Loc` positions. The text is not owned: the compilation
/// keeps source text alive for the AST's lifetime.
pub const Source = struct {
    /// Display name for diagnostics, e.g. the file path.
    name: []const u8,
    id: SourceId,
    /// The whole source text; every `Span` offset indexes into it.
    text: []const u8,
    /// Byte offset of the start of each line. `line_starts[0]` is always 0.
    line_starts: std.ArrayList(u32),

    pub fn init(
        allocator: std.mem.Allocator,
        name: []const u8,
        id: SourceId,
        text: []const u8,
    ) !Source {
        var self: Source = .{
            .name = name,
            .id = id,
            .text = text,
            .line_starts = std.ArrayList(u32).empty,
        };
        try self.line_starts.append(allocator, 0);
        for (text, 0..) |ch, i| {
            if (ch == '\n') try self.line_starts.append(allocator, @intCast(i + 1));
        }
        return self;
    }

    pub fn deinit(self: *Source, allocator: std.mem.Allocator) void {
        self.line_starts.deinit(allocator);
    }

    /// Turn a byte offset into `text` into a 1-based line/column position.
    /// An offset past the end of the text lands on the final line.
    pub fn locOf(self: *const Source, offset: u32) Loc {
        std.debug.assert(offset <= self.text.len);
        const starts = self.line_starts.items;
        const count = std.sort.upperBound(u32, starts, offset, struct {
            fn cmp(ctx: u32, item: u32) std.math.Order {
                return std.math.order(ctx, item);
            }
        }.cmp);
        const start = starts[count - 1];
        return .{ .line = @intCast(count), .column = offset - start + 1 };
    }
};

/// One parse or lexical error: the offending source range and a
/// human-readable message. The parser records the first error it finds;
/// nothing after it is guaranteed to be meaningful.
pub const Diagnostic = struct {
    span: Span,
    message: []const u8,
};

// ---------------------------------------------------------------------------
// Names and programs
// ---------------------------------------------------------------------------

/// An identifier as written: its name and the span of the spelling.
pub const Ident = struct {
    span: Span,
    text: []const u8,
};

/// A whole source file's module: the `program` production (Grammar).
pub const Program = struct {
    items: []ModuleItem,
};

/// A top-level item: the `module-item` production (Grammar).
pub const ModuleItem = union(enum) {
    const_def: ConstDef,
    func_def: FuncDef,
    type_def: TypeDef,
    struct_def: StructDef,
    union_def: UnionDef,
    using_decl: UsingDecl,
};

// ---------------------------------------------------------------------------
// Module items
// ---------------------------------------------------------------------------

/// `const name [: type] = expression;` (Grammar `const-def`, Core §5).
///
/// When `init` is null the declaration is a **host binding** — a constant
/// with a declared type and no Stilla initializer, whose value the host
/// provides at runtime (frontend §5.6).
pub const ConstDef = struct {
    span: Span,
    name: Ident,
    type_: ?Type,
    init: ?*Expr,
};

/// `fn name [params] (params) [-> type] block` (Grammar `func-def`, Core §6).
/// Function types are monomorphic; generic parameters are permitted on named
/// function declarations but not on lambdas or function types (Core §6).
///
/// When `body` is null the declaration is a **host binding** — a signature
/// with no Stilla definition, whose calls the frontend lowers to system
/// calls (frontend §5.6; e.g. `builtin` members, Runtime §4).
pub const FuncDef = struct {
    span: Span,
    name: Ident,
    type_params: []Ident,
    params: []Param,
    ret: ?Type,
    body: ?*Block,
};

/// `type name [params] = type;` — a transparent alias (Grammar `type-def`).
pub const TypeDef = struct {
    span: Span,
    name: Ident,
    type_params: []Ident,
    target: Type,
};

/// `struct name [params] { field* [drop-decl] }` (Grammar `struct-def`,
/// Core §7). A struct may contain at most one `drop` declaration, after all
/// fields (§9.1).
pub const StructDef = struct {
    span: Span,
    name: Ident,
    type_params: []Ident,
    fields: []FieldDecl,
    drop: ?*DropDecl,
};

/// `name: type;` inside a struct body (Grammar `field-decl`).
pub const FieldDecl = struct {
    span: Span,
    name: Ident,
    type_: Type,
};

/// `drop (name) block` (Grammar `drop-decl`, Core §9.1).
pub const DropDecl = struct {
    span: Span,
    param: Ident,
    body: *Block,
};

/// `union name [params] { variant-decl* }` (Grammar `union-def`, Core §11).
pub const UnionDef = struct {
    span: Span,
    name: Ident,
    type_params: []Ident,
    variants: []VariantDecl,
};

/// `using path [as name];` — a scoped compile-time path alias (Grammar
/// `using-decl`, Core §2.8). Without `as`, the alias is the final path
/// segment.
pub const UsingDecl = struct {
    span: Span,
    path: []Ident,
    alias: ?Ident,
};

/// `name [( type, ... )]` — one variant of a named union (Grammar
/// `variant-decl`). `types` is null when the variant has no payload.
pub const VariantDecl = struct {
    span: Span,
    name: Ident,
    types: ?[]Type,
};

/// Ownership mode of a function or lambda parameter (Grammar `param`,
/// `function-param-type`; Core §6, §10).
pub const ParamMode = enum {
    plain,
    borrow,
    move,
};

/// One function parameter: `[borrow|move] name: type`.
pub const Param = struct {
    span: Span,
    mode: ParamMode,
    name: Ident,
    type_: Type,
};

// ---------------------------------------------------------------------------
// Types
// ---------------------------------------------------------------------------

/// The `type` production (Grammar). Children that recurse are arena
/// pointers; list-like children are slices of nodes.
pub const Type = union(enum) {
    primitive: Primitive,
    named: NamedType,
    list: ListType,
    box: BoxType,
    tuple: TupleType,
    function: FunctionType,

    /// The source span of any type node.
    pub fn span(self: *const Type) Span {
        return switch (self.*) {
            .primitive => |n| n.span,
            .named => |n| n.span,
            .list => |n| n.span,
            .box => |n| n.span,
            .tuple => |n| n.span,
            .function => |n| n.span,
        };
    }
};

/// A built-in scalar type (Grammar `primitive-type`).
///
/// `any` is the top type: every value type coerces to it (Core §11.6);
/// `never` is the bottom type, which has no values and coerces to every
/// type (Core §13.2); `hostdata` is an opaque, host-defined payload
/// (Core §11.7), created only by the host and unique like `any`.
pub const PrimitiveKind = enum {
    any,
    byte,
    hostdata,
    int32,
    uint32,
    float32,
    bool,
    str,
    void,
    never,
};

pub const Primitive = struct {
    span: Span,
    kind: PrimitiveKind,
};

/// `path [type-args]` — a named (possibly generic) type (Grammar
/// `named-type`). The path is a dotted identifier chain.
pub const NamedType = struct {
    span: Span,
    path: []Ident,
    type_args: ?[]Type,
};

/// `list[T]` (Grammar `list-type`).
pub const ListType = struct {
    span: Span,
    elem: *Type,
};

/// `box[T]` (Grammar `box-type`).
pub const BoxType = struct {
    span: Span,
    inner: *Type,
};

/// `tuple[T, ...]` — may be empty (Grammar `tuple-type`).
pub const TupleType = struct {
    span: Span,
    elems: []Type,
};

/// `fn (params) -> type` — the arrow is required in function types
/// (Grammar `function-type`; Core §6.3).
pub const FunctionType = struct {
    span: Span,
    params: []FunctionParamType,
    ret: *Type,
};

/// `[borrow|move] type` inside a function type (Grammar
/// `function-param-type`).
pub const FunctionParamType = struct {
    span: Span,
    mode: ParamMode,
    type_: *Type,
};

// ---------------------------------------------------------------------------
// Blocks and statements
// ---------------------------------------------------------------------------

/// `{ statement* [expression] }` — a block, with an optional final
/// expression. The final expression is distinguished from an expression
/// statement by the absence of a trailing semicolon (Grammar `block`).
pub const Block = struct {
    span: Span,
    stmts: []Stmt,
    result: ?Expr,
};

/// The `statement` production (Grammar). `drop` here is the explicit
/// destruction statement (Core §9.4), not the struct `drop` declaration.
pub const Stmt = union(enum) {
    let: LetStmt,
    drop: DropStmt,
    using: UsingDecl,
    expr: ExprStmt,
    empty: EmptyStmt,
};

/// `let pattern [: type] = expression;` (Grammar `let-stmt`, Core §4).
pub const LetStmt = struct {
    span: Span,
    pattern: Pattern,
    type_: ?Type,
    init: *Expr,
};

/// `drop name;` — explicit destruction of a local binding (Grammar
/// `drop-stmt`, Core §9.4).
pub const DropStmt = struct {
    span: Span,
    name: Ident,
};

/// `expression;` (Grammar `expr-stmt`).
pub const ExprStmt = struct {
    span: Span,
    expr: Expr,
};

/// `;` — a statement that does nothing (Grammar `empty-stmt`).
pub const EmptyStmt = struct {
    span: Span,
};

// ---------------------------------------------------------------------------
// Expressions
// ---------------------------------------------------------------------------

/// The `expression` production (Grammar). Children that recurse are arena
/// pointers; list-like children are slices of nodes.
pub const Expr = union(enum) {
    int: IntLiteral,
    float: FloatLiteral,
    string: StringLiteral,
    bool: BoolLiteral,
    void: VoidLiteral,
    path: PathExpr,
    paren: ParenExpr,
    tuple: TupleExpr,
    list: ListExpr,
    lambda: Lambda,
    if_: IfExpr,
    match: MatchExpr,
    import: ImportExpr,
    block: BlockExpr,
    unary: Unary,
    binary: Binary,
    move: MoveExpr,
    cast: Cast,
    member: Member,
    index: Index,
    call: Call,
    specialize: Specialize,

    /// The source span of any expression. Every variant carries its span as
    /// its first field.
    pub fn span(self: *const Expr) Span {
        return switch (self.*) {
            .int => |n| n.span,
            .float => |n| n.span,
            .string => |n| n.span,
            .bool => |n| n.span,
            .void => |n| n.span,
            .path => |n| n.span,
            .paren => |n| n.span,
            .tuple => |n| n.span,
            .list => |n| n.span,
            .lambda => |n| n.span,
            .if_ => |n| n.span,
            .match => |n| n.span,
            .import => |n| n.span,
            .block => |n| n.span,
            .unary => |n| n.span,
            .binary => |n| n.span,
            .move => |n| n.span,
            .cast => |n| n.span,
            .member => |n| n.span,
            .index => |n| n.span,
            .call => |n| n.span,
            .specialize => |n| n.span,
        };
    }
};

pub const IntLiteral = struct {
    span: Span,
    value: u64,
};

pub const FloatLiteral = struct {
    span: Span,
    value: f64,
};

/// The value is the decoded string content (escapes resolved by the lexer).
pub const StringLiteral = struct {
    span: Span,
    value: []const u8,
};

pub const BoolLiteral = struct {
    span: Span,
    value: bool,
};

/// `()` — the unique value of type `void` (Grammar `void-literal`).
pub const VoidLiteral = struct {
    span: Span,
};

/// An identifier-leading expression (Grammar `path-expression`): a dotted
/// path with optional type arguments, followed by one of the `path-tail`
/// forms — a struct construction brace, a union variant `:: name`, or
/// nothing (an ordinary value expression).
pub const PathExpr = struct {
    span: Span,
    path: []Ident,
    type_args: ?[]Type,
    tail: PathTail,
};

/// The `path-tail` production (Grammar). `.none` is the empty alternative:
/// the path is an ordinary value expression.
pub const PathTail = union(enum) {
    construct: StructConstruct,
    variant: VariantExpr,
    none: void,
};

/// `{ field: expression, ... }` after a type path (Grammar
/// `struct-field-init`; Core §8.1).
pub const StructConstruct = struct {
    span: Span,
    fields: []StructFieldInit,
};

pub const StructFieldInit = struct {
    span: Span,
    name: Ident,
    value: *Expr,
};

/// `:: name [( args )]` — construction of a named union variant (Grammar
/// `path-tail`; Core §11). `args` is null when the parens are absent.
pub const VariantExpr = struct {
    span: Span,
    name: Ident,
    args: ?[]Expr,
};

/// `( expression )` — parenthesized expression (Grammar `paren-or-tuple`).
pub const ParenExpr = struct {
    span: Span,
    inner: *Expr,
};

/// `( e, ... )` — a tuple literal with two or more elements, or one element
/// written with a trailing comma (Grammar `paren-or-tuple`).
pub const TupleExpr = struct {
    span: Span,
    elems: []Expr,
};

/// `[ e, ... ]` (Grammar `list-literal`).
pub const ListExpr = struct {
    span: Span,
    elems: []Expr,
};

/// `fn (params) [-> type] block` in expression position (Grammar `lambda`,
/// Core §6.3). Lambdas take no generic parameters.
pub const Lambda = struct {
    span: Span,
    params: []Param,
    ret: ?Type,
    body: *Block,
};

/// `if (cond) then [else (block | if)]` (Grammar `if-expression`, Core
/// §13.1). `else_` is null when there is no `else` branch.
pub const IfExpr = struct {
    span: Span,
    cond: *Expr,
    then: *Block,
    else_: ?*Expr,
};

/// `match (scrutinee) { pattern => expression, ... }` (Grammar
/// `match-expression`, Core §13.2).
pub const MatchExpr = struct {
    span: Span,
    scrutinee: *Expr,
    arms: []MatchArm,
};

pub const MatchArm = struct {
    span: Span,
    pattern: Pattern,
    body: *Expr,
};

/// `import ( "module" )` (Grammar `import-expression`, Core §2.2). The
/// string must be a literal token; static semantics restrict this form to
/// module-constant initializers.
pub const ImportExpr = struct {
    span: Span,
    module: []const u8,
};

/// A block in expression position (Grammar `primary` → `block`).
pub const BlockExpr = struct {
    span: Span,
    block: *Block,
};

/// `-operand` or `!operand` (Grammar `unary`, Core §16).
pub const UnaryOp = enum {
    neg,
    not,
};

pub const Unary = struct {
    span: Span,
    op: UnaryOp,
    operand: *Expr,
};

/// Binary operators by precedence level (Grammar `logic-or`, `logic-and`,
/// `comparison`, `addition`, `multiply`; Core §16). Comparison operators
/// are non-associative: `comparison` parses at most one comparison-op.
pub const BinaryOp = enum {
    or_,
    and_,
    eq,
    ne,
    lt,
    le,
    gt,
    ge,
    add,
    sub,
    mul,
    div,
    rem,
};

pub const Binary = struct {
    span: Span,
    op: BinaryOp,
    lhs: *Expr,
    rhs: *Expr,
};

/// `move name` — names a complete local binding to move (Grammar
/// `move-expression`, Core §10.3). There is no general borrow expression.
pub const MoveExpr = struct {
    span: Span,
    name: Ident,
};

/// `operand as type`, chained for repeated casts (Grammar `cast`, Core §16).
pub const Cast = struct {
    span: Span,
    operand: *Expr,
    target: Type,
};

/// `object.name` (Grammar `member-suffix`, Core §15).
pub const Member = struct {
    span: Span,
    object: *Expr,
    name: Ident,
};

/// `object@[index]` (Grammar `index-suffix`). The `@` marker keeps indexing
/// distinct from generic type arguments.
pub const Index = struct {
    span: Span,
    object: *Expr,
    index: *Expr,
};

/// `callee(args)` (Grammar `call-suffix`).
pub const Call = struct {
    span: Span,
    callee: *Expr,
    args: []Expr,
};

/// `operand::[types]` — generic specialization, accepted syntactically as
/// postfix syntax but eliminated during compile-time specialization
/// (Grammar `specialization-suffix` and the `path-tail` `:: type-args`
/// branch; Core §12).
pub const Specialize = struct {
    span: Span,
    operand: *Expr,
    type_args: []Type,
};

// ---------------------------------------------------------------------------
// Patterns
// ---------------------------------------------------------------------------

/// The `pattern` production (Grammar; Core §14).
pub const Pattern = union(enum) {
    wildcard: WildcardPattern,
    literal: LiteralPattern,
    type_test: TypeTestPattern,
    tuple: TuplePattern,
    path: PathPattern,
    list: ListPattern,

    /// The source span of any pattern.
    pub fn span(self: *const Pattern) Span {
        return switch (self.*) {
            .wildcard => |n| n.span,
            .literal => |n| n.span,
            .type_test => |n| n.span,
            .tuple => |n| n.span,
            .path => |n| n.span,
            .list => |n| n.span,
        };
    }
};

/// `_` (Grammar `wildcard-pattern`).
pub const WildcardPattern = struct {
    span: Span,
};

/// A literal in pattern position (Grammar `literal-pattern`). `neg_int` and
/// `neg_float` hold the magnitude; `string` is the decoded value.
pub const LiteralValue = union(enum) {
    int: u64,
    neg_int: u64,
    float: f64,
    neg_float: f64,
    string: []const u8,
    bool: bool,
};

pub const LiteralPattern = struct {
    span: Span,
    value: LiteralValue,
};

/// `type-test-type [identifier]` (Grammar `type-test-pattern`, Core §11.6.2,
/// §14.7): a concrete type name — keyword-led (`int32 n`, `str s`,
/// `list[int32] xs`) or identifier-led (`File f`, `Option[int32] o`) —
/// optionally followed by a binding identifier. It matches an `any` value
/// by runtime type tag; `binding` is null when the type stands alone.
pub const TypeTestPattern = struct {
    span: Span,
    type_: Type,
    binding: ?Ident,
};

/// `( pattern, ... )` — at least one pattern followed by a comma; `()` is
/// the empty tuple pattern matching the void value (Grammar
/// `tuple-pattern`). A single bare `(p)` is not a pattern.
pub const TuplePattern = struct {
    span: Span,
    elems: []Pattern,
};

/// An identifier-leading pattern (Grammar `path-pattern`): a dotted path
/// with optional type arguments and one of the `pattern-tail` forms — a
/// struct pattern brace, a union variant `:: name`, or nothing (an
/// identifier pattern binding the name).
pub const PathPattern = struct {
    span: Span,
    path: []Ident,
    type_args: ?[]Type,
    tail: PatternTail,
};

/// The `pattern-tail` production (Grammar). `.none` is the empty
/// alternative: an `identifier-pattern`.
pub const PatternTail = union(enum) {
    struct_: StructPattern,
    variant: VariantPattern,
    none: void,
};

/// `{ field, field: pattern, ... }` after a type path (Grammar
/// `field-pattern`). A field without `: pattern` is a shorthand
/// identifier-pattern binding the same name.
pub const StructPattern = struct {
    span: Span,
    fields: []FieldPattern,
};

pub const FieldPattern = struct {
    span: Span,
    name: Ident,
    pattern: ?Pattern,
};

/// `:: name [( pattern, ... )]` — a union variant pattern (Grammar
/// `pattern-tail`). `args` is null when the parens are absent.
pub const VariantPattern = struct {
    span: Span,
    name: Ident,
    args: ?[]Pattern,
};

/// `[ pattern, ..., ..rest ]` (Grammar `list-pattern`). `rest` is the
/// identifier bound by `..name`, when present.
pub const ListPattern = struct {
    span: Span,
    items: []Pattern,
    rest: ?Ident,
};

test "Span covers a byte range" {
    const s = Span.init(0, 4, 10);
    try std.testing.expectEqual(@as(u32, 4), s.start);
    try std.testing.expectEqual(@as(u32, 10), s.end);
    try std.testing.expectEqual(@as(u32, 6), s.len());
}

test "Span.merge covers both spans" {
    const s = Span.merge(Span.init(0, 4, 10), Span.init(0, 0, 6));
    try std.testing.expectEqual(@as(u32, 0), s.start);
    try std.testing.expectEqual(@as(u32, 10), s.end);
}

test "Source.locOf resolves line and column" {
    const text = "let x = 1\n  borrow x\n";
    var src = try Source.init(std.testing.allocator, "t.st", 0, text);
    defer src.deinit(std.testing.allocator);

    // First line starts at offset 0.
    try std.testing.expectEqual(Loc{ .line = 1, .column = 1 }, src.locOf(0));
    // Offset 4 is the `x` in `let x`, column 5 on the first line.
    try std.testing.expectEqual(Loc{ .line = 1, .column = 5 }, src.locOf(4));
    // Second line starts right after the newline; offset 12 is its `b`.
    try std.testing.expectEqual(Loc{ .line = 2, .column = 3 }, src.locOf(12));
    // End of file lands on the empty final line.
    try std.testing.expectEqual(Loc{ .line = 3, .column = 1 }, src.locOf(text.len));
}

test "Source.locOf clamps at end of file" {
    var src = try Source.init(std.testing.allocator, "t.st", 0, "abc");
    defer src.deinit(std.testing.allocator);

    try std.testing.expectEqual(Loc{ .line = 1, .column = 4 }, src.locOf(3));
}

test "Span.len is the byte count" {
    const s = Span.init(0, 4, 9);
    try std.testing.expectEqual(@as(u32, 5), s.len());
}

test "Span.merge joins non-overlapping spans" {
    const a = Span.init(0, 2, 5);
    const b = Span.init(0, 8, 12);
    const m = a.merge(b);
    try std.testing.expectEqual(@as(u32, 2), m.start);
    try std.testing.expectEqual(@as(u32, 12), m.end);
}

test "Source.locOf resolves line and column on multi-line text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var source = try Source.init(arena.allocator(), "t.st", 0, "ab\ncd\nef");
    // Line starts: 0, 3, 6. Offset 7 is the 'f' at line 3, column 2
    // (locOf is 1-based: line = 1 + newlines before, column = offset - start + 1).
    const loc = source.locOf(7);
    try std.testing.expectEqual(@as(u32, 3), loc.line);
    try std.testing.expectEqual(@as(u32, 2), loc.column);
}

test "Source.locOf clamps past the end of file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var source = try Source.init(arena.allocator(), "t.st", 0, "ab\ncd");
    // The end-of-file offset (== text.len) resolves to the last line.
    const loc = source.locOf(5);
    try std.testing.expectEqual(@as(u32, 2), loc.line);
    try std.testing.expectEqual(@as(u32, 3), loc.column);
}
