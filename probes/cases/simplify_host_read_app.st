const sensor = import("sensor");
fn f() -> int32 {
    let unused: int32 = sensor.read();
    0
}
