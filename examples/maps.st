// maps — hash map operations over a unique opaque container (StdLib §3).
//
// `HashMap[K, V]` is a host-backed opaque nominal type (Core §11.8): unique
// by declaration, no raw construction, only the module's host bindings
// produce and consume values. `insert`/`remove` consume the input map
// (`move m`) and return the updated map, so the host may mutate the table
// in place and the source semantics stay purely functional. Generic host
// bindings need explicit specialization syntax `::[K, V]` (Core §12.3) when
// the arguments do not determine the type parameters. `remove` returns a
// tuple of the new map and the removed entry as `Option[V]`; `get`
// returns `Option[V]` too, matched here without inspecting the payload.

const builtin = import("builtin");
const hm = import("hashmap");
using builtin.Option;

fn main() -> void {
    // Build a map with two entries. Each step consumes the previous map.
    let m = hm.empty::[int32, str]();
    let m = hm.insert(move m, 1, "one");
    let m = hm.insert(move m, 2, "two");
    builtin.assert(hm.len::[int32, str](m) == 2, "two entries");

    // remove consumes the map and returns (new map, removed entry).
    let (m, removed) = hm.remove::[int32, str](move m, 1);
    builtin.assert(hm.len::[int32, str](m) == 1, "removed one");
    // The payload of `Some` is generic here, so the match only
    // distinguishes presence.
    let removed_some = match (removed) {
        Option::Some(v) => true,
        Option::None => false,
    };
    builtin.assert(removed_some, "removed entry is Some");

    // get returns Option[V]; contains is a bool.
    let found = hm.get::[int32, str](m, 2);
    let found_some = match (found) {
        Option::Some(v) => true,
        Option::None => false,
    };
    builtin.assert(found_some, "get finds the survivor");
    builtin.assert(hm.contains::[int32, str](m, 2), "contains");
    builtin.assert(!hm.contains::[int32, str](m, 1), "absent key");

    // clone gives a second live map with independent storage.
    let m2 = hm.clone::[int32, str](m);
    builtin.assert(hm.len::[int32, str](m2) == 1, "clone duplicates");

    // Removing the last entry yields None.
    let (m3, gone) = hm.remove::[int32, str](move m2, 2);
    let gone_none = match (gone) {
        Option::Some(v) => false,
        Option::None => true,
    };
    builtin.assert(gone_none, "last removal is None");
    builtin.assert(hm.len::[int32, str](m3) == 0, "empty again");
}
