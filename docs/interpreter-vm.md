# Stilla Interpreter VM

> **Status:** implementation design for the Stilla v1.3 LLIR interpreter
> (v10 encoding).
>
> The LLIR Specification owns the program image, registers, frames, and
> call/return contract. The LLIR Instruction Set owns instruction encoding,
> operand validation, and opcode semantics. The Runtime Specification owns
> observable execution, destruction, modules, host integration, and
> termination. This document owns only the interpreter choices left open by
> those specifications.

## 1. Design assessment

The existing LLIR is a good interpreter boundary: it has fixed-width
instructions, explicit call windows, validated side tables, and explicit
counted-value lifecycle records. The VM can therefore be a direct executor;
it does not need an SSA evaluator, a runtime type map for registers, or a
second ownership analysis.

The first design should stay deliberately small:

- one validation boundary and **token-based indirect threading** (§7): a
  comptime handler table indexed by the decoded opcode, one tail-jump
  (`@call(.always_tail, ...)`) per instruction;
- one flat cell stack and one 16-cell temporary bank;
- boxed aggregates with explicit reference counting where LLIR requests it;
- one iterative destruction walker;
- lazy module initialization and reverse-order normal teardown;
- a typed host-call boundary and immediate panic/trap termination.

Three v10 properties are decisive before implementation:

1. **The opcodes carry their numeric semantics.** The integer arithmetic
   families are widthless (`add`, `div`/`divu`, `shri`/`shriu`, …) — they
   compute on the full 64-bit cell, splitting only by signedness where the
   operation differs; a 32-bit type's modulo-2³² semantics are explicit in
   the lowering's `sext32`/`zext32` sequences around the widthless opcode.
   The float families carry the width in the opcode (`add.f64`,
   `seq.f32`); integer comparisons and branches carry only signedness
   because 32-bit integer cells are already canonicalized. The interpreter
   reads signedness and immediate interpretation straight from the decoded
   opcode. There is **no load-time typed dataflow analysis and no execution
   plan**: loading decodes the wire records once into the VM's own
   fixed-size instruction image (§7, §11), and the dispatch reads the
   opcode and its fields straight out of that image.
2. **Cells are fixed raw `u64` with no inline type information.** A cell is
   the value itself: there is no VM-internal `ValueKind` tag and no
   fixed-width payload field, so no bit pattern is reserved for type
   information. A fixed width keeps behavior and tests identical across
   hosts. The type of a value is fixed by its opcode (a float rep, an
   integer signedness, or a canonicalization sequence) and the
   descriptor-carried types, never by bits in the cell; pointers occupy
   the full host address width in the cell and are validated against the
   live-object and host-resource registries before dereference.
3. **Context cleanup cannot recover types by scanning untyped, reused cells.**
   The implementation must track live host-owned pointers as they cross the
   host boundary, as required by the Runtime Specification's live-resource
   inventory. The registry proposed below is not a handle table and does
   not change the value stored in a cell.

## 2. Scope

The interpreter consumes the final `LlirProgram`:

```text
source -> CFG -> optimize -> drop lowering -> LLIR lowering
       -> allocation -> lifecycle planning -> fusion -> LlirProgram
       -> structural validate -> interpreter
```

At this point the frontend has already established SSA dominance, ownership,
borrow validity, drop placement, register allocation, and call-window layout.
The interpreter:

- executes every valid opcode according to the LLIR Instruction Set;
- performs frame transfers according to the LLIR Specification;
- owns runtime values, module instances, host calls, and termination;
- treats a validated image as immutable for the duration of a run.

The first version does not include a JIT, concurrency, exceptions, debugger
snapshots, suspension, a stable binary ABI, or dispatch specialization
(dispatch specialization is structurally unnecessary in v10 — the opcodes
are already specialized).

## 3. Core invariants

These invariants should appear near the `VmCtx` type and be asserted in focused
tests:

1. `pc` always names an instruction in the current function, except while the
   VM is entering or leaving a frame.
2. `fp` names the first F cell of the current frame and `sp` names the first
   unused stack cell.
3. F/X/T cells are untyped storage. A handler obtains type and layout from
   its decoded opcode (the rep), its descriptor, its signature, or the heap
   object header — never from the cell and never from a load-time plan.
4. No cell carries type information. An operand's type is exactly what its
   opcode says (the rep), and dereference/destruction types come from the
   object header and the descriptor tables.
5. T0–T15 are one VM-global volatile bank. `jal ra`/`jalr`/non-self
   tailcalls logically clobber them; the VM does not clear them.
6. A counted owner changes its reference count only at an explicit lifecycle
   instruction or at an opcode whose specification creates a new owner.
7. A unique owner is transferred or destroyed exactly once on normal control
   flow. Panic and trap do not unwind.
8. A host-owned pointer is registered exactly once when it enters VM
   ownership and unregistered exactly once when it leaves VM ownership or is
   destroyed.
9. An instruction either completes its specified effects or terminates the
   context at its defined trap point. In particular, checks that must precede
   writes or ownership transfer do so — the call entry validates the window,
   the take-at-return-pc contract, and the frame end before writing
   the header, `ra`, or `fp`; a static `jal` target was resolved and
   entry-checked at load, a `jalr` target is resolved and entry-checked
   before the call.

The VM does not maintain shadow slot types, initialized-bit maps, borrow
records, predecessor state, or per-frame cleanup masks.

## 4. Runtime state

Use one VM per active run; there is no separate context object. The raw
cell type and value codecs (`ValueCodec`, `decodeScalar`, `newStr`) live in
`vm_types.zig`, along with the heap (`VmHeap` — allocation and the
provenance registry, which `newStr`/`decodeScalar` take by pointer); the
interpreter owns one `VmHeap` instance plus the execution structures and
dispatch:

```zig
const Value = vm.Value;

const VmCtx = struct {
    allocator: std.mem.Allocator,
    /// The `ModuleLoader` provider callback: how execution obtains more
    /// code at runtime. Runtime `module_ref`/`load_member` resolution
    /// (`resolveImport`) can lazily load a module during execution, so
    /// the provider is an execution dependency; the publication
    /// algorithms themselves stay in `interpreter_loader.zig`.
    provider: ModuleLoader = .{},
    /// The loaded data (`VmLoadedData`, §8): the decoded instruction
    /// arena, the function registry, the loaded modules, and the root
    /// identity — what the loader produces and execution reads.
    loaded: VmLoadedData = .{},
    /// The runtime state (`VmRuntimeState`, §8): every per-run mutable
    /// resource — the value stack, the register file `fast_regs`, the
    /// execution position `pc`/`sp`/`fp`/`current_fn`, run status
    /// `running`/`terminated`, the dispatch-chain out-of-band state
    /// `result`/`pending_err`/`popped_hook_cont`, and the execution
    /// resources below (the heap, the host-resource and
    /// string-constant registries, the destruction-work and
    /// continuation stacks, the host scratch
    /// (argument cells + C-string bytes, docs/host-bindings.md §6),
    /// and the panic scratch buffer) — where execution is. No
    /// default: the heap requires the allocator at construction.
    runtime: VmRuntimeState,
    stack_limit: u32 = 1 << 20,
    /// Host-binding dispatch (phase 6): the default adapter implements
    /// the required `builtin` interface; an embedding replaces it to
    /// provide its own host modules.
    host: HostCall = .{},
};

/// The runtime state in full: the execution position plus every
/// per-run resource. `VmCtx.runtime` owns all of these; the loaded
/// data (`VmLoadedData`) is the only other per-context state.
const VmRuntimeState = struct {
    stack: std.ArrayList(Value) = .empty,
    fast_regs: [llir.fast_reg_count]Value = .{0} ** llir.fast_reg_count,
    pc: u32 = 0,
    sp: u32 = 0,
    fp: u32 = 0,
    current_fn: llir.FunctionId = 0,
    running: bool = false,
    terminated: bool = false,
    result: ?Termination = null,
    pending_err: ?RunError = null,
    popped_hook_cont: bool = false,

    heap: VmHeap,
    host_resources: std.AutoHashMapUnmanaged(u64, HostResource) = .empty,
    string_consts: std.AutoHashMapUnmanaged(u64, Value) = .empty,
    destroy_work: std.ArrayList(DestroyWork) = .empty,
    continuations: std.ArrayList(Continuation) = .empty,
    /// Per-call host scratch (argument cells + C-string bytes).
    host_scratch: HostScratch = .{},
    /// Scratch buffer for `panicFmt` messages.
    panic_buf: [1024]u8 = undefined,
};
```

`VmCtx` is the run context: the fixed configuration (the allocator, the
module-loading provider, the host adapter, the stack limit) plus the
loaded data (the program image plus the loaded modules and host-module
registrations — `VmLoadedData`, §8) plus the runtime state
(`VmRuntimeState` — the value stack, the fast register bank, the
`pc`/`sp`/`fp`/`current_fn` execution position,
`running`/`terminated`, the threaded-dispatch out-of-band state
(`result`/`pending_err`/`popped_hook_cont`, §7), and every per-run
resource: the heap, the host-resource and string-constant registries,
the destruction-work and continuation stacks, the host scratch
(argument cells + C-string bytes), and the panic scratch buffer). The
split is by
kind, not by mutability: lazy loading
and hot-reload mutate the loaded data during a run (appending modules,
repointing `module_by_symbol`, flipping initialization state, filling
slots and caches), while the runtime state is everything that changes
with the run and dies with it.

`VmCtx` owns the allocator, the module instances and their slots, host
registrations, the live host-resource registry, and termination data. The
listing above is the current `interpreter.VmCtx`; treat `interpreter.zig` as
the source of truth for field types and defaults. There is no link-register
field: a call writes `ra = pc + 1` into the frame's
`saved_ra` cell and `returnFrom` restores `pc` from it (§7). There is no
validator artifact and no `ValidatedLlir`: `validate(image)` returns after
its checks and the interpreter runs the same `image`. The one stream the run
image owns beyond the artifact is the decoded instruction image —
`loaded.code` above, filled once per module at load with exactly one
`VmInstr` per wire record (§7). Nothing is allocated per *executed*
instruction; decoding is a load-time, not a step-time, cost.

The first implementation runs to completion. Do not add a public snapshot
type until a debugger or suspension feature has concrete requirements.

### 4.1 Stack allocation

The stack grows dynamically but has a configurable cell limit. At the call
record, before writing any callee-frame header or changing `fp`/`sp`, the VM
checks arithmetic, checks the limit, and reserves the full callee frame.
Failure leaves no partial callee frame. The preceding `slot_*` records have
already performed their specified ownership effects; they are not rolled back
because the trap terminates the whole context without unwinding.

Growing the backing allocation may move it, so handlers must not retain a
pointer into `stack` across a call, allocation, host callback, or destruction
hook. A cached current-frame slice may be refreshed after those operations.

### 4.2 Register access

Keep register decoding in small helpers:

- F registers address `stack[fp + n]` for `n < f_count` — the frame's own
  locals;
- the **window aliases** — `n >= f_count`, i.e. the header reserve
  `F(f_count)`, `F(f_count+1)`, `F(f_count+2)` and the output aliases `O(0)..O(O-1)` —
  address `stack[callBase(fp, f) + (n - f_count)]`, equivalently
  `stack[fp + x_count + n]` (the X cells are never register-addressed);
- T registers address `fast_regs[temp_base + n]`;
- `zero` reads the zero defined by the operand context and discards writes
  (one register, dual role);
- `ra` is the link register — addressable only through the `jal`/`jalr`
  handlers and the return path;
- `cond` is the dedicated boolean condition register (`fast_regs[1]`);
  the zero/cond/ra/T block `[0, frame_base)` indexes `fast_regs` directly (one
  bounds check per access, Instruction Set §3.1.1);
- no other register encoding exists — validation rejects everything else.

X spill cells are addressed only by `spill_take`/`spill_put`'s `imm16` and
output-window cells by `slot_*`'s `imm16` — those instructions use their
dedicated physical addressing, not the register path.

## 5. Value representation

Every cell is one raw `u64`; there is no kind field, no payload mask, and
no bit pattern reserved for type information. The canonical scalar
encodings are frozen by the Runtime Specification §7.2:

| Scalar | Canonical cell |
| --- | --- |
| `bool` | exactly `0` or `1` |
| `byte` | low 8 bits; bits 63-8 zero |
| `int32`/`uint32`/`float32` | raw low 32-bit pattern; bits 63-32 zero |
| `i64`/`u64` | all 64 bits (two's-complement / raw unsigned pattern) |
| `f64` | all 64 bits of the IEEE 754 binary64 pattern; NaN payload lossless |

All scalar zeros therefore share the single all-zero cell: `bool(false)`,
`byte(0)`, `int32(0)`, `uint32(0)`, `float32(+0.0)`, `i64(0)`, `u64(0)`,
and `f64(+0.0)` are all `0x0000_0000_0000_0000`. No typed zero retains a
distinguishing bit pattern; the type of a zero is supplied by the opcode's
rep, never by the value.

**Type provenance.** An operand's numeric representation is part of its
opcode. `add` computes on the full 64-bit cell (a 32-bit result is
canonicalized by the explicit `sext32` in its sequence), `add.f64` on the
IEEE binary64 pattern, `divu` on the unsigned 64-bit pattern — there is
nothing to resolve at load time. The expected `TypeId`
of every dereferenced or destroyed value comes from the object header and
the descriptor tables. Object headers carry the concrete `TypeId` of heap
values; dereference validates the header kind against the operation (§5.1).
The VM maintains no shadow slot-type table, no runtime type map for
registers, and never touches a validation plan.

| Value family | Cell representation |
| --- | --- |
| scalar (`byte`/`bool`/`int32`/`uint32`/`i64`/`u64`/`float32`/`f64`) | the canonical scalar pattern above |
| `str`, non-empty `list[T]`, `box[T]`, struct, tuple, union, `any` | VM-object pointer at the full host address width |
| empty `list[T]` | the all-zero cell — null under a list type |
| opaque host type, `hostdata` | host pointer at the full host address width |
| Stilla function | **executable entry PC** (a raw `u64` instruction index; `jalr` adds its signed 16-bit offset) |
| module | `ModuleId` (raw `u64` value) |

**Null is not a general pointer.** A zero cell under a list type is the
empty list and is the only legal null. A zero cell under `str`, `box[T]`,
struct, tuple, union, `any`, opaque, or `hostdata` is invalid: the VM traps
before dereferencing it. Pointer values are full-width host addresses —
there is no 48-bit limit, no handle table, and no pointer compression.

**The `zero` operand register** produces the all-zero cell for the scalar
type its instruction's rep requires. Because the all-zero pattern is the
canonical zero of every scalar type, the pattern alone never identifies the
type: the rep supplies it. `copy cond, zero` is unambiguous (bool);
`ret zero` returns a zero or `false` for a void/Copy return; a general
`copy dst, zero` for a non-bool type is materialized as a typed `const` by
the lowering, and `cmov` with two `zero` sources is rejected.

**Pointer safety is registry-validated, not magic-validated.** A pointer
cell is dereferenced only in a fixed order: registry membership (the
live-object registry in `VmHeap` for VM objects, the host-resource registry
for host pointers) → alignment/range → `ObjectHeader.type_id`/layout match. The VM
never dereferences a pointer to read a magic value first — reading a header
*is* the dereference the membership check protects. A pointer that is not
in the registry, or a forged scalar pattern used as a pointer, traps before
any dereference.

Copy, move, borrow, spill, argument, and return transfers copy the complete
raw cell; no transfer validates, masks, or rewrites bits.

### 5.1 VM-owned objects

VM-owned heap objects are self-describing. The header lives at the start of
one allocation; payload cells follow it contiguously (`cells[0..total_cells]`),
and the live-object registry in `VmHeap` maps the full-width cell value to the
header without dereferencing it (§6.4):

```zig
const ObjectHeader = struct {
    kind: ObjKind,            // str_ | list_cons | box_ | tuple_ | struct_ | union_ | any_ | opaque_
    type_id: TypeId,          // the concrete type this object was created for
    len: u32,                 // str: byte length; list_cons: suffix length (the
                             //   element count from this node to the end, so
                             //   `list#len` and `read_index` read the head's
                             //   stored count in O(1)); other kinds keep 0
    track: union(enum) {      // per-object lifecycle tracking
        CopyValue: u32,       //   counted shells (str/list/box): the reference count
        UniqueValue: bool,    //   unique shells: the struct drop hook ran once
    },
    total_cells: usize,
    cells: [*]Value,
};
```

The exact allocation kind and layout follow `type_id` through the program's
type tables; there is no outer representation class stored in the cell — a
pointer cell's validity comes from registry membership and its header's
`type_id` (§5). Only `any` additionally stores a runtime payload `TypeId`
in its object. Counted shells (str/list/box) carry their reference count in
`track.CopyValue`; every other kind is uniquely owned, and structs whose
declared drop hook runs once per object use `track.UniqueValue` as the
hook-ran flag.

Payload shapes are intentionally simple:

- `str`: byte length followed by owned bytes;
- `list[T]`: an immutable cons node containing cached suffix length, one
  element cell, and a pointer to the next node; the empty list is null;
- `box[T]`: one payload cell;
- struct or tuple: one cell per field or element;
- union: variant tag followed by active payload cells;
- `any`: payload `TypeId` and one payload cell.

One cell per component keeps aggregate access independent of host ABI layout.
The cons representation makes `tail` a pointer to the next node. For a
statically Unique base the result is borrowed, with no allocation or retain,
and its lifetime is anchored by the base borrow. For a Copy base the result is
an owned implicit copy, so the next node is retained. Consuming `split_list`
can transfer the head cell and next-node ownership only when the consumed node
has one reference; if it is shared, the handler retains/copies the outputs and
releases the consumed base owner. `read_index` is O(n), which is acceptable for
the first version because source list access is pattern-based. A flat array
plus slice views is a measured future optimization.

### 5.2 String constants

At VM initialization, create one object per distinct string constant record
and keep a loader-owned pointer table indexed by `ConstId`. The table owns one
reference for the whole run. Executing `const` retains it for the new value;
VM disposal releases the table's references after execution has stopped.

This produces one string representation without a dangling cache, immortal
flags, or separate constant-string branches in every string handler.

### 5.3 Borrowed values

A borrowed aggregate is the same pointer copied without retain. A borrowed
scalar is the same bit pattern. The frontend guarantees that its root remains
alive, so the VM needs no borrow table or root/path representation.

## 6. Ownership and destruction

### 6.1 Counted lifecycle

The lifecycle pass already emits `release`, `copy_retain`, argument-retain,
replacement, and fused return records. The interpreter executes their exact
ordering and never infers liveness from frame contents.

Some data opcodes also create owners and therefore retain as specified, for
example a counted field read, a counted element read, construction from a
counted component, or copy-packing a counted value into `any`. Transfer
operations do not alter the count.

Use two internal primitives (implemented as `retainCell(addr)` and
`destroyValue(type_id, addr)`):

```text
retain(pointer)
destroy(type_id, value)
```

`retain` applies only to counted VM objects. `destroy` dispatches by the
type's runtime mode:

- plain: no action;
- counted: decrement and, at zero, enqueue the object's children and free it;
- structural unique: enqueue children in required reverse order;
- `any`: destroy its payload using the runtime payload type;
- opaque or `hostdata`: invoke host disposal and unregister the pointer.

The lifecycle opcodes first check the descriptor/header-resolved type of
their source: `release` and `copy_retain` accept only `str`, `list`, or
`box`. For an empty list, only the reference-count action is a no-op:
`copy_retain`, `slot_retain`, and `replace_copy` still write the
complete empty-list cell (the all-zero cell) to their destination, while
`release` still consumes its source owner. `destroy(type_id, value)`
destroys the value by `type_id`'s exact type metadata; for a pointer value
it first validates the pointer through the registry and the object's
`ObjectHeader.type_id` (a forged or stale pointer traps before any
structural work — the cell itself carries no tag that could be checked
instead). The `type_id` comes from the opcode's descriptor or the object
header; there is no tag-based catch for corrupt cells, because validated
execution cannot produce a type mismatch between a cell and its opcode —
such a mismatch is a VM or host-contract bug.

The current LLIR treats `str`, `list[T]`, and `box[T]` as counted runtime
containers even where the source type is statically Unique because of a
Unique component. Static ownership still prevents copying such a source
value; when its final container reference reaches zero, the nested Unique
components are destroyed once.

### 6.2 Iterative destruction walker

Destruction uses `destroy_work`, not Zig recursion. This prevents host-stack
overflow for deeply nested boxes or lists and provides a natural suspension
point when a user drop hook must run.

Each work item contains only the information needed to resume one step:

```text
DestroyWork = value { type_id, addr }        // destroy addr as type_id
            | free_obj: *ObjectHeader        // children already handled
            | resume_struct { type_id, h }   // resume after a struct drop hook
```

Do not encode a general coroutine framework. The required behavior is:

1. run a struct's hook while all fields remain valid;
2. destroy fields/elements/payloads in the order required by the Runtime
   Specification;
3. free VM-owned storage after its children have been transferred or
   destroyed;
4. stop immediately if a hook panics or traps.

Consuming destructure operations free the consumed shell but skip payload
cells transferred to destinations. Non-consuming reads retain only when the
result establishes a new counted owner.

### 6.3 Host-resource registry

Host pointers remain direct full-width pointer values in raw cells rather
than handles. Separately, the VM keeps a registry (`host_resources`) keyed
by the pointer value with the disposal identity needed by the host:

```text
host pointer -> host type/disposer
```

Register after a successful host call has transferred a pointer into VM
ownership. Unregister immediately before transferring it back to the host or
after successful normal destruction. If a host call fails before transfer is
committed, ownership remains with the side that held it on entry.

On context disposal, invoke each still-registered host disposer exactly once.
No Stilla drop hook runs on this path. The registry is required because
untyped cell reuse makes a reliable typed stack replay impossible; it is
cleanup bookkeeping, not an alternate value representation.

Host callbacks returning an opaque or `hostdata` owner must return a non-null,
newly transferred, non-aliased pointer. Returning the same owned pointer twice
is a host-contract violation and traps before the second value is committed.
Pointer-address reuse is valid after the previous resource has been
unregistered.

The Runtime Specification defines this context-level live-resource inventory;
it replaces an earlier stack-scan description that was incompatible with
unrestricted cell reuse and the absence of slot types.

### 6.4 Allocation and OOM

Every VM object is individually allocated and registered in the live-object
registry (`VmHeap`), keyed by the header's address. Normal destruction
removes and frees an object at its specified lifetime end. On panic or trap,
disposal walks the registry and frees the remaining allocations without
running structural destruction or Stilla hooks; registered host pointers are
disposed separately.

Allocation failure after dispatch begins is a deterministic out-of-memory
trap. A handler reserves every fallible destination allocation, continuation,
destroy-work entry, or registry slot before it consumes a source or publishes
a destination. If a host result cannot be registered, dispose that
uncommitted result immediately and then trap. If copying the original panic
message fails, return a static out-of-memory message so termination itself
does not allocate recursively.

On normal termination, disposal first completes module teardown and then
releases loader-owned string references. On every termination path it next
disposes the host-resource registry and raw-frees anything still in the
live-object registry. It also deinitializes the stack, constant-pointer table,
continuation buffer, destruction-work buffer, module slots/log, and registry
storage; these buffers are not heap objects.

## 7. Execution loop and frames

The interpreter is **token-based indirect threaded** (§1, §7): the
**token** is the decoded opcode (`VmInstr.op`), indexing a comptime
handler table; each instruction is **one indirect jump** to its
per-opcode handler, and each handler **tail-jumps**
(`@call(.always_tail, ...)`) to the next instruction's handler — no
call/return *between* handlers and no per-instruction loop back-edge. (The
common tail makes one `drainDestroyWork()` call per instruction, but it's
guarded: an empty destruction queue is a cheap branch-skip, not a call — see
`next` below.) The wire format is never re-decoded on the execution path.

```text
// entry — called only by `step` and `runLoop`:
dispatch(n):
    v = code[pc]
    always_tail handlers[v.op](self, n)

// common chain tail — drain (may arm a hook → moves pc), stop at the
// step budget, fetch the next token, jump to its handler:
next(n):
    if destroy_work is not empty:
        drainDestroyWork()        // may arm a hook → moves pc
    if n == 1: return          // step mode: exactly one instruction
    v = code[pc]
    always_tail handlers[v.op](self, n - 1)

// fallthrough ops (everything but transfer control):
fallthrough(n):
    pc += 1
    next(n)
```

The handler table is `[max tag + 1]Handler` indexed by
`@intFromEnum(op)` — `Opcode` has sparse explicit tags (1–234 with
holes), so the raw array is the dense index space; the comptime
initializer fills it with an exhaustive per-tag switch, and any tag
left unassigned fails the compile (the completeness guard, §12).
Reserved/non-dispatchable opcodes (`auipc`/`lui`) map to a trap
handler; hole slots are dead because `decodeInstr` rejects reserved
words at load.

Handlers fetch their own instruction from `code[self.pc]` at entry —
`pc` always points at the executing token (transfer handlers move it
only for the *next* instruction), so the 8-byte `VmInstr` never
crosses the always_tail boundary (Debug-mode codegen misplaces a
by-value extern struct argument there; see §7). The chain
carries only `(self, n)` — the chain reads `code[pc]` for the opcode
and the handler re-fetches its instruction (two loads per instruction,
versus one in the switch loop; measured worth it in §7).

Terminations and errors stop the chain **out-of-band** in `VmCtx` fields:
`stop(t)` sets `result`, `fail(e)` sets `pending_err`, and the chain
returns to `step`/`runLoop` instead of carrying a return value. `step`
= `dispatch(self, 1)` + field translation to the public `!?Termination`
contract (unchanged). `runLoop` = `while (!terminated) {
dispatch(self, maxInt); … }` — a whole instruction segment per
iteration; the chain stops only at a termination, an error, or a
drop-hook continuation resume (`popped_hook_cont`), which the run loop
re-drives after draining.

Transfer-control handlers (`j`/`jal`/`jalr`/`jr`/`switch`/`ret`/
`release_ret`/`tailcall_self`) set `pc` and end `next(n)`; every other
handler ends `fallthrough(n)` (advance, then the common tail). The
`pc_moved` flag is not needed: the chain shape encodes the distinction
(transfer handlers never fall through).

Every dispatch reads the opcode's type, width, and immediate interpretation
from the decoded opcode itself — there is no per-PC plan to consult.
Validation makes malformed operand shapes unreachable. Runtime-dependent
checks remain in handlers: bounds, division traps, dynamic tags, indirect
signatures, stack capacity, and computed control-flow targets.

Do not repeat the frame arithmetic here. Implement `enterCalleeId`,
`returnFrom`,
and `tailcallSelf` directly from the LLIR Specification §5 and keep parity
tests against `MiniVm` in `frontend_llir_normalize_tests.zig`. The v10 model
is the three-cell header `{ saved_fp, saved_fn, saved_ra }` with the
Itanium-style window overlap. A static `jal`'s callee registry index is
resolved at load time (publishArtifact rewrites the instruction's operand),
so the direct call reads it straight from the image; the dynamic `jalr`
target is resolved by `enterJalr`, which validates the target is a function
entry. Both hand off to the shared `enterCalleeId`, which validates P/R/A,
window bounds (
`A ≤ O` — the value area plus its header must fit the caller's output
window), the take-at-return-pc contract (relaxed for static `jal` when the
call was coalesced onto the result alias — Step 8 — but strict for `jalr`,
whose take's source register is the only dynamic `A`-mismatch check), and
the full callee frame end, then sets
`ra = pc + 1`, writes the header, switches `fp`/`sp`, and jumps to the
entry; `returnFrom` publishes the result into the callee's `F0` (the
caller's register `F(L+3+O-A)`), restores the caller frame, restores
`ra` from `saved_ra`, and jumps; `tailcallSelf` reuses the frame and
preserves `ra`: it moves each prepared window slot `W - P + k` into the
reused frame's parameter cell `Fk` (clearing the window slot — the
`slot_*` preparation records honor their ownership forms at runtime,
`slot_retain` retaining the counted source and `slot_move` transferring
it, Instruction Set §5.5/§11.2), then jumps to the entry.

Frame-header cells are ordinary raw cells read **by position**: the fixed
three-cell header at `fp - 3` is decoded as `{ saved_fp, saved_fn,
saved_ra }`, and each field's range and sentinel values are checked before
use — `saved_fp` must be the caller's frame base (strictly below
the current `fp`) or the root `invalid_pc` sentinel; `saved_fn` a valid
function registry index (or the root sentinel); `saved_ra` a valid
executable pc within `funcs[saved_fn]`'s code range, `vm_internal_pc`, or
the root `invalid_pc` sentinel. The three equal
`0xffff_ffff` sentinels are distinguished by the header field's position,
never by cell bits. The canonical payload sentinels are:

| Name | Payload | Use |
| --- | --- | --- |
| `invalid_pc` | `0xffff_ffff` | root `saved_fp`, root `saved_fn`, and root `saved_ra` |
| `vm_internal_pc` | `0xffff_fffe` | runtime continuation return |

The header field's position distinguishes the three equal `0xffff_ffff`
values. A load is valid only when every executable pc is below
`vm_internal_pc`; therefore the sentinel never collides with a program
value. Sentinels live in the corresponding header field, never in a
distinct sentinel encoding.

### 7.1 Runtime-initiated calls

The runtime has two reasons to call Stilla code outside a LLIR call handler:
module initialization and a dynamic struct drop hook. Reuse the ordinary
frame convention (the three-cell header) and add only a small VM
continuation stack.

`vm_internal_pc` distinguishes these calls from normal LLIR returns and root
return. A continuation is one of:

- resume the instruction that triggered module initialization;
- enter the root function after its module initialization;
- resume the destruction walker.

The load-time range rule in §7 guarantees that the sentinel is outside the
instruction range. Nested initialization and nested hooks then follow ordinary
stack nesting. No general callback or suspension abstraction is needed.

### 7.2 Instruction failure ordering

Handlers must make ownership-changing failure points explicit:

- check list bounds before producing or transferring an element;
- check an `any` tag before unpacking;
- validate an indirect target and signature before entering its frame
  (`enterJalr` resolves the dynamic target; `enterCalleeId` validates the
  full contract before any write);
- reserve the complete frame before writing its header;
- retain the source before releasing an aliased destination in
  `replace_copy`;
- copy a panic message before freeing the storage that backs it.

These cases deserve direct tests because a visually equivalent reordering can
cause leaks, double drops, or use-after-free.

## 8. Modules

A `RuntimeModule` is the VM-owned record of one loaded module, identified
by its canonical symbol (byte-exact; the VM never resolves importer-relative
paths — canonicalization is the compiler's job):

```text
RuntimeModule {
    symbol: []u8,               // canonical module symbol
    state: loading | loaded | initializing | initialized,
    image: *LlirProgram,        // the parsed per-module artifact
    code_base: u32,             // image base in `code` (vm_pc = code_base + llir_pc)
    code_len: u32, func_base: u32,
    slots: []Value,             // module constant slots (Runtime §2.5)
    slot_log: ArrayList(u32),   // teardown log: slots written by @init, in store order
    import_cache: []?u64,       // resolved member values, by import-descriptor index
    owned_image: bool, is_host: bool,
}
```

Runtime module loading lives in `interpreter_loader.zig`: the top-level
loader functions (`loadModule`, `publishRoot`, `publishArtifact`,
`abortLoad`) generate and maintain a `VmLoadedData`, the loaded data
execution reads through `VmCtx.loaded`. `loadModule(symbol)` publishes at most
one module per symbol: the cached module returns immediately; otherwise a
provisional `.loading` registry
entry (cycle detection) is created, the `ModuleLoader` provider returns
either allocator-owned artifact bytes or a registered host module, the
bytes are parsed and structurally validated **without loading imports**,
decoded and relocated with every resulting pc checked, and the registry
entry, code range, and caches are committed atomically. Any earlier failure
removes the provisional entry and frees all temporary state — a malformed
load never exposes a partial module. Load errors are `module_not_found`,
`invalid_artifact`, and allocation failure; missing members, kind
mismatches, and init/load cycles are deterministic runtime traps at the
resolving instruction. The root module loads eagerly at startup;
dependencies are **eager at module level** — each demand (a `module_ref`
or an imported member first needed) loads its whole module through the
complete fetch → parse → validate → decode → publish sequence before any
instruction of that module can execute. Successful member resolutions cache
in the importing module's `import_cache` by import-descriptor index.

The `VmLoadedData` is the loader functions' product: the append-only decoded
instruction arena, the relocated function registry, and the loaded modules (one
replaceable slot per canonical symbol). It stays minimal — modules are
discrete units that can be re-published, which is what the hot-reload entry
point `reloadModule` does: it re-fetches, re-parses, re-validates, and
re-decodes a loaded module's artifact through the provider and atomically
repoints `module_by_symbol` (and the root identity, when the reloaded module
is the root) at the fresh version, returning its new registry index. Superseded
versions remain resident in the append-only arenas (live pcs stay valid, and
`VmLoadedData.deinit` frees every appended image exactly once), and every
other module's `import_cache` is cleared so import resolution re-targets the
new module on demand. Quiesce contract: reload is only sound when no running frame
references the old image, so it is refused while the VM is executing (`reloadModule`
takes both the loaded data and the runtime state for this check) — the
caller must drain the VM first (run to termination, or never start it). On
failure the old module is untouched: the provisional load is rolled back
(`abortLoad`) and the previous mapping restored, so a bad artifact never
displaces the running image.

Initialization is decoupled from loading (Runtime §2.3): `module_ref` loads
the target, initializes it if needed, then publishes its handle; `load_member`
resolves the target's sorted export row after initialization and returns the
function pc, slot value, nested module handle, or a clear error for
non-first-class host bindings; `syscall` resolves the same
`(module_symbol, member_symbol)` pair through a host-module descriptor —
host modules are ready after registration and have no Stilla initializer.
`ensureModule` runs a module's init function exactly once with a
`vm_internal_pc` continuation that flips the state to `initialized` on
return; seeing `initializing` or `loading` from a re-entrant resolution is
a deterministic cycle trap, never silent reuse of partially initialized
storage.

Record successful slot initialization in one context-wide log. Normal
termination walks that log backward — reverse initialization order —
destroying module-owned Unique slots and releasing counted slots. Panic
and trap skip this teardown; context disposal still releases registered
host resources and raw-frees remaining live-object allocations.

## 9. Host boundary

Resolve a syscall through its descriptor to a host binding, then dispatch by
the binding's module and member identity. Host bindings lower only to
`syscall`; indirect calls (`jalr`) accept executable entry PCs only. The
host boundary and the typed binding layer are specified in
host-bindings.md; this section covers the interpreter-side contract.

`hSyscall` (interpreter_dispatch.zig) resolves the syscall's import
descriptor — the `(module_symbol, member_symbol)` byte pair in the
executing artifact's `imports` table — into a `HostSignature` view (the
artifact's signature row, resolved once; hosts never touch `TypeId`
tables, host-bindings.md §3.0), then dispatches through `HostCall`: the
member-table registry (`defaultHostRegistry`, the stdlib modules) by
default, or the opt-out `invoke` adapter when set. Same-named members in
different modules (`string.len` vs `list.len`) reach different handlers
via the member tables; a module or member with no handler reports
`not_implemented`, which the syscall dispatch turns into a deterministic
trap.

The six stdlib modules are module structs registered through
`host_bind.register` (host-bindings.md §7): members with a plain
scalar/str signature bind typed (all 20 `math` functions, `builtin.print`,
and the four pure `string` predicates), and every other member is a
raw-shaped fn carrying the adapter logic directly — the per-module
member dispatch switches are deleted. `defaultHostCall` survives as the
opt-out adapter: a registry dispatch that dynamic-host `invoke`
overriders delegate non-intercepted members to.

Each member (typed or raw) is responsible for:

- checking the descriptor/signature before crossing the boundary;
- translating `str` to a borrowed byte slice;
- exposing list borrows through read-only accessors rather than raw mutable
  storage (walking cons chains, reading the head node's stored suffix
  length);
- passing opaque and `hostdata` pointers without reinterpretation;
- passing `any` as an opaque tagged payload;
- committing ownership transfers and updating the host-resource registry;
- converting the host result into the declared Stilla representation
  (allocating str/list/union objects, encoding scalars).

The adapters keep the VM heap mechanics (decode cells, walk lists, allocate
objects); the handler structs in `host.zig` (`DefaultHostCall`,
`MathHostCall`, `StringHostCall`, `ListHostCall`) receive only verified
plain data and never touch the VM (M2). The typed member machinery
generates the same decode/encode glue from a Zig/C function
signature, with signature verification against the artifact before
decoding (host-bindings.md §3, §5). The string handlers operate on code
points, never byte offsets; their errors map to owned deterministic trap
messages (StdLib §5, Runtime §7.2).

M3 opaque host objects (`array`, `hashmap`): each value is a heap shell
(`allocObject(.opaque_, ...)`) whose payload cell 0 holds the host object
pointer (`ArrayObject`/`HashMapObject` storage in `host_array.zig`/`host_hashmap.zig` — plain data,
no VM knowledge). The shell is registered in the host-resource registry
keyed by its address, so `drop` (the `.opaque_` destruction arm) and panic
teardown run the module disposer exactly once; the disposer releases every
stored cell and frees the host object, while the destruction machinery frees
the shell. The adapters own the retain/release contract: elements are
retained on store (`make`/`insert`/`set`/`clone`), `get` retains the
returned copy, `remove` transfers the value into the result `Option` and
releases the stored key, overwrite releases the displaced cells, and
release goes through a registry-checked helper so scalars and non-counted
Copy shells (e.g. `Option[int32]` elements) never reach the counted
lifecycle opcodes. Key hashing/equality for `hashmap` mirror `builtin.hash`
(Wyhash, seed 0) and `==` (str content equality); key types outside
`builtin.hash`'s supported set (primitive scalars + str) trap
deterministically — the frontend does not reject them today.

Keep box/unbox inside the VM even if they arrive through builtin syscall
records, because they manipulate VM-owned object layout. Other builtin and
host-module functions go through registered host callbacks.

The initial host API should be synchronous. Reentrancy, asynchronous host
calls, and host-held borrowed VM values are out of scope; adding any of them
would require an explicit lifetime contract.

## 10. Panic, traps, and disposal

All runtime traps and `builtin.panic` enter one termination path:

1. create an owned termination message;
2. mark execution terminated;
3. stop dispatch immediately;
4. skip local destruction, pending destroy work, and module teardown;
5. dispose registered host resources without invoking Stilla hooks;
6. raw-free remaining allocations through the live-object registry;
7. return `Termination.panic` to the host.

Normal return runs module teardown before steps 5-7 and returns
`Termination.normal`.

The first version reports a stable message plus numeric `FunctionId` and `pc`
when useful. A symbolic name table is deferred until the binary or CLI has a
real debug-metadata design.

Arithmetic handlers must use explicit wrapping and trap checks rather than
depending on Zig build mode. The LLIR Instruction Set and Runtime
Specification are the source of truth for division overflow, remainder,
floating-point, shifts, and numeric conversions — the rep of the decoded
opcode selects the width and signedness.

## 11. Loading and public API

Keep deserialization separate from execution:

```text
read binary -> LlirProgram -> validate -> run
```

Binary and in-memory inputs are untrusted at the public API. Bounds-check
deserialization (rejecting any version other than the current format
version before a single table count is decoded), then run the structural
validator — shape, range, tag,
and bound checks only; there is no typed dataflow analysis and no plan to
derive — before allocating runtime objects or invoking host code.
Validation occurs once per load, not once per instruction. **The VM
executes its own decoded instruction image**: loading decodes every 4-byte
LLIR record once into a fixed 8-byte `VmInstr` (`op: VmOpcode`, three
register bytes, and a `u32` operand) — exactly one decoded instruction per
LLIR record, in the same order, so `vm_pc = module.code_base + llir_pc`
always identifies the corresponding instruction and every pc stays stable
for the run. `step` indexes `VmInstr` directly and never re-decodes the
wire format. The decoded image is append-only: loaded modules are cached
and never relocated or unloaded, so existing pcs and frames remain valid.
The in-place interpretation contract of earlier versions is retired.

The minimal library surface is:

```zig
pub fn run(allocator: std.mem.Allocator, image: *LlirProgram) RunError!Termination;
```

`run` enters the artifact's recorded entry export (`entry_member`) through
the symbolic resolver. `runWithHost` takes an explicit `HostCall` — a
member-table registry plus an opt-out adapter (`host_bind.register`
derives a module from a struct: `pub const symbol` + `pub fn` members,
host-bindings.md §3) — instead
of the default stdlib registry; `runWithEntry` runs from an explicit
module-local `FunctionId`; the `*AndLoader` forms (`runWithEntryAndLoader`,
`runWithHostAndLoader`) resolve cross-module references through a
`ModuleLoader` — a whole-program artifact bundle or an embedding's provider
— instead of the no-op default; `runValidated` structurally validates
`image` first and then runs that same image.

`RunError` covers setup failures that occur before Stilla execution begins,
such as an invalid image or unsupported platform. Once execution starts,
language panic, runtime traps, and OOM are returned as `Termination`, not Zig
errors. The initial standalone entry contract is `fn() -> void`; other
signatures are setup errors until a separate embedding-call API defines
argument and result ownership.

Before entering the entry function, the root module initializes eagerly
through the same `vm_internal_pc` continuation mechanism used by
`module_ref` (Runtime §3.3). A `VmCtx` is
single-use: `run` constructs it, transitions it from created to running to
terminated, and completes cleanup before returning; a run cannot be resumed.

Put value encoding in `vm_types.zig` and the execution implementation in
`interpreter.zig`; runtime module loading lives in
`interpreter_loader.zig` — the loader functions build the
`VmLoadedData` the `VmCtx` executes against; `VmCtx` carries the
`ModuleLoader` provider (runtime `module_ref`/`load_member` can load
lazily during execution). Re-export the public
modules from `root.zig`. Binary loading remains a thin caller of `read` and
`run`; the interpreter itself accepts an in-memory program.

CLI integration: `stilla --run <input>` executes. An input
starting with the LLIR magic loads through `readBin` → `validateLlir` →
`run`, executing from the header's symbolic entry member — the binary
header carries the module symbol and entry member (binary format version
16), so a serialized artifact is self-contained and needs no side
information (D3). Anything else compiles the whole dependency closure
(entry plus `-I` imports and the embedded standard library) into one
per-module artifact bundle and runs the root artifact through
`runWithHostAndLoader`/`runWithEntryAndLoader` with the bundle's loader —
real cross-module programs execute, not just what the optimizer inlines
away. Exit codes: 0 normal termination, 1
Stilla panic (the owned message — which records the trap site, §10 —
goes to stderr), 2 load/compile error.

## 12. Test strategy

Black-box interpreter tests belong in `interpreter_tests.zig` and are wired
through `root.zig`. Small white-box tests may remain in `interpreter.zig` only
for private helpers such as cell conversion, retain/release primitives, and
destruction-work ordering.

The acceptance matrix is:

| Area | Required evidence |
| --- | --- |
| Load boundary | malformed binary and invalid LLIR are rejected before host callbacks or runtime allocations; a non-v16 input is rejected on magic/version alone; loading decodes exactly one `VmInstr` per record (1:1, order-preserving), and the executed path allocates nothing per instruction |
| Value encoding | canonical scalar bit patterns (bool 0/1, byte high bits zero, 32-bit integers sign-extended to a cell, `float32` high bits zero, full-width `i64`/`u64`/`f64`, NaN payload round-trip), rep-resolved typed `zero`, empty-list all-zero encoding, full-cell transfers, pointer cells validated by registry membership before dereference, null-only-for-empty-list traps, and no 48-bit pointer rejection path |
| Scalars | arithmetic, comparison, the casts, zero/discard (zero read/write), `ret zero`, `copy cond, zero`, and every trap edge — dispatched per rep |
| Comparisons | C-Type comparisons overwrite `cond`; integer opcodes distinguish only signed from unsigned because 32-bit integers are already cell-extended; float width remains explicit; NaN boundaries (`seq` false, `sne` true, `slt`/`sle` false); `copy dst, cond` materialization |
| Frames | direct (`jal ra`) and indirect (`jalr`) calls, positive and negative `offs16`, `jalr` base-plus-offset overflow, non-entry targets, nested-call `ra` save/restore, `j` discarding no link, return to F/T/zero, recursion, self-tailcall preserving `ra`, stack-limit atomicity, dynamic take-contract mismatch and failure atomicity, T0–T15 call-clobber, the O aliases' call-clobber, parity with `MiniVm` |
| Control flow | branches, switch, computed-target success and out-of-range traps |
| Heap values | string constants, concat, list/box/aggregate construction and projection, consuming destructure |
| Lifecycle | every retain site, explicit releases, fused-form equivalence, alias-sensitive replacement, zero live objects after normal fixtures, argument-0 ownership consumed before the result overwrites the result register |
| Destruction | reverse order, dynamic `any`, host opaque/`hostdata`, hook suspension, panic inside a hook |
| Modules | initialize once, nested imports, partial-init trap, reverse slot teardown, no teardown after panic |
| Host boundary | typed argument/result conversion, transfer commit/rollback, duplicate-pointer rejection, cleanup registry exactly once |
| Allocation failure | failure injection proves no partial callee frame or published allocation result, preserves the specified pre-call `slot_*` effects, and terminates without leaks |
| End to end | compile representative source programs, serialize, load, execute, and compare output/termination with golden results |

Opcode completeness is checked mechanically: the dispatch table itself
**is** the guard — it is built from an exhaustive comptime switch over
every tag of the logical `Opcode` enum, so an opcode without a handler
fails the compile (§7). A `comptime {}` assertion additionally pins
representative tag→handler mappings. Maintain at least one semantic test
per handler family. Opcodes not yet emitted from source use hand-built
valid `LlirProgram` fixtures. The typed opcodes are part of the same
mechanical coverage: every 6-rep branch/comparison family (integer-4 +
float-2), every integer-4 family, the casts, the move-wide family, and
the U-type opcodes.

## 13. Implementation milestones

Each milestone leaves `zig build test` green and adds only the state required
by the next one.

1. **Execution skeleton:** validated in-memory program, scalar/control-flow
   opcodes (rep-dispatched), root/direct calls (`jal ra`), the result
   `take`, return, tailcall, traps, and stack limit.
2. **Modules and basic host calls:** module instances/init continuation,
   scalar/string print and panic, normal teardown log.
3. **Heap and counted lifecycle:** object layouts, strings, lists, boxes,
   aggregates, lifecycle instructions, iterative destruction without hooks.
4. **Dynamic destruction and host resources:** `any`, unions, drop-hook
   continuation, opaque/`hostdata`, and the resource registry.
5. **Coverage and integration:** remaining opcodes, `jalr` indirect calls,
   hand-built image cases, binary load path, end-to-end corpus, then CLI
   wiring.

Implemented milestones:

- **M1 — Module identity + binary v11:** `ModuleDesc` carries the resolved
  import specifier (`spec_*` into the strings blob); the binary format
  round-trips it (version 10 → 11); the assembly projection renders it.
- **M2 — Host dispatch + `math`/`string`/`list` bindings:** the default host
  dispatches `(specifier, member)` to per-module adapters and handler
  structs; `math` maps the 20 StdLib §4 functions onto IEEE 754 `f32`;
  `string` implements the 19 StdLib §5 functions with code-point semantics
  and full Unicode default case conversion (`src/unicode_case.zig`);
  `list` provides O(1) `len` and inclusive `range`. Each cons node records
  its suffix length, so `list#len` and `read_index` read it directly.
- **M3 — Opaque host objects (`array`/`hashmap`):** opaque values are heap
  shells registered in the host-resource registry keyed by the shell
  address, so `drop` and panic teardown dispose each object exactly once;
  `host_array.zig`/`host_hashmap.zig` hold the plain-data storage (open
  addressing, linear probing, tombstones, ~70% load resize). The adapters
  own the retain/release contract (`make`/`insert`/`set`/`clone` retain,
  `get` copies out, `remove` transfers, overwrite releases the displaced
  entry); `hashmap` keys mirror `builtin.hash` (Wyhash, seed 0) and `==`
  (str content equality).
- **M5 — CLI `--run` + binary load path:** `stilla --run` executes a
  source file (compile → lower → resolve the entry through the builder's
  `func_ids`) or, for an input starting with the LLIR magic, a
  self-contained binary (readBin → validate → run from the header's entry
  id; the header carries the entry `FunctionId`, binary format v12). Exit
  codes: 0 normal, 1 panic (the owned message — with the trap site, §10 —
  goes to stderr), 2 load/compile error. The `--run` process is probed
  end-to-end from build.zig: stdout cannot run in-process, because fd 1
  is the test-runner's `--listen` protocol pipe under `zig build test`.
- **M6 — End-to-end acceptance corpus:** one golden program per stdlib
  module (`builtin`, `math`, `string`, `list`, `array`, `hashmap`) plus a
  combined multi-module program is compiled, serialized to the LLIR binary
  (header entry resolved through the builder's `func_ids`), read back,
  structurally validated, and executed with an output-capturing host
  adapter; each asserts its golden termination and printed text exactly.
  A coverage guard walks every bundle module's declaration-only `fn`
  members and asserts the default host dispatches each — a declared
  stdlib binding never falls through to `.not_implemented`.
- **M7 — Typed host-binding registry (host-bindings.md):** `HostCall`
  dispatches through a member-table registry (`defaultHostRegistry`);
  `hSyscall` passes a `HostSignature` view (the artifact's signature
  row, resolved once — hosts never touch `TypeId` tables) instead of a
  bare signature index; `host_bind.zig` adds the typed member layer
  (`host_bind.register` over a module struct — `pub const symbol` +
  `pub fn` members; comptime decode/encode glue, module userdata
  injection, reusable `HostScratch` for NUL-terminated C strings). The
  six stdlib modules migrated onto it: members with a plain
  scalar/str signature bind typed (the 20 `math` functions,
  `builtin.print`, the four pure `string` predicates), the rest are
  raw-shaped fns carrying the adapter logic — the per-module member
  dispatch switches and `moduleFromFields` are deleted. The
  pre-registry adapter contract remains as the `invoke` opt-out for
  dynamic hosts (`defaultHostCall` now dispatches through the
  registry).

Do not implement all opcode handlers before the execution skeleton has a real
end-to-end test. Conversely, do not declare completion until mechanical
opcode coverage has no gaps.

## 14. Deferred decisions

The following are intentionally deferred until profiling or a feature request
provides evidence:

- **true direct threading** (per-instruction jump addresses stored in the
  decoded stream, one unconditional jump per instruction) — token-based
  indirect threading is adopted (§1, §7); a true direct-threading follow-up
  stays deferred, gated on measurement;
- flat-array lists and slice views;
- custom slab allocation or packed object layouts;
- debugger metadata, stepping, snapshots, or suspension;
- asynchronous or reentrant host calls;
- JIT compilation, concurrency, exceptions, or cycle collection;
- a stable persistence ABI for LLIR binaries;
- a predecode cache (v10's opcodes are already typed, so a cache would only
  save decode, not re-typing — measure before adding it).

These features must not shape the first public API or add fields to every
runtime object preemptively.

## 15. Files that define the contract

- `Stilla LLIR Specification.md`: program image and frame/call contract
  (the three-cell header, the Itanium-style window overlap, the result `take`).
- `Stilla LLIR Instruction Set.md`: encoding, validation, and opcode
  semantics (the typed opcodes and their reps).
- `Stilla Runtime Specification.md`: observable runtime and host behavior.
- `air.md`: source CFG ownership and drop semantics projected into LLIR.
- `llir.zig`: frozen image records and the logical `Opcode`/`opInfo`/
  `encode`/`decode` tables.
- `llir_validate.zig`: executable load-time structural invariants.
- `frontend_llir_normalize_tests.zig`: current frame-contract model.
- `PLAN.md`: implementation tracking for the loader/interpreter split;
  it is not normative.
