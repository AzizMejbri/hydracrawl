package store

import "core:testing"
import resp "../resp"

@(private)
bulk_value :: proc(s: string) -> resp.Value {
  items := make([]u8, len(s))
  copy(items, transmute([]u8)s)
  return resp.Bulk_String{len = uint(len(s)), items = items}
}

@(test)
test_set_get :: proc(t: ^testing.T) {
  s: Store
  store_init(&s)
  defer store_deinit(&s)

  input := bulk_value("hello")
  set_reply := set(&s, "greeting", input)
  resp.deinit_value(&input)
  resp.deinit_value(&set_reply)

  got := get(&s, "greeting")
  defer resp.deinit_value(&got)
  b, ok := got.(resp.Bulk_String)
  testing.expect(t, ok && !b.is_null && string(b.items) == "hello")

  got2 := get(&s, "greeting")
  defer resp.deinit_value(&got2)
  b2, ok2 := got2.(resp.Bulk_String)
  testing.expect(t, ok2 && string(b2.items) == "hello")
  testing.expect(t, &b.items[0] != &b2.items[0])
}

@(test)
test_missing_keys :: proc(t: ^testing.T) {
  s: Store
  store_init(&s)
  defer store_deinit(&s)

  got := get(&s, "missing")
  defer resp.deinit_value(&got)
  b, ok := got.(resp.Bulk_String)
  testing.expect(t, ok && b.is_null)

  exists_reply := exists(&s, "missing")
  defer resp.deinit_value(&exists_reply)
  e, eok := exists_reply.(resp.Integer)
  testing.expect(t, eok && e.raw == 0)

  ttl_reply := ttl(&s, "missing")
  defer resp.deinit_value(&ttl_reply)
  tv, tok := ttl_reply.(resp.Integer)
  testing.expect(t, tok && tv.raw == -2)

  del_reply := del(&s, "missing")
  defer resp.deinit_value(&del_reply)
  dv, dok := del_reply.(resp.Integer)
  testing.expect(t, dok && dv.raw == 0)
}

@(test)
test_exists_and_del :: proc(t: ^testing.T) {
  s: Store
  store_init(&s)
  defer store_deinit(&s)

  input := bulk_value("value")
  set_reply := set(&s, "key", input)
  resp.deinit_value(&input)
  resp.deinit_value(&set_reply)

  exists_reply := exists(&s, "key")
  defer resp.deinit_value(&exists_reply)
  e, eok := exists_reply.(resp.Integer)
  testing.expect(t, eok && e.raw == 1)

  del_reply := del(&s, "key")
  defer resp.deinit_value(&del_reply)
  d, dok := del_reply.(resp.Integer)
  testing.expect(t, dok && d.raw == 1)

  exists_after := exists(&s, "key")
  defer resp.deinit_value(&exists_after)
  ea, eaok := exists_after.(resp.Integer)
  testing.expect(t, eaok && ea.raw == 0)

  got := get(&s, "key")
  defer resp.deinit_value(&got)
  b, bok := got.(resp.Bulk_String)
  testing.expect(t, bok && b.is_null)
}

@(test)
test_ttl_and_expire :: proc(t: ^testing.T) {
  s: Store
  store_init(&s)
  defer store_deinit(&s)

  input := bulk_value("value")
  set_reply := set(&s, "key", input)
  resp.deinit_value(&input)
  resp.deinit_value(&set_reply)

  ttl_reply := ttl(&s, "key")
  defer resp.deinit_value(&ttl_reply)
  tv, tok := ttl_reply.(resp.Integer)
  testing.expect(t, tok && tv.raw == -1)

  expire_reply := expire(&s, "key", 100)
  defer resp.deinit_value(&expire_reply)
  ev, eok := expire_reply.(resp.Integer)
  testing.expect(t, eok && ev.raw == 1)

  ttl_after := ttl(&s, "key")
  defer resp.deinit_value(&ttl_after)
  ta, taok := ttl_after.(resp.Integer)
  testing.expect(t, taok && ta.raw > 0 && ta.raw <= 100)

  input2 := bulk_value("new")
  set_reply2 := set(&s, "key", input2)
  resp.deinit_value(&input2)
  resp.deinit_value(&set_reply2)

  ttl_cleared := ttl(&s, "key")
  defer resp.deinit_value(&ttl_cleared)
  tc, tcok := ttl_cleared.(resp.Integer)
  testing.expect(t, tcok && tc.raw == -1)

  expire_zero := expire(&s, "key", 0)
  defer resp.deinit_value(&expire_zero)
  ez, ezok := expire_zero.(resp.Integer)
  testing.expect(t, ezok && ez.raw == 1)

  got := get(&s, "key")
  defer resp.deinit_value(&got)
  b, bok := got.(resp.Bulk_String)
  testing.expect(t, bok && b.is_null)

  ttl_expired := ttl(&s, "key")
  defer resp.deinit_value(&ttl_expired)
  tx, txok := ttl_expired.(resp.Integer)
  testing.expect(t, txok && tx.raw == -2)

  expire_missing := expire(&s, "missing", 10)
  defer resp.deinit_value(&expire_missing)
  em, emok := expire_missing.(resp.Integer)
  testing.expect(t, emok && em.raw == 0)
}

@(test)
test_expired_key_is_removed :: proc(t: ^testing.T) {
  s: Store
  store_init(&s)
  defer store_deinit(&s)

  input := bulk_value("value")
  set_reply := set(&s, "key", input)
  resp.deinit_value(&input)
  resp.deinit_value(&set_reply)

  expire_reply := expire(&s, "key", 100)
  resp.deinit_value(&expire_reply)

  s.expiry["key"] = 0

  got := get(&s, "key")
  defer resp.deinit_value(&got)
  b, ok := got.(resp.Bulk_String)
  testing.expect(t, ok && b.is_null)

  ttl_reply := ttl(&s, "key")
  defer resp.deinit_value(&ttl_reply)
  tv, tok := ttl_reply.(resp.Integer)
  testing.expect(t, tok && tv.raw == -2)
}

@(test)
test_incr :: proc(t: ^testing.T) {
  s: Store
  store_init(&s)
  defer store_deinit(&s)

  first := incr(&s, "counter")
  defer resp.deinit_value(&first)
  f, fok := first.(resp.Integer)
  testing.expect(t, fok && f.raw == 1)

  second := incr(&s, "counter")
  defer resp.deinit_value(&second)
  sec, sok := second.(resp.Integer)
  testing.expect(t, sok && sec.raw == 2)

  got := get(&s, "counter")
  defer resp.deinit_value(&got)
  g, gok := got.(resp.Integer)
  testing.expect(t, gok && g.raw == 2)

  input := bulk_value("not an integer")
  set_reply := set(&s, "text", input)
  resp.deinit_value(&input)
  resp.deinit_value(&set_reply)

  wrong := incr(&s, "text")
  defer resp.deinit_value(&wrong)
  werr, wok := wrong.(resp.Error)
  testing.expect(t, wok && string(resp.error_kind(werr)) == "ERR")

  max_set := set(&s, "max", resp.Integer{raw = max(i64)})
  resp.deinit_value(&max_set)

  overflow := incr(&s, "max")
  defer resp.deinit_value(&overflow)
  overr, ook := overflow.(resp.Error)
  testing.expect(t, ook && string(resp.error_kind(overr)) == "ERR")
}

@(test)
test_init_value_deep_copies :: proc(t: ^testing.T) {
  inner := bulk_value("x")
  inner_array := resp.Array{len = 1, items = make([]resp.Value, 1)}
  inner_array.items[0] = inner

  outer := resp.Array{len = 1, items = make([]resp.Value, 1)}
  outer.items[0] = inner_array

  original: resp.Value = outer
  cloned := resp.init_value(original)

  original_array, ok := original.(resp.Array)
  testing.expect(t, ok && len(original_array.items) == 1)

  source_bulk, sok := inner.(resp.Bulk_String)
  testing.expect(t, sok)
  source_bulk.items[0] = 'y'

  cloned_array, cok := cloned.(resp.Array)
  testing.expect(t, cok && len(cloned_array.items) == 1)
  cloned_inner, ciok := cloned_array.items[0].(resp.Array)
  testing.expect(t, ciok && len(cloned_inner.items) == 1)
  cloned_bulk, cbok := cloned_inner.items[0].(resp.Bulk_String)
  testing.expect(t, cbok && string(cloned_bulk.items) == "x")

  resp.deinit_value(&cloned)
  resp.deinit_value(&original)
}
