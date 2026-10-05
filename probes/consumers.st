// consumers — the opt-in effect-driven HIR consumers (hir.md §11)
// reachable from source: dead-let of a discardable scalar call and of a
// discardable Unique constructor, plus selective A-Normal Form hoisting
// of a Unique call result out of a consuming argument and of an
// effectful operand to the right of a pure one. `Loud`'s destructor
// prints, so the consumers-on/off differential pins the destructor's
// position as well as the values; `Quiet`'s destructor only reads, so
// the dead Unique binding is provably discardable and must vanish.

const builtin = import("builtin");

struct Loud {
    id: int32;
    drop(t) { builtin.print(builtin.str(t.id)); }
}

struct Quiet {
    id: int32;
    drop(t) { let x = t.id; }
}

fn make(id: int32) -> Loud { Loud { id: id } }
fn take(move t: Loud) -> int32 { t.id }
fn show(borrow t: Loud) -> int32 { t.id }
fn pure(x: int32) -> int32 { x * 2 }

fn dead_scalar(x: int32) -> int32 {
    let unused: int32 = pure(x);
    x + 1
}

fn dead_unique(id: int32) -> int32 {
    let unused = Quiet { id: id };
    7
}

fn anf_transfer(x: int32) -> int32 {
    take(make(x))
}

fn anf_borrow(x: int32) -> int32 {
    show(make(x))
}

fn anf_ltr(x: int32) -> int32 {
    pure(1) + builtin.hash(x)
}

fn main() -> void {
    builtin.print(builtin.str(dead_scalar(3)));
    builtin.print(builtin.str(dead_unique(4)));
    builtin.print(builtin.str(anf_transfer(5)));
    builtin.print(builtin.str(anf_borrow(6)));
    builtin.print(builtin.str(anf_ltr(7)));
}
