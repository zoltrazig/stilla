# Host bindings: a typed registry for Zig/C host functions

Design for replacing the single-string-switch host call with a comptime
registered, signature-checked binding table. This document is the
authority for the change; the Runtime spec's host contract (Runtime §3)
and the `.st` interface sources remain normative and unchanged.

## 1. Problem: how host calls look today

A host binding is a bodyless `fn` declaration in a host module interface
(`Sources.standard_library` text, e.g. `builtin`'s stdlib sources). The
frontend lowers calls to it as `syscall` instructions carrying a symbolic
`(module_symbol, member_symbol)` pair (phase3-cfg-lowering.md, "System
calls for host bindings"). At runtime `hSyscall` resolves the pair and
calls the embedding's adapter:

```zig
self.host.invoke(vm, self.host.userdata, mod_bytes, member, dd.signature_id, args)
```

where `HostCall.invoke` (interpreter_host.zig) is one hand-written
dispatch: `defaultHostCall` string-compares `(module_symbol, member)` and
forwards to a per-module adapter — `hostBuiltin`, `hostMath`,
`hostString`, `hostList`, `hostArray`, `hostHashMap`. Every adapter then
hand-decodes `args: []const Value` (cell → `strSliceOf` / `decodeScalar` /
payload-cell / cons-chain walk), hand-encodes the result (`ValueCodec`,
`newStr`, `allocObject`, `optionCell`, `wrapOpaque`), and hand-wires
retain/release and host-resource registration.

Pain points this change targets:

- **One giant switch**: adding a host module means editing core dispatch
  (`defaultHostCall`) or forking it; there is no per-module registration.
- **Raw cells everywhere**: the embedding decodes every argument by hand
  with VM-internal knowledge (`vm.runtime.heap.*`, `ValueCodec`).
- **`sig` is an artifact-local index, not signature data**; the adapters
  reach into `image.signatures[sig]` themselves (hostBuiltin,
  hostString, hostList, hostArray, hostHashMap) and resolve `TypeId`s
  through the artifact's types table by hand. There is no host-facing
  signature interface — the embedding receives `sig: u32` and nothing
  else, and each adapter re-implements the same resolution.
- **No C-ABI support**: a C function needs handwritten glue (str cells are
  length-prefixed, not NUL-terminated; canonical floats are `f32`).

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

Non-goals (explicitly out of scope for this change):

- **Frontend interface derivation.** The bodyless `.st` interface text
  stays the authoritative compile-time contract; `Sources.host` and the
  documented host-interface registry stay stubbed (frontend.md §2). No
  checker/LLIR/artifact changes.
- **Ownership transfer through typed glue.** `move` parameters, lists,
  unions, and retained/owned returns do not go through the typed layer;
  they use a raw-shaped member (`raw`, §3.3).
- Async/reentrant hosts and host-held borrowed VM values (interpreter-vm.md
  §9: synchronous host calls only).

## 3. API

### 3.0 The signature interface

Today there is no host-facing signature interface: `invoke` receives a
bare `sig: llir.SignatureId` and the adapters resolve it against the
artifact themselves. The redesign makes the signature first-class — a
zero-allocation view over the artifact's signature row, resolved once
by the syscall path and passed to every thunk. Hosts never touch
`TypeId` tables.

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

The syscall path builds the view once per call — bounds-checking
`dd.signature_id` (today's `defaultHostCall` range check) — so a thunk
can compare before decoding and never misdecode. `matches` rejects any
difference; a `move`-mode parameter fails immediately (typed glue
cannot honor ownership transfer).

### 3.1 Value wrappers (host.zig, new)

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
in llir.zig). Returns may also be `void` or `Str` (owned). `Opaque`
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
    /// parameter is the module-userdata injection point.
    pub fn query(s: host_bind.Str) i32 { return @intCast(s.bytes.len); }
    /// A C function, callconv(.c): strs map to `[*:0]const u8`
    /// (NUL-terminated via HostScratch, §6); scalar/void returns only.
    pub fn connect(s: [*:0]const u8) callconv(.c) c_int { ... }
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
3. calls the fn, encoding the result back into a cell.

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
/// full `sig` + `args` surface, exactly like today's adapters.
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

## 4. Dispatch (interpreter_host.zig, interpreter_dispatch.zig)

`HostCall.invoke` (the single-string-switch adapter) becomes an
**opt-out**: when set, every syscall dispatches through it and the
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
matches only `.composite`. Typed bindings declare `plain`-mode
parameters (the `?*anyopaque` first parameter is the module userdata
injection point, excluded from the signature); a `move`-mode runtime
parameter always fails — the typed glue cannot honor ownership
transfer, and the binding must use `raw()` instead.

A mismatch is a deterministic trap ("binding signature mismatch for
mydb.query"), never a misdecode. This catches embedding bugs (interface
`.st` and Zig binding disagree) at the first call instead of corrupting
values.

## 6. HostScratch: no per-call allocation

`VmRuntimeState.host_args` becomes

```zig
pub const HostScratch = struct {
    /// Argument staging (today's `host_args`): one canonical cell per
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
represented in a `[*:0]const u8`). The existing root-frame pre-size of
`host_args` (interpreter.zig `installRootFrame`) carries over to
`HostScratch.values`; `bytes` grows on demand like any scratch buffer.

C-ABI members return **scalar or void only**. `char *` returns are
excluded: ownership/freeing is ambiguous at the boundary.

## 7. Stdlib migration (staged — done)

One mechanism, two member kinds: generated typed thunks for members
whose Stilla signature is plain scalars/str, raw-shaped fns for
ownership-sensitive ones. Order:

1. **Registered as-is**: every `builtin`/`math`/`string`/`list`/`array`/
   `hashmap` member was a registry `Binding` via `raw()` trampolines
   around the existing adapters (a `moduleFromFields` helper deriving
   the member tables from the handler structs) — behavior identical,
   zero rewrites.
2. **Parity**: the interpreter_host_tests suite passed against the
   registry before any adapter was touched.
3. **Converted** *(done)*: the six modules are now module structs
   registered through `host_bind.register` (interpreter_host.zig).
   Members with a plain scalar/str signature bind typed — all 20
   `math` functions (`float32` in/out), `builtin.print`, and the four
   pure `string` predicates (`is_empty`/`contains`/`starts_with`/
   `ends_with`). Every other member is a raw-shaped fn carrying the
   adapter logic directly; the per-module member dispatch switches, the
   dispatch enums (`MathMember`/`StringMember`/`ArrayMember`/
   `HashMapMember`), and `moduleFromFields` are deleted.
4. **Handlers stay**: the host.zig handler structs (`DefaultHostCall`/
   `MathHostCall`/`StringHostCall`/`ListHostCall`) remain the
   implementations — the module members forward to them, so the
   host-customization surface (`Sources.host`) is untouched.
   `defaultHostCall` survives as the opt-out adapter: a registry
   dispatch used by dynamic-host `invoke` overriders to delegate
   non-intercepted members.

## 8. Tests

Staged in host_bind_tests.zig (new) and the existing suites:

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

- Frontend interface derivation from Zig (`Sources.host`, the host
  interface registry) — separate change.
- Typed ownership: `move`/`borrow` transfer, lists, unions, retained
  returns through the typed layer — stays on `raw()`. `BorrowedOpaque` and
  borrowed-`str` parameters are deferred.
- C string (`char *`) returns.
- Hosts that cannot enumerate members statically — the `invoke` opt-out
  covers them today.
