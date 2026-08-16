// hashmap — concrete hash table with contiguous bucket storage
// (StdLib §1, §3).
//
// Host binding module: every function member is a *declaration without a
// Stilla definition* (frontend §5.6); the host implements the storage and
// operations. `HashMap[K, V]` is an ordinary nominal struct (StdLib §3):
// its value is an immutable *token* naming a host-owned opaque table.
// Stilla never inspects the table, and the module functions are its only
// access path (see std/array.st).
//
// Key type `K` and value type `V` must be Copy (StdLib §3); `builtin.hash`
// provides hashing for the primitive key types (Runtime §4.9). Insertion
// and removal are persistent-style: they take the token by plain (Copy)
// parameter and return a *new* map token; the input token remains usable
// and references the previous immutable table, so the map is never
// partially mutated. `get` returns a copy of the value as `Option[V]`.
// Iteration order is unspecified but stable within a single execution
// context.
//
// Type arguments of `empty`/`get`/`contains`/`remove`/`len` occur only in
// the token or result type and must be written explicitly (`::[K, V]`,
// Core §12.3); `insert`'s `K` and `V` are inferred from the key and value
// arguments.

// `Option` is the `builtin` type member (Core §2.8); `builtin` is imported
// like any other standard-library module (Core §3).
const builtin = import("builtin");
using builtin.Option;

struct HashMap[K, V] {}

fn empty[K, V]() -> HashMap[K, V];
fn insert[K, V](m: HashMap[K, V], key: K, value: V) -> HashMap[K, V];
fn get[K, V](m: HashMap[K, V], key: K) -> Option[V];
fn contains[K, V](m: HashMap[K, V], key: K) -> bool;
fn remove[K, V](m: HashMap[K, V], key: K) -> tuple[HashMap[K, V], Option[V]];
fn len[K, V](m: HashMap[K, V]) -> int32;
