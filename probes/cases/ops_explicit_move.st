const builtin = import("builtin");
fn wrap(a: int32) -> any { a } // return packs into any
fn sink(move a: any) -> void { let _ = a; }
fn main() -> void {
    let x = 5;
    let y = move x; // a Copy move folds away (air.md §5.4)
    let z = y + y;
    let u = wrap(z); // u: any, unique
    sink(move u); // the unique move survives
    builtin.print(builtin.str(x));
}
