// hashmap — concrete hash table with contiguous bucket storage
// (StdLib §1, §3).
//
// Host binding module: every function member is a *declaration without a
// Stilla definition* (frontend §5.6); the host implements the storage and
// operations. `HashMap[K, V]` is a concrete implementation type whose value
// is itself a `hostdata` payload (StdLib §6, Core §11.7): Stilla never
// inspects it, and the module functions are its only access path. The
// empty `struct HashMap[K, V]` below is the interface token (see
// std/array.st).
//
// A key type `K` must be duplicable and hashable; `builtin.hash` provides
// hashing for the primitive key types (Runtime §4.11). Insertion and
// removal are persistent-style: they consume the input map and return a new
// map. Because the map is always affine (StdLib §6), ownership transfers as
// a whole and the map is never partially mutated. `get` returns `Option[V]`;
// for affine `V` the payload is borrowed for the lifetime of the operation.
// Iteration order is unspecified but stable within a single execution
// context.

// `Option` is the `builtin` type member (Core §2.8); `builtin` is imported
// like any other standard-library module (Core §3).
const builtin = import("builtin");
using builtin.Option;

struct HashMap[K, V] {}

fn empty[K, V]() -> HashMap[K, V];
fn insert[K, V](move m: HashMap[K, V], move key: K, move value: V) -> HashMap[K, V];
fn get[K, V](move m: HashMap[K, V], key: K) -> Option[V];
fn contains[K, V](move m: HashMap[K, V], key: K) -> bool;
fn remove[K, V](move m: HashMap[K, V], key: K) -> tuple[HashMap[K, V], Option[V]];
fn len[K, V](move m: HashMap[K, V]) -> int32;
