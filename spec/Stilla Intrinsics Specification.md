# Stilla Intrinsics Specification

> **Version:** v1.3 Draft
>
> This document defines compile-time expansion of standard-library operations
> that have no Stilla implementation. Intrinsics are eliminated while lowering
> source to canonical AIR and do not appear in AIR or LLIR.

# 1. Scope

Most standard-library functions are ordinary Stilla functions. An
**intrinsic** is an implementation-supplied standard-library declaration that
has no Stilla body or initializer and is replaced by ordinary AIR during CFG
lowering.

Intrinsics are not source-language keywords, host bindings, runtime services,
LLIR instructions, or a VM interface. Their observable behavior is defined by
the [Runtime Specification](Stilla%20Runtime%20Specification.md) and the
[Standard Library](Stilla%20Standard%20Library.md).

# 2. Recognition

No source syntax marks a declaration as intrinsic. A declaration is an
intrinsic if and only if:

1. it originates in the implementation-supplied standard-library bundle; and
2. it is a function without a Stilla body or a constant without an initializer.

Its only identity is its existing public `(module, member)` pair.

A bodyless declaration outside the implementation-supplied standard-library
bundle remains a host binding, even if it has the same spelling as a standard
library member. Source origin prevents user or host modules from claiming
intrinsic status.

# 3. Expansion

After type checking and generic specialization, source-to-AIR lowering must
replace every intrinsic use it emits with ordinary typed AIR. For an
intrinsic function used as a first-class value, the frontend synthesizes one
ordinary AIR function for that concrete specialization and uses its function
reference. The synthesized function is an `IrFunc`, not a module member; every
source member use is rewritten directly to its `fn_ref`. A direct call may use
the same function or inline its expansion.

An expansion may:

- materialize a specified constant;
- emit existing AIR operations; or
- emit a call to an ordinary Stilla function with a body or to an existing
  host binding.

Expansion must preserve the declaration's concrete signature, argument
evaluation order, parameter modes, ownership transfers, traps, termination,
and all other observable behavior.

The completed expansion participates in the ordinary optimizer and AIR
validator; no intrinsic-specific effect system is required.

If the frontend has no valid expansion for an intrinsic use that it must emit,
compilation must fail before canonical AIR is produced. It must not defer an
“intrinsic not found” failure to an AIR consumer or execution backend.

# 4. AIR boundary

Intrinsic recognition occurs inside source-to-AIR lowering while the frontend
still has the annotated declaration and its bundle origin. The canonical
in-memory AIR does not carry an intrinsic marker, identity, or temporary
intrinsic `syscall`.

Canonical in-memory AIR contains only ordinary AIR operations, ordinary calls,
and genuine host bindings. It is therefore self-contained and may be
optimized, interpreted, or lowered to LLIR without the source module graph.

# 5. LLIR boundary

LLIR has no intrinsic representation:

- no intrinsic opcode;
- no secondary numeric identity;
- no reserved module or sentinel `ModuleId`;
- no intrinsic descriptor or version; and
- no intrinsic-specific validation or dispatch.

CFG-to-LLIR lowering consumes canonical AIR, in which an intrinsic target is
not representable. Consequently, a VM or native backend implements only the
LLIR instruction set and the existing host-binding contract; it does not
implement standard-library intrinsic dispatch.

# 6. Ownership and failure

An intrinsic introduces no ownership rule. Its declaration determines whether
each argument is copied, borrowed, or moved, and the expanded AIR must obey the
ordinary ownership and lifecycle rules.

Specified traps and `never` termination must remain explicit in the expansion.
The normal AIR and LLIR validators remain the sole validators after expansion.

# 7. Extension

To add an intrinsic, add a bodyless declaration to the implementation standard
library and implement its frontend expansion. Adding one does not change the
LLIR instruction set or image version.

Prefer an ordinary Stilla implementation whenever the operation can be
expressed clearly in Stilla. Prefer existing AIR operations over adding new
ones. Add a new general-purpose AIR/LLIR operation only when the required
capability cannot otherwise be expressed and belongs in the execution model
independently of one standard-library API.

## See also

- [Stilla Standard Library](Stilla%20Standard%20Library.md) — public behavior
- [Stilla AIR Specification](air.md) — canonical expansion output
- [Stilla LLIR Specification](Stilla%20LLIR%20Specification.md) — the
  intrinsic-free backend boundary
- [Stilla Runtime Specification](Stilla%20Runtime%20Specification.md) — traps,
  termination, and host integration
