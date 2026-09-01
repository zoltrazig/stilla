# Host bindings: a typed registry for Zig/C host functions

How a Stilla host module — a specifier, a member table, and typed
functions — is declared and bound to Zig or C. The Runtime spec's host
contract (Runtime §3) and the `.st` interface sources remain normative.

## 1. How host calls work

A host binding is a bodyless `fn` declaration in a host module interface
(`Sources.standard_library` text, e.g. `builtin`'s stdlib sources). The
frontend lowers calls to it as `syscall` instructions carrying a symbolic
`(module_symbol, member_symbol)` pair (phase3-cfg-lowering.md, "System
calls for host bindings"). At runtime `hSyscall` resolves the pair against
the **registry** — a comptime-built, sorted member table (§3, §4) — and
calls the member's thunk with a resolved signature view and the decoded
canonical cells:

```zig
thunk(vm, module_userdata, sig, args)
```

The default path is the registry; a dynamic host (one that cannot
enumerate members statically) opts out by setting `HostCall.invoke`
(§4), which bypasses the registry entirely. The registry replaced the
earlier single-string-switch dispatch `defaultHostCall`, which survives
only as that opt-out adapter.

A member thunk never misdecodes: it signature-checks the call (§5)
before decoding cells into typed parameters (§3), so an interface that
disagrees with its Zig binding is a deterministic trap at the first call
rather than corrupted values. C functions bind directly through
`callconv(.c)` members.

## 2. Goals and non-goals

Goals:

- One host module = a specifier + a member table + typed functions.
- A module is a struct: `register(M)` derives the member table —
  argument decode and result encode from each member fn's Zig signature.
- A C function binds directly: a `callconv(.c)` member with `[*:0]const u8`
  parameters (e.g. `fn connect(s: [*:0]const u8) callconv(.c) c_int`).
- Ownership-sensitive members keep a **raw** escape hatch (the existing
  adapter logic, unchanged).
- The stdlib modules migrate onto the same registry mechanism.

Non-goals (out of scope today):

- **Frontend interface derivation.** The bodyless `.st` interface text
  is the authoritative compile-time contract the frontend checks call
  sites against (§3.4). For a typed member it can now be *derived* from
  the binding's Zig signature (`interfaceOf`), so the two can't drift;
  the `Sources.host` interface *registry* (automatic discovery without
  the embedder supplying each interface) stays future work (§9).
- **Ownership transfer through typed glue.** `move` parameters, lists,
  unions, and retained/owned returns do not go through the typed layer;
  they use a raw-shaped member (`raw`, §3.3).
- Async/reentrant hosts and host-held borrowed VM values (interpreter-vm.md
  §9: synchronous host calls only).

## 3. API

### 3.0 The signature interface

The signature is a first-class host-facing interface: a zero-allocation
view over the artifact's signature row, resolved once by the syscall path
and passed to every thunk. Hosts never touch `TypeId` tables.

```zig
/// Host-facing projection of a Stilla type, resolved from a `TypeId`
/// through the artifact's `types` table. The typed layer binds the
/// primitive/str/opaque/hostdata/any subset; any other type
/// (list, tuple, struct, union, box) resolves to `.composite` and can
/// only be bound by a `raw()` handler.
pub const HostType = enum {
    void, bool, byte, int32, uint32, i64, u64,
    float32, float64, str, any, hostdata, opaque_, composite,
    // wildcard: expected-signature marker only, matches any runtime type
};

pub const HostParam = struct { mode: llir.ParamMode, ty: HostType };

/// Comptime-declared expected signature (built from a bound function's
/// Zig parameter types) — plain data, no artifact.
pub const ExpectedSignature = struct { params: []const HostParam, ret: HostType };

/// The resolved signature view. `desc` is the artifact's own
/// `SignatureDesc` row (params point into the flat `params` table —
/// borrowed, never copied); `image` resolves types on demand.
pub const HostSignature = struct {
    image: *const llir.LlirProgram,
    desc: llir.SignatureDesc,
    pub inline fn paramCount(self: HostSignature) usize;
    pub inline fn param(self: HostSignature, i: usize) HostParam; // mode + resolved type
    pub inline fn ret(self: HostSignature) HostType;
    /// Element-wise compare against a comptime expected signature
    /// (mode exact; `.composite` matches only itself).
    pub fn matches(self: HostSignature, expected: ExpectedSignature) bool;
};
```

The syscall path builds the view once per call, bounds-checking
`dd.signature_id` — so a thunk
can compare before decoding and never misdecode. `matches` rejects any
difference; a `move`-mode parameter fails immediately (typed glue
cannot honor ownership transfer).

### 3.1 Value wrappers (host.zig)

Bare pointers are ambiguous (str vs opaque payload vs hostdata; borrowed
vs owned), so typed bindings declare parameters with explicit wrappers:

```zig
/// A Stilla `str`: borrowed in (valid during the call only), owned out
/// (the VM allocates the str object).
pub const Str = struct { bytes: []const u8 };

/// An opaque value's host payload (`cell 0` of the `.opaque_` shell).
/// The id is the stable host identity (e.g. "mydb.Database"), carried
/// for future verification against the shell's declared host type.
pub fn Opaque(comptime id: []const u8) type;

/// Pass one canonical cell through unchanged (`any`, `hostdata`, or
/// anything a raw handler wants to see).
pub const RawValue = struct { value: Value };
```

Scalars map directly: `bool`, `i32`, `u32`, `i64`, `u64`, `f32`, `f64`
and the C-ABI `c_int`/`c_uint` (Stilla primitive widths: `PrimitiveId`
in llir.zig). Returns may be `void`, a scalar, `Str` (owned — the
thunk allocates the str object), `RawValue` (the member allocated the
result itself — e.g. a str/list/union object through the hidden ctx),
or `HostResult` (typed arguments with a full raw body: allocation,
panics). A return may be an error union over any of these: the thunk
turns the error into a deterministic trap (§5). Two hidden leading
parameters are excluded from the signature: `?*anyopaque` or `*T`
module userdata (a typed `*T` is cast by the generated thunk, so
members read their state directly — random_demo.zig) and `*HostCtx`
adapter context (the VM plus the current call's signature, with the
shared adapter helpers). `Opaque`
parameters are accepted in v1 (payload pass-through); `BorrowedOpaque`
and borrowed-`str` parameters are deferred — a `borrow`-mode parameter
uses a `raw()` handler instead.

### 3.2 A module is a struct

A host module is declared as a plain struct: `pub const symbol` names the
module; every `pub fn` is a member binding. `register(M)` derives the
sorted member table at comptime — one generated thunk per member:

```zig
const mydb = struct {
    pub const symbol = "mydb";
    /// Typed member: scalars, host.Str, host.Opaque, host.RawValue, and
    /// C-ABI types ([*:0]const u8, c_int, ...). A leading `?*anyopaque`
    /// or `*T` parameter is the module-userdata injection point — a
    /// typed `*T` is cast by the generated thunk, so members read their
    /// state directly (random_demo.zig); a leading
    /// `*HostCtx` is the adapter context (the VM + the current call's
    /// signature, plus the shared decode/alloc/trap helpers).
    pub fn query(s: host_bind.Str) i32 { return @intCast(s.bytes.len); }
    /// A C function, callconv(.c): strs map to `[*:0]const u8`
    /// (NUL-terminated via HostScratch, §6); scalar/void returns only.
    pub fn connect(s: [*:0]const u8) callconv(.c) c_int { ... }
    /// Hidden ctx + error return: the thunk maps the error to a
    /// deterministic trap ("concat: <spec message>", §5).
    pub fn concat(ctx: *host_bind.HostCtx, a: host_bind.Str, b: host_bind.Str) host_module.StringErr!host_bind.RawValue { ... }
    /// Typed arguments with a raw body: signature-checked and decoded,
    /// but the member keeps full control (unions, lists, panics).
    pub fn index_of(ctx: *host_bind.HostCtx, haystack: host_bind.Str, needle: host_bind.Str) interp_types.HostResult { ... }
    /// Raw member: the (vm, userdata, sig, args) thunk shape registers
    /// raw — no signature check, the full surface for ownership-sensitive
    /// members.
    pub fn backup(vm: *interpreter.VmCtx, userdata: ?*anyopaque, sig: interp_types.HostSignature, args: []const vm_types.Value) interp_types.HostResult { ... }
};
const mydb_desc: host_bind.ModuleDesc = host_bind.register(mydb);
```

Every fn in the module struct is a member — helpers live at file scope.
Each member's generated thunk:

1. checks the expected signature (see §5);
2. decodes each canonical cell according to the declared parameter type,
   trapping deterministically on mismatch — never misdecoding;
3. calls the fn, mapping an error-union result to a deterministic trap
   (§5) and encoding the result back into a cell.

### 3.3 Registry

```zig
pub const Binding = struct {
    name: []const u8,
    /// Normalized from the function type at comptime (§3.0 shapes:
    /// mode fixed by the wrapper type, type by the wrapper).
    expected: HostSignature,
    thunk: *const fn (vm: *VmCtx, userdata: ?*anyopaque, sig: HostSignature, args: []const Value) HostResult,
};

pub const ModuleDesc = struct {
    symbol: []const u8,
    members: []const Binding, // sorted by name (binary search)
};

pub const RegisteredModule = struct {
    desc: *const ModuleDesc,
    /// Module-level context, injected separately from the VM's
    /// `HostCall.userdata`; not a Stilla parameter. This is where a C
    /// module's database handle lives.
    userdata: ?*anyopaque,
};

pub const HostRegistry = struct {
    modules: []const RegisteredModule, // sorted by symbol
};

/// Hand-written handler for ownership-sensitive members. `raw` gets the
/// full `sig` + `args` surface.
pub fn raw(comptime name: []const u8, comptime f: anytype) Binding;
```

A module is registered at comptime — the struct is the value:

```zig
const mydb_desc: ModuleDesc = host_bind.register(mydb); // mydb from §3.2
const registry = HostRegistry{ .modules = &.{ .{ .desc = &mydb_desc, .userdata = &db } } };
```

`register` derives `members` from the struct's fns (sorted, each with its
`expected` signature); a fn with the raw thunk shape gets `expected =
null` (raw, no check).

### 3.4 The worked example: random_demo.zig

The runnable embedding example is `examples/embed/random_demo.zig` —
`zig build embed` compiles it, runs it, and prints the round trip it
observed. It is the demonstration of everything in §3, so the excerpt
below is deliberately thin; the file is the single source of truth.

The embedder gives Stilla a `random` host module (a plain struct: `pub
const symbol` names the module, every `pub fn` is a member binding). A
leading `*Rng` parameter is the module's injected state — the generated
thunk comptime-casts the registered userdata, so members read `Rng`
directly, never a Stilla parameter. `register` derives the sorted,
signature-checked member table; `interfaceOf` renders the `.st` text the
frontend checks call sites against, so the Zig signatures and the
interface can't drift:

```zig
const random = struct {
    pub const symbol = "random";
    pub fn next(rng: *Rng) i32 { /* ... */ }
    pub fn int(rng: *Rng, max: i32) i32 { /* ... */ }
    pub fn seed(rng: *Rng, s: i32) void { rng.prng = ...; }
    pub fn time(rng: *Rng) i32 { /* reads the host clock through std.Io */ }
};
const random_desc: host_bind.ModuleDesc = host_bind.register(random);
const random_iface = host_bind.interfaceOf(random, "");
// fn next() -> int32;  fn int(arg0: int32) -> int32;
// fn seed(arg0: int32) -> void;  fn time() -> int32;
```

(Parameter names render as `arg0`, `arg1`, … — call sites are
positional. Members whose concrete Stilla signature can't be derived —
`raw()` thunks, `RawValue`/`HostResult` returns, borrow/`move` modes —
are skipped; pass their lines as `interfaceOf`'s second argument,
appended verbatim.)

The Stilla side imports it as an ordinary module; each call lowers to a
`syscall` dispatched through the registry:

```stilla
const random = import("random");
const builtin = import("builtin");
fn main() -> int32 {
    random.seed(random.time());
    let a = random.next();
    let b = random.int(6);
    builtin.print("draw b");
    builtin.print(builtin.str(b));
    a + b
}
```

`builtin.print` has no runtime default (§7) — the embedder supplies the
output sink as a `PrintHook` with its own userdata and an `invoke`
callback; the CLI `--run` mode passes one that writes to stdout.

Compile, lower, and run through the two-stage embed path (`buildProgram`
builds the source/interface maps, compiles, lowers, and merges the
module into the default host registry; `runProgram` executes the built
program, so one build runs many times):

```zig
var failed: stilla.frontend.Compilation = undefined;
var built = stilla.interpreter.buildProgram(arena, .{
    .entry = "app",
    .sources = &.{.{ .specifier = "app", .text = APP }},
    .ifaces = &.{.{ .specifier = "random", .text = random_iface }},
    .modules = &.{.{ .desc = &random_desc, .userdata = &rng }},
    .entry_fn = "main",
    .print = .{ .userdata = &print_sink, .invoke = appPrint },
}, &failed) catch |err| switch (err) {
    error.CompileFailed => {
        // render failed.diag.message, then
        return error.CompileFailed;
    },
    else => return err,
};
const term = try stilla.interpreter.runProgram(arena, &built);
```

The example then verifies the round trip: the run's `Termination` switch
checks that `main`'s return equals the draws the host observed. The
layered API this wraps (`frontend.compile`, `ArtifactBundle.build`,
`runWithHostAndLoader` — interpreter-vm.md §11) stays available for
embedders who need finer control; on a compile failure the failed
compilation comes back through the `&failed` out-param for its
diagnostic.

## 4. Dispatch (interpreter_host.zig, interpreter_dispatch.zig)

`HostCall.invoke` is an **opt-out**: when set, every syscall dispatches through it and the
registry is bypassed (the pre-registry adapter contract, kept for
dynamic hosts and existing embedders). The default path is the
registry:

```zig
pub const HostCall = struct {
    userdata: ?*anyopaque = null,
    registry: HostRegistry = defaultHostRegistry,
    /// Opt-out: when set, `registry` is bypassed entirely.
    invoke: ?InvokeFn = null,
};
```

`hSyscall` (interpreter_dispatch.zig) resolves the `(module_symbol,
member_symbol)` bytes against the registry: binary search the sorted
module list, then the sorted member list, then call
`thunk(vm, module_userdata, sig, args)` with `sig` the resolved
`HostSignature` view (§3.0). Misses are a deterministic
`not_implemented` trap (today's behavior for unknown members). Lookup
is O(log n) byte compares — no allocation, no hand switch.
`defaultHostRegistry` is the stdlib table (§7).

## 5. Signature verification

The Zig function type is the contract, but not trusted blindly: before
decoding, the thunk calls `sig.matches(self.expected)` — its
comptime-normalized `HostSignature` (§3.0) against the resolved view
of the artifact's actual signature for the call. The comparison is
element-wise: param count, each param's mode and type, and the return
type. `matches` is exact: a `Str` binding requires a `str` param, an
`Opaque` binding requires an `opaque` type, a `.composite` expected
matches only `.composite`. `RawValue` maps to a wildcard that accepts
any type, and `HostResult` returns skip the return check. Typed
bindings declare `plain`-mode parameters (a hidden leading `?*anyopaque`
module-userdata or `*HostCtx` adapter-context parameter is excluded
from the signature); a `move`-mode runtime parameter always fails —
the typed glue cannot honor ownership transfer, and the binding must
use `raw()` instead.

A mismatch is a deterministic trap ("binding signature mismatch for
mydb.query"), never a misdecode. This catches embedding bugs (interface
`.st` and Zig binding disagree) at the first call instead of corrupting
values.

An error-union return is also a deterministic trap: the thunk formats
`"{member}: {message}"` into the VM's panic scratch, where the message
is the spec text for the stdlib string errors (`InvalidUtf8` → "invalid
UTF-8", `Range` → "index out of range", `BadCodepoint` → "not a
Unicode scalar value", `OutOfMemory` → "out of memory") and the
error name otherwise.

## 6. HostScratch: no per-call allocation

Per-call scratch (argument staging and C-string buffers) is a reusable
`HostScratch` on the runtime state:

```zig
pub const HostScratch = struct {
    /// Argument staging: one canonical cell per
    /// parameter, gathered by hSyscall.
    values: std.ArrayList(Value) = .empty,
    /// C-string staging: reusable NUL-terminated byte buffer.
    bytes: std.ArrayList(u8) = .empty,
};
```

C-string members (`[*:0]const u8` parameters) use `bytes`, never the
allocator per call: the thunk first
computes the total length of all `[*:0]const u8` parameters, resizes
`bytes` once, writes each string with its NUL terminator (stable
pointers — fill after the single resize), calls `f`, and discards. An
embedded NUL in a Stilla string traps deterministically (it cannot be
represented in a `[*:0]const u8`). The root frame pre-sizes
`HostScratch.values` (interpreter.zig `installRootFrame`); `bytes` grows on demand like any scratch buffer.

C-ABI members return **scalar or void only**. `char *` returns are
excluded: ownership/freeing is ambiguous at the boundary.

## 7. The standard-library modules

One mechanism, several member kinds: generated typed thunks for members
whose Stilla signature is expressible, raw-shaped fns for
ownership-sensitive ones. The six stdlib modules (`builtin`, `math`,
`string`, `list`, `array`, `hashmap`) are plain module structs
registered through `host_bind.register` (interpreter_host.zig); 47 of the
60 members are typed bindings with signature checks:

- plain typed — all 20 `math` functions (inlined `std.math`),
  `builtin.assert`/`panic`, the four pure `string`
  predicates, `string.len` (error return);
- hidden `*HostCtx` + error return — the `string` producers
  (`concat`/`substring`/`trim`/`lower`/`upper`/`replace`/`repeat`,
  returning `StringErr!RawValue` with the result str allocated
  directly);
- hidden `*HostCtx` + `HostResult` body (typed arguments, raw
  body) — `builtin.print`/`str`/`hash`, `string`
  `index_of`/`split`/`to_utf8`/`to_codepoints`, `list.range`;
- the rest bind typed-args through `RawValue`/wildcard params
  (`builtin.str`/`hash`).

The member implementations are plain `pub` fns in host.zig
(`hostStr`..`hostHash`, `stringLen`..`stringFromCodepoints`,
`listLen`/`listRange`); `defaultHostCall` survives only as the opt-out
adapter for dynamic hosts (§4).

`builtin.print` is a host hook, not a default implementation: it
dispatches to the `HostCall.print` hook (`PrintHook` — a callback plus
its own userdata); without one, `print` resolves through the registry to
a `not_implemented` trap. The runtime has no `std.Io` output dependency —
the embedding decides where program output goes. The CLI `--run` mode
passes a hook that writes message + newline to its `Io`'s stdout; the
embed path (`RunProgramOptions.print`) passes the hook through
`buildProgram`.

**Still raw** (13 members, by design, §9): `list.len` (borrow mode),
all of `array` (borrow/move + opaque) and `hashmap` (borrow/move +
opaque), `builtin.box`/`unbox` (move), and the `string` members with
list parameters (`join`, `from_utf8`, `from_codepoints`).

## 8. Tests

In host_bind_tests.zig and the existing suites:

1. typed Zig scalar + `Str` bindings round-trip values;
2. arity/type/mode mismatches trap deterministically (signature check);
3. module-level userdata injection (distinct from `HostCall.userdata`);
4. `bindC`-style members: scalar + C-string bindings, embedded-NUL rejection, scratch
   reuse (no allocation per call — assert via allocator counter);
5. unknown module/member → `not_implemented` trap; duplicate member
   rejected at comptime;
6. `raw()` handlers keep list/array/hashmap ownership semantics
   (existing interpreter_host_tests + lifecycle tests);
7. full `zig build test --summary all` regression.

## 9. Out of scope / future

- `Sources.host` and the host interface **registry** — automatic
  discovery of each host module's interface without the embedder
  supplying it (§3.4 uses `interfaceOf` per module; the registry stays
  future work).
- Typed ownership: `move`/`borrow` transfer, list/union/opaque
  **parameters**, retained returns through the typed layer — stays on
  `raw()` (the mode check rejects them deterministically). List/union
  **returns** are handled by hidden-ctx members returning `RawValue` or
  `HostResult`. `BorrowedOpaque` and borrowed-`str` parameters are
  deferred.
- C string (`char *`) returns.
- Hosts that cannot enumerate members statically — the `invoke` opt-out
  covers them today.
