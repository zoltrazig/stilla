// hashmap — concrete hash table with contiguous bucket storage
// (StdLib §1, §3).
//
// Intrinsic module: every function member is a *declaration without a
// Stilla definition* (the Intrinsics Specification §2), recognized as an
// intrinsic by its standard-library source origin and expanded into
// ordinary AIR during source-to-AIR lowering; each expansion is a call
// to the existing host binding. `HashMap[K, V]` is a host-backed opaque
// nominal type (Core §11.8): it has no fields and no Stilla-visible representation, its
// value is a unique opaque handle naming a host-owned contiguous table,
// and only the module functions construct, read, and transform values.
// Stilla can never raw-construct, field-access, or destructure a
// `HashMap[K, V]` (Core §11.8).
//
// `HashMap[K, V]` is unique by declaration (Core §11.8): it is never Copy,
// even when `K` and `V` are Copy, so `insert`/`remove` take the map by
// `move` and return the updated map and the host may mutate the table in
// place (StdLib §1, §3); `get`/`contains`/`len`/`clone` borrow. Key type
// `K` must be Copy and hashable; value type `V` must be Copy (StdLib §3):
// the plain key/value parameters reject a unique `K`/`V` at compile time,
// so `HashMap[Unique, V]` / `HashMap[K, Unique]` is uninhabited; a
// borrowed unique return is not expressible (Core §10.7), so `get`
// returns `Option[V]` by value. `builtin.hash` provides hashing for the
// primitive key types (Runtime §4.9). Iteration order is unspecified but
// stable within a single execution context.
//
// Type arguments of `empty`/`get`/`contains`/`remove`/`len`/`clone` occur
// only in the token or result type and must be written explicitly
// (`::[K, V]`, Core §12.3); `insert`'s `K` and `V` are inferred from the
// key and value arguments, `remove`'s from the moved map and key.

// `Option` is the `builtin` type member (Core §2.8); `builtin` is imported
// like any other standard-library module (Core §3).
const builtin = import("builtin");
using builtin.Option;

opaque type HashMap[K, V];

fn empty[K, V]() -> HashMap[K, V];
fn insert[K, V](move m: HashMap[K, V], key: K, value: V) -> HashMap[K, V];
fn get[K, V](borrow m: HashMap[K, V], key: K) -> Option[V];
fn contains[K, V](borrow m: HashMap[K, V], key: K) -> bool;
fn remove[K, V](move m: HashMap[K, V], key: K) -> tuple[HashMap[K, V], Option[V]];
fn len[K, V](borrow m: HashMap[K, V]) -> int32;
fn clone[K, V](borrow m: HashMap[K, V]) -> HashMap[K, V];
