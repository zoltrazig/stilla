const builtin = import("builtin");
const lists = import("list");
union Result { Ok(str), Err(str) }
fn main() -> void {
    let result = Result::Ok("done");
    let message = match (result) {
        Result::Ok(value) => "ok: " + builtin.str(value),
        Result::Err(error) => "error: " + error
    };
    builtin.print(message);
}
