const builtin = import("builtin");
fn f1() -> int64 {
    ((-250826282122) >> ((-196082829395) >> (-25495947749))) + (142791762226)
}
fn f4() -> uint64 {
    ((257500157809) & (249363292281)) * ((123056492540) & (165846480652))
}
fn main() -> void {
    let v1: uint32 = 9;
    let v3: uint64 = 12;
    let v45: int64 = f1();
    let v49: bool = (((v45) << (v45)) > (v45)) or ((((f4()) >> (((v45 as uint64)) >> ((v3) << ((v3) & (f4()))))) > (v3)) and (((v1) + ((v45 as uint32))) >= ((v1) & (v1))));
    builtin.assert(v49 == true, "x");
}
