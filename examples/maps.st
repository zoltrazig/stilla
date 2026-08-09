// maps — persistent-style hash map operations (StdLib §3).
//
// Insertion and removal are persistent: they consume the input map
// (`move m`) and return a new one, so the map is never partially
// mutated and ownership transfers as a whole. Generic host bindings
// need explicit specialization syntax `::[K, V]` (Core §12.3) when the
// arguments do not determine the type parameters. `remove` returns a
// tuple of the new map and the removed entry as `Option[V]`; `get`
// returns `Option[V]` too, matched here without inspecting the payload.

const builtin = import("builtin");
const hm = import("hashmap");
using builtin.Option;

fn main() -> void {
    // Build a map with two entries. Each step consumes the previous map.
    let m0 = hm.empty::[int32, str]();
    let m1 = hm.insert::[int32, str](m0, 1, "one");
    let m2 = hm.insert::[int32, str](m1, 2, "two");
    builtin.assert(hm.len::[int32, str](m2) == 2, "two entries");

    // remove consumes the map and returns (new map, removed entry).
    let (m3, removed) = hm.remove::[int32, str](m2, 1);
    builtin.assert(hm.len::[int32, str](m3) == 1, "removed one");
    // The payload of `Some` is generic here, so the match only
    // distinguishes presence.
    let removed_some = match (removed) {
        Option::Some(v) => true,
        Option::None => false,
    };
    builtin.assert(removed_some, "removed entry is Some");

    // get returns Option[V]; contains is a bool.
    let found = hm.get::[int32, str](m3, 2);
    let found_some = match (found) {
        Option::Some(v) => true,
        Option::None => false,
    };
    builtin.assert(found_some, "get finds the survivor");
    builtin.assert(hm.contains::[int32, str](m3, 2), "contains");
    builtin.assert(!hm.contains::[int32, str](m3, 1), "absent key");

    // Removing the last entry yields None.
    let (m4, gone) = hm.remove::[int32, str](m3, 2);
    let gone_none = match (gone) {
        Option::Some(v) => false,
        Option::None => true,
    };
    builtin.assert(gone_none, "last removal is None");
    builtin.assert(hm.len::[int32, str](m4) == 0, "empty again");
}
