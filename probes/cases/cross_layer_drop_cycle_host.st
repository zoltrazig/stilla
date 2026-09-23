// Two host reads on sibling host domains (host(2) / host(3), chosen by
// the embedding) — reused by the cross-layer-cycle reorder fixture below.
fn read(x: int32) -> int32;
fn peek(x: int32) -> int32;
